#!/usr/bin/python3
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = REPOSITORY_ROOT / "scripts" / "tunnelpad-remote-forward-helper.py"
SPEC = importlib.util.spec_from_file_location("tunnelpad_remote_forward_helper", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


def listener_line(port, inode):
    return (
        f"0: 0100007F:{port:04X} 00000000:0000 0A "
        f"00000000:00000000 00:00000000 00000000 0 0 {inode} 1\n"
    )


class RemoteForwardHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tunnelpad-helper-")
        self.proc_root = Path(self.temporary.name)
        (self.proc_root / "net").mkdir()
        self.original_proc_root = HELPER.PROC_ROOT
        HELPER.PROC_ROOT = str(self.proc_root)

    def tearDown(self):
        HELPER.PROC_ROOT = self.original_proc_root
        self.temporary.cleanup()

    def write_sockets(self, tcp_lines=(), tcp6_lines=()):
        header = "sl local_address rem_address st tx_queue tr tm->when retrnsmt uid timeout inode\n"
        (self.proc_root / "net" / "tcp").write_text(header + "".join(tcp_lines), encoding="ascii")
        (self.proc_root / "net" / "tcp6").write_text(header + "".join(tcp6_lines), encoding="ascii")

    def add_owner(self, pid, *inodes):
        descriptors = self.proc_root / str(pid) / "fd"
        descriptors.mkdir(parents=True)
        for index, inode in enumerate(inodes):
            os.symlink(f"socket:[{inode}]", descriptors / str(index + 3))

    def run_clean(self, port):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                HELPER.clean(port)
        return stopped.exception.code, json.loads(output.getvalue())

    def test_kills_every_ipv4_and_ipv6_listener_owner(self):
        self.write_sockets(
            tcp_lines=[listener_line(18080, 111), listener_line(18081, 333)],
            tcp6_lines=[listener_line(18080, 222)],
        )
        self.add_owner(101, 111)
        self.add_owner(202, 222)
        sent = []

        with mock.patch.object(HELPER.os, "pidfd_open", side_effect=lambda pid, _flags: pid + 1000, create=True), \
             mock.patch.object(HELPER.signal, "pidfd_send_signal", side_effect=lambda fd, sig, _info, _flags: sent.append((fd, sig)), create=True), \
             mock.patch.object(HELPER.os, "close"):
            exit_code, result = self.run_clean(18080)

        self.assertEqual(exit_code, 0)
        self.assertEqual(result["sanitizedCode"], "listeners_killed")
        self.assertEqual(result["killedCount"], 2)
        self.assertEqual(sent, [(1101, signal.SIGKILL), (1202, signal.SIGKILL)])

    def test_pid_reuse_does_not_signal_replacement_process(self):
        self.write_sockets(tcp_lines=[listener_line(18080, 111)])
        self.add_owner(101, 111)
        sockets = iter(({"111"}, set()))

        with mock.patch.object(HELPER, "pid_socket_inodes", side_effect=lambda _pid: next(sockets)), \
             mock.patch.object(HELPER.os, "pidfd_open", return_value=1101, create=True), \
             mock.patch.object(HELPER.signal, "pidfd_send_signal", create=True) as send_signal, \
             mock.patch.object(HELPER.os, "close"):
            exit_code, result = self.run_clean(18080)

        self.assertEqual(exit_code, 4)
        self.assertEqual(result["sanitizedCode"], "listener_changed")
        send_signal.assert_not_called()


if __name__ == "__main__":
    unittest.main()

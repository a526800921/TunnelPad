#!/usr/bin/python3
"""强制释放一个远端 TCP 监听端口；由 TunnelPad 经 SSH stdin 临时执行。"""

import glob
import json
import os
import signal
import sys

VERSION = 1
PROC_ROOT = "/proc"


def finish(exit_code, category, code, killed=0):
    print(json.dumps({
        "version": VERSION,
        "stage": "remoteCleanup",
        "category": category,
        "retryHint": 0 if exit_code == 0 else 60,
        "sanitizedCode": code,
        "exitCode": exit_code,
        "killedCount": killed,
    }, separators=(",", ":")))
    raise SystemExit(exit_code)


def listener_inodes(port):
    expected = f"{port:04X}"
    found = set()
    for name in ("net/tcp", "net/tcp6"):
        path = os.path.join(PROC_ROOT, name)
        try:
            with open(path, "r", encoding="ascii") as stream:
                next(stream, None)
                for line in stream:
                    fields = line.split()
                    if len(fields) < 10 or fields[3] != "0A":
                        continue
                    local = fields[1]
                    if ":" not in local:
                        continue
                    _, encoded_port = local.rsplit(":", 1)
                    if encoded_port.upper() == expected and fields[9].isdigit():
                        found.add(fields[9])
        except (FileNotFoundError, PermissionError, OSError):
            finish(4, "unknown", "proc_unavailable")
    return found


def pid_socket_inodes(pid):
    found = set()
    for descriptor in glob.glob(os.path.join(PROC_ROOT, str(pid), "fd", "*")):
        try:
            target = os.readlink(descriptor)
        except (FileNotFoundError, PermissionError, OSError):
            continue
        if target.startswith("socket:[") and target.endswith("]"):
            inode = target[8:-1]
            if inode.isdigit():
                found.add(inode)
    return found


def owner_pids(inodes):
    owners = set()
    for process in glob.glob(os.path.join(PROC_ROOT, "[0-9]*")):
        name = os.path.basename(process)
        if not name.isdigit():
            continue
        pid = int(name)
        if pid_socket_inodes(pid) & inodes:
            owners.add(pid)
    return owners


def clean(port):
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        finish(2, "local", "pidfd_unavailable")

    inodes = listener_inodes(port)
    if not inodes:
        finish(0, "success", "listener_absent")

    owners = owner_pids(inodes)
    if not owners:
        finish(4, "unknown", "listener_owner_unknown")

    killed = 0
    for pid in sorted(owners):
        try:
            pidfd = os.pidfd_open(pid, 0)
        except ProcessLookupError:
            continue
        except (PermissionError, OSError):
            finish(4, "unknown", "pidfd_open_failed", killed)
        try:
            # pidfd 消除 PID 复用；信号前仍须确认这个进程继续持有本轮发现的监听 socket。
            current = listener_inodes(port)
            if not current or not (current & inodes & pid_socket_inodes(pid)):
                continue
            try:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL, None, 0)
                killed += 1
            except ProcessLookupError:
                continue
            except (PermissionError, OSError):
                finish(4, "unknown", "pidfd_signal_failed", killed)
        finally:
            os.close(pidfd)

    if killed == 0:
        finish(4, "transient", "listener_changed")
    finish(0, "success", "listeners_killed", killed)


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        finish(2, "local", "cleanup_arguments")
    port = int(sys.argv[1])
    if port < 1 or port > 65535:
        finish(2, "local", "cleanup_arguments")
    clean(port)


if __name__ == "__main__":
    main()

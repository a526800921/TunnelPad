#!/usr/bin/env python3
"""隔离的 owner JSON 能力契约；不调用 launchctl 或任何云资源。"""
import ctypes
import json
import pathlib
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
library = ctypes.CDLL(str(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else
                          root / "rust/target/debug/libtunnelpad_core.dylib"))
library.tp_core_create.argtypes = [ctypes.c_char_p]
library.tp_core_create.restype = ctypes.c_void_p
library.tp_core_command.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
library.tp_core_command.restype = ctypes.c_void_p
library.tp_string_free.argtypes = [ctypes.c_void_p]
library.tp_core_destroy.argtypes = [ctypes.c_void_p]

with tempfile.TemporaryDirectory(prefix="tunnelpad-capability-") as home:
    owner = library.tp_core_create(home.encode())
    assert owner, "隔离 owner 创建失败"
    try:
        pointer = library.tp_core_command(owner, b'{"op":"launchRecoveryCapabilities"}')
        assert pointer, "能力响应为空"
        try:
            response = json.loads(ctypes.string_at(pointer))
        finally:
            library.tp_string_free(pointer)
        assert response.get("ok") is True, "缺少严格启动能力（旧版本的预期失败基线）"
        assert response["result"]["version"] == 1
        assert response["result"]["checkedStart"] is True
        assert response["result"]["deadline"] is True
        print("PASS launchRecoveryCapabilities v1: checkedStart + deadline")
    finally:
        library.tp_core_destroy(owner)

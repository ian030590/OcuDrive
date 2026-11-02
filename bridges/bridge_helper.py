"""Run one selected eye tracker; communicate only with the parent over loopback."""
import argparse
import importlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import socket
import sys
import threading
import time


def resource_root():
    return Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))


def finite_number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def token_matches(value, expected):
    return isinstance(value, str) and secrets.compare_digest(value.encode("utf-8"), expected.encode("utf-8"))


class Bridge:
    def __init__(self, source, port, token, parent_pid=0):
        if not 1024 <= port <= 65535 or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token):
            raise ValueError("Invalid bridge port or session token")
        self.source, self.token, self.parent_pid = source, token, parent_pid
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.2)
        self.destination = ("127.0.0.1", port)
        self.stop = threading.Event()
        self.sequence = 0
        self.gaze_sequence = 0
        self.started_at = time.monotonic()
        self.lock = threading.Lock()

    def send(self, kind, **fields):
        with self.lock:
            self.sequence += 1
            if kind == "gaze":
                self.gaze_sequence += 1
            packet = dict(token=self.token, type=kind, source=self.source,
                          process_id=os.getpid(),
                          sequence=self.gaze_sequence if kind == "gaze" else self.sequence,
                          transport_sequence=self.sequence, bridge_timestamp_us=time.perf_counter_ns() // 1000,
                          **fields)
            try:
                self.socket.sendto(json.dumps(packet, allow_nan=False, separators=(",", ":")).encode(), self.destination)
            except OSError:
                self.stop.set()

    def status(self, state, message, **fields):
        self.send("status", state=state, message=str(message)[:500], **fields)

    def gaze(self, x, y, valid, timestamp_us, **metadata):
        finite = finite_number(x) and finite_number(y)
        timestamp_ok = finite_number(timestamp_us) and timestamp_us >= 0
        valid = bool(valid and finite and timestamp_ok and 0 <= x <= 1 and 0 <= y <= 1)
        reason = "" if valid else "provider_invalid"
        if not finite:
            reason = "missing_or_nonfinite_coordinate"
        elif not timestamp_ok:
            reason = "invalid_source_timestamp"
        elif not 0 <= x <= 1 or not 0 <= y <= 1:
            reason = "outside_screen"
        metadata.setdefault("invalid_reason", reason)
        metadata.setdefault("raw_x", float(x) if finite_number(x) else None)
        metadata.setdefault("raw_y", float(y) if finite_number(y) else None)
        metadata.setdefault("host_timestamp_us", time.perf_counter_ns() // 1000)
        self.send("gaze", x=float(x) if valid else 0.0, y=float(y) if valid else 0.0,
                  valid=valid, source_timestamp_us=int(timestamp_us) if timestamp_ok else None,
                  simulated=False, coordinate_space="screen_normalized", **metadata)

    def controls(self):
        last_alive = 0.0
        while not self.stop.is_set():
            try:
                data, peer = self.socket.recvfrom(4097)
                host_receive_us = time.perf_counter_ns() // 1000
                if peer != self.destination or len(data) > 4096:
                    continue
                message = json.loads(data)
                if isinstance(message, dict) and token_matches(message.get("token"), self.token):
                    if message.get("type") == "stop":
                        self.stop.set()
                    elif message.get("type") == "clock_ping" and finite_number(message.get("godot_ticks_us")):
                        self.send("clock_sync", godot_ticks_us=message["godot_ticks_us"],
                                  host_receive_us=host_receive_us,
                                  host_send_us=time.perf_counter_ns() // 1000)
            except (socket.timeout, UnicodeError, ValueError, RecursionError):
                pass
            except OSError:
                self.stop.set()
            if self.parent_pid and time.monotonic() - last_alive > 1:
                last_alive = time.monotonic()
                if not process_alive(self.parent_pid):
                    self.stop.set()

    def close(self):
        self.stop.set()
        self.socket.close()


def process_alive(pid):
    if sys.platform == "win32":
        import ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        code = ctypes.c_uint32()
        try:
            return bool(kernel.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, choices=("webgazer", "sol", "tobii"))
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--token", required=True)
    parser.add_argument("--parent-pid", type=int, default=0)
    parser.add_argument("--sol-host", default="")
    parser.add_argument("--sol-port", type=int, default=8080)
    parser.add_argument("--sol-mapping", default="")
    parser.add_argument("--no-browser", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv=None):
    options = parse_args(argv)
    bridge = Bridge(options.source, options.port, options.token, options.parent_pid)
    threading.Thread(target=bridge.controls, daemon=True).start()
    bridge.status("loading", "正在載入所選眼動橋接。", control_port=bridge.socket.getsockname()[1])
    failed = False
    try:
        provider = importlib.import_module("bridges.sources." + options.source)
        provider.run(bridge, options)
    except Exception as error:
        failed = True
        bridge.status("error", str(error))
        print(f"{options.source}: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    finally:
        if not failed:
            bridge.status("stopped", "眼動橋接已停止，裝置資源已釋放。")
        bridge.close()
    return 0


if __name__ == "__main__":
    if __package__ in (None, ""):
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    raise SystemExit(main())

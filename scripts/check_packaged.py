"""Exercise frozen providers without opening a camera or recording participant gaze."""
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def loaded_modules(pid):
    class Module(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("module_id", wintypes.DWORD), ("process_id", wintypes.DWORD),
                    ("global_count", wintypes.DWORD), ("process_count", wintypes.DWORD),
                    ("base", ctypes.c_void_p), ("base_size", wintypes.DWORD), ("handle", ctypes.c_void_p),
                    ("name", wintypes.WCHAR * 256), ("path", wintypes.WCHAR * 260)]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel.Module32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Module)]
    kernel.Module32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Module)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    snapshot = kernel.CreateToolhelp32Snapshot(0x18, pid)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    modules = []
    item = Module()
    item.size = ctypes.sizeof(item)
    try:
        valid = kernel.Module32FirstW(snapshot, ctypes.byref(item))
        while valid:
            modules.append(item.path)
            valid = kernel.Module32NextW(snapshot, ctypes.byref(item))
    finally:
        kernel.CloseHandle(snapshot)
    return modules


def main():
    helper = ROOT / "build/bridge/OcuDriveBridge.exe"
    directory = ROOT / ".tmp/packaged-check"
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / "temporary"
    temporary.mkdir(exist_ok=True)
    environment = os.environ.copy()
    environment.update(TEMP=str(temporary), TMP=str(temporary))
    report = {"helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(), "checks": [], "hardware_tested": False}
    for source in ["webgazer", "sol", "tobii"]:
        receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        receiver.bind(("127.0.0.1", 0))
        receiver.settimeout(.4)
        token = secrets.token_hex(32)
        command = [str(helper), "--source", source, "--port", str(receiver.getsockname()[1]), "--token", token,
                   "--parent-pid", str(os.getpid()), "--no-browser"]
        if source == "sol":
            command += ["--sol-host", "192.168.1.10"]
        process = subprocess.Popen(command, cwd=directory, env=environment)
        peer = None
        statuses = []
        modules = []
        clock_ok = False
        child_pid = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                try:
                    packet, address = receiver.recvfrom(16384)
                except socket.timeout:
                    if process.poll() is not None:
                        break
                    continue
                data = json.loads(packet)
                assert data["token"] == token and data["source"] == source
                peer = address
                child_pid = data.get("process_id")
                if data["type"] == "status":
                    statuses.append({"state": data["state"], "message": data["message"]})
                    if source == "webgazer" and data["state"] == "calibrating":
                        modules = loaded_modules(child_pid)
                        receiver.sendto(json.dumps({"token": token, "type": "clock_ping", "godot_ticks_us": 12345}).encode(), peer)
                    if data["state"] == "error":
                        break
                if data["type"] == "clock_sync":
                    clock_ok = data.get("godot_ticks_us") == 12345 and data["host_send_us"] >= data["host_receive_us"]
                    break
            if source == "webgazer":
                assert clock_ok, "Frozen WebGazer bridge failed clock handshake"
                assert not any(any(term in item.lower() for term in ["tobii_stream", "cv2", "numpy", "ganzin"]) for item in modules), "An unselected SDK was loaded"
                assert all(item["state"] != "ready" for item in statuses), "Uncalibrated camera source must not be ready"
            elif source == "sol":
                manifest = json.loads((ROOT / "dist/build-manifest.json").read_text())
                if not manifest["sol_vendor_sdk_included"]:
                    assert any(item["state"] == "error" and "SDK" in item["message"] for item in statuses), "Missing Sol SDK must report a concrete error"
            else:
                assert any(item["state"] in ["ready", "error"] for item in statuses), "Tobii DLL must either initialize or report a device error"
                assert not any("Failed to load" in item["message"] or "DLL load failed" in item["message"] for item in statuses), "Frozen Tobii dependency load failed"
        finally:
            if peer:
                receiver.sendto(json.dumps({"token": token, "type": "stop"}).encode(), peer)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
                raise AssertionError("Frozen helper failed to release after authenticated stop")
            receiver.close()
        report["checks"].append({"source": source, "statuses": statuses, "clock_handshake": clock_ok,
                                 "unselected_native_sdks_absent": not any("tobii_stream" in item.lower() for item in modules) if modules else None,
                                 "native_module_names": [Path(item).name for item in modules], "exit_code": process.returncode})
        print("PASS frozen bridge: " + source, flush=True)
    report["passed"] = True
    (ROOT / ".tmp/packaged-check.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()

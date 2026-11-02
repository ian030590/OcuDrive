"""Build the lazily launched bridge and embed it in one Godot executable."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(command, env=None, timeout=600):
    print(subprocess.list2cmdline([str(item) for item in command]), flush=True)
    result = subprocess.run(command, cwd=ROOT, env=env, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Build command failed ({result.returncode})")


def pyinstaller_environment():
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["PYINSTALLER_CONFIG_DIR"] = str(ROOT / ".tmp" / "pyinstaller-config")
    if importlib.util.find_spec("PyInstaller"):
        return environment
    cache = Path(os.environ.get("LOCALAPPDATA", "")) / "uv" / "cache" / "archive-v0"
    required = {"pyinstaller", "pyinstaller_hooks_contrib", "altgraph", "pefile", "pywin32_ctypes", "packaging", "setuptools"}
    candidates = {}
    if cache.is_dir():
        for folder in cache.iterdir():
            if not folder.is_dir():
                continue
            for info in folder.glob("*.dist-info"):
                name, _, version = info.name.removesuffix(".dist-info").rpartition("-")
                if name.lower() in required:
                    key = tuple(int(part) if part.isdigit() else part for part in re.split(r"[.-]", version))
                    previous = candidates.get(name.lower())
                    if previous is None or key > previous[0]:
                        candidates[name.lower()] = (key, folder)
    if not required.issubset(candidates):
        raise RuntimeError("Install PyInstaller in this Python environment before building. No network install is performed by this script.")
    paths = [str(item[1]) for item in candidates.values()]
    environment["PYTHONPATH"] = os.pathsep.join(paths + [str(ROOT), environment.get("PYTHONPATH", "")])
    return environment


def prepare_offline_template(engine):
    data = bytearray(engine.read_bytes())
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise RuntimeError("The installed Godot engine is not a PE executable")
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    table = optional + optional_size
    sections = [table + index * 40 for index in range(count)]
    if any(data[position:position + 8].rstrip(b"\0") == b"pck" for position in sections):
        return engine
    new_header = table + count * 40
    first_raw = min(struct.unpack_from("<I", data, position + 20)[0] for position in sections if struct.unpack_from("<I", data, position + 20)[0])
    if new_header + 40 > first_raw or any(data[new_header:new_header + 40]):
        raise RuntimeError("No spare PE section-header space. Supply an official Windows export template with --template.")
    alignment = struct.unpack_from("<I", data, optional + 32)[0]
    last_end = max(struct.unpack_from("<I", data, position + 12)[0] + max(8, struct.unpack_from("<I", data, position + 8)[0]) for position in sections)
    address = (last_end + alignment - 1) // alignment * alignment
    # Godot's Windows exporter requires this section and fills its on-disk PCK offset/size.
    struct.pack_into("<8sIIIIIIHHI", data, new_header, b"pck\0\0\0\0\0", 8, address, 0, 0, 0, 0, 0, 0, 0x40000040)
    struct.pack_into("<H", data, pe + 6, count + 1)
    struct.pack_into("<I", data, optional + 56, address + alignment)
    # The rebuilt local copy is unsigned, regardless of the original engine signature.
    directory = optional + (112 if struct.unpack_from("<H", data, optional)[0] == 0x20B else 96)
    struct.pack_into("<II", data, directory + 4 * 8, 0, 0)
    target = ROOT / "build" / "godot-offline-template.exe"
    target.write_bytes(data)
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT_EXE", r"C:\Program Files\Godot\Godot_v4.7.1-stable_win64.exe"))
    parser.add_argument("--template", help="Official Windows x86_64 release export template; defaults to installed engine as a larger offline fallback")
    parser.add_argument("--require-sol", action="store_true", help="Refuse a build without the vendor Ganzin SDK")
    parser.add_argument("--skip-bridge", action="store_true")
    args = parser.parse_args()
    engine = Path(args.godot).resolve()
    template = Path(args.template).resolve() if args.template else engine
    if not engine.is_file() or not template.is_file():
        raise RuntimeError("Godot engine/export template path does not exist")
    for folder in ["build", "dist", ".tmp", "godot/embedded"]:
        (ROOT / folder).mkdir(parents=True, exist_ok=True)
    if not args.template:
        template = prepare_offline_template(engine)
    sol_present = importlib.util.find_spec("ganzin") is not None
    if args.require_sol and not sol_present:
        raise RuntimeError("Missing Ganzin Sol SDK. Install the original SDK wheel using a supported Python version; no complete-Sol release was produced.")
    capabilities = {"webgazer_bridge": True, "tobii_bridge": True, "sol_bridge": True,
                    "sol_vendor_sdk_included": sol_present, "sol_aruco_available": sol_present and importlib.util.find_spec("cv2") is not None,
                    "engine": str(engine.name), "official_export_template": bool(args.template),
                    "python_version": sys.version.split()[0], "version": "0.1.0"}
    if not args.skip_bridge:
        command = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--onefile", "--noconsole", "--name", "OcuDriveBridge",
                   "--distpath", "build/bridge", "--workpath", "build/pyinstaller", "--specpath", "build",
                   "--paths", str(ROOT), "--hidden-import", "bridges.sources.webgazer", "--hidden-import", "bridges.sources.tobii",
                   "--hidden-import", "bridges.sources.sol", "--add-data", f"{ROOT / 'bridges/web'};web",
                   "--add-binary", f"{ROOT / 'bridges/native/tobii_stream_engine.dll'};native"]
        for module in ["cv2", "numpy"] if sol_present else []:
            if importlib.util.find_spec(module):
                command += ["--hidden-import", module]
        if sol_present:
            command += ["--collect-all", "ganzin", "--collect-all", "av", "--collect-all", "websockets"]
        command.append(str(ROOT / "bridges/bridge_helper.py"))
        run(command, pyinstaller_environment())
        shutil.copyfile(ROOT / "build/bridge/OcuDriveBridge.exe", ROOT / "godot/embedded/bridge_helper.bin")
    helper = ROOT / "godot/embedded/bridge_helper.bin"
    if not helper.is_file():
        raise RuntimeError("Bridge binary is missing")
    (helper.with_suffix(".sha256")).write_text(hashlib.sha256(helper.read_bytes()).hexdigest(), encoding="ascii")
    (ROOT / "godot/embedded/capabilities.json").write_text(json.dumps(capabilities, indent=2), encoding="utf-8")
    shutil.copyfile(ROOT / "LICENSE", ROOT / "godot/embedded/LICENSE.txt")
    shutil.copyfile(ROOT / "bridges/THIRD_PARTY.md", ROOT / "godot/embedded/THIRD_PARTY.txt")
    config_path = ROOT / "godot/export_presets.cfg"
    original = config_path.read_text(encoding="utf-8")
    configured = re.sub(r'custom_template/release="[^"]*"', 'custom_template/release="' + template.as_posix() + '"', original)
    config_path.write_text(configured, encoding="utf-8")
    try:
        run([engine, "--headless", "--path", ROOT / "godot", "--log-file", ROOT / ".tmp/export-import.log", "--editor", "--import"])
        run([engine, "--headless", "--path", ROOT / "godot", "--log-file", ROOT / ".tmp/export.log", "--export-release", "Windows Desktop", ROOT / "dist/OcuDrive.exe"])
    finally:
        config_path.write_text(original, encoding="utf-8")
    target = ROOT / "dist/OcuDrive.exe"
    export_log = (ROOT / ".tmp/export.log").read_text(encoding="utf-8", errors="replace")
    if not target.is_file() or target.stat().st_size <= template.stat().st_size or "Project export failed" in export_log or "SCRIPT ERROR" in export_log:
        raise RuntimeError("Godot export did not produce a valid embedded executable; inspect .tmp/export.log")
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (ROOT / "dist/OcuDrive.exe.sha256").write_text(digest + "  OcuDrive.exe\n", encoding="ascii")
    capabilities.update(executable_sha256=digest, executable_bytes=target.stat().st_size,
                        bridge_sha256=hashlib.sha256(helper.read_bytes()).hexdigest())
    (ROOT / "dist/build-manifest.json").write_text(json.dumps(capabilities, indent=2), encoding="utf-8")
    print(json.dumps(capabilities, indent=2))
    if not sol_present:
        print("LIMITATION: Sol bridge is included, but Ganzin vendor SDK is unavailable. This build cannot connect a real Sol device.")


if __name__ == "__main__":
    main()

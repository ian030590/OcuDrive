"""Run focused offline checks and preserve evidence independently of GUI exit codes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT_EXE", r"C:\Program Files\Godot\Godot_v4.7.1-stable_win64.exe"))
    parser.add_argument("--gui", action="store_true")
    args = parser.parse_args()
    output = ROOT / ".tmp" / "verification"
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["OCUDRIVE_DATA_DIR"] = str(output / "data")
    checks = []

    def check(name, command, marker, timeout=40, working=ROOT, log=None):
        result = subprocess.run([str(item) for item in command], cwd=working, env=environment, timeout=timeout,
                                capture_output=True, text=True, encoding="utf-8", errors="replace")
        transcript = result.stdout + result.stderr
        if log and log.is_file():
            transcript += log.read_text(encoding="utf-8", errors="replace")
        passed = marker in transcript and "SCRIPT ERROR" not in transcript and "FAIL:" not in transcript and "Parse Error" not in transcript
        (output / f"{name}.txt").write_text(transcript, encoding="utf-8")
        checks.append({"name": name, "passed": passed, "exit_code": result.returncode,
                       "evidence": str(output / f"{name}.txt"), "marker": marker})
        print(("PASS " if passed else "FAIL ") + name, flush=True)

    check("bridges", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_bridges.py", "-v"], "\nOK")
    check("browser-discovery", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_browser_discovery.py", "-v"], "\nOK")
    tests = [("tff", "../tests/test_tff.gd", "TFF PASS:"),
             ("world", "res://tests/test_driving_world.gd", "PASS driving world:"),
             ("recorder", "res://tests/test_session_recorder.gd", "RECORDER PASS:"),
             ("bridge-manager", "res://tests/test_bridge_manager.gd", "BRIDGE_MANAGER PASS:"),
             ("frame-alignment", "res://tests/test_frame_alignment.gd", "FRAME_ALIGNMENT PASS:"),
             ("ui", "res://tests/test_main_ui.gd", "PASS main UI:")]
    for name, script, marker in tests:
        log = output / f"{name}.log"
        command = [args.godot, "--path", ROOT / "godot", "--log-file", log, "--quit-after", "1800", "--script", script]
        if not args.gui or name != "ui":
            command.insert(1, "--headless")
        check(name, command, marker, log=log)
    executable = ROOT / "dist" / "OcuDrive.exe"
    if executable.is_file():
        independent = output / "independent-directory"
        independent.mkdir(exist_ok=True)
        log = output / "standalone.log"
        smoke_result = output / "standalone.json"
        check("standalone", [executable, "--headless", "--log-file", log, "--", "--smoke-run", "--smoke-output", smoke_result], "OCUDRIVE_SMOKE", working=independent, log=log)
        if smoke_result.is_file():
            smoke = json.loads(smoke_result.read_text(encoding="utf-8"))
            checks[-1]["passed"] = checks[-1]["passed"] and smoke["saved"] and smoke["events"] >= 5 and smoke["gaze_samples"] == 0 and smoke["vehicle_samples"] > 1000
        else:
            checks[-1]["passed"] = False
        log = output / "packaged-host.log"
        check("packaged-host", [executable, "--headless", "--log-file", log, "--quit-after", "1800", "--script", ROOT / "tests/test_packaged_host.gd"], "PACKAGED_HOST PASS:", working=independent, log=log)
    report = {"checks": checks, "passed": all(item["passed"] for item in checks),
              "hardware_tested": False, "certificate_store_warning": "Godot cannot read the system certificate store inside the current sandbox",
              "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest() if executable.is_file() else None}
    (ROOT / ".tmp/verification.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()

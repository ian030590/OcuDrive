"""Repeatable local security checks; this is not an online CVE assessment."""
import argparse
import ast
import datetime as dt
import hashlib
import http.client
import json
import mmap
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from bridges.bridge_helper import Bridge
from bridges.local_ui import LocalUI


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def check(name, passed, evidence):
    return {"name": name, "status": "PASS" if passed else "FAIL", "evidence": evidence}


def source_files():
    for folder in ("bridges", "scripts", "godot", "tests"):
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and path.suffix in {".py", ".gd", ".js", ".json", ".cfg", ".tscn", ".md"}:
                if any(part in {"__pycache__", ".godot", "embedded"} for part in path.relative_to(ROOT).parts):
                    continue
                if path.name == "webgazer.js" or "model.json" in path.name:
                    continue
                yield path


def scan_sources():
    findings, reviewed, count = [], [], 0
    secrets_patterns = [re.compile(pattern) for pattern in (
        r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        r"\bAKIA[A-Z0-9]{16}\b", r"\bgh[pousr]_[A-Za-z0-9]{32,}\b", r"\bsk-[A-Za-z0-9_-]{30,}\b")]
    sensitive_calls = {"eval", "exec", "os.system", "pickle.load", "pickle.loads", "marshal.loads"}
    for path in source_files():
        count += 1
        relative = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8-sig", errors="replace")
        for line, value in enumerate(text.splitlines(), 1):
            if any(pattern.search(value) for pattern in secrets_patterns):
                findings.append({"path": relative, "line": line, "issue": "Secret-like literal; value deliberately omitted"})
        if path.suffix != ".py":
            continue
        try:
            tree = ast.parse(text)
        except SyntaxError as error:
            findings.append({"path": relative, "line": error.lineno, "issue": "Python parse failed"})
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            name = ast.unparse(node.func)
            if name in sensitive_calls:
                findings.append({"path": relative, "line": node.lineno, "issue": "Unsafe execution/deserialization sink: " + name})
            if name.startswith("subprocess.") and name.rsplit(".", 1)[-1] in {"Popen", "run", "call", "check_call", "check_output"}:
                shell = next((item.value for item in node.keywords if item.arg == "shell"), None)
                if shell is not None and not (isinstance(shell, ast.Constant) and shell.value is False):
                    findings.append({"path": relative, "line": node.lineno, "issue": "Shell execution enabled or variable"})
                else:
                    reviewed.append({"path": relative, "line": node.lineno, "sink": name,
                                     "reason": "Argument-vector launch, no shell; caller supplies local build/test/browser or fixed Defender executable"})
            if name.endswith((".CDLL", ".WinDLL")):
                expression = ast.unparse(node.args[0]) if node.args else ""
                safe = (relative == "bridges/sources/tobii.py" and expression == "str(path.resolve())") or (
                    name.endswith(".WinDLL") and expression in {"'kernel32'", "'kernel32.dll'"})
                (reviewed if safe else findings).append({"path": relative, "line": node.lineno,
                    "sink": name, "reason" if safe else "issue": "Resolved bundled Tobii path or Windows KnownDLL" if safe else "Unreviewed native DLL path"})
            if name.endswith(".bind") and node.args:
                binding = ast.unparse(node.args[0])
                if "'0.0.0.0'" in binding or "'::'" in binding or "''" in binding:
                    findings.append({"path": relative, "line": node.lineno, "issue": "Non-loopback socket binding"})
            if name in {"yaml.load", "yaml.unsafe_load", "tempfile.mktemp"}:
                findings.append({"path": relative, "line": node.lineno, "issue": "Unsafe parser/temp path sink: " + name})
    source = (ROOT / "bridges/sources/tobii.py").read_text(encoding="utf-8")
    dll_fixed = 'resource_root() / "native" / "tobii_stream_engine.dll"' in source and "C.CDLL(str(path.resolve()))" in source
    return [check("first_party_ast_and_secret_literals", not findings,
                  {"files_scanned": count, "findings": findings, "reviewed_sinks": reviewed}),
            check("native_sdk_load_path", dll_fixed, "Tobii loads only bundled native/tobii_stream_engine.dll via resolved absolute path; kernel32 uses Windows KnownDLL name")]


def http_attacks():
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(("127.0.0.1", 0))
    token = os.urandom(32).hex()
    bridge = Bridge("sol", receiver.getsockname()[1], token)
    ui = LocalUI(bridge, "sol", on_post=lambda path, data: {"ok": True})
    ui.start(no_browser=True)
    results, held = [], []

    def request(method, path, body=None, cookie=True, origin=None, token_header=True, host=None, content_type="application/json"):
        connection = http.client.HTTPConnection("127.0.0.1", ui.server.server_port, timeout=3)
        headers = {"Content-Type": content_type}
        if cookie:
            headers["Cookie"] = "ocudrive_session=" + token
        if token_header:
            headers["X-OcuDrive-Token"] = token
        if origin:
            headers["Origin"] = origin
        if host:
            headers["Host"] = host
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            data, status = response.read(), response.status
            return status, dict(response.getheaders()), data
        finally:
            connection.close()

    try:
        cases = [
            ("missing_cookie", ("GET", "/api/config"), {"cookie": False}, 403),
            ("host_rebinding", ("GET", "/api/config"), {"host": "evil.example"}, 403),
            ("cross_origin_post", ("POST", "/api/stop", "{}"), {"origin": "https://evil.example"}, 403),
            ("missing_origin", ("POST", "/api/stop", "{}"), {}, 403),
            ("missing_csrf_token", ("POST", "/api/stop", "{}"), {"origin": ui.origin, "token_header": False}, 403),
            ("non_json_post", ("POST", "/api/anything", "{}"), {"origin": ui.origin, "content_type": "text/plain"}, 415),
            ("malformed_json", ("POST", "/api/anything", "{"), {"origin": ui.origin}, 400),
            ("bounded_nested_json_does_not_crash_handler", ("POST", "/api/anything", '{"a":' * 1500 + "0" + "}" * 1500), {"origin": ui.origin}, 200),
            ("json_array", ("POST", "/api/anything", "[]"), {"origin": ui.origin}, 400),
            ("body_size_limit", ("POST", "/api/anything", "a" * 16385), {"origin": ui.origin}, 413),
            ("cross_origin_preflight", ("OPTIONS", "/api/anything"), {"origin": "https://evil.example"}, 403),
        ]
        for name, args, keywords, expected in cases:
            actual = request(*args, **keywords)[0]
            results.append(check(name, actual == expected, {"expected": expected, "actual": actual}))
        paths = ["/../native/tobii_stream_engine.dll", "/%2e%2e/native/tobii_stream_engine.dll", "/webgazer.js", "/.git/config", "/api/scene.jpg/../../bridge_helper.py", "/C:/Windows/win.ini", "/..\\native\\tobii_stream_engine.dll"]
        path_results = {path: request("GET", path)[0] for path in paths}
        results.append(check("fixed_static_path_allowlist", all(status == 404 for status in path_results.values()), path_results))
        actual, headers, _ = request("GET", "/session/" + token, cookie=False)
        bootstrap_ok = actual == 303 and headers.get("Location") == "/" and "HttpOnly" in headers.get("Set-Cookie", "") and "SameSite=Strict" in headers.get("Set-Cookie", "")
        results.append(check("bootstrap_cookie_and_relative_redirect", bootstrap_ok, "303 to /; cookie HttpOnly and SameSite=Strict; token value omitted"))
        actual, headers, _ = request("GET", "/api/config")
        safe_headers = headers.get("X-Content-Type-Options") == "nosniff" and headers.get("Cache-Control") == "no-store" and "frame-ancestors 'none'" in headers.get("Content-Security-Policy", "")
        results.append(check("authenticated_ui_and_security_headers", actual == 200 and safe_headers,
                             {key: headers.get(key) for key in ("Cache-Control", "X-Content-Type-Options", "Referrer-Policy", "Content-Security-Policy")}))
        duplicate = socket.create_connection(("127.0.0.1", ui.server.server_port), timeout=2)
        duplicate.sendall(("GET /api/config HTTP/1.1\r\nHost: " + ui.origin[7:] + "\r\nHost: evil.example\r\nCookie: ocudrive_session=" + token + "\r\n\r\n").encode())
        reply = duplicate.recv(1024)
        duplicate.close()
        results.append(check("duplicate_host_rejected", reply.startswith(b"HTTP/1.1 403"), "Raw duplicate Host request rejected with 403"))
        for _ in range(20):
            connection = socket.create_connection(("127.0.0.1", ui.server.server_port), timeout=1)
            connection.settimeout(.1)
            held.append(connection)
        time.sleep(.1)
        active = 12 - ui.server.slots._value
        rejected = 0
        for connection in held:
            try:
                if connection.recv(1) == b"":
                    rejected += 1
            except (ConnectionResetError, ConnectionAbortedError):
                rejected += 1
            except socket.timeout:
                pass
        for connection in held:
            connection.close()
        held.clear()
        time.sleep(.1)
        recovered = request("GET", "/api/config")[0] == 200
        results.append(check("connection_bound_and_recovery", 1 <= active <= 12 and rejected >= 1 and recovered,
                             {"active_handlers": active, "handler_limit": 12, "excess_connections_rejected": rejected, "authenticated_request_after_release": recovered, "socket_read_timeout_seconds": 2}))
        results.append(check("loopback_bind", ui.server.server_address[0] == "127.0.0.1" and bridge.socket.getsockname()[0] == "127.0.0.1", "HTTP and UDP sockets bind only 127.0.0.1"))
    finally:
        for connection in held:
            connection.close()
        ui.close()
        bridge.close()
        receiver.close()
    return results


def pck_entries(data):
    if data[-4:] != b"GDPC":
        raise ValueError("No Godot embedded PCK footer")
    start = len(data) - 12 - struct.unpack_from("<Q", data, len(data) - 12)[0]
    if data[start:start + 4] != b"GDPC" or struct.unpack_from("<I", data, start + 4)[0] != 4:
        raise ValueError("Security scanner currently supports Godot PCK format 4")
    flags = struct.unpack_from("<I", data, start + 20)[0]
    if flags & 1:
        raise ValueError("Encrypted PCK directory cannot be inspected")
    base = start + struct.unpack_from("<Q", data, start + 24)[0]
    cursor = start + struct.unpack_from("<Q", data, start + 32)[0]
    count = struct.unpack_from("<I", data, cursor)[0]
    cursor += 4
    if count > 100000:
        raise ValueError("PCK directory size exceeds safety limit")
    entries = []
    for _ in range(count):
        length = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        if length > 4096:
            raise ValueError("PCK path too long")
        name = data[cursor:cursor + length].rstrip(b"\0").decode("utf-8")
        cursor += length
        offset, size = struct.unpack_from("<QQ", data, cursor)
        cursor += 36
        if base + offset + size > len(data):
            raise ValueError("PCK member outside executable bounds")
        entries.append((name, base + offset, size))
    return entries


def carchive_entries(data):
    cookie = data.rfind(b"MEI\014\013\012\013\016")
    if cookie < 0:
        raise ValueError("No PyInstaller CArchive cookie")
    _, length, toc_offset, toc_size, version, library = struct.unpack_from("!8sIIII64s", data, cookie)
    start = cookie + 88 - length
    cursor, end = start + toc_offset, start + toc_offset + toc_size
    if not 0 <= cursor <= end <= len(data):
        raise ValueError("CArchive directory outside executable bounds")
    names = []
    while cursor < end:
        size = struct.unpack_from("!I", data, cursor)[0]
        if size < 18 or cursor + size > end:
            raise ValueError("Invalid CArchive directory entry")
        names.append(data[cursor + 18:cursor + size].rstrip(b"\0").decode("utf-8"))
        cursor += size
    return names


def package_checks():
    results, artifacts = [], {}
    bad_path = re.compile(r"(^|/)(references|tests|\.tmp|\.git|\.aws|\.env|credentials|sessions?|Data)(/|$)|Sol_SDK_Tutorial|\.pdf$", re.I)
    for relative in ("build/bridge/OcuDriveBridge.exe", "dist/OcuDrive.exe"):
        path = ROOT / relative
        if not path.is_file():
            results.append({"name": "package_" + relative, "status": "NOT_RUN", "evidence": "Artifact not available yet"})
            continue
        digest = sha256(path)
        artifacts[relative] = {"sha256": digest, "bytes": path.stat().st_size}
        with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            if relative.startswith("build/"):
                names = carchive_entries(data)
            else:
                entries = pck_entries(data)
                names = [item[0] for item in entries]
                helper = next((item for item in entries if item[0] == "embedded/bridge_helper.bin"), None)
                if helper:
                    embedded_digest = hashlib.sha256(data[helper[1]:helper[1] + helper[2]]).hexdigest()
                    expected = artifacts.get("build/bridge/OcuDriveBridge.exe", {}).get("sha256")
                    results.append(check("embedded_helper_matches_scanned_helper", embedded_digest == expected, {"embedded_sha256": embedded_digest, "helper_sha256": expected}))
            exposed = [name for name in names if bad_path.search(name.replace("\\", "/"))]
            results.append(check("package_directory_" + relative, not exposed,
                                 {"member_count": len(names), "unexpected_sensitive_members": exposed, "members": names}))
    return results, artifacts


def defender_scan(artifacts):
    candidates = [Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "Microsoft/Windows Defender/Platform/CurrentVersion/MpCmdRun.exe",
                  Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Windows Defender/MpCmdRun.exe"]
    executable = next((path for path in candidates if path.is_file()), None)
    if not executable:
        return [{"name": "windows_defender", "status": "NOT_RUN", "evidence": "Defender CLI unavailable without privilege changes"}]
    results = []
    for relative in artifacts:
        target = ROOT / relative
        try:
            process = subprocess.run([str(executable), "-Scan", "-ScanType", "3", "-File", str(target), "-DisableRemediation"],
                                     capture_output=True, text=True, errors="replace", timeout=180)
            output = (process.stdout + process.stderr).strip()
            passed = process.returncode == 0 and "found no threats" in output.lower()
            results.append(check("defender_" + relative, passed, {"exit_code": process.returncode, "output": output,
                                 "sha256": sha256(target), "remediation_disabled": True}))
        except (OSError, subprocess.TimeoutExpired) as error:
            results.append({"name": "defender_" + relative, "status": "NOT_RUN", "evidence": str(error)})
    return results


def write_report(report):
    target = ROOT / ".tmp/security-scan.json"
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# 本機資安弱掃紀錄", "", "執行時間（UTC）：" + report["timestamp_utc"], "", 
             "這是本專案原始碼、自己啟動的loopback服務與實際執行檔的離線檢查。未下載CVE資料庫，不能解釋為已通過相依套件CVE評估或第三方滲透測試。", "", "## 檢查結果", ""]
    for item in report["checks"]:
        evidence = item["evidence"]
        if isinstance(evidence, dict):
            evidence = json.dumps({key: value for key, value in evidence.items() if key not in {"members", "reviewed_sinks"}}, ensure_ascii=False)
        lines.append(f"- {item['status']} `{item['name']}`：{evidence}")
    lines += ["", "## 掃描的實際產物", ""]
    for name, artifact in report["artifacts"].items():
        lines.append(f"- `{name}`：{artifact['bytes']} bytes，SHA-256 `{artifact['sha256']}`。")
    lines += ["", "## 無法驗證與保留限制", "",
              "- 未取得完整Ganzin原廠SDK，不能評估其依賴、網路實作或Sol實機安全性。套件metadata必須保持SDK未內含的標記。",
              "- 未以真實相機、Tobii、Sol及不同螢幕DPI進行精度與完整生命週期驗收。瀏覽器推論fixture只證明控制流程。",
              "- WebGazer及其TensorFlow/model vendor bundle保留原始碼與授權，但本次未完成線上CVE比對；CSP的unsafe-eval用於該本機vendor runtime，connect-src仍限self。",
              "- loopback憑證防止其他網站直接呼叫；不承諾防禦已取得本機使用者權限的惡意程序。session URL含短期token，量測紀錄不得保存該URL與token。",
              "- Defender結果只適用上述hash與當時的本機引擎/定義；不表示檔案簽章或供應鏈認證。",
              "", "## 重跑", "", "`python scripts/security_scan.py --defender`", "",
              "完整逐項HTTP結果、套件目錄與人工審閱的AST sink清單位於 `.tmp/security-scan.json`。重建產物後應重跑，新的報告會以新hash取代舊結果。", ""]
    (ROOT / "docs/security-review.md").write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--defender", action="store_true", help="Scan current artifacts without remediation or changing system settings")
    args = parser.parse_args()
    checks = scan_sources()
    checks += http_attacks()
    package_results, artifacts = package_checks()
    checks += package_results
    if args.defender:
        checks += defender_scan(artifacts)
    else:
        checks.append({"name": "windows_defender", "status": "NOT_RUN", "evidence": "Use --defender for artifact scan"})
    report = {"timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "checks": checks, "artifacts": artifacts,
              "online_cve_database_used": False}
    write_report(report)
    failures = [item["name"] for item in checks if item["status"] == "FAIL"]
    print(json.dumps({"checks": len(checks), "failed": failures, "artifacts": artifacts,
                      "report": "docs/security-review.md", "evidence": ".tmp/security-scan.json"}, indent=2))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())

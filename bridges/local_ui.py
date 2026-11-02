"""Token-authenticated loopback UI shared by camera-based providers."""
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit

from bridges.bridge_helper import resource_root, token_matches


class BoundedHTTPServer(ThreadingHTTPServer):
    request_queue_size = 8

    def __init__(self, *args):
        self.slots = threading.BoundedSemaphore(12)
        super().__init__(*args)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class LocalUI:
    def __init__(self, bridge, mode, on_post=None, snapshot=None):
        self.bridge, self.mode = bridge, mode
        self.on_post, self.snapshot = on_post, snapshot
        self.browser = None
        self.profile = None
        self.config = {"mode": mode, "token": bridge.token}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def log_message(self, *args):
                pass

            def answer(self, status, body=b"", content_type="text/plain; charset=utf-8", cookie=None):
                self.close_connection = True
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("Cross-Origin-Resource-Policy", "same-origin")
                self.send_header("Permissions-Policy", "camera=(self), microphone=(), geolocation=()")
                self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-eval'; connect-src 'self'; img-src 'self' blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:; frame-ancestors 'none'; object-src 'none'; base-uri 'none'")
                if cookie:
                    self.send_header("Set-Cookie", cookie)
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def host_ok(self):
                return self.headers.get_all("Host", []) == [owner.origin.removeprefix("http://")]

            def authenticated(self):
                if not self.host_ok():
                    return False
                cookie = SimpleCookie()
                try:
                    cookie.load(self.headers.get("Cookie", ""))
                    value = cookie.get("ocudrive_session")
                    return bool(value and token_matches(value.value, owner.bridge.token))
                except Exception:
                    return False

            def do_GET(self):
                path = urlsplit(self.path).path
                if not self.host_ok():
                    return self.answer(403)
                if path.startswith("/session/") and token_matches(path[9:], owner.bridge.token):
                    self.close_connection = True
                    self.send_response(303)
                    self.send_header("Location", "/")
                    self.send_header("Set-Cookie", f"ocudrive_session={owner.bridge.token}; HttpOnly; SameSite=Strict; Path=/")
                    self.send_header("Content-Length", "0")
                    self.send_header("Connection", "close")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.end_headers()
                    return
                if not self.authenticated():
                    return self.answer(403)
                if path == "/api/config":
                    return self.answer(200, json.dumps(owner.config, ensure_ascii=False).encode(), "application/json")
                if path == "/api/scene.jpg" and owner.snapshot:
                    frame = owner.snapshot()
                    return self.answer(200 if frame else 503, frame or b"No scene frame", "image/jpeg" if frame else "text/plain")
                names = {"/": ("index.html", "text/html; charset=utf-8"),
                         "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                         "/app.css": ("app.css", "text/css; charset=utf-8")}
                if owner.mode == "webgazer":
                    names.update({"/" + name: (name, mime) for name, mime in [
                        ("webgazer.js", "text/javascript"),
                        ("webgazer-blazeface-model.json", "application/json"),
                        ("webgazer-blazeface-weights.bin", "application/octet-stream"),
                        ("webgazer-facemesh-model.json", "application/json"),
                        ("webgazer-facemesh-weights.bin", "application/octet-stream")]})
                if path not in names:
                    return self.answer(404)
                name, mime = names[path]
                try:
                    return self.answer(200, (resource_root() / "web" / name).read_bytes(), mime)
                except OSError:
                    return self.answer(503, b"Missing bundled asset; rebuild OcuDrive")

            def do_POST(self):
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 1 <= length <= 16384:
                        return self.answer(413)
                    body = self.rfile.read(length)
                except (ValueError, TimeoutError):
                    return self.answer(400)
                if not self.authenticated() or self.headers.get("Origin") != owner.origin:
                    return self.answer(403)
                if not token_matches(self.headers.get("X-OcuDrive-Token", ""), owner.bridge.token):
                    return self.answer(403)
                if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                    return self.answer(415)
                try:
                    self.connection.settimeout(2)
                    data = json.loads(body)
                    if not isinstance(data, dict):
                        raise ValueError("JSON object required")
                    if self.path == "/api/stop":
                        owner.bridge.stop.set()
                        result = {"ok": True}
                    elif owner.on_post:
                        result = owner.on_post(self.path, data)
                    else:
                        return self.answer(404)
                    self.answer(200, json.dumps(result or {"ok": True}, allow_nan=False).encode(), "application/json")
                except (ValueError, TypeError, KeyError, TimeoutError, RecursionError) as error:
                    self.answer(400, str(error).encode())

            def do_OPTIONS(self):
                self.answer(403)

        self.server = BoundedHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def start(self, no_browser=False):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        url = self.origin + "/session/" + self.bridge.token
        self.bridge.status("calibrating", "請在校正視窗完成設定，再返回 OcuDrive。", calibration_url=url)
        if not no_browser:
            self.open_browser(url)
        return url

    def open_browser(self, url):
        executable = find_browser()
        if not executable:
            raise RuntimeError("找不到 Microsoft Edge、Google Chrome 或 Brave。請安裝其中一個瀏覽器後使用相機眼動橋接。")
        self.profile = Path(tempfile.mkdtemp(prefix="ocudrive-camera-"))
        self.browser = subprocess.Popen([str(executable), "--app=" + url,
            "--user-data-dir=" + str(self.profile), "--no-first-run", "--no-default-browser-check",
            "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
            "--disable-backgrounding-occluded-windows", "--window-size=1280,800"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def wait(self):
        while not self.bridge.stop.wait(0.3):
            if self.browser and self.browser.poll() is not None:
                self.bridge.stop.set()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        if self.browser and self.browser.poll() is None:
            if sys.platform == "win32":
                taskkill = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "taskkill.exe"
                subprocess.run([str(taskkill), "/PID", str(self.browser.pid), "/T", "/F"],
                               capture_output=True, creationflags=0x08000000, timeout=10)
            else:
                self.browser.terminate()
                self.browser.wait(timeout=5)
        if self.profile and self.profile.parent == Path(tempfile.gettempdir()) and self.profile.name.startswith("ocudrive-camera-"):
            shutil.rmtree(self.profile, ignore_errors=True)


def find_browser():
    candidates = []
    if sys.platform == "win32":
        import winreg
        for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
            for browser in ("msedge.exe", "chrome.exe", "brave.exe"):
                try:
                    with winreg.OpenKey(hive, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\" + browser) as key:
                        candidates.append(Path(winreg.QueryValueEx(key, None)[0]))
                except OSError:
                    pass
        for directory in (os.environ.get("PROGRAMFILES", ""), os.environ.get("PROGRAMFILES(X86)", ""), os.environ.get("LOCALAPPDATA", "")):
            if directory:
                candidates += [Path(directory) / "Microsoft/Edge/Application/msedge.exe", Path(directory) / "Google/Chrome/Application/chrome.exe",
                               Path(directory) / "BraveSoftware/Brave-Browser/Application/brave.exe"]
    if sys.platform != "win32":
        for name in ("msedge", "google-chrome", "chromium", "chromium-browser"):
            found = shutil.which(name)
            if found:
                candidates.append(Path(found))
    return next((path for path in candidates if path.is_file()), None)

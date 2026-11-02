import ctypes
import http.client
import importlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import unittest

from bridges.bridge_helper import Bridge, finite_number, token_matches
from bridges.local_ui import LocalUI
from bridges.sources.sol import DEFAULT_MAPPING, load_mapping, marker_homography, validate_host
from bridges.sources.tobii import NativeGaze

TOKEN = "a" * 64


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.receiver.bind(("127.0.0.1", 0))
        self.receiver.settimeout(2)
        self.bridge = Bridge("webgazer", self.receiver.getsockname()[1], TOKEN)

    def tearDown(self):
        self.bridge.close()
        self.receiver.close()

    def packet(self):
        return json.loads(self.receiver.recv(16384))

    def test_invalid_samples_stay_invalid_and_nan_is_never_json(self):
        self.bridge.gaze(float("nan"), .5, True, 1234)
        sample = self.packet()
        self.assertEqual(sample["x"], 0.0)
        self.assertIsNone(sample["raw_x"])
        self.assertFalse(sample["valid"])
        self.assertEqual(sample["source_timestamp_us"], 1234)
        self.assertGreater(sample["host_timestamp_us"], 0)
        self.bridge.gaze(1.2, .5, True, 1235)
        self.assertFalse(self.packet()["valid"])
        self.bridge.gaze(.1, .5, True, 1236)
        self.assertTrue(self.packet()["valid"])

    def test_status_and_clock_do_not_consume_gaze_sequence(self):
        self.bridge.gaze(.5, .5, True, 1)
        first = self.packet()
        self.bridge.status("ready", "ready")
        self.packet()
        self.bridge.send("clock_sync", godot_ticks_us=1)
        self.packet()
        self.bridge.gaze(.5, .5, True, 2)
        second = self.packet()
        self.assertEqual(second["sequence"], first["sequence"] + 1)
        self.assertEqual(second["transport_sequence"], first["transport_sequence"] + 3)

    def test_boolean_is_not_a_numeric_coordinate(self):
        self.assertFalse(finite_number(True))
        self.assertFalse(token_matches("中文", TOKEN))

    def test_stop_requires_token_and_exact_parent_socket(self):
        thread = threading.Thread(target=self.bridge.controls, daemon=True)
        thread.start()
        destination = self.bridge.socket.getsockname()
        self.receiver.sendto(json.dumps({"token": "中文", "type": "stop"}).encode(), destination)
        time.sleep(.05)
        self.assertFalse(self.bridge.stop.is_set())
        self.receiver.sendto(json.dumps({"token": TOKEN, "type": "stop"}).encode(), destination)
        thread.join(1)
        self.assertTrue(self.bridge.stop.is_set())

    def test_clock_sync_echoes_parent_clock_and_monotonic_host_clock(self):
        thread = threading.Thread(target=self.bridge.controls, daemon=True)
        thread.start()
        self.receiver.sendto(json.dumps({"token": TOKEN, "type": "clock_ping", "godot_ticks_us": 123456}).encode(), self.bridge.socket.getsockname())
        result = self.packet()
        self.assertEqual(result["type"], "clock_sync")
        self.assertEqual(result["godot_ticks_us"], 123456)
        self.assertGreaterEqual(result["host_send_us"], result["host_receive_us"])

    def test_tobii_matches_ocutrain_native_abi(self):
        self.assertEqual(ctypes.sizeof(NativeGaze), 24)
        self.assertEqual(NativeGaze.timestamp_us.offset, 0)
        self.assertEqual(NativeGaze.validity.offset, 8)
        self.assertEqual(NativeGaze.x.offset, 12)
        self.assertEqual(NativeGaze.y.offset, 16)

    def test_provider_sdk_modules_are_not_eagerly_imported(self):
        code = "import bridges.bridge_helper,sys; assert not any(x.startswith(('cv2','numpy','ganzin')) for x in sys.modules)"
        subprocess.run([sys.executable, "-c", code], check=True, cwd=Path(__file__).resolve().parent.parent)


class HttpSecurityTests(unittest.TestCase):
    def setUp(self):
        self.receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.receiver.bind(("127.0.0.1", 0))
        self.bridge = Bridge("sol", self.receiver.getsockname()[1], TOKEN)
        self.ui = LocalUI(self.bridge, "sol", on_post=lambda p, d: {"ok": True})
        self.ui.start(no_browser=True)

    def tearDown(self):
        self.ui.close()
        self.bridge.close()
        self.receiver.close()

    def request(self, method, path, body=None, authenticated=True, origin=None, host=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.ui.server.server_port, timeout=3)
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers.update({"Cookie": "ocudrive_session=" + TOKEN, "X-OcuDrive-Token": TOKEN})
        if origin:
            headers["Origin"] = origin
        if host:
            headers["Host"] = host
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        status, payload, result_headers = response.status, response.read(), dict(response.getheaders())
        connection.close()
        return status, payload, result_headers

    def test_config_requires_session_cookie_and_host(self):
        self.assertEqual(self.request("GET", "/api/config", authenticated=False)[0], 403)
        self.assertEqual(self.request("GET", "/api/config", host="attacker.example")[0], 403)
        self.assertEqual(self.request("GET", "/api/config")[0], 200)

    def test_cross_origin_and_no_origin_mutations_are_denied(self):
        self.assertEqual(self.request("POST", "/api/stop", "{}", origin="https://attacker.example")[0], 403)
        self.assertEqual(self.request("POST", "/api/stop", "{}")[0], 403)
        self.assertFalse(self.bridge.stop.is_set())
        self.assertEqual(self.request("POST", "/api/stop", "{}", origin=self.ui.origin)[0], 200)

    def test_body_limits_and_path_allowlist(self):
        self.assertEqual(self.request("POST", "/api/anything", "a" * 16385, origin=self.ui.origin)[0], 413)
        self.assertEqual(self.request("GET", "/../native/tobii_stream_engine.dll")[0], 404)
        self.assertEqual(self.request("GET", "/webgazer.js")[0], 404)

    def test_bootstrap_sets_httponly_same_site_and_never_redirects_externally(self):
        status, _, headers = self.request("GET", "/session/" + TOKEN, authenticated=False)
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/")
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        self.assertIn("SameSite=Strict", headers["Set-Cookie"])


class SolMappingTests(unittest.TestCase):
    def test_endpoint_is_private_and_mapping_cannot_be_static(self):
        self.assertEqual(validate_host("192.168.1.10"), "192.168.1.10")
        self.assertEqual(validate_host("sol-phone.local"), "sol-phone.local")
        for host in ("127.0.0.1", "8.8.8.8", "0.0.0.0", "169.254.169.254", "http://phone", "a.local/path"):
            with self.assertRaises(ValueError):
                validate_host(host)
        self.assertEqual(load_mapping()["method"], "live_marker_centers")

    def test_four_generated_markers_map_screen_and_loss_invalidates(self):
        try:
            import cv2
            import numpy as np
        except ImportError:
            self.skipTest("OpenCV/NumPy optional Sol runtime not installed")
        detector = cv2.aruco.ArucoDetector(cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50))
        image = np.full((1000, 1400), 255, dtype=np.uint8)
        origins = [(20, 20), (1212, 20), (1212, 812), (20, 812)]
        root = Path(__file__).resolve().parent.parent
        for marker, (x, y) in enumerate(origins):
            tile = cv2.imread(str(root / "godot" / "markers" / f"marker_{marker}.png"), cv2.IMREAD_GRAYSCALE)
            image[y:y + 168, x:x + 168] = tile
        transform = marker_homography(image, cv2, np, detector, DEFAULT_MAPPING["screen_points"])
        self.assertIsNotNone(transform)
        mapped = cv2.perspectiveTransform(np.asarray([[[700, 500]]], dtype=np.float32), transform)[0, 0]
        self.assertAlmostEqual(float(mapped[0]), .5, places=2)
        self.assertAlmostEqual(float(mapped[1]), .5, places=2)
        image[20:188, 20:188] = 255
        self.assertIsNone(marker_homography(image, cv2, np, detector, DEFAULT_MAPPING["screen_points"]))


@unittest.skipUnless(os.environ.get("PLAYWRIGHT_MODULE"), "Set PLAYWRIGHT_MODULE for browser UI check")
class CalibrationBrowserTests(unittest.TestCase):
    def test_nine_point_calibration_five_point_validation_and_stop(self):
        receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        receiver.bind(("127.0.0.1", 0))
        bridge = Bridge("webgazer", receiver.getsockname()[1], TOKEN)
        from bridges.sources import webgazer
        from unittest.mock import patch
        options = type("Options", (), {"no_browser": True})()
        captured = []
        original_start = LocalUI.start

        def capture_start(ui, no_browser=False):
            captured.append(ui)
            return original_start(ui, no_browser=True)

        with patch.object(LocalUI, "start", capture_start):
            thread = threading.Thread(target=webgazer.run, args=(bridge, options), daemon=True)
            thread.start()
            deadline = time.monotonic() + 3
            while not captured and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(captured)
            url = captured[0].origin + "/session/" + TOKEN
            script = r'''
const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE);
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_BROWSER});
 const page=await browser.newPage({viewport:{width:1280,height:800}}); const errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/webgazer.js', route=>route.fulfill({contentType:'text/javascript',body:`
 let trained=0;window.testRecordings=0;window.testEnded=false;
 const tracker={positionsTimestamp:0,getPositions:()=>[1]};
 window.webgazer={showPredictionPoints(){return this},showVideo(){return this},showFaceOverlay(){return this},showFaceFeedbackBox(){return this},async begin(){},removeMouseEventListeners(){},pause(){},async clearData(){trained=0},recordScreenPosition(){trained++;window.testRecordings++},getTracker(){return tracker},async getCurrentPrediction(){tracker.positionsTimestamp=performance.now();if(!trained)return null;const r=document.getElementById('target').getBoundingClientRect();return {x:r.x+r.width/2+2,y:r.y+r.height/2+2,t:performance.now()}},end(){window.testEnded=true}};`}));
 await page.goto(process.env.CALIBRATION_URL);
 await page.getByRole('button',{name:'開啟相機並開始九點校正'}).click();
 await page.waitForSelector('#stage:not([hidden])');
 for(let point=0;point<9;point++){
   await page.waitForTimeout(450);
   for(let repeat=0;repeat<5;repeat++){
     await page.locator('#target').click();await page.waitForTimeout(175);
   }
 }
 assert.equal(await page.evaluate(()=>window.testRecordings),45);
 await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('校正完成'),null,{timeout:20000});
 assert.equal(await page.locator('#reset').isEnabled(),true);
 await page.getByRole('button',{name:'停止追蹤並關閉相機'}).click();
 assert.equal(await page.evaluate(()=>window.testEnded),true);
 assert.deepEqual(errors,[]);
 console.log(JSON.stringify({calibration_points:9,recordings:45,validation_points:5,camera_released:true,page_errors:errors}));
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
'''
            environment = dict(os.environ, CALIBRATION_URL=url)
            try:
                result = subprocess.run(["node", "-e", script], env=environment, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                print(result.stdout.strip())
            finally:
                bridge.stop.set()
                thread.join(3)
                bridge.close()
                receiver.close()


if __name__ == "__main__":
    unittest.main()

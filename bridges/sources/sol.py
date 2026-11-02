"""Ganzin Sol SDK gaze + scene stream with live ArUco screen remapping."""
import importlib
import ipaddress
import json
from pathlib import Path
import socket
import threading
import time

from bridges.bridge_helper import finite_number
from bridges.local_ui import LocalUI

DEFAULT_MAPPING = {"version": 1, "dictionary": "DICT_4X4_50", "marker_ids": [0, 1, 2, 3],
                   "screen_points": [[.04, .04], [.96, .04], [.96, .96], [.04, .96]],
                   "method": "live_marker_centers", "static_homography_allowed": False}


def validate_host(host):
    if not host or len(host) > 253 or any(ch in host for ch in "/\\:@\r\n\t "):
        raise ValueError("請輸入 Chronus 手機的私人網路 IPv4 位址或 .local 主機名稱。")
    try:
        address = ipaddress.ip_address(host)
        if address.version != 4 or not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast or address.is_link_local:
            raise ValueError("Sol 僅允許私人區域網路 IPv4 位址。")
    except ValueError:
        if not host.endswith(".local") or not all(char.isascii() and (char.isalnum() or char in "-.") for char in host):
            raise ValueError("Sol 主機必須是私人網路 IPv4 或有效的 .local 主機名稱。")
    return host


def load_mapping(path=""):
    mapping = json.loads(Path(path).read_text(encoding="utf-8")) if path else DEFAULT_MAPPING.copy()
    if not isinstance(mapping, dict) or mapping.get("version") != 1 or mapping.get("dictionary") != "DICT_4X4_50":
        raise ValueError("Sol 標記配置格式不符。")
    if mapping.get("marker_ids") != [0, 1, 2, 3] or mapping.get("method") != "live_marker_centers":
        raise ValueError("Sol 必須使用四角 IDs 0、1、2、3 的即時映射。")
    points = mapping.get("screen_points")
    if points != DEFAULT_MAPPING["screen_points"]:
        raise ValueError("此版本固定四角標記中心為 (.04,.04)、(.96,.04)、(.96,.96)、(.04,.96)。")
    return DEFAULT_MAPPING.copy()


def resolve_host(host):
    validate_host(host)
    addresses = {item[4][0] for item in socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)}
    if not addresses:
        raise ValueError("Sol 手機主機名稱無法解析。")
    for address in addresses:
        validate_host(address)
    return sorted(addresses)[0]


def timestamp_of(sample):
    method = getattr(sample, "get_timestamp", None)
    value = method() if callable(method) else getattr(sample, "timestamp", None)
    if not finite_number(value) or value < 0:
        raise ValueError("Sol SDK 未提供有效微秒時間戳，無法安全同步場景與視線。")
    return int(value)


def marker_homography(image, cv2, np, detector, screen_points):
    corners, ids, _ = detector.detectMarkers(image)
    if ids is None or len(ids) != 4 or set(ids.flatten().tolist()) != {0, 1, 2, 3}:
        return None
    centers = {int(marker_id): np.asarray(corner, dtype=np.float32).reshape(4, 2).mean(axis=0)
               for corner, marker_id in zip(corners, ids.flatten())}
    source = np.asarray([centers[i] for i in range(4)], dtype=np.float32)
    polygon = source.reshape(-1, 1, 2)
    if not cv2.isContourConvex(polygon) or cv2.contourArea(polygon) < image.shape[0] * image.shape[1] * .01:
        return None
    transform = cv2.getPerspectiveTransform(source, np.asarray(screen_points, dtype=np.float32))
    return transform if np.isfinite(transform).all() and abs(np.linalg.det(transform)) > 1e-15 else None


def run(bridge, options):
    host = resolve_host(options.sol_host)
    if not 1 <= options.sol_port <= 65535:
        raise ValueError("Sol 連線埠必須介於1與65535。")
    mapping = load_mapping(options.sol_mapping)
    try:
        sync_module = importlib.import_module("ganzin.sol_sdk.synchronous.sync_client")
        models = importlib.import_module("ganzin.sol_sdk.synchronous.models")
    except ImportError as error:
        raise RuntimeError("未內含 Ganzin Sol SDK。請由 Chronus Remote Browser 取得原廠 Python 3.12 SDK wheel，依 BUILD.md 加入套件後重建。此處不會使用模擬資料替代。") from error
    try:
        cv2, np = importlib.import_module("cv2"), importlib.import_module("numpy")
    except ImportError as error:
        raise RuntimeError("Sol 即時螢幕映射需要隨附 OpenCV ArUco 與 NumPy。請建立包含 Sol 依賴的完整套件。") from error
    if not hasattr(cv2, "aruco"):
        raise RuntimeError("OpenCV 缺少 ArUco 模組，無法執行安全的 Sol 螢幕映射。")
    detector = cv2.aruco.ArucoDetector(cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50))
    state = {"transform": None, "frame_us": None, "received": 0.0, "jpeg": None,
             "mapped": False, "error": None, "clock_offset_us": None}
    lock = threading.Lock()

    def post(path, data):
        if path == "/api/mapping/export":
            return {"ok": True, "mapping": mapping}
        if path == "/api/mapping/verify":
            with lock:
                valid = state["transform"] is not None and time.monotonic() - state["received"] <= .25
            return {"ok": valid, "message": "四角即時映射已確認。" if valid else "四個標記尚未同時可見。請返回 OcuDrive 全螢幕畫面確認四角標記。靜態配置不能代替即時映射。"}
        raise ValueError("Unknown endpoint")

    def snapshot():
        with lock:
            return state["jpeg"]

    ui = LocalUI(bridge, "sol", on_post=post, snapshot=snapshot)
    client, stream_thread = None, None

    def video_worker():
        last_preview = 0.0
        while not bridge.stop.is_set():
            try:
                frames = client.get_video_frames_from_streaming(timeout=.5)
                if not frames:
                    continue
                frame = frames[-1]
                buffer = frame.get_buffer()
                stamp = timestamp_of(frame)
                now = time.monotonic()
                transform = marker_homography(buffer, cv2, np, detector, mapping["screen_points"])
                jpeg = None
                if now - last_preview > .5:
                    resized = cv2.resize(buffer, (664, 600))
                    ok, encoded = cv2.imencode(".jpg", resized, [cv2.IMWRITE_JPEG_QUALITY, 65])
                    if ok:
                        jpeg = bytes(encoded)
                    last_preview = now
                with lock:
                    state.update(transform=transform, frame_us=stamp, received=now)
                    if jpeg:
                        state["jpeg"] = jpeg
                    mapped = transform is not None
                    changed = state["mapped"] != mapped
                    state["mapped"] = mapped
                if changed:
                    bridge.status("ready" if mapped else "disconnected",
                        "Sol 四角即時映射已建立。Chronus 校正仍需由使用者確認。" if mapped else "Sol 四角標記缺失，注視座標已判無效。請讓全部標記重新進入場景相機。",
                        calibration="external_chronus", mapping_method="live_aruco")
            except TimeoutError:
                with lock:
                    state["transform"] = None
                    was_mapped = state["mapped"]
                    state["mapped"] = False
                if was_mapped:
                    bridge.status("disconnected", "Sol 場景逾時，四角映射已清除。")
            except Exception as error:
                with lock:
                    state["error"] = str(error)
                    state["transform"] = None
                bridge.stop.set()

    try:
        client = sync_module.SyncClient(host, options.sol_port)
        stream_thread = client.create_streaming_thread(models.StreamingMode.GAZE_SCENE)
        stream_thread.daemon = True
        stream_thread.start()
        bridge.status("calibrating", "Sol 已開啟RTSP串流，等待場景、視線與四角標記。", calibration="external_chronus")
        threading.Thread(target=video_worker, daemon=True).start()
        ui.start(options.no_browser)
        last_stamp, stale_at = -1, 0.0
        while not bridge.stop.is_set():
            if ui.browser and ui.browser.poll() is not None:
                break
            try:
                gazes = client.get_gazes_from_streaming(timeout=.5)
            except TimeoutError:
                if time.monotonic() - stale_at > 2:
                    bridge.status("disconnected", "Sol 尚未傳回視線。請檢查Chronus遠端預覽與私人網路。")
                    stale_at = time.monotonic()
                continue
            if not gazes:
                continue
            newest_stamp = timestamp_of(gazes[-1])
            arrival = time.perf_counter_ns() // 1000
            with lock:
                offset = arrival - newest_stamp
                previous = state["clock_offset_us"]
                state["clock_offset_us"] = min(offset, previous) if previous is not None else offset
                transform, frame_us, received = state["transform"], state["frame_us"], state["received"]
                host_offset = state["clock_offset_us"]
            for gaze in gazes:
                stamp = timestamp_of(gaze)
                if stamp <= last_stamp:
                    continue
                last_stamp = stamp
                point = gaze.combined_gaze_2d
                gx, gy = point.x, point.y
                valid = (finite_number(gx) and finite_number(gy) and gx >= 0 and gy >= 0 and
                         transform is not None and frame_us is not None and abs(stamp - frame_us) <= 100000 and
                         time.monotonic() - received <= .25)
                x, y = None, None
                if valid:
                    mapped = cv2.perspectiveTransform(np.asarray([[[gx, gy]]], dtype=np.float32), transform)[0, 0]
                    x, y = float(mapped[0]), float(mapped[1])
                bridge.gaze(x, y, valid, stamp, scene_x_px=float(gx) if finite_number(gx) else None,
                            scene_y_px=float(gy) if finite_number(gy) else None,
                            frame_source_timestamp_us=frame_us, mapping_valid=bool(valid),
                            mapping_method="live_aruco", clock_domain="sol_microseconds",
                            host_timestamp_us=int(stamp + host_offset), clock_sync="minimum_arrival_offset_estimate")
        if state["error"]:
            raise RuntimeError("Sol 場景處理失敗：" + state["error"])
    finally:
        bridge.stop.set()
        if client:
            for name in ("stop_streaming", "close"):
                method = getattr(client, name, None)
                if callable(method):
                    try:
                        method()
                    except Exception:
                        pass
        ui.close()

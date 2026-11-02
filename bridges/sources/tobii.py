"""Tobii Stream Engine ABI used by OcuTrain, without simulated samples."""
import ctypes as C
from pathlib import Path
import time

from bridges.bridge_helper import resource_root


class NativeGaze(C.Structure):
    _fields_ = [("timestamp_us", C.c_int64), ("validity", C.c_int32),
                ("x", C.c_float), ("y", C.c_float)]


def run(bridge, options):
    path = resource_root() / "native" / "tobii_stream_engine.dll"
    if not path.is_file():
        raise RuntimeError("缺少隨附 Tobii Stream Engine DLL，請重新建立完整套件。")
    sdk = C.CDLL(str(path.resolve()))
    handle = C.c_void_p
    url_callback = C.CFUNCTYPE(None, C.c_char_p, handle)
    gaze_callback = C.CFUNCTYPE(None, C.POINTER(NativeGaze), handle)
    signatures = {
        "tobii_api_create": [C.POINTER(handle), handle, handle],
        "tobii_api_destroy": [handle],
        "tobii_enumerate_local_device_urls": [handle, url_callback, handle],
        "tobii_device_create": [handle, C.c_char_p, C.c_int32, C.POINTER(handle)],
        "tobii_device_destroy": [handle],
        "tobii_gaze_point_subscribe": [handle, gaze_callback, handle],
        "tobii_gaze_point_unsubscribe": [handle],
        "tobii_wait_for_callbacks": [C.c_int32, C.POINTER(handle)],
        "tobii_device_process_callbacks": [handle],
        "tobii_system_clock": [handle, C.POINTER(C.c_int64)],
        "tobii_update_timesync": [handle],
    }
    for name, arguments in signatures.items():
        function = getattr(sdk, name)
        function.argtypes, function.restype = arguments, C.c_int32

    def check(code, operation):
        if code:
            raise RuntimeError(f"Tobii {operation} 失敗，SDK錯誤碼 {code}。請確認 Tobii Experience 與裝置連線。")

    api, device = handle(), handle()
    urls, subscribed = [], False

    @url_callback
    def collect_url(url, context):
        if url:
            urls.append(bytes(url))

    @gaze_callback
    def collect_gaze(pointer, context):
        sample = pointer.contents
        # The SDK clock mapping preserves device timing; it does not assume 60 Hz.
        bridge.gaze(sample.x, sample.y, sample.validity == 1, sample.timestamp_us,
                    clock_domain="tobii_system_clock", clock_offset_us=clock_offset[0],
                    host_timestamp_us=sample.timestamp_us + clock_offset[0])

    clock_offset = [0]
    try:
        check(sdk.tobii_api_create(C.byref(api), None, None), "API初始化")
        if not api:
            raise RuntimeError("Tobii API未提供有效handle。")
        check(sdk.tobii_enumerate_local_device_urls(api, collect_url, None), "搜尋裝置")
        if not urls:
            raise RuntimeError("未找到 Tobii Eye Tracker 5。請先安裝並啟動 Tobii Experience，完成同一螢幕校正。")
        check(sdk.tobii_device_create(api, urls[0], 1, C.byref(device)), "建立裝置")
        if not device:
            raise RuntimeError("Tobii未提供有效device handle。")
        check(sdk.tobii_update_timesync(device), "同步時鐘")
        sdk_clock = C.c_int64()
        before = time.perf_counter_ns() // 1000
        check(sdk.tobii_system_clock(api, C.byref(sdk_clock)), "取得時鐘")
        clock_offset[0] = (before + time.perf_counter_ns() // 1000) // 2 - sdk_clock.value
        check(sdk.tobii_gaze_point_subscribe(device, collect_gaze, None), "訂閱視線")
        subscribed = True
        bridge.status("ready", "Tobii 已連線。請確認已在 Tobii Experience 校正本次訓練螢幕。",
                      calibration="external_tobii_experience", clock_domain="tobii_system_clock")
        synced_at = time.monotonic()
        while not bridge.stop.is_set():
            code = sdk.tobii_wait_for_callbacks(1, C.byref(device))
            if code != 6:
                check(code, "等待樣本")
                check(sdk.tobii_device_process_callbacks(device), "處理樣本")
            if time.monotonic() - synced_at > 30:
                check(sdk.tobii_update_timesync(device), "同步時鐘")
                synced_at = time.monotonic()
    finally:
        if subscribed:
            sdk.tobii_gaze_point_unsubscribe(device)
        if device:
            sdk.tobii_device_destroy(device)
        if api:
            sdk.tobii_api_destroy(api)

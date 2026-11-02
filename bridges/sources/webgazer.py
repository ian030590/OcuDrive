import math
import time

from bridges.bridge_helper import finite_number
from bridges.local_ui import LocalUI


def run(bridge, options):
    state = {"calibrated": False, "last_sample": time.monotonic(), "last_timestamp": -1, "clock_offset_us": None}

    def post(path, data):
        if path == "/api/calibration":
            errors = data.get("errors_px")
            width, height = data.get("width"), data.get("height")
            counts = data.get("validation_counts")
            if not isinstance(errors, list) or len(errors) != 5 or not all(finite_number(x) and 0 <= x <= 10000 for x in errors):
                raise ValueError("Five measured validation errors required")
            if not finite_number(width) or not finite_number(height) or min(width, height) < 480:
                raise ValueError("Full-screen calibration geometry required")
            if not isinstance(counts, list) or len(counts) != 5 or any(not finite_number(x) or x < 10 for x in counts):
                raise ValueError("At least ten measured samples per validation target required")
            mean_error = sum(errors) / 5
            if mean_error > min(width, height) * 0.15 or max(errors) > min(width, height) * 0.25:
                state["calibrated"] = False
                bridge.status("calibrating", "WebGazer 驗證誤差過大，請調整光線與頭部位置後重做九點校正。")
                return {"ok": False, "mean_error_px": mean_error}
            state["calibrated"] = True
            bridge.status("ready", "WebGazer 九點校正與五點驗證完成。請保持頭位，返回 OcuDrive。",
                          calibration={"method": "nine_point_five_validation", "width_css_px": width,
                                       "height_css_px": height, "errors_px": errors, "counts": counts,
                                       "mean_error_px": mean_error, "dpr": data.get("dpr", 1)})
            return {"ok": True, "mean_error_px": mean_error}
        if path == "/api/reset":
            state["calibrated"] = False
            bridge.status("calibrating", "正在重新校正 WebGazer。")
            return {"ok": True}
        if path == "/api/gaze":
            samples = data.get("samples")
            if not isinstance(samples, list) or len(samples) > 64:
                raise ValueError("Maximum 64 gaze samples per batch")
            sent = data.get("sent_timestamp_us")
            if finite_number(sent):
                offset = time.perf_counter_ns() // 1000 - sent
                previous = state["clock_offset_us"]
                state["clock_offset_us"] = min(offset, previous) if previous is not None else offset
            for sample in samples:
                if not isinstance(sample, dict):
                    raise ValueError("Invalid sample")
                stamp = sample.get("timestamp_us")
                if not finite_number(stamp) or stamp <= state["last_timestamp"]:
                    continue
                state["last_timestamp"] = stamp
                state["last_sample"] = time.monotonic()
                x, y = sample.get("x"), sample.get("y")
                valid = sample.get("valid") is True and state["calibrated"]
                bridge.gaze(x, y, valid, stamp, clock_domain="browser_performance",
                            calibration_valid=state["calibrated"],
                            host_timestamp_us=int(stamp + state["clock_offset_us"]) if state["clock_offset_us"] is not None else time.perf_counter_ns() // 1000)
            return {"ok": True}
        if path == "/api/status":
            if data.get("state") == "error":
                state["calibrated"] = False
                bridge.status("error", str(data.get("message", "WebGazer 相機追蹤失敗。"))[:400])
            return {"ok": True}
        raise ValueError("Unknown endpoint")

    ui = LocalUI(bridge, "webgazer", on_post=post)
    try:
        ui.start(options.no_browser)
        stale = False
        while not bridge.stop.wait(0.3):
            if ui.browser and ui.browser.poll() is not None:
                break
            missing = time.monotonic() - state["last_sample"] > 2
            if state["calibrated"] and missing and not stale:
                bridge.status("disconnected", "WebGazer 超過2秒未傳回樣本。請返回校正視窗檢查相機；目前樣本不可計分。")
            elif stale and not missing and state["calibrated"]:
                bridge.status("ready", "WebGazer 已恢復接收樣本。")
            stale = missing
    finally:
        ui.close()

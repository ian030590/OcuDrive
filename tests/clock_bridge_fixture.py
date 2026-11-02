"""Synthetic protocol fixture: exercises loopback clocks without loading a tracker."""
from pathlib import Path
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bridges.bridge_helper import Bridge


bridge = Bridge("tobii", int(sys.argv[1]), sys.argv[2], int(sys.argv[3]))
threading.Thread(target=bridge.controls, daemon=True).start()
bridge.status("ready", "Synthetic clock fixture; no hardware loaded.")
deadline = time.monotonic() + 8
try:
    while not bridge.stop.wait(0.02) and time.monotonic() < deadline:
        stamp = time.perf_counter_ns() // 1000
        bridge.send("gaze", x=0.4, y=0.5, valid=True,
                    source_timestamp_us=stamp, host_timestamp_us=stamp,
                    simulated=True, clock_sync="synthetic_fixture")
finally:
    bridge.close()

extends SceneTree

const Main = preload("res://scripts/main.gd")

var checks := 0
var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _run() -> void:
	await create_timer(0.15).timeout
	var main = Main.new()
	var now_us := Time.get_ticks_usec()
	var t0 := now_us - 100000
	var t1 := now_us - 50000
	main.segment_start_ticks_us = t0 - 1000
	main.frame_history.assign([
		{"ticks_us": t0, "elapsed_ms": 1000.0, "aois": [{"id": "old", "x": 0.1, "y": 0.2, "w": 0.2, "h": 0.3}]},
		{"ticks_us": t1, "elapsed_ms": 1050.0, "aois": [{"id": "new", "x": 0.7, "y": 0.2, "w": 0.2, "h": 0.3}]},
	])
	var first: Dictionary = main._frame_for_sample(t0 + 10000.0)
	var second: Dictionary = main._frame_for_sample(t0 + 20000.0)
	_check(first.aois[0].id == "old" and second.aois[0].id == "old", "delayed gaze uses the historical displayed AOI rather than newest rectangle")
	_check(first.sample_t_ms == 1010.0 and second.sample_t_ms == 1020.0, "multiple gaze samples in one displayed frame retain different active times")
	var latest: Dictionary = main._frame_for_sample(t1 + 10000.0)
	_check(latest.aois[0].id == "new" and latest.sample_t_ms == 1060.0, "samples after a new frame use its AOI")
	var capped: Dictionary = main._frame_for_sample(t1 + 40000.0)
	_check(capped.sample_t_ms == 1083.0, "last-frame extrapolation is bounded")
	_check(main._frame_for_sample(t0 - 2000.0).is_empty(), "samples before the resumed segment cannot reuse old history")
	_check(main._frame_for_sample(now_us - 300000.0).is_empty(), "excessively delayed sample is not scored")
	_check(main._frame_for_sample(Time.get_ticks_usec() + 50000.0).is_empty(), "future sample is not mapped into a stale frame")
	main.stop_ticks_us = t1 + 20000
	_check(main._frame_for_sample(t1 + 30000.0).is_empty(), "post-stop sample is excluded during the drain interval")
	main.frame_history.clear()
	_check(main._frame_for_sample(t1 + 10000.0).is_empty(), "missing frame history remains empty rather than inventing an AOI")
	main.free()
	if failures.is_empty() and checks == 9:
		print("FRAME_ALIGNMENT PASS: %d assertions" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("FRAME_ALIGNMENT FAIL: %d / %d assertions" % [failures.size(), checks])
		quit(1)

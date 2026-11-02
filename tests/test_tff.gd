extends SceneTree

const Analyzer = preload("res://scripts/tff_analyzer.gd")

var checks := 0
var failures: Array[String] = []
var groups_completed := 0
var box: Array = [{"id": "pedestrian", "x": 0.2, "y": 0.2, "w": 0.4, "h": 0.5}]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_entry_and_fixation()
	_test_short_look_and_missing()
	_test_breaks()
	_test_order_and_source_clock()
	_test_dynamic_aoi_and_bounds()
	_test_pause_and_events()
	_test_input_validation()
	_test_delayed_delivery()
	_check(groups_completed == 8, "all eight test groups complete without a script error")
	if failures.is_empty():
		print("TFF PASS: %d assertions" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("TFF FAIL: %d / %d assertions" % [failures.size(), checks])
		quit(1)


func _new(onset_ms: float = 1000.0) -> RefCounted:
	var analyzer = Analyzer.new()
	analyzer.begin_event({"id": "pedestrian", "label": "行人", "onset_ms": onset_ms})
	return analyzer


func _sample(t: float, x: float = 0.4, valid: bool = true) -> Dictionary:
	return {"t_ms": t, "x": x, "y": 0.4, "valid": valid, "source": "test"}


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _test_entry_and_fixation() -> void:
	var analyzer = _new()
	analyzer.add_sample(_sample(980.0), box)
	analyzer.add_sample(_sample(1020.0, 0.9), box)
	analyzer.add_sample(_sample(1050.0), box)
	analyzer.add_sample(_sample(1110.0), box)
	analyzer.add_sample(_sample(1170.0), box)
	var result: Dictionary = analyzer.end_event("pedestrian", 1200.0)
	_check(result["time_to_first_entry_ms"] == 50.0, "first entry uses actual onset and ignores earlier gaze")
	_check(result["time_to_first_fixation_ms"] == 50.0, "confirmed dwell reports run onset, not confirmation time")
	_check(result["fixation_confirmed_ms"] == 1170.0, "confirmation retains the 120ms delay")
	_check(result["valid_samples"] == 4, "pre-onset samples do not enter quality counts")
	_check(result["observed_ms"] == 150.0 and result["unobserved_ms"] == 50.0, "quality does not extrapolate event boundaries")
	_check(result["aoi_dwell_ms"] == 120.0, "dwell counts intervals between consecutive inside samples")
	groups_completed += 1


func _test_short_look_and_missing() -> void:
	var analyzer = _new()
	analyzer.add_sample(_sample(1020.0), box)
	analyzer.add_sample(_sample(1080.0), box)
	analyzer.add_sample(_sample(1140.0, 0.9), box)
	var result: Dictionary = analyzer.end_event("pedestrian", 1200.0)
	_check(result["time_to_first_entry_ms"] == 20.0, "brief entry is retained")
	_check(result["time_to_first_fixation_ms"] == null, "brief entry is not a fixation")
	_check(result["status"] == "no_confirmed_aoi_dwell", "brief entry status is explicit")
	analyzer = _new()
	result = analyzer.end_event("pedestrian", 1200.0)
	_check(result["time_to_first_entry_ms"] == null and result["time_to_first_fixation_ms"] == null, "unobserved metrics are null, not zero")
	_check(result["status"] == "no_valid_samples" and result["unobserved_ms"] == 200.0, "empty event marks all duration unobserved")
	groups_completed += 1


func _test_breaks() -> void:
	for reason in ["invalid", "nan", "outside", "gap", "missing_aoi", "sequence_gap"]:
		var analyzer = _new()
		analyzer.add_sample(_sample(1020.0), box)
		analyzer.add_sample(_sample(1080.0), box)
		match reason:
			"invalid": analyzer.add_sample(_sample(1110.0, 0.4, false), box)
			"nan": analyzer.add_sample(_sample(1110.0, NAN), box)
			"outside": analyzer.add_sample(_sample(1110.0, 0.95), box)
			"gap": pass
			"missing_aoi": analyzer.add_sample(_sample(1110.0), [])
			"sequence_gap":
				var packet := _sample(1110.0)
				packet["sequence"] = 1
				analyzer.add_sample(packet, box)
		var resumed_ms := 1200.0 if reason == "gap" else 1140.0
		var resumed := _sample(resumed_ms)
		if reason == "sequence_gap":
			resumed["sequence"] = 3
		analyzer.add_sample(resumed, box)
		var later := _sample(resumed_ms + 60.0)
		if reason == "sequence_gap":
			later["sequence"] = 4
		analyzer.add_sample(later, box)
		var result: Dictionary = analyzer.end_event("pedestrian", resumed_ms + 80.0)
		_check(result["time_to_first_fixation_ms"] == null, "%s breaks continuous dwell" % reason)
		_check(result["time_to_first_entry_ms"] == 20.0, "%s preserves earlier entry" % reason)
	var analyzer = _new()
	analyzer.add_sample(_sample(1000.0), box)
	analyzer.add_sample(_sample(1100.0), box)
	analyzer.add_sample(_sample(1120.0), box)
	_check(analyzer.end_event("pedestrian", 1120.0)["time_to_first_fixation_ms"] == 0.0, "exactly 100ms gap is allowed and zero is a real onset entry")
	groups_completed += 1


func _test_order_and_source_clock() -> void:
	for reason in ["session_duplicate", "session_reverse", "source_duplicate", "source_reverse", "sequence_duplicate", "sequence_reverse"]:
		var analyzer = _new()
		var first := _sample(1020.0)
		first.merge({"source_timestamp_us": 9000020.0, "sequence": 2})
		analyzer.add_sample(first, box)
		var second := _sample(1080.0)
		second.merge({"source_timestamp_us": 9060020.0, "sequence": 3})
		analyzer.add_sample(second, box)
		var bad := _sample(1110.0)
		bad.merge({"source_timestamp_us": 9090020.0, "sequence": 4})
		match reason:
			"session_duplicate": bad["t_ms"] = 1080.0
			"session_reverse": bad["t_ms"] = 1070.0
			"source_duplicate": bad["source_timestamp_us"] = 9060020.0
			"source_reverse": bad["source_timestamp_us"] = 9000020.0
			"sequence_duplicate": bad["sequence"] = 3
			"sequence_reverse": bad["sequence"] = 2
		var rejection: Dictionary = analyzer.add_sample(bad, box)
		analyzer.add_sample(_sample(1140.0), box)
		var result: Dictionary = analyzer.end_event("pedestrian", 1160.0)
		_check(not rejection["accepted"] and result["rejected_samples"] == 1, "%s is rejected" % reason)
		_check(result["time_to_first_fixation_ms"] == null, "%s interrupts dwell" % reason)
	var analyzer = _new()
	for index in range(3):
		var packet := _sample(1020.0 + 60.0 * index)
		packet["source_timestamp_us"] = 999000000.0 + 60000.0 * index
		analyzer.add_sample(packet, box)
	_check(analyzer.end_event("pedestrian", 1160.0)["time_to_first_fixation_ms"] == 20.0, "source clock absolute offset never changes session latency")
	analyzer = _new()
	analyzer.add_sample(_sample(1020.0), box)
	analyzer.add_sample(_sample(1080.0), box)
	analyzer.add_sample(_sample(980.0), box)
	analyzer.add_sample(_sample(1140.0), box)
	var result: Dictionary = analyzer.end_event("pedestrian", 1160.0)
	_check(result["time_to_first_fixation_ms"] == null, "late pre-onset packet interrupts current dwell without entering event counts")
	_check(result["valid_samples"] == 3 and result["rejected_samples"] == 0, "pre-onset packet remains excluded from counts")
	analyzer = _new()
	var timed := _sample(1020.0)
	timed.merge({"source_timestamp_us": 9000000, "sequence": 9})
	analyzer.add_sample(timed, box)
	analyzer.add_sample(_sample(1080.0), box)
	timed = _sample(1140.0)
	timed.merge({"source_timestamp_us": 8999999, "sequence": 8})
	_check(not analyzer.add_sample(timed, box)["accepted"], "omitted metadata cannot erase source-time/sequence high water")
	analyzer = _new()
	for index in range(3):
		var packet := _sample(1020.0 + 60.0 * index)
		packet["source_timestamp_us"] = 9000000.0 + 120000.0 * index
		analyzer.add_sample(packet, box)
	result = analyzer.end_event("pedestrian", 1160.0)
	_check(result["time_to_first_fixation_ms"] == null and result["sample_gap_count"] == 2, "source-time gaps break dwell despite short receipt-time intervals")
	groups_completed += 1


func _test_dynamic_aoi_and_bounds() -> void:
	var analyzer = _new()
	analyzer.add_sample(_sample(1020.0, 0.2), box)
	analyzer.add_sample(_sample(1080.0, 0.4), [{"id": "pedestrian", "x": 0.6, "y": 0.2, "w": 0.2, "h": 0.5}])
	analyzer.add_sample(_sample(1140.0), box)
	var result: Dictionary = analyzer.end_event("pedestrian", 1160.0)
	_check(result["time_to_first_entry_ms"] == 140.0, "AOI is evaluated per sample with exclusive edges")
	_check(result["time_to_first_fixation_ms"] == null, "moving AOI does not inherit an old rectangle hit")
	analyzer = _new()
	analyzer.add_sample(_sample(1020.0), box)
	analyzer.add_sample(_sample(1080.0), [{"id": "pedestrian", "x": NAN, "y": 0.2, "w": 0.4, "h": 0.5}])
	analyzer.add_sample(_sample(1140.0), box)
	result = analyzer.end_event("pedestrian", 1160.0)
	_check(result["missing_aoi_samples"] == 1 and result["time_to_first_fixation_ms"] == null, "invalid rectangle interrupts dwell")
	groups_completed += 1


func _test_pause_and_events() -> void:
	var analyzer = _new()
	analyzer.begin_event({"id": "light", "onset_ms": 1040.0})
	var both: Array = box + [{"id": "light", "x": 0.2, "y": 0.2, "w": 0.4, "h": 0.5}]
	analyzer.add_sample(_sample(1020.0), both)
	analyzer.add_sample(_sample(1080.0), both)
	analyzer.break_continuity()
	analyzer.add_sample(_sample(1090.0), both)
	analyzer.add_sample(_sample(1150.0), both)
	analyzer.add_sample(_sample(1210.0), both)
	var results: Array = analyzer.finish_all(1240.0)
	_check(results.size() == 2, "overlapping events finish independently")
	_check(results[0]["time_to_first_fixation_ms"] == 90.0 and results[1]["time_to_first_fixation_ms"] == 50.0, "pause breaks dwell even with a short active-time gap")
	_check(not analyzer.begin_event({"id": "light", "onset_ms": 1300.0}), "event identifiers cannot silently overwrite completed events")
	_check(analyzer.finish_all(1300.0).size() == 2, "finish_all does not duplicate completed results")
	analyzer.reset()
	_check(analyzer.begin_event({"id": "light", "onset_ms": 0.0}), "reset permits a new session and identifiers")
	analyzer = _new()
	analyzer.add_sample(_sample(1020.0), box)
	analyzer.add_sample(_sample(1080.0), box)
	var switched := _sample(1140.0)
	switched.merge({"source": "different_tracker", "source_timestamp_us": 1, "sequence": 0}, true)
	_check(analyzer.add_sample(switched, box)["accepted"], "new source may start a new device clock and sequence")
	_check(analyzer.end_event("pedestrian", 1160.0)["time_to_first_fixation_ms"] == null, "source change interrupts dwell")
	groups_completed += 1


func _test_input_validation() -> void:
	var analyzer = Analyzer.new(20.0, -1.0)
	_check(analyzer.minimum_fixation_ms == 100.0 and analyzer.maximum_gap_ms == 100.0, "minimum dwell cannot fall below 100ms and invalid gap uses default")
	_check(not analyzer.begin_event({"id": "bad", "onset_ms": NAN}), "NaN onset rejected")
	_check(not analyzer.begin_event({"id": "bad", "onset_ms": "1000"}), "numeric strings rejected at time boundary")
	_check(not analyzer.begin_event({"id": "", "onset_ms": 0}), "empty identifier rejected")
	analyzer = _new()
	for bad in [{"t_ms": NAN}, {"t_ms": 1020.0, "source_timestamp_us": INF}, {"t_ms": 1030.0, "sequence": -1}, {"t_ms": 1040.0, "sequence": 1.5}]:
		_check(not analyzer.add_sample(bad, box)["accepted"], "invalid time/order field rejected")
	analyzer.add_sample(_sample(1100.0, INF), box)
	_check(analyzer.end_event("pedestrian", 1090.0).is_empty(), "offset before last accepted sample cannot truncate observed duration")
	_check(analyzer.end_event("pedestrian", INF).is_empty(), "nonfinite offset rejected")
	var result: Dictionary = analyzer.end_event("pedestrian", 1200.0)
	_check(result["invalid_samples"] == 1 and result["rejected_samples"] == 4, "invalid coordinates and invalid clocks remain separate")
	groups_completed += 1


func _test_delayed_delivery() -> void:
	var analyzer = _new()
	analyzer.add_sample(_sample(1020.0), box)
	_check(analyzer.mark_event_offset("pedestrian", 1200.0), "event can mark its visible offset before late packets arrive")
	analyzer.add_sample(_sample(1080.0), box)
	analyzer.add_sample(_sample(1140.0), box)
	analyzer.add_sample(_sample(1200.0), box)
	analyzer.add_sample(_sample(1220.0), box)
	analyzer.add_sample(_sample(1240.0, 0.4, false), box)
	var result: Dictionary = analyzer.end_event("pedestrian", 1200.0)
	_check(result["time_to_first_fixation_ms"] == 20.0, "late packets before offset may confirm dwell using historical AOI")
	_check(result["valid_samples"] == 4 and result["invalid_samples"] == 0, "post-offset gaze contributes no quality counts")
	_check(result["observed_ms"] == 180.0 and result["offset_ms"] == 1200.0, "ending uses the actual offset rather than packet drain time")
	analyzer = _new()
	_check(not analyzer.mark_event_offset("unknown", 1200.0), "unknown event cannot mark offset")
	analyzer.add_sample(_sample(1080.0), box)
	_check(not analyzer.mark_event_offset("pedestrian", 1070.0) and not analyzer.mark_event_offset("pedestrian", NAN), "invalid offset markers cannot truncate accepted samples")
	_check(analyzer.mark_event_offset("pedestrian", 1200.0) and analyzer.mark_event_offset("pedestrian", 1200.0), "repeating the same offset marker is idempotent")
	_check(not analyzer.mark_event_offset("pedestrian", 1210.0), "already-marked event cannot move its visible offset")
	analyzer.add_sample(_sample(1220.0, 0.4, false), box)
	var results: Array = analyzer.finish_all(1500.0)
	_check(results.size() == 1 and results[0]["offset_ms"] == 1200.0, "session drain preserves previously marked event offset")
	_check(results[0]["invalid_samples"] == 0 and results[0]["valid_samples"] == 1, "post-offset invalid gaze is excluded during session drain")
	groups_completed += 1

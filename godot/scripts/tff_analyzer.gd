extends RefCounted

const ALGORITHM := "aoi_entry_and_continuous_dwell_v1"

var minimum_fixation_ms: float = 120.0
var maximum_gap_ms: float = 100.0
var _events: Dictionary = {}
var _completed: Array[Dictionary] = []
var _last_time_ms: Variant = null
var _last_source_us: Variant = null
var _last_sequence: Variant = null
var _last_source := ""


func _init(minimum_ms: float = 120.0, gap_ms: float = 100.0) -> void:
	if is_finite(minimum_ms):
		minimum_fixation_ms = maxf(100.0, minimum_ms)
	if is_finite(gap_ms) and gap_ms > 0.0:
		maximum_gap_ms = gap_ms


func begin_event(event: Dictionary) -> bool:
	var id := str(event.get("id", ""))
	var onset: Variant = event.get("onset_ms")
	if id.is_empty() or _events.has(id) or not _number(onset) or float(onset) < 0.0:
		return false
	for previous in _completed:
		if previous["id"] == id:
			return false
	_events[id] = {
		"event": event.duplicate(true), "onset_ms": float(onset),
		"marked_offset_ms": null,
		"first_entry_ms": null, "fixation_onset_ms": null, "fixation_confirmed_ms": null,
		"valid_samples": 0, "invalid_samples": 0, "rejected_samples": 0,
		"missing_aoi_samples": 0, "sample_gap_count": 0,
		"observed_ms": 0.0, "aoi_dwell_ms": 0.0, "latest_ms": float(onset),
		"previous_valid_ms": null, "previous_inside_ms": null,
		"run_start_ms": null, "run_samples": 0,
	}
	return true


func add_sample(sample: Dictionary, aois: Array) -> Dictionary:
	var t: Variant = sample.get("t_ms")
	if not _number(t) or float(t) < 0.0:
		_reject(null)
		return {"accepted": false, "reason": "invalid_session_time"}
	var now_ms := float(t)
	var source := str(sample.get("source", ""))
	var source_us: Variant = sample.get("source_timestamp_us")
	var sequence: Variant = sample.get("sequence")
	if source_us != null and (not _number(source_us) or float(source_us) < 0.0):
		_reject(now_ms)
		return {"accepted": false, "reason": "invalid_source_timestamp"}
	if sequence != null and (not _number(sequence) or float(sequence) < 0.0 or float(sequence) != floorf(float(sequence))):
		_reject(now_ms)
		return {"accepted": false, "reason": "invalid_sequence"}
	if _last_time_ms != null and now_ms <= float(_last_time_ms):
		_reject(now_ms)
		return {"accepted": false, "reason": "non_monotonic_session_time"}
	var source_changed := _last_time_ms != null and source != _last_source
	if not source_changed:
		if source_us != null and _last_source_us != null and float(source_us) <= float(_last_source_us):
			_reject(now_ms)
			return {"accepted": false, "reason": "non_monotonic_source_time"}
		if sequence != null and _last_sequence != null and float(sequence) <= float(_last_sequence):
			_reject(now_ms)
			return {"accepted": false, "reason": "non_monotonic_sequence"}
	var gap := false
	if _last_time_ms != null:
		gap = now_ms - float(_last_time_ms) > maximum_gap_ms
	if not source_changed and source_us != null and _last_source_us != null:
		gap = gap or (float(source_us) - float(_last_source_us)) / 1000.0 > maximum_gap_ms
	if not source_changed and sequence != null and _last_sequence != null:
		gap = gap or float(sequence) - float(_last_sequence) > 1.0
	if source_changed or gap:
		break_continuity()
	_last_time_ms = now_ms
	if source_changed or source_us != null:
		_last_source_us = source_us
	if source_changed or sequence != null:
		_last_sequence = sequence
	_last_source = source
	var x: Variant = sample.get("x")
	var y: Variant = sample.get("y")
	var valid: bool = sample.get("valid") is bool and sample["valid"] and _number(x) and _number(y)
	if valid:
		valid = float(x) >= 0.0 and float(x) <= 1.0 and float(y) >= 0.0 and float(y) <= 1.0
	var hits: Array[String] = []
	for id: String in _events:
		var state: Dictionary = _events[id]
		if now_ms < state["onset_ms"] or (state["marked_offset_ms"] != null and now_ms > float(state["marked_offset_ms"])):
			continue
		state["latest_ms"] = now_ms
		if gap:
			state["sample_gap_count"] += 1
		if not valid:
			state["invalid_samples"] += 1
			_break_event(state)
			continue
		state["valid_samples"] += 1
		if state["previous_valid_ms"] != null:
			state["observed_ms"] += now_ms - float(state["previous_valid_ms"])
		state["previous_valid_ms"] = now_ms
		var aoi := _find_aoi(id, aois)
		if aoi.is_empty():
			state["missing_aoi_samples"] += 1
			_break_run(state)
			continue
		# Strict bounds match the reference ttf.py first-entry test.
		var inside := float(x) > float(aoi["x"]) and float(x) < float(aoi["x"]) + float(aoi["w"]) and float(y) > float(aoi["y"]) and float(y) < float(aoi["y"]) + float(aoi["h"])
		if not inside:
			_break_run(state)
			continue
		hits.append(id)
		if state["first_entry_ms"] == null:
			state["first_entry_ms"] = now_ms
		if state["previous_inside_ms"] != null:
			state["aoi_dwell_ms"] += now_ms - float(state["previous_inside_ms"])
		state["previous_inside_ms"] = now_ms
		if state["run_start_ms"] == null:
			state["run_start_ms"] = now_ms
		state["run_samples"] += 1
		if state["fixation_onset_ms"] == null and state["run_samples"] >= 3 and now_ms - float(state["run_start_ms"]) >= minimum_fixation_ms:
			state["fixation_onset_ms"] = state["run_start_ms"]
			state["fixation_confirmed_ms"] = now_ms
	return {"accepted": true, "valid": valid, "aoi_hits": hits}


func break_continuity() -> void:
	for state: Dictionary in _events.values():
		_break_event(state)


func mark_event_offset(id: String, offset_ms: float) -> bool:
	if not _events.has(id) or not is_finite(offset_ms):
		return false
	var state: Dictionary = _events[id]
	if offset_ms < float(state["latest_ms"]):
		return false
	if state["marked_offset_ms"] != null:
		return float(state["marked_offset_ms"]) == offset_ms
	state["marked_offset_ms"] = offset_ms
	return true


func end_event(id: String, offset_ms: float) -> Dictionary:
	if not _events.has(id) or not is_finite(offset_ms):
		return {}
	var state: Dictionary = _events[id]
	if offset_ms < state["latest_ms"]:
		return {}
	if state["marked_offset_ms"] != null and offset_ms != float(state["marked_offset_ms"]):
		return {}
	var onset := float(state["onset_ms"])
	var duration := offset_ms - onset
	var result: Dictionary = state["event"].duplicate(true)
	result.merge({
		"onset_ms": onset, "offset_ms": offset_ms, "duration_ms": duration,
		"time_to_first_entry_ms": null if state["first_entry_ms"] == null else float(state["first_entry_ms"]) - onset,
		"time_to_first_fixation_ms": null if state["fixation_onset_ms"] == null else float(state["fixation_onset_ms"]) - onset,
		"first_entry_ms": state["first_entry_ms"],
		"fixation_onset_ms": state["fixation_onset_ms"], "fixation_confirmed_ms": state["fixation_confirmed_ms"],
		"status": "confirmed_aoi_dwell" if state["fixation_onset_ms"] != null else ("no_confirmed_aoi_dwell" if state["first_entry_ms"] != null else ("no_aoi_entry" if state["valid_samples"] > 0 else "no_valid_samples")),
		"valid_samples": state["valid_samples"], "invalid_samples": state["invalid_samples"],
		"rejected_samples": state["rejected_samples"], "missing_aoi_samples": state["missing_aoi_samples"],
		"sample_gap_count": state["sample_gap_count"], "observed_ms": state["observed_ms"],
		"unobserved_ms": maxf(0.0, duration - float(state["observed_ms"])),
		"aoi_dwell_ms": state["aoi_dwell_ms"], "algorithm": ALGORITHM,
		"minimum_fixation_ms": minimum_fixation_ms, "maximum_gap_ms": maximum_gap_ms,
		"minimum_samples": 3, "fixation_definition": "continuous_aoi_dwell_proxy",
	}, true)
	_completed.append(result)
	_events.erase(id)
	return result.duplicate(true)


func finish_all(offset_ms: float) -> Array[Dictionary]:
	for id: String in _events.keys():
		var marked: Variant = _events[id]["marked_offset_ms"]
		end_event(id, offset_ms if marked == null else float(marked))
	return _completed.duplicate(true)


func reset() -> void:
	_events.clear()
	_completed.clear()
	_last_time_ms = null
	_last_source_us = null
	_last_sequence = null
	_last_source = ""


func _reject(t: Variant) -> void:
	for state: Dictionary in _events.values():
		if t != null and state["marked_offset_ms"] != null and float(t) > float(state["marked_offset_ms"]):
			continue
		_break_event(state)
		if t != null and float(t) < float(state["onset_ms"]):
			continue
		state["rejected_samples"] += 1


func _break_event(state: Dictionary) -> void:
	state["previous_valid_ms"] = null
	_break_run(state)


func _break_run(state: Dictionary) -> void:
	state["run_start_ms"] = null
	state["run_samples"] = 0
	state["previous_inside_ms"] = null


func _find_aoi(id: String, aois: Array) -> Dictionary:
	for item: Variant in aois:
		if not item is Dictionary or str(item.get("id", "")) != id or item.get("visible", true) != true:
			continue
		var aoi: Dictionary = item
		if not _number(aoi.get("x")) or not _number(aoi.get("y")) or not _number(aoi.get("w")) or not _number(aoi.get("h")):
			return {}
		if float(aoi["w"]) <= 0.0 or float(aoi["h"]) <= 0.0:
			return {}
		return aoi
	return {}


func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

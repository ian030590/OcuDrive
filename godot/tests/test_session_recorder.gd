extends SceneTree

const Recorder = preload("res://scripts/session_recorder.gd")

var checks := 0
var failures: Array[String] = []
var groups_completed := 0
var test_root := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = OS.get_environment("OCUDRIVE_DATA_DIR")
	if test_root.is_empty():
		test_root = ProjectSettings.globalize_path("res://../.tmp/session-recorder-tests")
		OS.set_environment("OCUDRIVE_DATA_DIR", test_root)
	_check(DirAccess.make_dir_recursive_absolute(test_root) == OK, "test output directory is writable")
	_test_participant_paths()
	_test_roundtrip()
	_test_csv_cells()
	_test_write_failure()
	_test_finalization_failure()
	_check(groups_completed == 5, "all five test groups completed without script errors")
	if failures.is_empty():
		print("RECORDER PASS: %d assertions" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("RECORDER FAIL: %d / %d assertions" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _test_participant_paths() -> void:
	for code in ["", "../escape", "..\\escape", "absolute/path", "C:\\escape", "P 01", "姓名", "A\nB", "=calc", "x".repeat(41)]:
		var recorder = Recorder.new()
		_check(not recorder.open_session({"participant_code": code}), "unsafe participant code is rejected: %s" % code.c_escape())
		_check(not recorder.error_message.is_empty(), "invalid participant has a visible error")
	var first = Recorder.new()
	var second = Recorder.new()
	_check(first.open_session({"participant_code": "P_TEST-01"}), "safe participant code opens")
	_check(second.open_session({"participant_code": "P_TEST-01"}), "same participant can open another session")
	var normalized_root := test_root.replace("\\", "/").simplify_path().trim_suffix("/") + "/sessions/"
	_check(first.folder.replace("\\", "/").simplify_path().begins_with(normalized_root), "session remains inside the configured output root")
	_check(first.folder != second.folder, "sessions cannot overwrite each other even in the same second")
	first.close_files()
	second.close_files()
	groups_completed += 1


func _test_roundtrip() -> void:
	var recorder = Recorder.new()
	_check(recorder.open_session({"participant_code": "ROUNDTRIP", "source": "test", "test_run": true}), "roundtrip session opens")
	var folder: String = recorder.folder
	var initial: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("metadata.json")))
	_check(initial.get("completed") == false, "initial metadata distinguishes an unfinished session")
	_check(initial.get("invalid_tracking_is_blink") == false, "metadata does not label missing tracking as blink")
	var reason := "=HYPERLINK(\"https://example.invalid\",\"test\"), quoted\nsecond line"
	var good := {"t_ms": 10.0, "received_ticks_us": 10010, "source_timestamp_us": 9000010, "sequence": 1,
		"source": "test", "valid": true, "x": 0.25, "y": 0.75, "reason": reason,
		"host_timestamp_us": 1234500010, "frame_ticks_us": 10000,
		"clock_offset_us": -1234490000, "clock_rtt_us": 200,
		"clock_sync": "test_clock", "analysis": {"accepted": true, "aoi_hits": ["one"]}}
	recorder.write_gaze(good, [{"id": "one", "x": 0.2, "y": 0.6, "w": 0.2, "h": 0.3, "timestamp_ms": 10.0}])
	recorder.write_gaze({"t_ms": 20.0, "received_ticks_us": 10020, "source_timestamp_us": 9000020, "sequence": 2,
		"source": "test", "valid": false, "x": null, "y": null, "reason": ""}, [])
	recorder.write_vehicle({"t_ms": 20.0, "speed_kmh": 12.5, "distance_m": 0.1,
		"lane_offset_m": -0.35, "steering": -0.5, "throttle": 0.0, "brake": 0.2,
		"collisions": 0, "lane_departures": 0, "lane_departure_s": 0.0})
	var event := {"id": "one", "label": "Test event", "onset_ms": 0.0, "offset_ms": 30.0,
		"time_to_first_entry_ms": 0.0, "time_to_first_fixation_ms": null,
		"valid_samples": 1, "invalid_samples": 1, "observed_ms": 0.0}
	_check(recorder.finish([event], {"elapsed_ms": 30.0}, "completed"), "roundtrip finishes and flushes")
	var summary: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("summary.json")))
	_check(summary.metadata.gaze_samples == 2 and summary.metadata.valid_gaze_samples == 1 and summary.metadata.vehicle_samples == 1, "summary counts match stored rows")
	_check(summary.metadata.completed == true and summary.metadata.stop_reason == "completed", "summary stores completion reason")
	_check(summary.events[0].time_to_first_entry_ms == 0.0 and summary.events[0].time_to_first_fixation_ms == null, "JSON distinguishes true zero from missing fixation")
	var gaze := FileAccess.open(folder.path_join("gaze.csv"), FileAccess.READ)
	var header := gaze.get_csv_line()
	var row1 := gaze.get_csv_line()
	var row2 := gaze.get_csv_line()
	gaze.close()
	_check(row1.size() == header.size() and row2.size() == header.size(), "CSV quoting preserves multiline cell and column counts")
	_check(row1[header.find("reason")] == "'" + reason, "formula cell is neutralized and commas/newlines roundtrip")
	_check(row2[header.find("x")] == "" and row2[header.find("y")] == "" and row2[header.find("reason")] == "", "CSV null and empty cells remain empty")
	var vehicle := FileAccess.open(folder.path_join("vehicle.csv"), FileAccess.READ)
	var vehicle_header := vehicle.get_csv_line()
	var vehicle_row := vehicle.get_csv_line()
	vehicle.close()
	_check(vehicle_row[vehicle_header.find("lane_offset_m")] == "-0.35", "numeric negative values are not changed into escaped text")
	_check(vehicle_header.has("lane_departure_s") and not vehicle_header.has("lane_departures"), "vehicle CSV names lane departure duration in seconds")
	var events := FileAccess.open(folder.path_join("events.csv"), FileAccess.READ)
	var event_header := events.get_csv_line()
	var event_row := events.get_csv_line()
	events.close()
	_check(float(event_row[event_header.find("time_to_first_entry_ms")]) == 0.0 and event_row[event_header.find("time_to_first_fixation_ms")] == "", "event CSV distinguishes zero from absent fixation")
	var journal := FileAccess.open(folder.path_join("timeline.jsonl"), FileAccess.READ)
	var entry1: Dictionary = JSON.parse_string(journal.get_line())
	var entry2: Dictionary = JSON.parse_string(journal.get_line())
	journal.close()
	_check(entry1.type == "gaze_aoi" and entry1.data.aois[0].id == "one" and entry2.data.aois.is_empty(), "journal stores the actual AOI per gaze including empty AOI")
	_check(entry1.data.get("clock_sync") == "test_clock" and entry1.data.get("analysis", {}).get("accepted") == true, "journal retains synchronization method and classification")
	var final_metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("metadata.json")))
	_check(final_metadata.get("completed") == true and final_metadata.get("gaze_samples") == 2, "metadata.json is finalized consistently with summary")
	_check(header.has("host_timestamp_us") and header.has("clock_offset_us") and header.has("clock_rtt_us") and header.has("frame_ticks_us"), "raw gaze keeps host clock alignment evidence")
	_check(float(row1[header.find("host_timestamp_us")]) == 1234500010.0 and float(row1[header.find("frame_ticks_us")]) == 10000.0 and float(row1[header.find("clock_rtt_us")]) == 200.0, "host/frame timing values survive CSV roundtrip")
	groups_completed += 1


func _test_csv_cells() -> void:
	var recorder = Recorder.new()
	var path := test_root.path_join("csv-cells-%d.csv" % Time.get_ticks_usec())
	var file := FileAccess.open(path, FileAccess.WRITE)
	var raw: Array = ["=1+1", "+1+1", "-2+3", "@SUM(1,2)", "\t=1+1", "\r=1+1", "\n=1+1", "plain,\"quoted\"", null, "", -1.25]
	recorder._csv(file, raw)
	file.close()
	file = FileAccess.open(path, FileAccess.READ)
	var cells := file.get_csv_line()
	file.close()
	_check(cells.size() == raw.size(), "CSV cell escaping preserves row width")
	for index in range(7):
		var expected := str(raw[index]).replace("\r\n", "\n").replace("\r", "\n")
		_check(index < cells.size() and cells[index] == "'" + expected, "dangerous CSV prefix is neutralized: %d" % index)
	_check(cells.size() == raw.size() and cells[7] == raw[7] and cells[8] == "" and cells[9] == "" and cells[10] == "-1.25", "normal text, null, empty, and numeric cells retain values")
	groups_completed += 1


func _test_write_failure() -> void:
	var obstruction := test_root.path_join("not-a-directory-%d" % Time.get_ticks_usec())
	var file := FileAccess.open(obstruction, FileAccess.WRITE)
	file.store_string("test obstruction")
	file.close()
	OS.set_environment("OCUDRIVE_DATA_DIR", obstruction)
	var recorder = Recorder.new()
	_check(not recorder.open_session({"participant_code": "P_WRITEFAIL"}), "output path occupied by a file prevents starting")
	_check(not recorder.error_message.is_empty(), "write failure has an actionable error")
	OS.set_environment("OCUDRIVE_DATA_DIR", test_root)
	groups_completed += 1


func _test_finalization_failure() -> void:
	var recorder = Recorder.new()
	_check(recorder.open_session({"participant_code": "FINALIZE_FAIL", "test_run": true}), "finalization failure fixture opens normally")
	var event_path: String = recorder.folder.path_join("events.csv")
	_check(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(event_path)) == OK, "fixture blocks event CSV with a directory")
	var saved: bool = recorder.finish([], {"elapsed_ms": 0.0}, "completed")
	_check(not saved and recorder.failed and not recorder.error_message.is_empty(), "event CSV creation failure marks the recording as failed")
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(recorder.folder.path_join("metadata.json")))
	var summary: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(recorder.folder.path_join("summary.json")))
	_check(metadata.get("recording_error") != null and summary.metadata.get("recording_error") != null, "final metadata and summary retain the actual finalization failure")
	groups_completed += 1

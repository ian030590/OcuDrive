extends RefCounted

const GAZE_HEADER := ["t_ms", "received_ticks_us", "source_timestamp_us", "host_timestamp_us", "bridge_timestamp_us", "sequence", "source", "valid", "x", "y", "reason", "frame_ticks_us", "clock_offset_us", "clock_rtt_us"]
const VEHICLE_HEADER := ["t_ms", "speed_kmh", "distance_m", "lane_offset_m", "steering", "throttle", "brake", "collisions", "lane_departure_s"]
var folder := ""
var error_message := ""
var metadata: Dictionary = {}
var gaze_file: FileAccess
var vehicle_file: FileAccess
var journal: FileAccess
var gaze_count := 0
var valid_count := 0
var vehicle_count := 0
var last_flush_us := 0
var failed := false

func open_session(config: Dictionary) -> bool:
	metadata = config.duplicate(true)
	var participant := str(config.get("participant_code", ""))
	if participant.is_empty() or participant.length() > 40:
		error_message = "請輸入 1 至 40 字的受試者代碼。"
		return false
	for character in participant:
		if not (character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"):
			error_message = "代碼只能包含英文字母、數字、底線與連字號。"
			return false
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "")
	var suffix := Crypto.new().generate_random_bytes(5).hex_encode()
	var root := OS.get_environment("OCUDRIVE_DATA_DIR")
	root = "user://" if root.is_empty() else root
	folder = root.path_join("sessions").path_join("%s_%s_%s" % [participant, stamp, suffix])
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder)) != OK:
		error_message = "無法建立紀錄資料夾，請檢查使用者資料夾的寫入權限。"
		return false
	gaze_file = FileAccess.open(folder.path_join("gaze.csv"), FileAccess.WRITE)
	vehicle_file = FileAccess.open(folder.path_join("vehicle.csv"), FileAccess.WRITE)
	journal = FileAccess.open(folder.path_join("timeline.jsonl"), FileAccess.WRITE)
	if gaze_file == null or vehicle_file == null or journal == null:
		error_message = "無法建立紀錄檔，訓練尚未開始。"
		close_files()
		return false
	gaze_file.store_csv_line(PackedStringArray(GAZE_HEADER))
	vehicle_file.store_csv_line(PackedStringArray(VEHICLE_HEADER))
	metadata["schema_version"] = "ocudrive.session.v1"
	metadata["started_utc"] = Time.get_datetime_string_from_system(true) + "Z"
	metadata["session_id"] = folder.get_file()
	metadata["completed"] = false
	metadata["software_version"] = "0.1.0"
	metadata["clock"] = "Godot monotonic active-session milliseconds; pauses excluded"
	metadata["gaze_coordinate_space"] = "normalized fullscreen training display"
	metadata["invalid_tracking_is_blink"] = false
	if not _write_json("metadata.json", metadata):
		close_files()
		return false
	last_flush_us = Time.get_ticks_usec()
	return true

func write_gaze(sample: Dictionary, aois: Array) -> void:
	if gaze_file == null or failed:
		return
	gaze_count += 1
	if bool(sample.get("valid", false)):
		valid_count += 1
	var row: Array = []
	for key in GAZE_HEADER:
		row.append(sample.get(key, null))
	_csv(gaze_file, row)
	write_event("gaze_aoi", {"t_ms": sample.get("t_ms"), "sequence": sample.get("sequence"), "aois": aois, "analysis": sample.get("analysis"), "clock_sync": sample.get("clock_sync")})
	_flush_if_due()

func write_vehicle(sample: Dictionary) -> void:
	if vehicle_file == null or failed:
		return
	vehicle_count += 1
	var row: Array = []
	for key in VEHICLE_HEADER:
		row.append(sample.get(key, null))
	_csv(vehicle_file, row)
	_flush_if_due()

func write_event(kind: String, payload: Dictionary) -> void:
	if journal == null or failed:
		return
	journal.store_line(JSON.stringify({"type": kind, "data": payload}))
	_check_file(journal)

func finish(results: Array, state: Dictionary, reason: String) -> bool:
	close_files()
	metadata["completed"] = reason == "completed"
	metadata["stop_reason"] = reason
	metadata["ended_utc"] = Time.get_datetime_string_from_system(true) + "Z"
	metadata["gaze_samples"] = gaze_count
	metadata["valid_gaze_samples"] = valid_count
	metadata["vehicle_samples"] = vehicle_count
	var ok := not failed
	var events_file := FileAccess.open(folder.path_join("events.csv"), FileAccess.WRITE)
	if events_file != null:
		var keys := ["id", "label", "onset_ms", "offset_ms", "time_to_first_entry_ms", "time_to_first_fixation_ms", "valid_samples", "invalid_samples", "observed_ms"]
		events_file.store_csv_line(PackedStringArray(keys))
		for event in results:
			var row: Array = []
			for key in keys:
				row.append(event.get(key, null))
			_csv(events_file, row)
		events_file.flush()
		_check_file(events_file)
		events_file.close()
	else:
		failed = true
		error_message = "無法建立事件摘要，原始紀錄已保留。"
	metadata["recording_complete"] = not failed
	metadata["recording_error"] = error_message if failed else null
	var summary := {"metadata": metadata.duplicate(true), "vehicle": state, "events": results,
		"tff_method": "AOI dwell proxy, 120ms and >=3 consecutive samples; not I-VT",
		"time_to_first_entry_method": "first valid AOI entry minus actual visible onset",
		"clinical_validated": false}
	ok = _write_json("summary.json", summary) and ok
	metadata["recording_complete"] = not failed
	metadata["recording_error"] = error_message if failed else null
	ok = _write_json("metadata.json", metadata) and ok
	return ok and not failed

func close_files() -> void:
	for file in [gaze_file, vehicle_file, journal]:
		if file != null:
			file.flush()
			_check_file(file)
			file.close()
	gaze_file = null
	vehicle_file = null
	journal = null

func _write_json(name: String, value: Dictionary) -> bool:
	var path := folder.path_join(name)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		error_message = "無法儲存 " + name
		failed = true
		return false
	file.store_string(JSON.stringify(value, "\t"))
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	if not ok or DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"), ProjectSettings.globalize_path(path)) != OK:
		error_message = "寫入失敗，已保留原始紀錄：" + name
		failed = true
		return false
	return true

func _csv(file: FileAccess, values: Array) -> void:
	var cells := PackedStringArray()
	for value in values:
		var cell := "" if value == null else str(value)
		cell = cell.replace("\r\n", "\n").replace("\r", "\n")
		if value is String and not cell.is_empty() and cell[0] in "=+-@\t\r\n":
			cell = "'" + cell
		cells.append(cell)
	file.store_csv_line(cells)
	_check_file(file)

func _flush_if_due() -> void:
	if Time.get_ticks_usec() - last_flush_us >= 1000000:
		for file in [gaze_file, vehicle_file, journal]:
			if file != null:
				file.flush()
				_check_file(file)
		last_flush_us = Time.get_ticks_usec()

func _check_file(file: FileAccess) -> void:
	if file.get_error() != OK:
		failed = true
		error_message = "紀錄寫入失敗，請保留資料夾並確認剩餘磁碟空間。"

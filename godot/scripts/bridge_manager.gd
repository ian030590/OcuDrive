extends Node

signal gaze_received(sample: Dictionary)
signal status_changed(state: String, message: String)
signal continuity_broken(reason: String)

var source := "off"
var state := "off"
var message := "未啟用眼動，不會啟動 SDK 或攝影機。"
var calibration: Dictionary = {}
var socket: PacketPeerUDP
var token := ""
var helper_pid := -1
var helper_port := -1
var last_packet_us := 0
var start_us := 0
var last_sequence := -1
var last_source_us := -1.0
var ready_seen := false
var clock_offset_us := 0.0
var clock_rtt_us := INF
var clock_ready := false
var last_ping_us := 0
var pending_pings: Dictionary = {}

func start_device(selected: String, options: Dictionary = {}) -> bool:
	stop_device()
	if selected == "off":
		return true
	if selected not in ["webgazer", "sol", "tobii"]:
		_set_status("error", "未知的眼動來源。")
		return false
	source = selected
	calibration = {}
	last_sequence = -1
	last_source_us = -1.0
	ready_seen = false
	clock_ready = false
	clock_rtt_us = INF
	pending_pings.clear()
	socket = PacketPeerUDP.new()
	if socket.bind(0, "127.0.0.1", 65536) != OK:
		_set_status("error", "無法啟動本機眼動連線。")
		return false
	token = Crypto.new().generate_random_bytes(32).hex_encode()
	var args := PackedStringArray(["--source", source, "--port", str(socket.get_local_port()), "--token", token, "--parent-pid", str(OS.get_process_id())])
	if selected == "sol":
		var host := str(options.get("sol_host", "192.168.1.10")).strip_edges()
		if not host.is_valid_ip_address():
			_set_status("error", "Sol 位址請使用裝置的 IPv4 位址。")
			return false
		args.append_array(["--sol-host", host, "--sol-port", str(clampi(int(options.get("sol_port", 8080)), 1, 65535))])
	if bool(options.get("no_browser", false)):
		args.append("--no-browser")
	var executable := ""
	if not FileAccess.file_exists("res://embedded/bridge_helper.bin"):
		executable = str(options.get("python_path", "python"))
		args.insert(0, ProjectSettings.globalize_path("res://../bridges/bridge_helper.py"))
	else:
		executable = _materialize_helper()
		if executable.is_empty():
			return false
	helper_pid = OS.create_process(executable, args, false)
	if helper_pid < 0:
		_set_status("error", "眼動橋接無法啟動，請檢查程式檔案與裝置設定。")
		return false
	start_us = Time.get_ticks_usec()
	last_packet_us = start_us
	_set_status("loading", "正在啟動所選眼動來源，請完成裝置校正。")
	return true

func stop_device() -> void:
	if socket != null and helper_port > 0:
		socket.set_dest_address("127.0.0.1", helper_port)
		socket.put_packet(JSON.stringify({"token": token, "type": "stop"}).to_utf8_buffer())
	if helper_pid > 0 and OS.is_process_running(helper_pid):
		# The helper owns camera and SDK resources; give its stop handler time to release them.
		var old_pid := helper_pid
		get_tree().create_timer(2.0).timeout.connect(func():
			if OS.is_process_running(old_pid):
				OS.kill(old_pid)
		)
	if socket != null:
		socket.close()
	socket = null
	helper_pid = -1
	helper_port = -1
	token = ""
	source = "off"
	calibration = {}
	_set_status("off", "未啟用眼動，不會啟動 SDK 或攝影機。")

func _process(_delta: float) -> void:
	if socket == null or source == "off":
		return
	var budget := 0
	while socket.get_available_packet_count() > 0 and budget < 512:
		budget += 1
		var packet := socket.get_packet()
		if socket.get_packet_ip() != "127.0.0.1" or packet.size() > 8192:
			continue
		var data = JSON.parse_string(packet.get_string_from_utf8())
		if not data is Dictionary or str(data.get("token", "")) != token or str(data.get("source", "")) != source:
			continue
		if helper_port > 0 and socket.get_packet_port() != helper_port:
			continue
		helper_port = socket.get_packet_port()
		last_packet_us = Time.get_ticks_usec()
		if str(data.get("type", "")) == "clock_sync":
			_accept_clock(data)
			continue
		if str(data.get("type", "")) == "status":
			var new_state := str(data.get("state", "error"))
			if new_state not in ["loading", "calibrating", "ready", "error", "disconnected", "stopped", "streaming"]:
				continue
			if data.has("calibration") and data["calibration"] is Dictionary:
				calibration = data["calibration"].duplicate(true)
			ready_seen = ready_seen or new_state in ["ready", "streaming"]
			_set_status(new_state, str(data.get("message", "" )).left(600))
		elif str(data.get("type", "")) == "gaze":
			_accept_gaze(data)
	if helper_port > 0 and Time.get_ticks_usec() - last_ping_us > 250000:
		last_ping_us = Time.get_ticks_usec()
		pending_pings[last_ping_us] = true
		socket.set_dest_address("127.0.0.1", helper_port)
		socket.put_packet(JSON.stringify({"token": token, "type": "clock_ping", "godot_ticks_us": last_ping_us}).to_utf8_buffer())
		for key in pending_pings.keys():
			if last_ping_us - int(key) > 10000000:
				pending_pings.erase(key)
	if helper_pid > 0 and not OS.is_process_running(helper_pid) and state not in ["error", "disconnected", "stopped"]:
		_set_status("error", "眼動橋接已停止，請重新連接或選擇無眼動練習。")
	elif Time.get_ticks_usec() - last_packet_us > 3000000 and state in ["ready", "streaming"]:
		_set_status("disconnected", "超過 3 秒沒有眼動資料，訓練將暫停。")
	elif Time.get_ticks_usec() - start_us > 120000000 and not ready_seen and state == "loading":
		_set_status("error", "裝置啟動逾時，請檢查橋接診斷並重新連接。")

func _accept_gaze(data: Dictionary) -> void:
	for key in ["x", "y", "source_timestamp_us", "sequence"]:
		if not (data.get(key) is float or data.get(key) is int) or not is_finite(float(data[key])):
			continuity_broken.emit("malformed_gaze_" + key)
			return
	if not data.get("valid") is bool:
		continuity_broken.emit("malformed_gaze_validity")
		return
	if float(data["sequence"]) < 0.0 or float(data["sequence"]) != floorf(float(data["sequence"])) or float(data["source_timestamp_us"]) < 0.0:
		continuity_broken.emit("invalid_gaze_sequence_or_timestamp")
		return
	var sequence := int(data["sequence"])
	var source_us := float(data["source_timestamp_us"])
	var valid := bool(data["valid"])
	var reason := str(data.get("reason", data.get("invalid_reason", "invalid_gaze" if not valid else "")))
	if sequence <= last_sequence or source_us <= last_source_us:
		valid = false
		reason = "non_monotonic_source"
	else:
		last_sequence = sequence
		last_source_us = source_us
	if float(data["x"]) < 0.0 or float(data["x"]) > 1.0 or float(data["y"]) < 0.0 or float(data["y"]) > 1.0:
		valid = false
		reason = "outside_display"
	var sample := {"source": source, "sequence": sequence, "source_timestamp_us": source_us,
		"received_ticks_us": Time.get_ticks_usec(), "x": float(data["x"]), "y": float(data["y"]), "valid": valid, "reason": reason}
	if (data.get("host_timestamp_us") is float or data.get("host_timestamp_us") is int) and is_finite(float(data["host_timestamp_us"])):
		sample["host_timestamp_us"] = float(data["host_timestamp_us"])
	if (data.get("bridge_timestamp_us") is float or data.get("bridge_timestamp_us") is int) and is_finite(float(data["bridge_timestamp_us"])):
		sample["bridge_timestamp_us"] = float(data["bridge_timestamp_us"])
		if float(sample.get("host_timestamp_us", -1.0)) > float(data["bridge_timestamp_us"]):
			sample["valid"] = false
			sample["reason"] = "sample_timestamp_in_future"
	if clock_ready and float(sample.get("host_timestamp_us", -1.0)) >= 0.0:
		sample["mapped_ticks_us"] = float(sample["host_timestamp_us"]) + clock_offset_us
		sample["clock_offset_us"] = clock_offset_us
		sample["clock_rtt_us"] = clock_rtt_us
		sample["clock_sync"] = "loopback NTP midpoint, minimum RTT"
	else:
		sample["valid"] = false
		sample["reason"] = "clock_not_synchronized"
	gaze_received.emit(sample)

func _accept_clock(data: Dictionary) -> void:
	for key in ["godot_ticks_us", "host_receive_us", "host_send_us"]:
		if not (data.get(key) is float or data.get(key) is int) or not is_finite(float(data[key])) or float(data[key]) < 0.0:
			return
	var t0 := int(data["godot_ticks_us"])
	if not pending_pings.has(t0):
		return
	pending_pings.erase(t0)
	var t3 := float(Time.get_ticks_usec())
	var t1 := float(data["host_receive_us"])
	var t2 := float(data["host_send_us"])
	var rtt := t3 - float(t0) - (t2 - t1)
	if t2 < t1 or rtt < 0.0 or rtt > 200000.0:
		return
	if rtt < clock_rtt_us:
		clock_rtt_us = rtt
		clock_offset_us = (float(t0) - t1 + t3 - t2) / 2.0
		clock_ready = true

func _materialize_helper() -> String:
	var resource := "res://embedded/bridge_helper.bin"
	var hash_path := "res://embedded/bridge_helper.sha256"
	if not FileAccess.file_exists(resource) or not FileAccess.file_exists(hash_path):
		_set_status("error", "此建置缺少眼動橋接，請使用完整單檔建置。")
		return ""
	var expected := FileAccess.get_file_as_string(hash_path).strip_edges().to_lower()
	if expected.length() != 64:
		_set_status("error", "眼動橋接完整性資訊無效。")
		return ""
	var root := OS.get_environment("OCUDRIVE_DATA_DIR")
	root = "user://" if root.is_empty() else root
	var folder := root.path_join("bridge-runtime").path_join(expected.left(16))
	var target := folder.path_join("OcuDriveBridge.exe")
	if FileAccess.file_exists(target) and FileAccess.get_sha256(target) == expected:
		return ProjectSettings.globalize_path(target)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder)) != OK:
		_set_status("error", "無法建立橋接快取資料夾。")
		return ""
	var output := FileAccess.open(target + ".tmp", FileAccess.WRITE)
	var input := FileAccess.open(resource, FileAccess.READ)
	if output == null or input == null:
		_set_status("error", "無法解開眼動橋接。")
		return ""
	while input.get_position() < input.get_length():
		output.store_buffer(input.get_buffer(1024 * 1024))
	output.flush()
	var write_ok := output.get_error() == OK
	output.close()
	input.close()
	if not write_ok or FileAccess.get_sha256(target + ".tmp") != expected:
		_set_status("error", "眼動橋接校驗失敗，請重新取得程式。")
		return ""
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(target + ".tmp"), ProjectSettings.globalize_path(target)) != OK:
		_set_status("error", "無法完成橋接快取寫入。")
		return ""
	return ProjectSettings.globalize_path(target)

func _set_status(next: String, text: String) -> void:
	state = next
	message = text
	status_changed.emit(state, message)

func _exit_tree() -> void:
	if socket != null and helper_port > 0:
		socket.set_dest_address("127.0.0.1", helper_port)
		socket.put_packet(JSON.stringify({"token": token, "type": "stop"}).to_utf8_buffer())

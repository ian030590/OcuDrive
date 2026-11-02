extends SceneTree

const Manager = preload("res://scripts/bridge_manager.gd")

var checks := 0
var failures: Array[String] = []
var groups_completed := 0
var received: Array[Dictionary] = []
var broken: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_clock_validation()
	_test_malformed_gaze()
	await _test_loopback_handshake()
	_check(groups_completed == 3, "all three bridge test groups completed without script errors")
	if failures.is_empty():
		print("BRIDGE_MANAGER PASS: %d assertions" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("BRIDGE_MANAGER FAIL: %d / %d assertions" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _test_clock_validation() -> void:
	var manager = Manager.new()
	var now_us := Time.get_ticks_usec()
	var host_epoch := 900000000000.0
	manager._accept_clock({"godot_ticks_us": now_us, "host_receive_us": host_epoch, "host_send_us": host_epoch})
	_check(not manager.clock_ready, "unsolicited clock echo is rejected")
	var t0 := Time.get_ticks_usec() - 40000
	manager.pending_pings[t0] = true
	var before := float(Time.get_ticks_usec())
	var t1 := float(t0) + host_epoch + 10000.0
	var t2 := t1 + 5000.0
	manager._accept_clock({"godot_ticks_us": t0, "host_receive_us": t1, "host_send_us": t2})
	var after := float(Time.get_ticks_usec())
	var expected_min := (float(t0) - t1 + before - t2) / 2.0
	var expected_max := (float(t0) - t1 + after - t2) / 2.0
	_check(manager.clock_ready, "requested NTP-style echo establishes clock")
	_check(manager.clock_offset_us >= expected_min - 1.0 and manager.clock_offset_us <= expected_max + 1.0, "clock offset uses four-timestamp midpoint formula")
	_check(manager.clock_rtt_us >= before - float(t0) - 5001.0 and manager.clock_rtt_us <= after - float(t0) - 4999.0, "roundtrip excludes helper processing duration")
	var best_offset: float = manager.clock_offset_us
	var best_rtt: float = manager.clock_rtt_us
	t0 = Time.get_ticks_usec() - 80000
	manager.pending_pings[t0] = true
	manager._accept_clock({"godot_ticks_us": t0, "host_receive_us": float(t0) + host_epoch + 10000.0, "host_send_us": float(t0) + host_epoch + 11000.0})
	_check(manager.clock_rtt_us == best_rtt and manager.clock_offset_us == best_offset, "slower echo does not replace minimum-RTT estimate")
	t0 = Time.get_ticks_usec() - 20000
	manager.pending_pings[t0] = true
	manager._accept_clock({"godot_ticks_us": t0, "host_receive_us": host_epoch + 10, "host_send_us": host_epoch})
	_check(manager.clock_rtt_us == best_rtt, "reversed host timestamps rejected")
	manager._accept_clock({"godot_ticks_us": NAN, "host_receive_us": host_epoch, "host_send_us": host_epoch})
	_check(manager.clock_rtt_us == best_rtt, "nonfinite clock echo rejected")
	manager.free()
	groups_completed += 1


func _packet(sequence: int = 1) -> Dictionary:
	return {"x": 0.4, "y": 0.5, "valid": true, "source_timestamp_us": 9000000 + 20000 * sequence,
		"host_timestamp_us": 1000000000 + Time.get_ticks_usec(), "sequence": sequence}


func _test_malformed_gaze() -> void:
	var manager = Manager.new()
	manager.source = "tobii"
	manager.clock_ready = true
	manager.clock_offset_us = -1000000000.0
	manager.clock_rtt_us = 500.0
	manager.gaze_received.connect(func(sample: Dictionary): received.append(sample))
	manager.continuity_broken.connect(func(reason: String): broken.append(reason))
	for change in [{"x": NAN}, {"y": INF}, {"x": null}, {"valid": "true"}, {"sequence": 1.5}, {"source_timestamp_us": -1}, {"y": "0.5"}]:
		var malformed := _packet()
		malformed.merge(change, true)
		var before := broken.size()
		manager._accept_gaze(malformed)
		_check(broken.size() == before + 1, "authenticated malformed gaze signals a continuity break: %s" % str(change.keys()))
	_check(received.is_empty(), "malformed gaze never becomes a scored coordinate")
	manager._accept_gaze(_packet())
	_check(received.size() == 1 and received[0].valid == true, "well formed synchronized gaze is delivered")
	_check(absf(float(received[0].mapped_ticks_us) - float(received[0].received_ticks_us)) < 2000.0, "host clock is mapped into Godot monotonic clock")
	manager._accept_gaze(_packet())
	_check(received.size() == 2 and received[1].valid == false and received[1].reason == "non_monotonic_source", "duplicate sequence reaches analyzer as invalid continuity boundary")
	var outside := _packet(2)
	outside["x"] = 1.1
	manager._accept_gaze(outside)
	_check(received.back().valid == false and received.back().reason == "outside_display", "outside-screen coordinates remain invalid")
	manager.clock_ready = false
	manager._accept_gaze(_packet(3))
	_check(received.back().valid == false and received.back().reason == "clock_not_synchronized", "clock handshake is required before scoring")
	manager.free()
	groups_completed += 1


func _test_loopback_handshake() -> void:
	var manager = Manager.new()
	root.add_child(manager)
	manager.source = "tobii"
	manager.token = "0123456789abcdef0123456789abcdef"
	manager.socket = PacketPeerUDP.new()
	_check(manager.socket.bind(0, "127.0.0.1", 65536) == OK, "protocol fixture binds only loopback")
	manager.start_us = Time.get_ticks_usec()
	manager.last_packet_us = manager.start_us
	manager._set_status("loading", "Synthetic test fixture")
	var fixture := ProjectSettings.globalize_path("res://../tests/clock_bridge_fixture.py")
	var args := PackedStringArray([fixture, str(manager.socket.get_local_port()), manager.token, str(OS.get_process_id())])
	manager.helper_pid = OS.create_process("python", args, false)
	_check(manager.helper_pid > 0, "synthetic Python helper launches without any tracker SDK")
	var samples: Array[Dictionary] = []
	manager.gaze_received.connect(func(sample: Dictionary): samples.append(sample))
	var deadline := Time.get_ticks_usec() + 4000000
	while (not manager.clock_ready or samples.size() < 4) and Time.get_ticks_usec() < deadline:
		await process_frame
	_check(manager.clock_ready and manager.clock_rtt_us >= 0.0 and manager.clock_rtt_us < 200000.0, "real loopback ping/pong establishes a bounded NTP estimate")
	_check(manager.helper_port > 0 and manager.state == "ready", "authenticated helper endpoint and readiness are discovered")
	await create_timer(0.6).timeout
	var valid_samples := 0
	var sequence_gaps := 0
	var previous_sequence := -1
	for sample in samples:
		if sample.valid:
			valid_samples += 1
		if previous_sequence >= 0 and int(sample.sequence) != previous_sequence + 1:
			sequence_gaps += 1
		previous_sequence = int(sample.sequence)
	_check(valid_samples > 0, "live synthetic gaze is scoreable only after clock handshake")
	_check(sequence_gaps == 0, "clock/status messages do not introduce artificial gaze sequence gaps")
	var adversary := PacketPeerUDP.new()
	adversary.bind(0, "127.0.0.1")
	adversary.set_dest_address("127.0.0.1", manager.socket.get_local_port())
	adversary.put_packet(JSON.stringify({"token": "wrong-token", "source": "tobii", "type": "status", "state": "error", "message": "unauthorized"}).to_utf8_buffer())
	await process_frame
	await process_frame
	_check(manager.state == "ready", "wrong-token packet cannot change device state")
	adversary.put_packet(JSON.stringify({"token": manager.token, "source": "tobii", "type": "status", "state": "error", "message": "wrong endpoint"}).to_utf8_buffer())
	await process_frame
	await process_frame
	_check(manager.state == "ready", "correct token from a different UDP endpoint is rejected after pinning")
	adversary.close()
	var fixture_pid: int = manager.helper_pid
	manager.stop_device()
	await create_timer(0.4).timeout
	_check(not OS.is_process_running(fixture_pid), "stop control releases the synthetic helper process")
	manager.queue_free()
	groups_completed += 1

extends SceneTree

var app: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var bridge: Node = app.bridge
	var ok: bool = bridge.start_device("webgazer", {"no_browser": true})
	if not ok:
		push_error("PACKAGED_HOST FAIL: bridge launch " + bridge.message)
		quit(1)
		return
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and (bridge.state != "calibrating" or not bridge.clock_ready):
		await create_timer(0.05).timeout
	var target_pid: int = bridge.helper_pid
	var ready: bool = bridge.state == "calibrating" and bridge.clock_ready and target_pid > 0
	var binary: String = bridge._materialize_helper()
	var expected := FileAccess.get_file_as_string("res://embedded/bridge_helper.sha256").strip_edges()
	var intact := not binary.is_empty() and FileAccess.get_sha256(binary) == expected
	bridge.stop_device()
	await create_timer(2.5).timeout
	var released := not OS.is_process_running(target_pid)
	app.queue_free()
	await process_frame
	if ready and intact and released:
		print("PACKAGED_HOST PASS: embedded helper extraction, hash, real frozen process, clock handshake, authenticated stop")
		quit(0)
	else:
		push_error("PACKAGED_HOST FAIL: ready=%s intact=%s released=%s" % [ready, intact, released])
		quit(1)

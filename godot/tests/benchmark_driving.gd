extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://../.tmp/perf-data")
	OS.set_environment("OCUDRIVE_DATA_DIR", directory)
	DirAccess.make_dir_recursive_absolute(directory)
	var app = load("res://main.tscn").instantiate()
	root.add_child(app)
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	app.participant.text = "PERF_OFF"
	app.duration_select.select(0)
	app.smoke_mode = true
	app._start_session()
	app.smoke_mode = false
	if not app.session_running:
		push_error("Benchmark could not start: " + app.form_error.text)
		quit(1)
		return
	var ready := FileAccess.open(directory.path_join("ready.json"), FileAccess.WRITE)
	ready.store_string(JSON.stringify({"pid": OS.get_process_id(), "source": "off", "bridge_pid": app.bridge.helper_pid}))
	ready.close()
	var start_us := Time.get_ticks_usec()
	var start_frames := Engine.get_frames_drawn()
	print("BENCHMARK_READY ", OS.get_process_id())
	await create_timer(15.0).timeout
	var elapsed_s := float(Time.get_ticks_usec() - start_us) / 1000000.0
	var rendered_frames := Engine.get_frames_drawn() - start_frames
	var report := {
		"wall_s": elapsed_s,
		"rendered_frames": rendered_frames,
		"average_fps": float(rendered_frames) / elapsed_s,
		"fps_limit": Engine.max_fps,
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_device": RenderingServer.get_video_adapter_name(),
		"viewport_pixels": {"width": root.get_texture().get_width(), "height": root.get_texture().get_height()},
		"source": "off",
		"bridge_pid": app.bridge.helper_pid,
		"session": app.world.get_state(),
	}
	await app._finish_session("benchmark_stopped")
	var output := FileAccess.open(directory.path_join("engine-report.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("BENCHMARK_COMPLETE ", JSON.stringify(report))
	app.free()
	quit(0)

extends SceneTree


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var world = load("res://scripts/driving_world.gd").new()
	root.add_child(world)
	world.set_physics_process(false)
	world.configure({"duration_s": 60, "seed": 481, "auto_speed": true})
	world.start_session()
	for index in range(85):
		world.step_simulation(0.1, {})
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var screenshot: Image = root.get_texture().get_image()
	var destination := ProjectSettings.globalize_path("res://../.tmp/driving-world.png")
	var error := screenshot.save_png(destination)
	print("Capture: %s (%s)" % [destination, error_string(error)])
	quit(error)

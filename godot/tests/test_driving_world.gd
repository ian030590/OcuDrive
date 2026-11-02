extends SceneTree

const DrivingWorld = preload("res://scripts/driving_world.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)


func _run() -> void:
	var world := DrivingWorld.new()
	root.add_child(world)
	world.set_physics_process(false)
	world.hide()
	_check(not world.get("_mirror").is_visible_in_tree(), "Hidden world retained mirror overlay")
	world.show()
	_check(world.get("_mirror").is_visible_in_tree(), "Visible world did not restore mirror overlay")
	world.configure({"duration_s": 60, "seed": 481, "auto_speed": true, "audio_enabled": false})
	var started: Array[Dictionary] = []
	var ended: Array[Dictionary] = []
	var samples: Array[Dictionary] = []
	var completions: Array[bool] = []
	world.hazard_started.connect(func(event: Dictionary): started.append(event))
	world.hazard_ended.connect(func(event: Dictionary): ended.append(event))
	world.telemetry.connect(func(sample: Dictionary): samples.append(sample))
	world.session_finished.connect(func(): completions.append(true))
	world.start_session()
	for index in range(30):
		world.step_simulation(0.1, {})
	var paused_at: float = world.get_state().elapsed_ms
	var paused_distance: float = world.get_state().distance_m
	world.set_paused(true)
	world.step_simulation(0.1, {"throttle": 1.0})
	_check(world.get_state().elapsed_ms == paused_at, "Pause advanced elapsed time")
	_check(world.get_state().distance_m == paused_distance, "Pause moved vehicle")
	world.set_paused(false)
	for index in range(650):
		world.step_simulation(0.1, {})
	_check(completions.size() == 1, "Session must finish exactly once")
	_check(is_equal_approx(world.get_state().elapsed_ms, 60000.0), "Duration boundary must be exact")
	_check(started.size() >= 5, "A 60-second cruising session must expose all five events")
	_check(ended.size() == started.size(), "Every visible event needs a closing record")
	var kinds: Dictionary = {}
	var order: Array[String] = []
	for event in started:
		kinds[event.kind] = true
		order.append(event.kind)
		_check(event.aoi.w > 0.0 and event.aoi.h > 0.0, "Visible event has an empty AOI")
		_check(event.aoi.x >= 0.0 and event.aoi.y >= 0.0, "AOI starts outside viewport")
		_check(event.aoi.x + event.aoi.w <= 1.0001 and event.aoi.y + event.aoi.h <= 1.0001, "AOI extends outside viewport")
	_check(kinds.size() == 5, "Missing an event type")
	_check(world.get_state().collisions >= 2, "Unbraked forward hazards must detect physical contact")
	_check(world.get_state().red_light_violations == 1, "Passing red light was not recorded")
	for index in range(1, samples.size()):
		_check(samples[index].timestamp_ms > samples[index - 1].timestamp_ms, "Telemetry timestamps must increase")
	started.clear()
	ended.clear()
	world.start_session()
	for index in range(610):
		world.step_simulation(0.1, {})
	for index in range(mini(order.size(), started.size())):
		_check(started[index].kind == order[index], "Same seed produced a different event order")
	started.clear()
	ended.clear()
	world.start_session()
	for index in range(100):
		world.step_simulation(0.1, {})
		if not started.is_empty():
			break
	world.step_simulation(0.1, {})
	world.step_simulation(0.1, {"brake": 1.0})
	var before_stop: Dictionary = world.get_state()
	_check(before_stop.brake == 1.0, "Brake input was not recorded")
	world.stop_session()
	_check(not ended.is_empty() and ended[-1].brake_reaction_ms != null, "New brake press did not receive reaction time")
	world.configure({"duration_s": 60, "auto_speed": false})
	world.start_session()
	world.step_simulation(0.1, {"steer": 1.0})
	_check(is_zero_approx(world.get_state().lateral_m), "Stationary steering moved vehicle laterally")
	world.stop_session()
	world.free()
	var audio := preload("res://scripts/drive_audio.gd").new()
	root.add_child(audio)
	_check(audio.get_child_count() == 0, "Muted audio allocated playback resources")
	audio.set_enabled(true)
	_check(audio.get_child_count() == 2, "Enabled audio did not create playback channels")
	_check(audio.get_child(0).stream.get_length() > 0.0, "Generated engine tone has no samples")
	# Godot's headless Dummy audio driver retains stopped playback until shutdown.
	if DisplayServer.get_name() != "headless":
		audio.set_engine(8.0, true)
		_check(audio.get_child(0).playing, "Engine audio did not start")
	audio.set_enabled(false)
	_check(not audio.get_child(0).playing, "Mute did not stop engine audio")
	await create_timer(0.1).timeout
	audio.free()
	if _failures.is_empty():
		print("PASS driving world: pause, duration, five hazards, AOIs, replay seed, telemetry, braking, contact, red light, stationary steering, audio mute")
	else:
		print("FAIL driving world: %d checks" % _failures.size())
	quit(0 if _failures.is_empty() else 1)

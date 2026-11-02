extends Node3D

signal hazard_started(event: Dictionary)
signal hazard_ended(event: Dictionary)
signal telemetry(sample: Dictionary)
signal session_finished()

const DriveAudio = preload("res://scripts/drive_audio.gd")
const KINDS: Array[String] = ["pedestrian", "lead_brake", "traffic_light", "obstacle", "rear_traffic"]
const LABELS: Dictionary = {
	"pedestrian": "行人穿越",
	"lead_brake": "前車減速",
	"traffic_light": "路口號誌",
	"obstacle": "車道障礙",
	"rear_traffic": "後方來車",
}
const SEGMENT_LENGTH := 30.0
const SEGMENT_COUNT := 10
const RIGHT_LANE_CENTER := 1.75

var _settings: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _camera: Camera3D
var _scenery: Array[Node3D] = []
var _materials: Dictionary = {}
var _mirror: Control
var _mirror_car: ColorRect
var _mirror_text: Label
var _audio: Node
var _running := false
var _paused := false
var _elapsed_ms := 0.0
var _distance_m := 0.0
var _speed_mps := 0.0
var _player_x := RIGHT_LANE_CENTER
var _steer := 0.0
var _throttle := 0.0
var _brake := 0.0
var _previous_brake := 0.0
var _lane_departure_ms := 0.0
var _collision_count := 0
var _red_light_count := 0
var _next_trigger_m := 45.0
var _event_number := 0
var _event_order: Array[String] = []
var _active: Dictionary = {}
var _hazard_root: Node3D
var _light_red: MeshInstance3D
var _light_green: MeshInstance3D
var _telemetry_accumulator := 0.0


func _ready() -> void:
	_build_world()
	visibility_changed.connect(_sync_overlay_visibility)
	_sync_overlay_visibility()
	_audio = DriveAudio.new()
	add_child(_audio)
	configure({})


func _sync_overlay_visibility() -> void:
	if is_instance_valid(_mirror):
		_mirror.visible = is_visible_in_tree()


func configure(settings: Dictionary) -> void:
	_settings = {
		"duration_s": clampi(int(settings.get("duration_s", 180)), 60, 600),
		"difficulty": "standard" if settings.get("difficulty", "gentle") == "standard" else "gentle",
		"seed": int(settings.get("seed", 20261101)),
		"auto_speed": bool(settings.get("auto_speed", true)),
		"audio_enabled": bool(settings.get("audio_enabled", false)),
	}
	if is_instance_valid(_audio):
		_audio.set_enabled(_settings.audio_enabled)


func start_session() -> void:
	stop_session()
	_rng.seed = _settings.seed
	_event_order.assign(KINDS)
	for index in range(_event_order.size() - 1, 0, -1):
		var swap_index := _rng.randi_range(0, index)
		var saved := _event_order[index]
		_event_order[index] = _event_order[swap_index]
		_event_order[swap_index] = saved
	_elapsed_ms = 0.0
	_distance_m = 0.0
	_player_x = RIGHT_LANE_CENTER
	_speed_mps = _target_speed() if _settings.auto_speed else 0.0
	_lane_departure_ms = 0.0
	_collision_count = 0
	_red_light_count = 0
	_next_trigger_m = 45.0
	_event_number = 0
	_telemetry_accumulator = 0.0
	_steer = 0.0
	_throttle = 0.0
	_brake = 0.0
	_previous_brake = 0.0
	_paused = false
	_running = true
	_update_scenery()
	telemetry.emit(get_state())


func set_paused(value: bool) -> void:
	_paused = value
	if _paused and is_instance_valid(_audio):
		_audio.stop()


func stop_session() -> void:
	if not _active.is_empty():
		_finish_hazard("session_ended")
	_running = false
	_paused = false
	if is_instance_valid(_audio):
		_audio.stop()
	if is_instance_valid(_mirror_car):
		_mirror_car.hide()


func get_state() -> Dictionary:
	return {
		"timestamp_ms": _elapsed_ms,
		"elapsed_ms": _elapsed_ms,
		"elapsed_s": _elapsed_ms / 1000.0,
		"remaining_s": maxf(0.0, float(_settings.get("duration_s", 180)) - _elapsed_ms / 1000.0),
		"speed_kph": _speed_mps * 3.6,
		"speed_mps": _speed_mps,
		"distance_m": _distance_m,
		"lateral_m": _player_x - RIGHT_LANE_CENTER,
		"steer": _steer,
		"throttle": _throttle,
		"brake": _brake,
		"lane_departure_s": _lane_departure_ms / 1000.0,
		"collisions": _collision_count,
		"red_light_violations": _red_light_count,
		"active_event_id": _active.get("id", ""),
		"active_event_kind": _active.get("kind", ""),
		"active_event_label": _active.get("label", ""),
		"running": _running,
		"paused": _paused,
		"seed": _settings.get("seed", 20261101),
	}


func get_event_aois() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _active.is_empty() or not _active.get("visible", false):
		return result
	var rect := _event_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return result
	result.append({
		"id": _active.id,
		"label": _active.label,
		"kind": _active.kind,
		"x": rect.position.x,
		"y": rect.position.y,
		"w": rect.size.x,
		"h": rect.size.y,
		"onset_ms": _active.onset_ms,
		"timestamp_ms": _elapsed_ms,
	})
	return result


func _physics_process(delta: float) -> void:
	step_simulation(delta, _read_controls())


func step_simulation(delta: float, controls: Dictionary) -> void:
	if not _running or _paused:
		return
	var remaining := float(_settings.duration_s) - _elapsed_ms / 1000.0
	var dt := minf(clampf(delta, 0.0, 0.1), remaining)
	if dt <= 0.0:
		return
	_elapsed_ms += dt * 1000.0
	_steer = clampf(float(controls.get("steer", 0.0)), -1.0, 1.0)
	_throttle = clampf(float(controls.get("throttle", 0.0)), 0.0, 1.0)
	_brake = clampf(float(controls.get("brake", 0.0)), 0.0, 1.0)
	var acceleration := _throttle * 3.0 - _brake * 7.0 - 0.15
	if _settings.auto_speed and _brake < 0.05 and _throttle < 0.05:
		acceleration = clampf((_target_speed() - _speed_mps) * 1.5, -1.8, 1.8)
	_speed_mps = clampf(_speed_mps + acceleration * dt, 0.0, _target_speed() * 1.25)
	_player_x = clampf(_player_x + _steer * _speed_mps * 0.18 * dt, -6.5, 6.5)
	_distance_m += _speed_mps * dt
	if _player_x < 0.45 or _player_x > 3.4:
		_lane_departure_ms += dt * 1000.0
	_update_scenery()
	if _active.is_empty() and _distance_m >= _next_trigger_m:
		_spawn_hazard()
	if not _active.is_empty():
		_update_hazard(dt)
	_previous_brake = _brake
	_telemetry_accumulator += dt
	if _telemetry_accumulator >= 0.05:
		_telemetry_accumulator = fmod(_telemetry_accumulator, 0.05)
		telemetry.emit(get_state())
	_audio.set_engine(_speed_mps, true)
	if _elapsed_ms >= float(_settings.duration_s) * 1000.0 - 0.001:
		stop_session()
		session_finished.emit()


func _read_controls() -> Dictionary:
	var steer := float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
	steer -= float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT))
	var throttle := float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP))
	var brake := float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_SPACE))
	var devices := Input.get_connected_joypads()
	if not devices.is_empty():
		var device: int = devices[0]
		var analog := Input.get_joy_axis(device, JOY_AXIS_LEFT_X)
		if absf(analog) > 0.12:
			steer = analog
		throttle = maxf(throttle, maxf(0.0, Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT)))
		brake = maxf(brake, maxf(0.0, Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT)))
	return {"steer": steer, "throttle": throttle, "brake": brake}


func _target_speed() -> float:
	return 8.333333 if _settings.get("difficulty", "gentle") == "gentle" else 12.5


func _spawn_hazard() -> void:
	var kind: String = _event_order[_event_number % _event_order.size()]
	_event_number += 1
	_next_trigger_m = _distance_m + (95.0 if _settings.difficulty == "gentle" else 110.0)
	_hazard_root = Node3D.new()
	add_child(_hazard_root)
	_hazard_root.position = Vector3(RIGHT_LANE_CENTER, 0.0, -48.0)
	_active = {
		"id": "hazard_%03d" % _event_number,
		"kind": kind,
		"label": LABELS[kind],
		"trigger_distance_m": _distance_m,
		"onset_ms": _elapsed_ms,
		"visible": false,
		"brake_reaction_ms": null,
		"steering_reaction_ms": null,
		"collision": false,
		"red_light_violation": false,
		"start_lateral_m": _player_x,
		"minimum_speed_mps": _speed_mps,
		"start_speed_mps": _speed_mps,
		"required_response": "observe" if kind == "rear_traffic" else ("avoid_or_brake" if kind == "obstacle" else "brake"),
	}
	match kind:
		"pedestrian":
			_hazard_root.position.x = 4.6
			_box(_hazard_root, Vector3(0.55, 0.85, 0.36), Vector3(0.0, 1.0, 0.0), Color("e7b749"))
			_box(_hazard_root, Vector3(0.36, 0.4, 0.36), Vector3(0.0, 1.65, 0.0), Color("b8815f"))
			_box(_hazard_root, Vector3(0.18, 0.6, 0.2), Vector3(-0.17, 0.3, 0.0), Color("384754"))
			_box(_hazard_root, Vector3(0.18, 0.6, 0.2), Vector3(0.17, 0.3, 0.0), Color("384754"))
		"lead_brake":
			_car(_hazard_root, Color("f1eee6"), true)
		"traffic_light":
			_hazard_root.position.x = 4.45
			_box(_hazard_root, Vector3(0.12, 3.7, 0.12), Vector3(0.0, 1.85, 0.0), Color("5b6264"))
			_box(_hazard_root, Vector3(0.62, 1.6, 0.42), Vector3(0.0, 3.45, 0.0), Color("202428"))
			_light_red = _box(_hazard_root, Vector3(0.4, 0.4, 0.08), Vector3(0.0, 3.95, 0.25), Color("f02828"))
			_light_green = _box(_hazard_root, Vector3(0.4, 0.4, 0.08), Vector3(0.0, 2.95, 0.25), Color("263e36"))
			_box(_hazard_root, Vector3(7.4, 0.03, 0.45), Vector3(-4.45, 0.04, 0.0), Color("f6f7f9"))
		"obstacle":
			_box(_hazard_root, Vector3(1.15, 0.75, 0.8), Vector3(0.0, 0.375, 0.0), Color("c66c28"))
			_box(_hazard_root, Vector3(1.2, 0.12, 0.84), Vector3(0.0, 0.5, 0.0), Color("f4eee3"))
		"rear_traffic":
			_mirror_car.show()
			_mirror_text.text = "後方示意：來車"
	if kind != "rear_traffic":
		_active["bounds_center"] = Vector3(0.0, 3.45, 0.0) if kind == "traffic_light" else Vector3(0.0, 0.9, 0.0)
		_active["bounds_size"] = Vector3(0.75, 1.8, 0.6) if kind == "traffic_light" else Vector3(1.8, 1.6, 3.6)
		if kind == "pedestrian":
			_active.bounds_size = Vector3(0.7, 1.9, 0.6)
		elif kind == "obstacle":
			_active.bounds_center = Vector3(0.0, 0.4, 0.0)
			_active.bounds_size = Vector3(1.3, 0.9, 1.0)
	_try_mark_visible()


func _try_mark_visible() -> void:
	if _active.get("visible", false):
		return
	if _event_rect().size.x <= 0.0:
		return
	_active.visible = true
	_active.onset_ms = _elapsed_ms
	var record := _public_event()
	var aois := get_event_aois()
	if not aois.is_empty():
		record["aoi"] = aois[0]
	hazard_started.emit(record)


func _update_hazard(dt: float) -> void:
	_try_mark_visible()
	var age_s: float = (_elapsed_ms - float(_active.onset_ms)) / 1000.0
	var kind: String = _active.kind
	if _active.brake_reaction_ms == null and _previous_brake < 0.2 and _brake >= 0.2:
		_active.brake_reaction_ms = _elapsed_ms - float(_active.onset_ms)
	if _active.steering_reaction_ms == null and absf(_player_x - float(_active.start_lateral_m)) >= 0.35:
		_active.steering_reaction_ms = _elapsed_ms - float(_active.onset_ms)
	_active.minimum_speed_mps = minf(float(_active.minimum_speed_mps), _speed_mps)
	if kind == "rear_traffic":
		var car_size := Vector2(22.0, 13.0).lerp(Vector2(58.0, 31.0), minf(age_s / 6.0, 1.0))
		_mirror_car.size = car_size
		_mirror_car.position = Vector2((_mirror.size.x - car_size.x) * 0.5, _mirror.size.y * 0.55)
		if age_s >= 6.0:
			_finish_hazard("observation_window_ended")
		return
	var closing_speed := maxf(0.0, _speed_mps - 2.0) if kind == "lead_brake" else _speed_mps
	var previous_z := _hazard_root.position.z
	_hazard_root.position.z += closing_speed * dt
	if kind == "pedestrian":
		var crossing_delay := maxf(0.0, 47.0 / maxf(float(_active.start_speed_mps), 1.0) - 2.28)
		_hazard_root.position.x = maxf(-4.6, 4.6 - maxf(0.0, age_s - crossing_delay) * 1.25)
	if kind == "traffic_light" and age_s >= 7.0:
		_light_red.material_override = _material(Color("563030"))
		_light_green.material_override = _material(Color("26a55a"))
	if previous_z < -1.0 and _hazard_root.position.z >= -1.0:
		if kind == "traffic_light":
			if age_s < 7.0 and _speed_mps > 0.5:
				_active.red_light_violation = true
				_red_light_count += 1
		elif absf(_hazard_root.position.x - _player_x) < (1.5 if kind == "lead_brake" else 1.0):
			_active.collision = true
			_collision_count += 1
			_audio.play_cue("collision")
	if _hazard_root.position.z > 4.0:
		_finish_hazard("passed")
	elif age_s >= 10.0:
		_finish_hazard("observation_window_ended")


func _finish_hazard(reason: String) -> void:
	if _active.is_empty():
		return
	var record := _public_event()
	record["end_ms"] = _elapsed_ms
	record["duration_ms"] = _elapsed_ms - float(_active.onset_ms)
	record["end_reason"] = reason
	record["end_distance_m"] = _distance_m
	if _active.get("visible", false):
		hazard_ended.emit(record)
	_active.clear()
	if is_instance_valid(_hazard_root):
		_hazard_root.queue_free()
	_hazard_root = null
	if is_instance_valid(_mirror_car):
		_mirror_car.hide()
	if is_instance_valid(_mirror_text):
		_mirror_text.text = "後方示意"


func _public_event() -> Dictionary:
	var record := _active.duplicate(true)
	record.erase("bounds_center")
	record.erase("bounds_size")
	return record


func _event_rect() -> Rect2:
	if _active.is_empty() or not is_instance_valid(_camera):
		return Rect2()
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return Rect2()
	if _active.kind == "rear_traffic":
		var mirror_position := _mirror.global_position + _mirror_car.position
		return Rect2(mirror_position / viewport_size, _mirror_car.size / viewport_size)
	if not is_instance_valid(_hazard_root):
		return Rect2()
	var center: Vector3 = _active.get("bounds_center", Vector3(0, 1, 0))
	var half: Vector3 = _active.get("bounds_size", Vector3.ONE) * 0.5
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var point := _hazard_root.global_position + center + half * Vector3(x_sign, y_sign, z_sign)
				if _camera.is_position_behind(point):
					return Rect2()
				var projected := _camera.unproject_position(point)
				minimum = minimum.min(projected)
				maximum = maximum.max(projected)
	var padded := Rect2(minimum - Vector2(4, 4), maximum - minimum + Vector2(8, 8))
	var clipped := padded.intersection(Rect2(Vector2.ZERO, viewport_size))
	if not clipped.has_area():
		return Rect2()
	return Rect2(clipped.position / viewport_size, clipped.size / viewport_size)


func _build_world() -> void:
	var environment := WorldEnvironment.new()
	var sky := Environment.new()
	sky.background_mode = Environment.BG_COLOR
	sky.background_color = Color("bbd3df")
	sky.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky.ambient_light_color = Color.WHITE
	sky.ambient_light_energy = 0.8
	environment.environment = sky
	add_child(environment)
	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 65.0
	_camera.near = 0.1
	_camera.far = 260.0
	_camera.position = Vector3(RIGHT_LANE_CENTER, 1.55, 0.0)
	_camera.rotation_degrees.x = -3.0
	add_child(_camera)
	_box(self, Vector3(220.0, 0.1, 340.0), Vector3(0.0, -0.12, -140.0), Color("9cb48d"))
	for index in range(SEGMENT_COUNT):
		var segment := Node3D.new()
		add_child(segment)
		_scenery.append(segment)
		_box(segment, Vector3(8.0, 0.08, SEGMENT_LENGTH), Vector3.ZERO, Color("656e70"))
		for edge_x in [-3.8, 3.8]:
			_box(segment, Vector3(0.12, 0.02, SEGMENT_LENGTH), Vector3(edge_x, 0.052, 0.0), Color("f3eee0"))
		for dash in range(4):
			_box(segment, Vector3(0.13, 0.02, 3.8), Vector3(0.0, 0.052, -11.0 + dash * 7.5), Color("f3eee0"))
		for side in [-1.0, 1.0]:
			var tree_x: float = side * (8.0 + float(index % 3) * 1.6)
			_box(segment, Vector3(0.35, 2.5, 0.35), Vector3(tree_x, 1.2, -8.0), Color("756451"))
			var crown := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 1.8
			cone.height = 4.5
			cone.radial_segments = 5
			crown.mesh = cone
			crown.material_override = _material(Color("5e7a61") if index % 2 == 0 else Color("6d8969"))
			crown.position = Vector3(tree_x, 4.0, -8.0)
			crown.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			segment.add_child(crown)
		if index % 3 == 0:
			_box(segment, Vector3(6.0, 5.5, 8.0), Vector3(-16.0, 2.7, 2.0), Color("d4c9b6"))
			_box(segment, Vector3(6.4, 0.3, 8.4), Vector3(-16.0, 5.5, 2.0), Color("867e72"))
	_build_mirror()
	_update_scenery()


func _build_mirror() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	_mirror = Control.new()
	_mirror.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mirror.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	layer.add_child(_mirror)
	var background := ColorRect.new()
	background.color = Color("202428")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mirror.add_child(background)
	var road := ColorRect.new()
	road.color = Color("697374")
	road.mouse_filter = Control.MOUSE_FILTER_IGNORE
	road.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	road.offset_left = 4
	road.offset_right = -4
	road.offset_top = 25
	road.offset_bottom = -4
	_mirror.add_child(road)
	_mirror_text = Label.new()
	_mirror_text.text = "後方示意"
	_mirror_text.add_theme_font_size_override("font_size", 14)
	var readable_font := SystemFont.new()
	readable_font.font_names = PackedStringArray(["Microsoft JhengHei UI", "Microsoft JhengHei", "Noto Sans CJK TC"])
	_mirror_text.add_theme_font_override("font", readable_font)
	_mirror_text.add_theme_color_override("font_color", Color("f6f7f9"))
	_mirror_text.position = Vector2(8, 2)
	_mirror.add_child(_mirror_text)
	_mirror_car = ColorRect.new()
	_mirror_car.color = Color("f1eee6")
	_mirror_car.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mirror_car.size = Vector2(22, 13)
	_mirror.add_child(_mirror_car)
	_mirror_car.hide()
	get_viewport().size_changed.connect(_layout_mirror)
	_layout_mirror()


func _layout_mirror() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	_mirror.position = viewport_size * Vector2(0.4, 0.14)
	_mirror.size = viewport_size * Vector2(0.2, 0.13)


func _update_scenery() -> void:
	if not is_instance_valid(_camera):
		return
	_camera.position.x = _player_x
	for index in range(_scenery.size()):
		_scenery[index].position.z = fposmod(float(index) * SEGMENT_LENGTH + _distance_m, SEGMENT_LENGTH * SEGMENT_COUNT) - 255.0


func _box(parent: Node3D, dimensions: Vector3, origin: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = dimensions
	mesh.mesh = box
	mesh.material_override = _material(color)
	mesh.position = origin
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	return mesh


func _material(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if not _materials.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_materials[key] = material
	return _materials[key]


func _car(parent: Node3D, body_color: Color, brake_lights: bool) -> void:
	_box(parent, Vector3(1.65, 0.65, 3.4), Vector3(0.0, 0.65, 0.0), body_color)
	_box(parent, Vector3(1.35, 0.55, 1.7), Vector3(0.0, 1.24, 0.0), Color("4d6d79"))
	for wheel_x in [-0.8, 0.8]:
		for wheel_z in [-1.1, 1.1]:
			_box(parent, Vector3(0.25, 0.5, 0.5), Vector3(wheel_x, 0.3, wheel_z), Color("303638"))
	for tail_x in [-0.58, 0.58]:
		_box(parent, Vector3(0.32, 0.2, 0.08), Vector3(tail_x, 0.8, 1.74), Color("ee3030") if brake_lights else Color("853737"))

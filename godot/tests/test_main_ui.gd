extends SceneTree

var _failures: Array[String] = []
var _evidence: Array[String] = []
var _app: Node
var _output_directory := ""


func _initialize() -> void:
	_output_directory = ProjectSettings.globalize_path("res://../.tmp/ui-data")
	OS.set_environment("OCUDRIVE_DATA_DIR", _output_directory)
	DirAccess.make_dir_recursive_absolute(_output_directory)
	call_deferred("_run")


func _check(condition: bool, description: String) -> void:
	_evidence.append(("PASS " if condition else "FAIL ") + description)
	if not condition:
		_failures.append(description)
		push_error(description)


func _frames(count: int = 2) -> void:
	for index in range(count):
		await process_frame


func _resize(dimensions: Vector2i) -> void:
	root.mode = Window.MODE_WINDOWED
	root.size = dimensions
	await _frames(3)


func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := _output_directory.path_join(name + ".png")
	var screenshot := root.get_texture().get_image()
	var error := screenshot.save_png(path)
	_check(error == OK, "Screenshot saved: " + name)
	var expected := Vector2i(960, 640) if name.ends_with("960x640") else Vector2i(1280, 720)
	_check(screenshot.get_size() == expected, "Actual viewport pixels %s: %s" % [name, screenshot.get_size()])


func _button_below(node: Node, text: String) -> Button:
	if node is Button and node.text == text:
		return node
	for child in node.get_children():
		var result := _button_below(child, text)
		if result != null:
			return result
	return null


func _scroll_to(control: Control) -> void:
	var ancestor := control.get_parent()
	while ancestor != null:
		if ancestor is ScrollContainer:
			ancestor.ensure_control_visible(control)
			break
		ancestor = ancestor.get_parent()
	await _frames()


func _press(button: Button) -> void:
	if button == null:
		_check(false, "Requested button exists")
		return
	await _scroll_to(button)
	_check(button.is_visible_in_tree() and not button.disabled, "Enabled control: " + button.text)
	button.pressed.emit()
	await _frames()


func _select_source(index: int) -> void:
	_app.source_select.select(index)
	_app.source_select.item_selected.emit(index)
	await _frames()


func _key(keycode: Key) -> void:
	var pressed := InputEventKey.new()
	pressed.keycode = keycode
	pressed.physical_keycode = keycode
	pressed.pressed = true
	root.push_input(pressed)
	var released := pressed.duplicate()
	released.pressed = false
	root.push_input(released)
	await _frames()


func _visible_rect(control: Control) -> Rect2:
	var result := control.get_global_rect().intersection(root.get_visible_rect())
	var ancestor := control.get_parent()
	while ancestor != null:
		if ancestor is Control and ancestor.clip_contents:
			result = result.intersection(ancestor.get_global_rect())
		ancestor = ancestor.get_parent()
	return result


func _buttons(node: Node) -> Array[Button]:
	var found: Array[Button] = []
	if node is Button:
		found.append(node)
	for child in node.get_children():
		found.append_array(_buttons(child))
	return found


func _check_marker_clearance(context: String) -> void:
	var collisions: Array[String] = []
	for marker in _app.markers:
		if not marker.is_visible_in_tree():
			continue
		for button in _buttons(_app.setup):
			if button.is_visible_in_tree() and _visible_rect(button).has_area():
				if marker.get_global_rect().intersects(_visible_rect(button)):
					collisions.append(button.text)
	_check(collisions.is_empty(), "Sol marker clearance %s: %s" % [context, ", ".join(collisions)])


func _run() -> void:
	var scene := load("res://main.tscn") as PackedScene
	if scene == null:
		_check(false, "Main scene parses and loads")
		_finish()
		return
	_app = scene.instantiate()
	root.add_child(_app)
	await _frames()
	if _app.get("participant") == null:
		_check(false, "Main UI initialized")
		_finish()
		return
	_app.set_process(false)
	_check(_app.setup.visible and not _app.hud.visible and not _app.results_panel.visible, "Initial setup state")
	_check(_app.participant.get_theme_color("font_color") == Color("202428"), "Input text inherits readable light theme")
	_check(_app.sound_check.get_theme_color("font_color") == Color("202428"), "Checkbox text inherits readable light theme")
	_check(_app.bridge.helper_pid == -1 and _app.bridge.socket == null, "Off launches no bridge or socket")
	_check(not _app.world.get("_mirror").is_visible_in_tree(), "Hidden driving world also hides mirror overlay")
	await _resize(Vector2i(960, 640))
	await _capture("setup-960x640")
	_check(_app.setup.get_global_rect().size.x <= root.get_visible_rect().size.x + 1.0, "Setup fits 960x640 width")
	_app.participant.grab_focus()
	await _key(KEY_TAB)
	_check(root.gui_get_focus_owner() != null and root.gui_get_focus_owner() != _app.participant, "Tab reaches the next setup control")
	_app.participant.text = ""
	await _press(_app.start_button)
	_check(not _app.session_running and not _app.form_error.text.is_empty(), "Empty participant code prevents training and shows reason")
	_app.participant.text = "../outside"
	await _press(_app.start_button)
	_check(not _app.session_running and not _app.form_error.text.is_empty(), "Invalid participant path characters prevent training")
	_app.participant.text = "UI_TEST"
	for source_index in range(1, 4):
		await _select_source(source_index)
		_check(_app.bridge.helper_pid == -1 and _app.bridge.socket == null, "Selecting %s leaves bridge unloaded" % _app.SOURCES[source_index])
		await _press(_app.start_button)
		_check(not _app.session_running and not _app.form_error.text.is_empty(), "Unconnected %s cannot start" % _app.SOURCES[source_index])
		if source_index in [2, 3]:
			_check(_app.calibration_confirm.visible and not _app.calibration_confirm.button_pressed, "Calibration confirmation starts unchecked for %s" % _app.SOURCES[source_index])
			await _press(_app.connect_button)
			_check(_app.bridge.helper_pid == -1 and not _app.form_error.text.is_empty(), "Unchecked calibration blocks %s bridge launch" % _app.SOURCES[source_index])
			_check(_app.calibration_confirm.get_theme_color("font_focus_color") == Color("202428"), "Focused calibration checkbox remains readable for %s" % _app.SOURCES[source_index])
			_app.calibration_confirm.button_pressed = true
			await _press(_app.start_button)
			_check(not _app.session_running, "Calibration checkbox alone cannot replace a connected device")
	await _select_source(2)
	await _scroll_to(_app.start_button)
	_check_marker_clearance("960x640 bottom")
	await _capture("sol-960x640")
	await _resize(Vector2i(1280, 720))
	await _scroll_to(_app.start_button)
	_check_marker_clearance("1280x720 bottom")
	await _capture("sol-1280x720")
	await _select_source(0)
	_check(not _app.marker_layer.visible and not _app.calibration_confirm.visible and not _app.connect_button.visible, "Off hides device-only controls and markers")
	await _scroll_to(_app.participant)
	await _capture("setup-1280x720")
	_app.duration_select.select(0)
	# This flag keeps tests windowed and marks metadata, while app processing stays disabled.
	_app.smoke_mode = true
	await _press(_app.start_button)
	_app.smoke_mode = false
	_app.world.set_physics_process(false)
	_check(_app.session_running and _app.hud.visible and not _app.setup.visible, "Start button opens the driving session")
	_check(_app.bridge.helper_pid == -1 and _app.bridge.socket == null, "Off training still loads no helper")
	_check(_app.world.get("_mirror").is_visible_in_tree(), "Training world shows mirror overlay")
	for index in range(85):
		_app.world.step_simulation(0.1, {})
	await _frames()
	await _capture("driving-1280x720")
	_app.smoke_mode = true
	await _resize(Vector2i(960, 640))
	_app.smoke_mode = false
	await _capture("driving-960x640")
	_check(_app.hud.get_global_rect().size.x <= root.get_visible_rect().size.x + 1.0, "HUD fits small viewport width")
	_app.smoke_mode = true
	await _resize(Vector2i(1280, 720))
	_app.smoke_mode = false
	await _press(_button_below(_app.hud, "聲音"))
	_check(_app.sound_check.button_pressed and _app.world.get("_audio").enabled, "Sound control enables actual audio module")
	await _press(_button_below(_app.hud, "聲音"))
	_check(not _app.sound_check.button_pressed and not _app.world.get("_audio").enabled, "Sound control disables actual audio module")
	await _key(KEY_ESCAPE)
	_check(_app.session_paused and _app.pause_panel.visible, "Esc opens pause view")
	var paused_time: float = _app.world.get_state().elapsed_ms
	for index in range(50):
		_app.world.step_simulation(0.1, {"throttle": 1.0})
	await create_timer(0.12).timeout
	_check(_app.world.get_state().elapsed_ms == paused_time, "Paused session excludes elapsed time and movement")
	await _capture("pause-1280x720")
	await _press(_app.resume_button)
	_check(not _app.session_paused and not _app.pause_panel.visible and _app.paused_ticks_us > 0, "Resume button excludes wall-clock pause duration")
	await _press(_button_below(_app.hud, "暫停 / Esc"))
	await _press(_button_below(_app.pause_panel, "結束並儲存本次紀錄"))
	for index in range(40):
		if not _app.session_running:
			break
		await create_timer(0.05).timeout
	_check(not _app.session_running and _app.results_panel.visible and not _app.hud.visible, "Finish button opens saved results")
	_check(not _app.world.get("_mirror").is_visible_in_tree(), "Results do not retain mirror overlay")
	var folder: String = _app.last_folder
	for name in ["gaze.csv", "vehicle.csv", "timeline.jsonl", "metadata.json", "summary.json", "events.csv"]:
		_check(FileAccess.file_exists(folder.path_join(name)), "Saved recording file: " + name)
	var summary = null
	if FileAccess.file_exists(folder.path_join("summary.json")):
		summary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("summary.json")))
	_check(summary is Dictionary and summary.metadata.source == "off" and summary.metadata.gaze_samples == 0, "Off results contain no fabricated gaze")
	_check(summary is Dictionary and summary.metadata.vehicle_samples > 0 and summary.events.size() > 0, "Saved results retain vehicle samples and visible hazards")
	await _capture("results-1280x720")
	await _resize(Vector2i(960, 640))
	await _capture("results-960x640")
	await _press(_button_below(_app.results_panel, "返回訓練設定"))
	_check(_app.setup.visible and not _app.results_panel.visible and _app.bridge.helper_pid == -1, "Return button restores setup with unloaded bridge")
	_finish()


func _finish() -> void:
	var name := "ui-test-report-headless.json" if DisplayServer.get_name() == "headless" else "ui-test-report.json"
	var output := FileAccess.open(_output_directory.path_join(name), FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify({"passed": _failures.is_empty(), "failures": _failures, "evidence": _evidence, "display_driver": DisplayServer.get_name()}, "\t"))
		output.close()
	print("%s main UI: %d checks; %d failures" % ["PASS" if _failures.is_empty() else "FAIL", _evidence.size(), _failures.size()])
	if is_instance_valid(_app):
		_app.free()
	quit(0 if _failures.is_empty() else 1)

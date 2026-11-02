extends Node

const World = preload("res://scripts/driving_world.gd")
const Bridge = preload("res://scripts/bridge_manager.gd")
const Recorder = preload("res://scripts/session_recorder.gd")
const Analyzer = preload("res://scripts/tff_analyzer.gd")
const SOURCES := ["off", "webgazer", "sol", "tobii"]
const BG := Color("f6f7f9")
const INK := Color("202428")
const MUTED := Color("46525b")
const GREEN := Color("146c5b")

var world: Node3D
var bridge: Node
var recorder: RefCounted
var analyzer: RefCounted
var ui: CanvasLayer
var setup: Control
var hud: Control
var pause_panel: Control
var results_panel: Control
var participant: LineEdit
var source_select: OptionButton
var duration_select: OptionButton
var difficulty_select: OptionButton
var screen_select: OptionButton
var seed_input: SpinBox
var auto_speed: CheckBox
var sound_check: CheckBox
var calibration_confirm: CheckBox
var sol_host: LineEdit
var sol_port: SpinBox
var device_info: Label
var status_label: Label
var form_error: Label
var connect_button: Button
var start_button: Button
var speed_label: Label
var time_label: Label
var event_label: Label
var tracking_label: Label
var pause_message: Label
var resume_button: Button
var result_text: RichTextLabel
var markers: Array[TextureRect] = []
var marker_layer: Control
var session_running := false
var session_paused := false
var requires_recalibration := false
var started_ticks_us := 0
var paused_ticks_us := 0
var pause_started_us := 0
var last_sample_us := 0
var last_folder := ""
var results: Array = []
var smoke_mode := false
var smoke_ending := false
var smoke_step_count := 0
var smoke_output := ""
var frame_history: Array[Dictionary] = []
var pending_event_ends: Array[Dictionary] = []
var session_finishing := false
var segment_start_ticks_us := 0
var stop_ticks_us := 0

func _ready() -> void:
	Engine.max_fps = 30
	get_tree().auto_accept_quit = false
	_setup_theme()
	world = World.new()
	add_child(world)
	world.hide()
	world.hazard_started.connect(_on_hazard_started)
	world.hazard_ended.connect(_on_hazard_ended)
	world.telemetry.connect(_on_vehicle)
	world.session_finished.connect(func(): _finish_session("completed"))
	bridge = Bridge.new()
	add_child(bridge)
	bridge.gaze_received.connect(_on_gaze)
	bridge.status_changed.connect(_on_device_status)
	bridge.continuity_broken.connect(_on_continuity_broken)
	_build_ui()
	get_viewport().size_changed.connect(_on_resize)
	get_window().focus_exited.connect(_on_focus_exited)
	RenderingServer.frame_post_draw.connect(_capture_frame)
	get_tree().root.close_requested.connect(_on_close)
	for index in range(OS.get_cmdline_user_args().size()):
		var arg := OS.get_cmdline_user_args()[index]
		if arg == "--smoke-run":
			smoke_mode = true
		elif arg == "--smoke-output" and index + 1 < OS.get_cmdline_user_args().size():
			smoke_output = OS.get_cmdline_user_args()[index + 1]
	if smoke_mode:
		_smoke_run.call_deferred()
	else:
		participant.grab_focus()

func _setup_theme() -> void:
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft JhengHei UI", "Microsoft JhengHei", "Noto Sans CJK TC", "Arial"])
	theme.default_font = font
	theme.default_font_size = 20
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "CheckBox", INK)
	for state_name in ["font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		theme.set_color(state_name, "CheckBox", INK)
	theme.set_color("font_color", "OptionButton", INK)
	theme.set_color("font_hover_color", "OptionButton", INK)
	theme.set_color("font_pressed_color", "OptionButton", INK)
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("font_placeholder_color", "LineEdit", MUTED)
	theme.set_color("caret_color", "LineEdit", INK)
	theme.set_color("font_color", "SpinBox", INK)
	theme.set_stylebox("normal", "LineEdit", _style(Color.WHITE, Color("697780")))
	theme.set_stylebox("focus", "LineEdit", _style(Color.WHITE, Color("1d6fd1"), 3))
	for kind in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", kind, _style(Color.WHITE, Color("697780")))
		theme.set_stylebox("hover", kind, _style(Color("e4eee9"), GREEN))
		theme.set_stylebox("pressed", kind, _style(Color("cce0d8"), GREEN))
		theme.set_stylebox("focus", kind, _style(Color(0, 0, 0, 0), Color("1d6fd1"), 3))
		theme.set_stylebox("disabled", kind, _style(Color("e0e4e6"), Color("697780")))
		theme.set_color("font_color", kind, INK)
		theme.set_color("font_hover_color", kind, INK)
		theme.set_color("font_pressed_color", kind, INK)
		theme.set_color("font_focus_color", kind, INK)
		theme.set_color("font_disabled_color", kind, Color("46525b"))
	theme.set_stylebox("focus", "CheckBox", _style(Color(0, 0, 0, 0), Color("1d6fd1"), 3))
	theme.set_stylebox("panel", "PopupMenu", _style(Color.WHITE, Color("697780")))
	theme.set_color("font_color", "PopupMenu", INK)
	theme.set_color("font_hover_color", "PopupMenu", INK)
	theme.set_stylebox("hover", "PopupMenu", _style(Color("e4eee9"), GREEN))
	get_tree().root.theme = theme

func _style(fill: Color, border: Color, width: int = 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(5)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _build_ui() -> void:
	ui = CanvasLayer.new()
	ui.layer = 10
	add_child(ui)
	setup = _screen()
	var content := _scroll_content(setup)
	_label(content, "OcuDrive", 38)
	_label(content, "駕駛情境練習", 26)
	_label(content, "保持車道、觀察道路並適時煞車。眼動只用於紀錄，不控制車輛。", 20, MUTED)
	_label(content, "訓練設定", 24)
	participant = LineEdit.new()
	participant.name = "ParticipantCode"
	participant.placeholder_text = "受試者代碼，例：P01（請勿填姓名）"
	participant.max_length = 40
	_field(content, "受試者代碼", participant)
	duration_select = OptionButton.new()
	for seconds in [60, 180, 300, 600]:
		duration_select.add_item("%d 分鐘" % (seconds / 60), seconds)
	duration_select.select(1)
	_field(content, "每次時間", duration_select)
	difficulty_select = OptionButton.new()
	difficulty_select.add_item("舒緩：低車速，較寬裕的反應距離")
	difficulty_select.add_item("標準：增加車速與事件壓力")
	_field(content, "情境難度", difficulty_select)
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 2147483646
	seed_input.value = 20261101
	seed_input.step = 1
	_field(content, "情境種子（相同種子可重播事件順序）", seed_input)
	auto_speed = CheckBox.new()
	auto_speed.text = "自動維持低車速，仍須自行轉向與煞車"
	auto_speed.button_pressed = true
	auto_speed.custom_minimum_size.y = 48
	content.add_child(auto_speed)
	sound_check = CheckBox.new()
	sound_check.text = "啟用低音量引擎與操作音（練習中可切換）"
	sound_check.custom_minimum_size.y = 48
	content.add_child(sound_check)
	screen_select = OptionButton.new()
	for index in range(maxi(1, DisplayServer.get_screen_count())):
		var screen_size := DisplayServer.screen_get_size(index)
		screen_select.add_item("螢幕 %d · %d × %d" % [index + 1, screen_size.x, screen_size.y], index)
	screen_select.select(maxi(0, DisplayServer.window_get_current_screen()))
	screen_select.item_selected.connect(_on_screen_selected)
	_field(content, "訓練螢幕（校正後不要移動視窗）", screen_select)
	_label(content, "眼動來源", 24)
	source_select = OptionButton.new()
	source_select.name = "EyeSource"
	for text in ["無眼動：只練習駕駛並記錄車況", "WebGazer：一般攝影機，內建校正", "Sol glasses：場景相機與螢幕映射", "Tobii Eye Tracker 5：Experience 校正"]:
		source_select.add_item(text)
	source_select.item_selected.connect(_on_source_selected)
	_field(content, "選擇後按「連接與校正」才載入橋接", source_select)
	sol_host = LineEdit.new()
	sol_host.placeholder_text = "Sol 裝置 IPv4 位址"
	sol_host.custom_minimum_size.y = 48
	content.add_child(sol_host)
	sol_port = SpinBox.new()
	sol_port.min_value = 1
	sol_port.max_value = 65535
	sol_port.value = 8080
	sol_port.prefix = "Sol 連線埠 "
	sol_port.custom_minimum_size.y = 48
	content.add_child(sol_port)
	device_info = _label(content, "", 20, MUTED)
	calibration_confirm = CheckBox.new()
	calibration_confirm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	calibration_confirm.custom_minimum_size.y = 60
	content.add_child(calibration_confirm)
	connect_button = _button(content, "連接與校正", _connect_device)
	status_label = _label(content, bridge.message, 20)
	status_label.name = "DeviceStatus"
	form_error = _label(content, "", 20, Color("a32c25"))
	start_button = _button(content, "開始駕駛練習", _start_session, true)
	start_button.name = "StartTraining"
	_label(content, "操作：方向鍵／WASD 轉向與加減速；空白鍵煞車。支援遊戲手把。Esc 暫停。", 20)
	_label(content, "若感到頭暈或疲勞，請暫停並結束本次練習。紀錄僅描述本次表現，不能推論上路能力。", 18, MUTED)
	_button(content, "開啟本機紀錄資料夾", _open_data)
	_button(content, "結束程式", _on_close)
	hud = Control.new()
	hud.theme = get_tree().root.theme
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hud)
	var strip := PanelContainer.new()
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	strip.add_theme_stylebox_override("panel", _style(Color("f6f7f9"), Color("697780")))
	hud.add_child(strip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	strip.add_child(row)
	speed_label = _label(row, "0 km/h", 26)
	time_label = _label(row, "", 22)
	event_label = _label(row, "觀察道路並保持車道", 20)
	event_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(row, "聲音", _toggle_audio)
	_button(row, "暫停 / Esc", func(): _pause_session("練習已暫停。"))
	tracking_label = Label.new()
	tracking_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	tracking_label.offset_top = -46
	tracking_label.add_theme_color_override("font_color", Color.WHITE)
	tracking_label.add_theme_stylebox_override("normal", _style(Color("202428"), Color("202428")))
	tracking_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(tracking_label)
	hud.hide()
	pause_panel = _screen()
	var pause_content := _scroll_content(pause_panel)
	_label(pause_content, "練習暫停", 36)
	pause_message = _label(pause_content, "", 22)
	resume_button = _button(pause_content, "繼續駕駛", _resume_session, true)
	_button(pause_content, "結束並儲存本次紀錄", func(): _finish_session("participant_stopped"))
	pause_panel.hide()
	results_panel = _screen()
	var result_content := _scroll_content(results_panel)
	_label(result_content, "本次駕駛紀錄", 36)
	result_text = RichTextLabel.new()
	result_text.fit_content = true
	result_text.custom_minimum_size.y = 260
	result_text.selection_enabled = true
	result_text.add_theme_color_override("default_color", INK)
	result_text.add_theme_font_size_override("normal_font_size", 20)
	result_content.add_child(result_text)
	_button(result_content, "開啟本次紀錄資料夾", _open_last_session)
	_button(result_content, "返回訓練設定", _return_setup, true)
	_button(result_content, "結束程式", _on_close)
	results_panel.hide()
	_build_markers()
	_on_source_selected(0)

func _screen() -> Control:
	var background := ColorRect.new()
	background.theme = get_tree().root.theme
	background.color = BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.add_child(background)
	return background

func _scroll_content(parent: Control) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 84 if edge in ["left", "right"] else 28)
	parent.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var center := HBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 14)
	center.add_child(content)
	return content

func _label(parent: Node, text: String, font_size: int = 20, color: Color = INK) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(label)
	return label

func _field(parent: VBoxContainer, title: String, control: Control) -> void:
	_label(parent, title)
	control.custom_minimum_size.y = 48
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(control)

func _button(parent: Node, text: String, action: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 48
	button.pressed.connect(action)
	if primary:
		button.add_theme_stylebox_override("normal", _style(GREEN, GREEN))
		button.add_theme_stylebox_override("hover", _style(Color("105547"), GREEN))
		button.add_theme_stylebox_override("pressed", _style(Color("0d483d"), GREEN))
		for state_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(state_name, Color.WHITE)
	parent.add_child(button)
	return button

func _build_markers() -> void:
	marker_layer = Control.new()
	marker_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.add_child(marker_layer)
	for index in range(4):
		var path := "res://markers/marker_%d.png" % index
		if not ResourceLoader.exists(path):
			continue
		var marker := TextureRect.new()
		marker.texture = load(path)
		marker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		marker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		marker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		marker_layer.add_child(marker)
		markers.append(marker)
	_layout_markers()
	marker_layer.hide()

func _layout_markers() -> void:
	var dimensions := get_viewport().get_visible_rect().size
	var centers := [Vector2(0.04, 0.04), Vector2(0.96, 0.04), Vector2(0.96, 0.96), Vector2(0.04, 0.96)]
	var edge := minf(56.0, dimensions.y * 0.075)
	for index in range(markers.size()):
		markers[index].position = dimensions * centers[index] - Vector2.ONE * edge / 2.0
		markers[index].size = Vector2.ONE * edge

func _on_source_selected(index: int) -> void:
	bridge.stop_device()
	calibration_confirm.button_pressed = false
	sol_host.visible = index == 2
	sol_port.visible = index == 2
	calibration_confirm.visible = index in [2, 3]
	connect_button.visible = index != 0
	marker_layer.visible = false if marker_layer == null else index == 2
	match SOURCES[index]:
		"off":
			device_info.text = "只記錄駕駛與事件。眼動指標顯示無資料，不使用滑鼠或假視線。"
		"webgazer":
			device_info.text = "連接後開啟離線校正頁：允許攝影機、九點校正、五點驗證。完成後返回此視窗。只選此來源時載入模型。"
		"sol":
			device_info.text = "先以 Chronus 完成 Sol 校正。四角標記用於將場景相機視線映射到螢幕；缺少標記時不計眼動。需廠商 SDK 與裝置連線。"
			if FileAccess.file_exists("res://embedded/capabilities.json"):
				var capabilities = JSON.parse_string(FileAccess.get_file_as_string("res://embedded/capabilities.json"))
				if capabilities is Dictionary and not capabilities.get("sol_vendor_sdk_included", false):
					device_info.text = "此建置缺少原廠 Sol SDK，尚無法連線。已包含橋接與四角動態映射；取得 Chronus SDK 後可重建完整版本。"
			calibration_confirm.text = "我已完成 Sol / Chronus 眼動校正"
		"tobii":
			device_info.text = "請先在同一訓練螢幕上使用 Windows 的 Tobii Experience 完成校正，再按連接。這裡不改寫官方硬體校正。"
			calibration_confirm.text = "我已在目前訓練螢幕完成 Tobii Experience 校正"

func _on_screen_selected(index: int) -> void:
	bridge.stop_device()
	calibration_confirm.button_pressed = false
	DisplayServer.window_set_current_screen(screen_select.get_item_id(index))
	form_error.text = "已切換訓練螢幕，請重新連接與校正眼動。"

func _connect_device() -> void:
	form_error.text = ""
	var source: String = SOURCES[source_select.selected]
	if source in ["sol", "tobii"] and not calibration_confirm.button_pressed:
		form_error.text = "請先完成上方指定的裝置校正，再勾選確認。"
		calibration_confirm.grab_focus()
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	bridge.start_device(source, {"sol_host": sol_host.text, "sol_port": int(sol_port.value)})

func _settings() -> Dictionary:
	return {"participant_code": participant.text.strip_edges(),
		"duration_s": duration_select.get_selected_id(), "difficulty": "gentle" if difficulty_select.selected == 0 else "standard",
		"seed": int(seed_input.value), "auto_speed": auto_speed.button_pressed, "audio_enabled": sound_check.button_pressed,
		"source": SOURCES[source_select.selected], "calibration": bridge.calibration.duplicate(true),
		"calibration_confirmed": calibration_confirm.button_pressed, "display_index": DisplayServer.window_get_current_screen(),
		"display_pixels": {"width": DisplayServer.screen_get_size().x, "height": DisplayServer.screen_get_size().y},
		"rendering_method": "gl_compatibility", "fps_limit": 30, "test_run": smoke_mode}

func _start_session() -> void:
	if session_running:
		return
	form_error.text = ""
	var config := _settings()
	if config.source != "off" and bridge.state not in ["ready", "streaming"]:
		form_error.text = "眼動尚未就緒，請完成連接與校正，或選擇無眼動練習。"
		return
	if config.source in ["sol", "tobii"] and not calibration_confirm.button_pressed:
		form_error.text = "請先完成裝置校正並勾選確認。"
		return
	recorder = Recorder.new()
	if not recorder.open_session(config):
		form_error.text = recorder.error_message
		return
	analyzer = Analyzer.new()
	results = []
	frame_history.clear()
	pending_event_ends.clear()
	session_finishing = false
	last_folder = recorder.folder
	requires_recalibration = false
	session_paused = false
	paused_ticks_us = 0
	pause_started_us = 0
	last_sample_us = Time.get_ticks_usec()
	setup.hide()
	results_panel.hide()
	pause_panel.hide()
	world.show()
	hud.show()
	marker_layer.visible = config.source == "sol"
	world.configure(config)
	if not smoke_mode:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	started_ticks_us = Time.get_ticks_usec()
	segment_start_ticks_us = started_ticks_us
	stop_ticks_us = 0
	session_running = true
	world.start_session()
	tracking_label.text = "無眼動 · 僅記錄駕駛" if config.source == "off" else "%s · 等待有效視線" % config.source
	if get_viewport().gui_get_focus_owner() != null:
		get_viewport().gui_get_focus_owner().release_focus()

func _on_vehicle(sample: Dictionary) -> void:
	if not session_running or recorder == null:
		return
	speed_label.text = "%02d km/h" % roundi(float(sample.get("speed_kph", 0.0)))
	time_label.text = "剩餘 %02d:%02d" % [int(sample.get("remaining_s", 0.0)) / 60, int(sample.get("remaining_s", 0.0)) % 60]
	var row := sample.duplicate(true)
	row["t_ms"] = sample.get("elapsed_ms")
	row["speed_kmh"] = sample.get("speed_kph")
	row["lane_offset_m"] = sample.get("lateral_m")
	row["steering"] = sample.get("steer")
	row["lane_departure_s"] = sample.get("lane_departure_s")
	recorder.write_vehicle(row)
	if recorder.failed:
		_pause_session(recorder.error_message)
		resume_button.disabled = true

func _on_hazard_started(event: Dictionary) -> void:
	if not session_running:
		return
	analyzer.begin_event(event)
	recorder.write_event("event_start", event)
	# Naming a hazard during measurement would cue the participant and bias TFF.
	event_label.text = "觀察道路並保持車道"

func _on_hazard_ended(event: Dictionary) -> void:
	if not session_running:
		return
	var offset := float(event.get("offset_ms", world.get_state().get("elapsed_ms", 0.0)))
	analyzer.mark_event_offset(str(event.get("id", "")), offset)
	pending_event_ends.append({"event": event.duplicate(true), "offset_ms": offset, "due_ticks_us": Time.get_ticks_usec() + 250000})
	recorder.write_event("event_end", event)

func _on_gaze(sample: Dictionary) -> void:
	last_sample_us = int(sample.get("received_ticks_us", Time.get_ticks_usec()))
	if not session_running or session_paused:
		return
	var sample_copy := sample.duplicate(true)
	var mapped_us := float(sample.get("mapped_ticks_us", -1.0))
	var frame := _frame_for_sample(mapped_us)
	var aois: Array = []
	if frame.is_empty():
		sample_copy["t_ms"] = null
		sample_copy["valid"] = false
		sample_copy["reason"] = "missing_frame_history_or_stale_delivery"
	else:
		sample_copy["t_ms"] = frame["sample_t_ms"]
		sample_copy["frame_ticks_us"] = frame["ticks_us"]
		aois = frame["aois"]
	var classification := {"accepted": false, "reason": sample_copy.get("reason", "")}
	if frame.is_empty():
		analyzer.break_continuity()
	else:
		classification = analyzer.add_sample(sample_copy, aois)
	sample_copy["analysis"] = classification
	recorder.write_gaze(sample_copy, aois)
	tracking_label.text = "%s · %s · %d 筆" % [bridge.source, "有效視線" if sample_copy.valid else "無效／未追蹤", recorder.gaze_count]

func _on_device_status(state: String, text: String) -> void:
	if is_instance_valid(status_label):
		status_label.text = text
		status_label.add_theme_color_override("font_color", Color("a32c25") if state in ["error", "disconnected"] else INK)
	if session_running and recorder != null:
		recorder.write_event("device_status", {"state": state, "message": text, "t_ms": world.get_state().get("elapsed_ms")})
		if state in ["error", "disconnected", "stopped"]:
			_pause_session("眼動連線中斷。請結束並儲存本次紀錄，再重新連接校正。")
			requires_recalibration = true
			resume_button.disabled = true

func _pause_session(reason: String) -> void:
	if not session_running or session_paused:
		return
	session_paused = true
	frame_history.clear()
	pause_started_us = Time.get_ticks_usec()
	world.set_paused(true)
	analyzer.break_continuity()
	recorder.write_event("pause", {"t_ms": world.get_state().get("elapsed_ms"), "reason": reason})
	pause_message.text = reason + "\n暫停時間不計入訓練或 TFF。"
	resume_button.disabled = requires_recalibration or recorder.failed
	pause_panel.show()
	marker_layer.hide()
	resume_button.grab_focus()

func _resume_session() -> void:
	if not session_running or not session_paused or requires_recalibration or recorder.failed:
		return
	if bridge.source != "off" and bridge.state not in ["ready", "streaming"]:
		pause_message.text = "眼動尚未就緒，請結束儲存後重新連接。"
		return
	paused_ticks_us += Time.get_ticks_usec() - pause_started_us
	frame_history.clear()
	segment_start_ticks_us = Time.get_ticks_usec()
	session_paused = false
	analyzer.break_continuity()
	world.set_paused(false)
	recorder.write_event("resume", {"t_ms": world.get_state().get("elapsed_ms")})
	pause_panel.hide()
	marker_layer.visible = bridge.source == "sol"
	if get_viewport().gui_get_focus_owner() != null:
		get_viewport().gui_get_focus_owner().release_focus()

func _finish_session(reason: String) -> void:
	if not session_running or smoke_ending or session_finishing:
		return
	session_finishing = true
	stop_ticks_us = Time.get_ticks_usec()
	world.stop_session()
	await get_tree().create_timer(0.30).timeout
	_flush_event_ends(true)
	var state: Dictionary = world.get_state()
	var remaining: Array = analyzer.finish_all(float(state.get("elapsed_ms", 0.0)))
	for result in remaining:
		var exists := false
		for saved in results:
			if saved.get("id") == result.get("id"):
				exists = true
		if not exists:
			results.append(result)
	session_running = false
	session_paused = false
	var saved: bool = recorder.finish(results, state, reason)
	bridge.stop_device()
	hud.hide()
	pause_panel.hide()
	marker_layer.hide()
	world.hide()
	results_panel.show()
	var lines := PackedStringArray()
	lines.append("%s · %.1f 秒 · %.0f 公尺" % ["時間到，已結束" if reason == "completed" else "本次已提前結束", float(state.get("elapsed_s", 0.0)), float(state.get("distance_m", 0.0))])
	lines.append("碰撞：%d 次；闖紅燈：%d 次；車道偏離：%.1f 秒" % [int(state.get("collisions", 0)), int(state.get("red_light_violations", 0)), float(state.get("lane_departure_s", 0.0))])
	lines.append("眼動：%d 筆，有效 %d 筆" % [recorder.gaze_count, recorder.valid_count])
	lines.append("\n事件：首次進入 / TFF（持續注視代理值）")
	if results.is_empty():
		lines.append("本次尚未遇到可紀錄的道路事件。")
	for result in results:
		lines.append("%s：%s / %s" % [str(result.get("label", result.get("id", ""))), _metric(result.get("time_to_first_entry_ms")), _metric(result.get("time_to_first_fixation_ms"))])
	lines.append("\nTFF 需連續停留至少 120 ms 且至少 3 筆；缺失、無效、離開目標或間隔超過 100 ms 會中斷。這是 AOI 停留代理值，不是臨床判定。")
	lines.append("\n" + ("紀錄已儲存：" if saved else "儲存未完整，請保留原始檔：") + ProjectSettings.globalize_path(last_folder))
	result_text.text = "\n".join(lines)
	if smoke_mode:
		smoke_ending = true
		if not smoke_output.is_empty():
			var output := FileAccess.open(smoke_output, FileAccess.WRITE)
			if output != null:
				output.store_string(JSON.stringify({"saved": saved, "folder": ProjectSettings.globalize_path(last_folder), "events": results.size(), "vehicle_samples": recorder.vehicle_count, "gaze_samples": recorder.gaze_count, "state": state}))
		print("OCUDRIVE_SMOKE ", JSON.stringify({"saved": saved, "events": results.size(), "vehicle_samples": recorder.vehicle_count, "folder": last_folder}))
		get_tree().quit(0 if saved and results.size() > 0 and recorder.vehicle_count > 0 else 1)

func _metric(value: Variant) -> String:
	return "無資料／未成立" if value == null else "%.0f ms" % float(value)

func _return_setup() -> void:
	results_panel.hide()
	setup.show()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_on_source_selected(source_select.selected)
	start_button.grab_focus()

func _toggle_audio() -> void:
	sound_check.button_pressed = not sound_check.button_pressed
	world.configure(_settings())
	if session_running:
		recorder.write_event("audio", {"enabled": sound_check.button_pressed, "t_ms": world.get_state().get("elapsed_ms")})

func _data_root() -> String:
	var override := OS.get_environment("OCUDRIVE_DATA_DIR")
	return override.path_join("sessions") if not override.is_empty() else "user://sessions"

func _open_data() -> void:
	var path := ProjectSettings.globalize_path(_data_root())
	if DirAccess.make_dir_recursive_absolute(path) != OK or OS.shell_open(path) != OK:
		form_error.text = "無法開啟資料夾：" + path

func _open_last_session() -> void:
	if not last_folder.is_empty():
		OS.shell_open(ProjectSettings.globalize_path(last_folder))

func _on_resize() -> void:
	_layout_markers()
	if session_running and not smoke_mode:
		requires_recalibration = bridge.source != "off"
		_pause_session("視窗或顯示器尺寸改變。" + ("眼動座標需重新校正，請結束並儲存後回到設定。" if requires_recalibration else "請確認道路畫面後繼續。"))
		resume_button.disabled = requires_recalibration

func _on_focus_exited() -> void:
	if session_running and not smoke_mode:
		_pause_session("視窗離開前景，練習已自動暫停。")

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if session_running:
			if session_paused:
				_resume_session()
			else:
				_pause_session("練習已暫停。")
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	_flush_event_ends()
	if smoke_mode and session_running and not session_paused and not session_finishing:
		for _index in range(90):
			if not session_running:
				break
			world.step_simulation(1.0 / 60.0, {"steer": 0.0, "throttle": 0.0, "brake": 0.0})
	if session_running and not session_paused and bridge.source != "off" and Time.get_ticks_usec() - last_sample_us > 3000000:
		_pause_session("超過 3 秒沒有眼動樣本。請結束並儲存本次紀錄，再重新連接校正。")
		requires_recalibration = true
		resume_button.disabled = true

func _on_close() -> void:
	if session_running:
		await _finish_session("application_closed")
	bridge.stop_device()
	get_tree().quit()

func _smoke_run() -> void:
	participant.text = "SMOKE"
	duration_select.select(0)
	source_select.select(0)
	_on_source_selected(0)
	_start_session()
	if not session_running:
		push_error("Smoke session could not start: " + form_error.text)
		get_tree().quit(1)

func _capture_frame() -> void:
	if not session_running or session_paused or session_finishing:
		return
	var ticks := Time.get_ticks_usec()
	frame_history.append({"ticks_us": ticks, "elapsed_ms": float(world.get_state().get("elapsed_ms", 0.0)), "aois": world.get_event_aois().duplicate(true)})
	while not frame_history.is_empty() and ticks - int(frame_history[0]["ticks_us"]) > 2000000:
		frame_history.pop_front()

func _frame_for_sample(ticks_us: float) -> Dictionary:
	if ticks_us < float(segment_start_ticks_us) or (stop_ticks_us > 0 and ticks_us > float(stop_ticks_us)) or Time.get_ticks_usec() - ticks_us > 250000.0 or ticks_us > float(Time.get_ticks_usec()) + 20000.0:
		return {}
	for index in range(frame_history.size() - 1, -1, -1):
		var frame := frame_history[index].duplicate(true)
		if float(frame["ticks_us"]) > ticks_us:
			continue
		var t_ms := float(frame["elapsed_ms"])
		if index + 1 < frame_history.size():
			var next := frame_history[index + 1]
			var interval := float(next["ticks_us"]) - float(frame["ticks_us"])
			if interval > 0.0:
				t_ms = lerpf(t_ms, float(next["elapsed_ms"]), clampf((ticks_us - float(frame["ticks_us"])) / interval, 0.0, 1.0))
		else:
			t_ms += minf(33.0, maxf(0.0, (ticks_us - float(frame["ticks_us"])) / 1000.0))
		frame["sample_t_ms"] = t_ms
		return frame
	return {}

func _flush_event_ends(force: bool = false) -> void:
	if analyzer == null:
		return
	for index in range(pending_event_ends.size() - 1, -1, -1):
		var item := pending_event_ends[index]
		if not force and Time.get_ticks_usec() < int(item["due_ticks_us"]):
			continue
		var event: Dictionary = item["event"]
		var result: Dictionary = analyzer.end_event(str(event.get("id", "")), float(item["offset_ms"]))
		if not result.is_empty():
			result["driving_response"] = event
			results.append(result)
		pending_event_ends.remove_at(index)

func _on_continuity_broken(reason: String) -> void:
	if session_running and analyzer != null:
		analyzer.break_continuity()
		recorder.write_event("gaze_rejected", {"reason": reason, "t_ms": world.get_state().get("elapsed_ms")})

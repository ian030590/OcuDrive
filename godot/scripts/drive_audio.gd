extends Node

var enabled: bool = false
var _engine: AudioStreamPlayer
var _cue: AudioStreamPlayer


func set_enabled(value: bool) -> void:
	enabled = value
	if enabled and not is_instance_valid(_engine):
		_engine = AudioStreamPlayer.new()
		_engine.stream = _tone(72.0, 0.25, true)
		_engine.volume_db = -26.0
		add_child(_engine)
		_cue = AudioStreamPlayer.new()
		_cue.volume_db = -18.0
		add_child(_cue)
	if not enabled:
		stop()


func set_engine(speed_mps: float, running: bool) -> void:
	if not enabled or not is_instance_valid(_engine):
		return
	if not running:
		_engine.stop()
		return
	_engine.pitch_scale = clampf(0.8 + speed_mps / 15.0, 0.8, 1.8)
	if not _engine.playing:
		_engine.play()


func play_cue(kind: String) -> void:
	if not enabled or not is_instance_valid(_cue):
		return
	# Event onset is intentionally silent, so sound cannot reveal an AOI before gaze.
	var frequency := 330.0 if kind == "collision" else 520.0
	_cue.stream = _tone(frequency, 0.12, false)
	_cue.play()


func stop() -> void:
	if is_instance_valid(_engine):
		_engine.stop()
	if is_instance_valid(_cue):
		_cue.stop()


func _tone(frequency: float, duration: float, looped: bool) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 22050
	var count := int(duration * stream.mix_rate)
	var samples := PackedByteArray()
	samples.resize(count * 2)
	for index in range(count):
		var time_s := float(index) / float(stream.mix_rate)
		var envelope := 1.0 if looped else sin(PI * float(index) / float(count))
		var value := sin(TAU * frequency * time_s) * envelope * 0.18
		samples.encode_s16(index * 2, int(value * 32767.0))
	stream.data = samples
	if looped:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = count
	return stream

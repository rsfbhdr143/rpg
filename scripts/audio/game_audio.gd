class_name GameAudio
extends RefCounted
## Обёртка над автозагрузкой Audio (её делает поток звука: scripts/audio/audio_manager.gd).
## Если автозагрузки нет или звук ещё не готов, вызовы тихо ничего не делают,
## поэтому игра работает и без звуковых файлов.

static var _music := ""
static var _ambient := ""


static func _audio() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("Audio")


static func _call(method: String, args: Array = []) -> void:
	var a := _audio()
	if a != null and a.has_method(method):
		a.callv(method, args)


static func music(id: String, fade := 1.0) -> void:
	if id == "" or id == _music:
		return
	_music = id
	_call("play_music", [id, fade])


static func stop_music(fade := 1.0) -> void:
	_music = ""
	_call("stop_music", [fade])


static func ambient(id: String, fade := 1.5) -> void:
	if id == _ambient:
		return
	_ambient = id
	var a := _audio()
	if a == null:
		return
	if id == "":
		for m in ["stop_ambient", "stop_ambience"]:
			if a.has_method(m):
				a.call(m, fade)
				return
		return
	for m in ["play_ambient", "play_ambience"]:
		if a.has_method(m):
			a.call(m, id, fade)
			return


static func sfx(id: String) -> void:
	if id != "":
		_call("play_sfx", [id])


static func stinger(id: String) -> void:
	if id != "":
		_call("play_stinger", [id])


static func skill(skill_id: String) -> void:
	_call("play_skill", [skill_id])


static func skill_impact(skill_id: String) -> void:
	_call("play_skill_impact", [skill_id])


static func ui(id: String) -> void:
	_call("play_ui", [id])


## bus: "Music", "SFX", "UI", "Ambience" или "Master"; value 0..1.
static func set_volume(bus: String, value: float) -> void:
	var a := _audio()
	if a != null and a.has_method("set_volume"):
		a.call("set_volume", bus, value)
		return
	var idx := AudioServer.get_bus_index(bus)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(value, 0.0001)))


static func reset() -> void:
	_music = ""
	_ambient = ""

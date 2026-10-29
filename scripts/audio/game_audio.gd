class_name GameAudio
extends RefCounted
## Обёртка над автозагрузкой Audio (scripts/audio/audio_manager.gd, все id — в data/audio.json).
## Если автозагрузки нет (тесты, сервер без звука), вызовы тихо ничего не делают.
## Повторный запуск той же музыки или петли менеджер сам пропускает.


static func _audio() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null or DisplayServer.get_name() == "headless":
		return null
	return loop.root.get_node_or_null("Audio")


static func _call(method: String, args: Array = []) -> void:
	var a := _audio()
	if a != null and a.has_method(method):
		a.callv(method, args)


## "" или "none" — тишина.
static func music(id: String, fade := -1.0) -> void:
	if id == "none":
		id = ""
	_call("play_music", [id, fade])


static func stop_music(fade := 1.0) -> void:
	_call("stop_music", [fade])


static func current_music() -> String:
	var a := _audio()
	return str(a.get("current_music")) if a != null else ""


static func ambient(id: String, fade := -1.0) -> void:
	if id == "none":
		id = ""
	_call("play_ambient", [id, fade])


static func sfx(id: String, volume_db := 0.0, pitch := 1.0) -> void:
	if id != "":
		_call("play_sfx", [id, volume_db, pitch])


static func stinger(id: String) -> void:
	if id != "":
		_call("play_stinger", [id])


static func skill(skill_id: String) -> void:
	_call("play_skill", [skill_id, "cast"])


static func skill_impact(skill_id: String, crit := false) -> void:
	_call("play_skill_impact", [skill_id, crit])


static func skill_miss(skill_id: String) -> void:
	_call("play_skill_miss", [skill_id])


static func status(status_id: String) -> void:
	_call("play_status", [status_id])


static func surface(surface_id: String) -> void:
	_call("play_surface", [surface_id])


static func ui(id: String) -> void:
	_call("play_ui", [id])


static func stop_all(fade := 0.5) -> void:
	_call("stop_all", [fade])


## bus: "Master", "Music", "Ambient", "SFX", "UI"; value 0..1.
static func set_volume(bus: String, value: float) -> void:
	var a := _audio()
	if a != null and a.has_method("set_volume"):
		a.call("set_volume", bus, value)
		return
	var idx := AudioServer.get_bus_index(bus)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(value, 0.0001)))


static func get_volume(bus: String) -> float:
	var a := _audio()
	if a != null and a.has_method("get_volume"):
		return float(a.call("get_volume", bus))
	return 1.0

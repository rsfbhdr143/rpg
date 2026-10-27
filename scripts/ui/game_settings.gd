class_name GameSettings
extends RefCounted
## Настройки игрока (громкость, пиксельность, полный экран, скорость текста) в user://settings.cfg.

const PATH := "user://settings.cfg"

static var values := {
	"music": 0.7, "sfx": 0.8, "ambient": 0.6, "fullscreen": false,
	"pixel_scale": 2, "posterize": true, "text_speed": 60.0, "player_name": "Игрок",
}
static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for k in values.keys():
			values[k] = cfg.get_value("settings", k, values[k])
	apply()


static func get_value(key: String) -> Variant:
	ensure_loaded()
	return values.get(key)


static func set_value(key: String, v: Variant) -> void:
	ensure_loaded()
	values[key] = v
	apply()
	save()


static func save() -> void:
	var cfg := ConfigFile.new()
	for k in values:
		cfg.set_value("settings", k, values[k])
	cfg.save(PATH)


static func apply() -> void:
	GameAudio.set_volume("Music", float(values["music"]))
	GameAudio.set_volume("SFX", float(values["sfx"]))
	GameAudio.set_volume("UI", float(values["sfx"]))
	GameAudio.set_volume("Ambience", float(values["ambient"]))
	if not OS.has_feature("web") and DisplayServer.get_name() != "headless":
		var want := DisplayServer.WINDOW_MODE_FULLSCREEN if bool(values["fullscreen"]) else DisplayServer.WINDOW_MODE_WINDOWED
		if DisplayServer.window_get_mode() != want and not (want == DisplayServer.WINDOW_MODE_WINDOWED \
				and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED):
			DisplayServer.window_set_mode(want)

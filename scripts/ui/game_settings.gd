class_name GameSettings
extends RefCounted
## Настройки игрока (пиксельность, полный экран, скорость текста, имя) в user://settings.cfg.
## Громкость хранит сам звуковой менеджер (user://audio_settings.cfg), здесь только мост к нему.

const PATH := "user://settings.cfg"
const VOLUME_BUSES := {"music": "Music", "sfx": "SFX", "ambient": "Ambient", "ui": "UI"}
## Растёт, когда меняются значения по умолчанию: старый файл настроек тогда их не перебивает.
const VERSION := 3

static var values := {
	"fullscreen": false, "pixel_scale": 2, "posterize": true, "shake": true,
	"text_speed": 60.0, "player_name": "Игрок", "server_url": "ws://127.0.0.1:8910",
}
static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		var old := int(cfg.get_value("settings", "version", 1)) < VERSION
		for k in values.keys():
			if old and k == "pixel_scale":
				continue
			values[k] = cfg.get_value("settings", k, values[k])
	apply()


static func get_value(key: String) -> Variant:
	ensure_loaded()
	if VOLUME_BUSES.has(key):
		return GameAudio.get_volume(VOLUME_BUSES[key])
	return values.get(key)


static func set_value(key: String, v: Variant) -> void:
	ensure_loaded()
	if VOLUME_BUSES.has(key):
		GameAudio.set_volume(VOLUME_BUSES[key], float(v))
		return
	values[key] = v
	apply()
	save()


static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "version", VERSION)
	for k in values:
		cfg.set_value("settings", k, values[k])
	cfg.save(PATH)


static func apply() -> void:
	if OS.has_feature("web") or DisplayServer.get_name() == "headless":
		return
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if bool(values["fullscreen"]) else DisplayServer.WINDOW_MODE_WINDOWED
	var now := DisplayServer.window_get_mode()
	if now == want or (want == DisplayServer.WINDOW_MODE_WINDOWED and now == DisplayServer.WINDOW_MODE_MAXIMIZED):
		return
	DisplayServer.window_set_mode(want)

extends Node
## Музыка, фоновые петли и звуки. Автозагрузка `Audio`.
## Все id, файлы и громкости лежат в data/audio.json, для нового звука код трогать не нужно.
##   Audio.play_music("village")            — сменить музыку с плавным переходом
##   Audio.play_stinger("victory")          — короткая вставка поверх приглушённой музыки
##   Audio.play_ambient("amb_forest")       — фоновая петля (ветер, болото, костёр)
##   Audio.play_sfx("melee_hit")            — звук: случайный вариант и небольшой разброс высоты
##   Audio.play_ui("ui_click")              — звук интерфейса
##   Audio.play_skill("fireball")           — звук применения навыка (раздел skills)
##   Audio.play_skill_impact("fireball")    — звук попадания навыка, crit = true для крита
##   Audio.play_status("frozen"), Audio.play_surface("steam") — звуки статусов и поверхностей
##   Audio.set_volume("Music", 0.5)         — громкость шины 0..1, сохраняется между запусками
## Неизвестный id не роняет игру, а один раз пишет предупреждение.
## Эффекты на шинах не используются: в веб-сборке Godot они не работают, реверберация уже в файлах.

const CONFIG_PATH := "res://data/audio.json"
const SETTINGS_PATH := "user://audio_settings.cfg"
## Шины создаются сами, если их нет в раскладке проекта.
## MusicBed (подшина Music) приглушается на время стингеров.
const BUSES := ["Music", "MusicBed", "Ambient", "SFX", "UI"]
const BUS_PARENT := {"MusicBed": "Music"}
const SFX_VOICES := 16
const SILENT_DB := -60.0

var config: Dictionary = {}
var current_music := ""
var current_ambient := ""

var _root := "res://assets/audio/"
var _music_players: Array[AudioStreamPlayer] = []
var _music_index := 0
var _ambient_players: Array[AudioStreamPlayer] = []
var _ambient_index := 0
var _stinger_player: AudioStreamPlayer
var _sfx_players: Array[AudioStreamPlayer] = []
var _streams: Dictionary = {}  # полный путь -> AudioStream (или null, если файла нет)
var _tweens: Dictionary = {}  # плеер -> Tween
var _duck_tween: Tween
var _positions: Dictionary = {}  # id музыки -> позиция, с которой продолжить
var _last_variant: Dictionary = {}  # id звука -> индекс последнего варианта
var _last_played: Dictionary = {}  # id звука -> время запуска, мс
var _volumes: Dictionary = {}  # шина -> громкость игрока 0..1
var _warned: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_config()
	_setup_buses()
	_load_settings()
	for _i in 2:
		_music_players.append(_make_player("MusicBed"))
		_ambient_players.append(_make_player("Ambient"))
	_stinger_player = _make_player("Music")
	_stinger_player.finished.connect(_unduck)
	for _i in SFX_VOICES:
		_sfx_players.append(_make_player("SFX"))


# --- Музыка ------------------------------------------------------------------

## Плавно переключает музыку. Пустой id останавливает её. fade < 0 берёт значение из defaults.
func play_music(id: String, fade := -1.0) -> void:
	if fade < 0.0:
		fade = float(_defaults().get("music_fade", 1.5))
	if id == "":
		stop_music(fade)
		return
	var key := _canonical("music", id)
	var entry := _entry("music", key)
	if entry.is_empty():
		_warn("music", id)
		return
	var current := _music_players[_music_index]
	if key == current_music and current.playing:
		return
	var stream := _stream(str(entry.get("file", "")))
	if stream == null:
		return
	_set_loop(stream, bool(entry.get("loop", true)))
	_remember_position()
	_fade(current, SILENT_DB, fade, true)
	_music_index = 1 - _music_index
	var player := _music_players[_music_index]
	player.stream = stream
	player.volume_db = SILENT_DB
	var from := 0.0
	if bool(entry.get("resume", false)):
		from = float(_positions.get(key, 0.0))
	player.play(from)
	current_music = key
	_fade(player, float(entry.get("volume_db", 0.0)), fade)


func stop_music(fade := 1.0) -> void:
	_remember_position()
	for p in _music_players:
		_fade(p, SILENT_DB, fade, true)
	current_music = ""


## Короткая музыкальная вставка (победа, уровень, знамение). Музыка на это время приглушается
## или останавливается: поле "music" у стингера = "duck" | "stop" | "keep".
func play_stinger(id: String) -> void:
	var entry := _entry("stingers", _canonical("stingers", id))
	if entry.is_empty():
		_warn("stingers", id)
		return
	var stream := _stream(str(entry.get("file", "")))
	if stream == null:
		return
	_set_loop(stream, false)
	_stinger_player.stream = stream
	_stinger_player.volume_db = float(entry.get("volume_db", 0.0))
	_stinger_player.play()
	match str(entry.get("music", "duck")):
		"stop":
			stop_music(float(entry.get("fade", 0.5)))
		"duck":
			_duck(float(_defaults().get("stinger_duck_db", -14.0)))


func is_music_playing() -> bool:
	return current_music != "" and _music_players[_music_index].playing


# --- Фоновые петли -----------------------------------------------------------


func play_ambient(id: String, fade := -1.0) -> void:
	if fade < 0.0:
		fade = float(_defaults().get("ambient_fade", 2.0))
	if id == "":
		stop_ambient(fade)
		return
	var key := _canonical("ambient", id)
	var entry := _entry("ambient", key)
	if entry.is_empty():
		_warn("ambient", id)
		return
	var current := _ambient_players[_ambient_index]
	if key == current_ambient and current.playing:
		return
	var stream := _stream(str(entry.get("file", "")))
	if stream == null:
		return
	_set_loop(stream, true)
	_fade(current, SILENT_DB, fade, true)
	_ambient_index = 1 - _ambient_index
	var player := _ambient_players[_ambient_index]
	player.stream = stream
	player.volume_db = SILENT_DB
	# Каждый раз с нового места, чтобы петля не звучала одинаково при каждом входе в локацию.
	player.play(randf() * maxf(stream.get_length() - 1.0, 0.0))
	current_ambient = key
	_fade(player, float(entry.get("volume_db", 0.0)), fade)


func stop_ambient(fade := 2.0) -> void:
	for p in _ambient_players:
		_fade(p, SILENT_DB, fade, true)
	current_ambient = ""


## Старое имя из первых договорённостей.
func play_ambience(id: String, fade := -1.0) -> void:
	play_ambient(id, fade)


func stop_ambience(fade := 2.0) -> void:
	stop_ambient(fade)


# --- Звуки -------------------------------------------------------------------


## Играет звук по id. volume_db добавляется к громкости из json, pitch умножает высоту.
## Возвращает плеер (например, чтобы остановить длинный звук) или null.
func play_sfx(id: String, volume_db := 0.0, pitch := 1.0) -> AudioStreamPlayer:
	var key := _canonical("sfx", id)
	var entry := _entry("sfx", key)
	if entry.is_empty():
		_warn("sfx", id)
		return null
	var defaults := _defaults()
	var now := Time.get_ticks_msec()
	var min_gap := float(entry.get("min_gap", defaults.get("sfx_min_gap", 0.03)))
	if now - int(_last_played.get(key, -100000)) < int(min_gap * 1000.0):
		return null
	var files := _files(entry)
	if files.is_empty():
		return null
	var i := 0
	if files.size() > 1:
		i = randi() % files.size()
		if i == int(_last_variant.get(key, -1)):
			i = (i + 1) % files.size()
	_last_variant[key] = i
	var stream := _stream(files[i])
	if stream == null:
		return null
	_set_loop(stream, false)
	var max_instances := int(entry.get("max_instances", defaults.get("sfx_max_instances", 4)))
	var player := _free_sfx_player(key, max_instances)
	player.stream = stream
	player.bus = str(entry.get("bus", "SFX"))
	player.volume_db = float(entry.get("volume_db", 0.0)) + volume_db
	var jitter := float(entry.get("pitch_jitter", defaults.get("pitch_jitter", 0.0)))
	player.pitch_scale = maxf(pitch * randf_range(1.0 - jitter, 1.0 + jitter), 0.05)
	player.set_meta("sfx_id", key)
	player.set_meta("started", now)
	player.play()
	_last_played[key] = now
	return player


func play_ui(id: String) -> AudioStreamPlayer:
	return play_sfx(id)


## Звук навыка. phase: "cast" (замах или заклинание), "hit", "crit", "miss".
## Навыки без своей записи берут раздел skills._default.
func play_skill(skill_id: String, phase := "cast") -> AudioStreamPlayer:
	var skills: Dictionary = config.get("skills", {})
	var entry: Dictionary = skills.get(skill_id, skills.get("_default", {}))
	var id := str(entry.get(phase, ""))
	if id == "" and phase == "crit":
		id = str(entry.get("hit", ""))
	if id == "":
		return null
	return play_sfx(id)


func play_skill_impact(skill_id: String, crit := false) -> AudioStreamPlayer:
	return play_skill(skill_id, "crit" if crit else "hit")


func play_skill_miss(skill_id: String) -> AudioStreamPlayer:
	return play_skill(skill_id, "miss")


## Статус наложен (frozen, burning, ...). Статусы без записи молчат.
func play_status(status_id: String) -> AudioStreamPlayer:
	return _play_mapped("statuses", status_id)


## Появилась поверхность или облако (steam, ice, fire, explosion, ...).
func play_surface(surface_id: String) -> AudioStreamPlayer:
	return _play_mapped("surfaces", surface_id)


func stop_all(fade := 0.5) -> void:
	stop_music(fade)
	stop_ambient(fade)
	_stinger_player.stop()
	_unduck()
	for p in _sfx_players:
		p.stop()


# --- Громкость ---------------------------------------------------------------


## Громкость шины для игрока: 0..1. Шины: Master, Music, Ambient, SFX, UI.
func set_volume(bus_name: String, value: float, save := true) -> void:
	_volumes[bus_name] = clampf(value, 0.0, 1.0)
	_apply_bus_volume(bus_name)
	if save:
		_save_settings()


func get_volume(bus_name: String) -> float:
	return float(_volumes.get(bus_name, 1.0))


# --- Внутреннее --------------------------------------------------------------


func _load_config() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if parsed is Dictionary:
		config = parsed
	else:
		push_warning("Audio: не удалось прочитать %s, звука не будет" % CONFIG_PATH)
		config = {}
	_root = str(config.get("root", _root))
	if not _root.ends_with("/"):
		_root += "/"


func _defaults() -> Dictionary:
	return config.get("defaults", {})


func _setup_buses() -> void:
	for bus_name in BUSES:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, BUS_PARENT.get(bus_name, "Master"))
	for bus_name in ["Master"] + BUSES:
		_apply_bus_volume(bus_name)


func _bus_base_db(bus_name: String) -> float:
	var buses: Dictionary = config.get("buses", {})
	var cfg = buses.get(bus_name, {})
	return float(cfg.get("volume_db", 0.0)) if cfg is Dictionary else 0.0


func _apply_bus_volume(bus_name: String) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1 or bus_name == "MusicBed":
		return
	var v := get_volume(bus_name)
	AudioServer.set_bus_volume_db(idx, _bus_base_db(bus_name) + linear_to_db(maxf(v, 0.0001)))
	AudioServer.set_bus_mute(idx, v <= 0.001)


func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK or not cf.has_section("volume"):
		return
	for bus_name in cf.get_section_keys("volume"):
		set_volume(bus_name, float(cf.get_value("volume", bus_name, 1.0)), false)


func _save_settings() -> void:
	var cf := ConfigFile.new()
	for bus_name in _volumes:
		cf.set_value("volume", bus_name, _volumes[bus_name])
	cf.save(SETTINGS_PATH)


func _make_player(bus_name: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus_name
	add_child(p)
	return p


## Id после алиасов: "explore_village" -> "village".
func _canonical(section: String, id: String) -> String:
	var table: Dictionary = config.get(section, {})
	var aliases: Dictionary = config.get("aliases", {})
	var key := id
	for _i in 8:
		if table.has(key) or not aliases.has(key):
			break
		key = str(aliases[key])
	return key


func _entry(section: String, key: String) -> Dictionary:
	var table: Dictionary = config.get(section, {})
	var entry = table.get(key)
	if entry is Dictionary:
		return entry
	if entry is String:
		return {"file": entry}
	return {}


func _files(entry: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var list = entry.get("files", [])
	if list is Array:
		for f in list:
			out.append(str(f))
	if entry.has("file"):
		out.append(str(entry["file"]))
	return out


func _stream(path: String) -> AudioStream:
	var full := path if path.begins_with("res://") else _root + path
	if _streams.has(full):
		return _streams[full]
	var s: AudioStream = null
	if ResourceLoader.exists(full):
		s = load(full) as AudioStream
	if s == null:
		push_warning("Audio: нет файла %s" % full)
	_streams[full] = s
	return s


func _set_loop(stream: AudioStream, loop: bool) -> void:
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = loop
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop


func _play_mapped(section: String, id: String) -> AudioStreamPlayer:
	var table: Dictionary = config.get(section, {})
	var sfx_id := str(table.get(id, ""))
	return play_sfx(sfx_id) if sfx_id != "" else null


func _free_sfx_player(key: String, max_instances: int) -> AudioStreamPlayer:
	var free: AudioStreamPlayer = null
	var oldest: AudioStreamPlayer = null
	var oldest_same: AudioStreamPlayer = null
	var same := 0
	for p in _sfx_players:
		if not p.playing:
			if free == null:
				free = p
			continue
		var started := int(p.get_meta("started", 0))
		if oldest == null or started < int(oldest.get_meta("started", 0)):
			oldest = p
		if str(p.get_meta("sfx_id", "")) == key:
			same += 1
			if oldest_same == null or started < int(oldest_same.get_meta("started", 0)):
				oldest_same = p
	if same >= max_instances and oldest_same != null:
		oldest_same.stop()
		return oldest_same
	if free != null:
		return free
	oldest.stop()
	return oldest


func _remember_position() -> void:
	var current := _music_players[_music_index]
	if current_music != "" and current.playing:
		_positions[current_music] = current.get_playback_position()


func _fade(player: AudioStreamPlayer, target_db: float, time: float, stop_after := false) -> void:
	var old: Tween = _tweens.get(player)
	if old != null and old.is_valid():
		old.kill()
	if time <= 0.0 or not player.playing:
		player.volume_db = target_db
		if stop_after:
			player.stop()
		return
	var tw := create_tween()
	_tweens[player] = tw
	var from := db_to_linear(player.volume_db)
	tw.tween_method(_set_linear_volume.bind(player), from, db_to_linear(target_db), time)
	if stop_after:
		tw.tween_callback(player.stop)


func _set_linear_volume(value: float, player: AudioStreamPlayer) -> void:
	player.volume_db = linear_to_db(maxf(value, 0.0001))


func _duck(db: float) -> void:
	_tween_bed(db, 0.25)


func _unduck() -> void:
	_tween_bed(0.0, 1.2)


func _tween_bed(db: float, time: float) -> void:
	var idx := AudioServer.get_bus_index("MusicBed")
	if idx == -1:
		return
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
	_duck_tween = create_tween()
	_duck_tween.tween_method(_set_bed_db, AudioServer.get_bus_volume_db(idx), db, time)


func _set_bed_db(db: float) -> void:
	var idx := AudioServer.get_bus_index("MusicBed")
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, db)


func _warn(section: String, id: String) -> void:
	var key := section + "/" + id
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("Audio: нет id «%s» в разделе %s файла %s" % [id, section, CONFIG_PATH])

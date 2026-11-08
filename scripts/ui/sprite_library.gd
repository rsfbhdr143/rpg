class_name SpriteLibrary
extends RefCounted
## Картинки для вида. Каталог спрайтов art/catalog.json пишет tools/art/import_art.py,
## а data/sprites.json говорит, какой спрайт у героя, врага, клетки, поверхности, навыка и статуса.
## Нет картинки — функции возвращают пустой словарь, и вид рисует заглушку. Логика игры про картинки не знает.
##
## Привязка в data/sprites.json бывает такой:
##   "wolf": "wolf_grey"                     — спрайт целиком (анимации idle, walk, attack, hurt, death...)
##   "wall": "dungeon_tiles#12"              — один кадр (номер виден на листе art/review/<спрайт>.png)
##   "floor": ["grass#0", "grass#1"]         — варианты, клетка выбирает свой по координатам
##   "wolf": {"sprite": "wolf_grey", "scale": 1.2, "flip": true, "offset": [0, 4],
##            "anims": {"idle": "row2"}, "draw": "upright", "mode": "animate", "alpha": 0.8}

const CATALOG_PATH := "res://art/catalog.json"
const BINDINGS_PATH := "res://data/sprites.json"
const OPPOSITE := {"left": "right", "right": "left"}

static var assets: Dictionary = {}
static var bindings: Dictionary = {}
static var _textures: Dictionary = {}   # путь -> Texture2D (null, если не загрузилась)
static var _cache: Dictionary = {}      # "категория/id@локация" -> разобранная привязка
static var _loaded := false


static func ensure_loaded() -> void:
	if not _loaded:
		reload_data()


static func reload_data() -> void:
	assets = _load_json(CATALOG_PATH).get("assets", {})
	bindings = _load_json(BINDINGS_PATH)
	_textures.clear()
	_cache.clear()
	_loaded = true


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpriteLibrary: %s не является JSON-объектом (ошибка синтаксиса?)" % path)
		return {}
	return parsed


static func setting(key: String, default: Variant = null) -> Variant:
	ensure_loaded()
	var s: Dictionary = bindings.get("settings", {})
	return s.get(key, default)


## Привязка как словарь с полем "refs" (ссылки на существующие спрайты) или {}, если её нет.
## Для клеток можно задать свою картинку в локации: "locations": {"forest": {"floor": ...}}.
static func binding(category: String, id: String, location: String = "") -> Dictionary:
	ensure_loaded()
	var key := "%s/%s@%s" % [category, id, location]
	if not _cache.has(key):
		_cache[key] = _parse_binding(category, id, location)
	return _cache[key]


static func _parse_binding(category: String, id: String, location: String) -> Dictionary:
	var raw: Variant = null
	if location != "":
		var locs: Dictionary = bindings.get("locations", {})
		var loc: Dictionary = locs.get(location, {})
		raw = loc.get(id)
	if raw == null:
		var table: Dictionary = bindings.get(category, {})
		raw = table.get(id)
	var b := {}
	match typeof(raw):
		TYPE_STRING:
			b["refs"] = [raw]
		TYPE_ARRAY:
			b["refs"] = raw
		TYPE_DICTIONARY:
			b = (raw as Dictionary).duplicate()
			var sp: Variant = b.get("sprite")
			b["refs"] = sp if typeof(sp) == TYPE_ARRAY else ([sp] if typeof(sp) == TYPE_STRING else [])
		_:
			return {}
	var refs: Array = (b["refs"] as Array).filter(func(r): return assets.has(str(r).get_slice("#", 0)))
	if refs.is_empty():
		return {}
	b["refs"] = refs
	return b


static func has_sprite(category: String, id: String, location: String = "") -> bool:
	return not binding(category, id, location).is_empty()


## Кадр для рисования: {"texture", "region", "flip", "scale", "offset", "draw", "alpha", "pixels", "opaque", "painted",
## "doors"} или {}.
##   anim   — idle, walk, attack, cast, hurt, death... Если анимации нет, берётся idle (кроме death).
##   facing — right/left/down/up: сначала ищется "<anim>_<facing>", для left/right подходит и отражённая.
##   time   — секунды от начала анимации; variant — номер варианта для клеток.
static func frame(category: String, id: String, anim: String = "idle", time: float = 0.0,
		facing: String = "", variant: int = 0, location: String = "") -> Dictionary:
	var b := binding(category, id, location)
	if b.is_empty():
		return {}
	var refs: Array = b["refs"]
	var variants := str(b.get("mode", "variants" if category == "tiles" else "animate")) == "variants"
	var ref := str(refs[posmod(variant, refs.size())] if variants else refs[0])
	var a: Dictionary = assets[ref.get_slice("#", 0)]
	var flip := bool(b.get("flip", false))
	var index := 0
	if ref.contains("#"):
		index = int(ref.get_slice("#", 1))
	elif not (a.get("animations", {}) as Dictionary).is_empty():
		var anims: Dictionary = a["animations"]
		var renames: Dictionary = b.get("anims", {})
		var found := _find_anim(anims, str(renames.get(anim, anim)), facing)
		var still := false
		if found.is_empty() and anim != "death":
			found = _find_anim(anims, str(renames.get("idle", "idle")), facing)
			if found.is_empty():
				found = _find_anim(anims, "walk", facing)   # у листов LPC стойка — первый кадр ходьбы
				still = true
			if found.is_empty():
				found = [anims.keys()[0], false]
		if found.is_empty():
			return {}
		var info: Dictionary = anims[found[0]]
		flip = flip != bool(found[1])
		var count := maxi(1, int(info.get("count", 1)))
		var k := 0
		if variants:
			k = posmod(variant, count)
		elif not still:
			var step := int(time * float(info.get("fps", 8.0)))
			k = posmod(step, count) if bool(info.get("loop", true)) else mini(step, count - 1)
		index = int(info.get("start", 0)) + k
	elif variants:
		index = posmod(variant, int(a.get("count", 1)))
	var tex := _texture(str(a.get("sheet", "")))
	if tex == null:
		return {}
	var size: Array = a.get("frame", [1, 1])
	var fw := int(size[0])
	var fh := int(size[1])
	var pad := int(a.get("pad", 0))
	var cols := maxi(1, int(a.get("cols", 1)))
	@warning_ignore("integer_division")
	var row := index / cols
	var offset: Array = b.get("offset", [0, 0])
	return {
		"texture": tex,
		"region": Rect2((index % cols) * (fw + 2 * pad) + pad, row * (fh + 2 * pad) + pad, fw, fh),
		"flip": flip,
		"scale": float(b.get("scale", 1.0)),
		"offset": Vector2(float(offset[0]), float(offset[1])),
		"draw": str(b.get("draw", "")),
		"alpha": float(b.get("alpha", -1.0)),
		"pixels": float(a.get("scale", 1.0)),   # во сколько раз импорт уменьшил кадр
		"opaque": bool(a.get("opaque", false)),  # сплошная текстура без прозрачности
		"painted": bool(a.get("painted", false)),  # рисованная картинка (портрет, значок): не пикселизовать, сглаживать
		"doors": bool(a.get("doors", false)),      # у рисунка дома двери нарисованы в клетках "+" карты
	}


## [имя анимации, нужно ли отразить] или [].
static func _find_anim(anims: Dictionary, name: String, facing: String) -> Array:
	if facing != "":
		if anims.has(name + "_" + facing):
			return [name + "_" + facing, false]
		if OPPOSITE.has(facing) and anims.has(name + "_" + str(OPPOSITE[facing])):
			return [name + "_" + str(OPPOSITE[facing]), true]
	if anims.has(name):
		return [name, facing == "left" and str(setting("sprites_face", "right")) == "right"
			or facing == "right" and str(setting("sprites_face", "right")) == "left"]
	for d in ["down", "right", "left", "up"]:
		if anims.has(name + "_" + d):
			return [name + "_" + d, false]
	return []


static func _texture(path: String) -> Texture2D:
	if _textures.has(path):
		return _textures[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	if tex == null and FileAccess.file_exists(path):
		# картинку ещё не импортировал редактор (например, запуск из консоли сразу после импорта)
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty():
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		push_warning("SpriteLibrary: нет картинки %s, рисую заглушку" % path)
	_textures[path] = tex
	return tex

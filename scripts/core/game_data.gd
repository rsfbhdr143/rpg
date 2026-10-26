class_name GameData
extends RefCounted
## Загружает все JSON из res://data/ и даёт к ним доступ.
## Все игровые числа и тексты живут в data/*.json, код их только читает.
## Чтобы поменять баланс, навыки, статусы, поверхности — правь JSON.

const DATA_DIR := "res://data/"

static var rules: Dictionary = {}
static var progression: Dictionary = {}
static var abilities: Dictionary = {}
static var talents: Dictionary = {}
static var statuses: Dictionary = {}
static var status_reactions: Array = []
static var surfaces: Dictionary = {}
static var surface_reactions: Dictionary = {}
static var element_surfaces: Dictionary = {}
static var skills: Dictionary = {}
static var characters: Dictionary = {}
static var encounters: Dictionary = {}

## Общий генератор случайных чисел. В тестах можно задать seed.
static var rng := RandomNumberGenerator.new()
static var _loaded := false


static func ensure_loaded() -> void:
	if not _loaded:
		reload()


static func reload() -> void:
	rules = _load_json("rules.json")
	progression = _load_json("progression.json")
	abilities = _load_json("abilities.json")
	talents = _load_json("talents.json")
	var st := _load_json("statuses.json")
	statuses = st.get("statuses", {})
	status_reactions = st.get("reactions", [])
	var sf := _load_json("surfaces.json")
	surfaces = sf.get("surfaces", {})
	surface_reactions = sf.get("reactions", {})
	element_surfaces = sf.get("element_surfaces", {})
	skills = _load_json("skills.json")
	characters = _load_json("characters.json")
	encounters = _load_json("encounters.json")
	_loaded = true


static func _load_json(file_name: String) -> Dictionary:
	var path := DATA_DIR + file_name
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("GameData: не удалось открыть %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GameData: %s не является JSON-объектом (ошибка синтаксиса?)" % path)
		return {}
	return parsed


# --- Доступ к записям ---------------------------------------------------------

static func rule(key: String, default: Variant = null) -> Variant:
	ensure_loaded()
	return rules.get(key, default)


static func skill(id: String) -> Dictionary:
	ensure_loaded()
	return skills.get(id, {})


static func status(id: String) -> Dictionary:
	ensure_loaded()
	return statuses.get(id, {})


static func surface(id: String) -> Dictionary:
	ensure_loaded()
	return surfaces.get(id, {})


static func ability(id: String) -> Dictionary:
	ensure_loaded()
	return abilities.get(id, {})


static func talent(id: String) -> Dictionary:
	ensure_loaded()
	return talents.get(id, {})


static func character(id: String) -> Dictionary:
	ensure_loaded()
	return characters.get(id, {})


static func encounter(id: String) -> Dictionary:
	ensure_loaded()
	return encounters.get(id, {})


static func attribute_list() -> Array:
	return rule("attributes", [])


## Реакция поверхности `surface_id` на стихию `element` (или пустой словарь).
static func surface_reaction(surface_id: String, element: String) -> Dictionary:
	ensure_loaded()
	var by_surface: Dictionary = surface_reactions.get(surface_id, {})
	return by_surface.get(element, {})


## Какую поверхность создаёт стихия на пустой клетке ("" если никакую).
static func element_surface(element: String) -> String:
	ensure_loaded()
	return str(element_surfaces.get(element, ""))


# --- Формулы ------------------------------------------------------------------

## Формула из rules.json: base + per_level * (level - 1) + Σ coef * (attr - attribute_base)
static func eval_formula(f: Dictionary, level: int, attrs: Dictionary) -> float:
	var attr_base := float(rule("attribute_base", 5))
	var v := float(f.get("base", 0.0)) + float(f.get("per_level", 0.0)) * (level - 1)
	var coefs: Dictionary = f.get("attr", {})
	for a in coefs:
		v += float(coefs[a]) * (float(attrs.get(a, attr_base)) - attr_base)
	return v


## Число, растущее с уровнем: {"base": x, "per_level": y}
static func scaled(f: Dictionary, level: int) -> float:
	return float(f.get("base", 0.0)) + float(f.get("per_level", 0.0)) * (level - 1)

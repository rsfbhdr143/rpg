class_name GameData
extends RefCounted
## Загружает все JSON из res://data/ и даёт к ним доступ.
## Все игровые числа и тексты живут в data/*.json, код их только читает.
## Чтобы поменять баланс, навыки, статусы, поверхности — правь JSON.

const DATA_DIR := "res://data/"
const STORY_DIR := "story/"   # тексты и сюжет (их пишет сценарист), сливаются с остальными данными

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
static var traps: Dictionary = {}
static var characters: Dictionary = {}
static var locations: Dictionary = {}
static var dialogues: Dictionary = {}
static var quests: Dictionary = {}
static var npcs: Dictionary = {}
static var items: Dictionary = {}
static var loot: Dictionary = {}       # что падает с тел (data/story/loot.json)
static var load_warnings: Array = []   # что не сошлось при слиянии сюжета с картами (видно в тестах)

## Общий генератор случайных чисел. В тестах можно задать seed.
static var rng := RandomNumberGenerator.new()
static var _loaded := false


static func ensure_loaded() -> void:
	if not _loaded:
		reload_data()


## Не называть reload(): GameData.reload() снаружи вызывает встроенный
## GDScript.reload(), который перекомпилирует скрипт и обнуляет данные.
static func reload_data() -> void:
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
	traps = _load_optional("traps.json", "traps")
	traps.erase("_doc")
	characters = _load_json("characters.json")
	locations = _load_json("locations.json")
	load_warnings = []
	for id in locations.keys():
		locations[id] = LocationData.normalize(str(id), locations[id], load_warnings)
	_load_story()
	_loaded = true


## Сюжет из data/story/: диалоги, задания, предметы, NPC и враги (формат characters.json),
## названия, музыка и встречи локаций. Геометрия локаций остаётся в data/locations.json.
static func _load_story() -> void:
	dialogues = _load_optional(STORY_DIR + "dialogues.json", "dialogues")
	quests = _load_optional(STORY_DIR + "quests.json", "quests")
	items = _load_optional(STORY_DIR + "items.json", "items")
	loot = _load_optional(STORY_DIR + "loot.json", "loot")
	npcs = _load_optional(STORY_DIR + "npcs.json", "npcs")
	var enemies := _load_optional(STORY_DIR + "enemies.json", "enemies")
	for id in enemies:
		var t: Dictionary = enemies[id]
		if not t.has("faction"):
			t["faction"] = "enemy"
		if characters.has(id):   # сюжет поверх шаблона: иначе теряется, например, "type": "undead" из characters.json
			var merged: Dictionary = characters[id].duplicate(true)
			merged.merge(t, true)
			t = merged
		characters[id] = t
	for id in npcs:
		var t: Dictionary = (npcs[id] as Dictionary).duplicate(true)
		if not t.has("faction"):
			t["faction"] = "npc"
		if characters.has(id):
			var merged: Dictionary = characters[id].duplicate(true)
			merged.merge(t, true)
			t = merged
		characters[id] = t
	var story_locs := _load_optional(STORY_DIR + "locations.json", "locations")
	for id in story_locs:
		locations[id] = LocationData.merge_story(locations.get(id, {}), story_locs[id], str(id), load_warnings)


## Необязательный файл: {} если его нет. wrap — ключ, под которым данные могут лежать внутри файла.
static func _load_optional(file_name: String, wrap: String) -> Dictionary:
	if not FileAccess.file_exists(DATA_DIR + file_name):
		return {}
	var d := _load_json(file_name)
	if d.has(wrap) and typeof(d[wrap]) == TYPE_DICTIONARY:
		return d[wrap]
	return d


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


static func trap(id: String) -> Dictionary:
	ensure_loaded()
	return traps.get(id, {})


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


static func location(id: String) -> Dictionary:
	ensure_loaded()
	return locations.get(id, {})


static func dialogue(id: String) -> Dictionary:
	ensure_loaded()
	return dialogues.get(id, {})


static func quest(id: String) -> Dictionary:
	ensure_loaded()
	return quests.get(id, {})


static func npc(id: String) -> Dictionary:
	ensure_loaded()
	return npcs.get(id, {})


static func item(id: String) -> Dictionary:
	ensure_loaded()
	return items.get(id, {})


## Строки добычи для шаблона (у жителя без своей записи — "_npc"), [] — с тела ничего не взять.
static func loot_table(template: String, npc := false) -> Array:
	ensure_loaded()
	if loot.has(template):
		return loot[template]
	return loot.get("_npc", []) if npc else []


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

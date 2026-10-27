class_name Character
extends RefCounted
## Персонаж: атрибуты, способности, таланты, навыки, статусы, ОЗ/ОД.
## Все производные характеристики считаются через get_stat() по формулам
## из rules.json плюс модификаторы от способностей, талантов и статусов.

static var _next_uid := 1

var uid: String = ""
var template_id: String = ""
var display_name: String = ""
var faction: String = "neutral"
var level: int = 1
var xp: int = 0
var xp_reward: int = 0

var attributes: Dictionary = {}   # "strength" -> int
var abilities: Dictionary = {}    # "pyrokinetic" -> ранг (int)
var talents: Array = []           # id талантов
var skills: Array = []            # id навыков
var weapon: Dictionary = {}       # {"name","min","max","element"}
var base_stats: Dictionary = {}   # плоские прибавки от экипировки/шаблона: {"armor": 10, "fire_res": 20}
var equipment: Array = []         # id надетых предметов (data/story/items.json): их "stats" складываются,
                                  # предмет с "weapon" заменяет оружие

var unspent_attribute_points: int = 0
var unspent_ability_points: int = 0
var unspent_talent_points: int = 0

var hp: float = 1.0
var ap: int = 0
var statuses: Dictionary = {}     # status_id -> {"turns": int, "level": int}
var cooldowns: Dictionary = {}    # skill_id -> оставшиеся ходы
var cell: Vector2i = Vector2i.ZERO
var death_handled := false
var encounter_id := ""            # к какой группе врагов локации относится (для врагов)


static func from_template(template_id: String) -> Character:
	var t := GameData.character(template_id)
	if t.is_empty():
		push_error("Character: нет шаблона '%s' в characters.json" % template_id)
	var c := Character.new()
	c.uid = "%s#%d" % [template_id, _next_uid]
	_next_uid += 1
	c.template_id = template_id
	c.display_name = str(t.get("name", template_id))
	c.faction = str(t.get("faction", "neutral"))
	c.level = int(t.get("level", 1))
	c.xp_reward = int(t.get("xp_reward", 0))

	var attr_base := int(GameData.rule("attribute_base", 5))
	var t_attrs: Dictionary = t.get("attributes", {})
	for a in GameData.attribute_list():
		c.attributes[a] = int(t_attrs.get(a, attr_base))
	var t_abilities: Dictionary = t.get("abilities", {})
	for ab in t_abilities:
		c.abilities[ab] = int(t_abilities[ab])
	var t_talents: Array = t.get("talents", [])
	c.talents = t_talents.duplicate()
	var t_skills: Array = t.get("skills", ["attack"])
	c.skills = t_skills.duplicate()
	var unarmed: Dictionary = GameData.rule("unarmed_weapon", {"min": 1, "max": 2, "element": "physical"})
	var t_weapon: Dictionary = t.get("weapon", unarmed)
	c.weapon = t_weapon.duplicate()
	var t_base: Dictionary = t.get("base_stats", {})
	c.base_stats = t_base.duplicate()

	var unspent: Dictionary = t.get("unspent", {})
	c.unspent_attribute_points = int(unspent.get("attribute", 0))
	c.unspent_ability_points = int(unspent.get("ability", 0))
	c.unspent_talent_points = int(unspent.get("talent", 0))

	c.hp = c.max_hp()
	return c


# --- Характеристики -----------------------------------------------------------

## Итоговое значение характеристики: формула + base_stats + модификаторы.
func get_stat(stat: String) -> float:
	var v := 0.0
	var derived: Dictionary = GameData.rule("derived", {})
	if derived.has(stat):
		v = GameData.eval_formula(derived[stat], level, attributes)
	v += float(base_stats.get(stat, 0.0))
	v += _modifier_sum(stat)
	return v


func get_int(stat: String) -> int:
	return int(floor(get_stat(stat)))


func _modifier_sum(stat: String) -> float:
	var s := 0.0
	for ab in abilities:
		var per_rank: Dictionary = GameData.ability(ab).get("per_rank", {})
		s += float(per_rank.get(stat, 0.0)) * int(abilities[ab])
	for t in talents:
		var mods: Dictionary = GameData.talent(t).get("modifiers", {})
		s += float(mods.get(stat, 0.0))
	for st in statuses:
		var smods: Dictionary = GameData.status(st).get("modifiers", {})
		s += float(smods.get(stat, 0.0))
	for it in equipment:
		var istats: Dictionary = GameData.item(str(it)).get("stats", {})
		s += float(istats.get(stat, 0.0))
	return s


## Оружие с учётом надетых предметов.
func effective_weapon() -> Dictionary:
	for it in equipment:
		var w: Dictionary = GameData.item(str(it)).get("weapon", {})
		if not w.is_empty():
			return w
	return weapon


## Сопротивление стихии в процентах, ограниченное ±resistance_cap.
func get_resistance(element: String) -> float:
	var cap := float(GameData.rule("resistance_cap", 100))
	return clampf(get_stat(element + "_res"), -cap, cap)


func max_hp() -> float:
	return maxf(1.0, roundf(get_stat("max_hp")))


## Флаги от талантов и статусов, например "poison_heals", "immune_knocked_down".
func has_flag(flag: String) -> bool:
	for t in talents:
		var flags: Array = GameData.talent(t).get("flags", [])
		if flags.has(flag):
			return true
	for st in statuses:
		var sflags: Array = GameData.status(st).get("flags", [])
		if sflags.has(flag):
			return true
	return false


func ability_rank(ability_id: String) -> int:
	return int(abilities.get(ability_id, 0))


# --- Состояние ----------------------------------------------------------------

func is_alive() -> bool:
	return hp > 0.0


func has_status(id: String) -> bool:
	return statuses.has(id)


func remove_status(id: String) -> void:
	statuses.erase(id)


## Может ли действовать в этот ход (не оглушён/заморожен/сбит с ног).
func can_act() -> bool:
	if not is_alive():
		return false
	for st in statuses:
		if bool(GameData.status(st).get("skip_turn", false)):
			return false
	return true


func take_damage(amount: float) -> void:
	hp = maxf(0.0, hp - amount)


func heal(amount: float) -> void:
	hp = minf(max_hp(), hp + amount)


func full_restore() -> void:
	hp = max_hp()
	statuses.clear()
	cooldowns.clear()
	death_handled = false


func describe() -> String:
	return "%s (ур. %d)" % [display_name, level]


# --- Сериализация (сеть, сохранения) -----------------------------------------

func to_dict() -> Dictionary:
	return {
		"uid": uid, "template_id": template_id, "name": display_name, "faction": faction,
		"level": level, "xp": xp, "xp_reward": xp_reward,
		"attributes": attributes.duplicate(), "abilities": abilities.duplicate(),
		"talents": talents.duplicate(), "skills": skills.duplicate(),
		"weapon": weapon.duplicate(), "base_stats": base_stats.duplicate(), "equipment": equipment.duplicate(),
		"points": [unspent_attribute_points, unspent_ability_points, unspent_talent_points],
		"hp": hp, "ap": ap,
		"statuses": statuses.duplicate(true), "cooldowns": cooldowns.duplicate(),
		"cell": [cell.x, cell.y], "death_handled": death_handled,
		"encounter": encounter_id,
	}


static func from_dict(d: Dictionary) -> Character:
	var c := Character.new()
	c.uid = str(d.get("uid", ""))
	c.template_id = str(d.get("template_id", ""))
	c.display_name = str(d.get("name", ""))
	c.faction = str(d.get("faction", "neutral"))
	c.level = int(d.get("level", 1))
	c.xp = int(d.get("xp", 0))
	c.xp_reward = int(d.get("xp_reward", 0))
	var attrs: Dictionary = d.get("attributes", {})
	for a in attrs:
		c.attributes[a] = int(attrs[a])
	var abs_d: Dictionary = d.get("abilities", {})
	for ab in abs_d:
		c.abilities[ab] = int(abs_d[ab])
	var t: Array = d.get("talents", [])
	c.talents = t.duplicate()
	var s: Array = d.get("skills", [])
	c.skills = s.duplicate()
	var w: Dictionary = d.get("weapon", {})
	c.weapon = w.duplicate()
	var bs: Dictionary = d.get("base_stats", {})
	c.base_stats = bs.duplicate()
	var eq: Array = d.get("equipment", [])
	c.equipment = eq.duplicate()
	var pts: Array = d.get("points", [0, 0, 0])
	c.unspent_attribute_points = int(pts[0])
	c.unspent_ability_points = int(pts[1])
	c.unspent_talent_points = int(pts[2])
	c.hp = float(d.get("hp", 1.0))
	c.ap = int(d.get("ap", 0))
	var sts: Dictionary = d.get("statuses", {})
	for id in sts:
		var st: Dictionary = sts[id]
		c.statuses[id] = {"turns": int(st.get("turns", 1)), "level": int(st.get("level", 1))}
	var cds: Dictionary = d.get("cooldowns", {})
	for sk in cds:
		c.cooldowns[sk] = int(cds[sk])
	var cl: Array = d.get("cell", [0, 0])
	c.cell = Vector2i(int(cl[0]), int(cl[1]))
	c.death_handled = bool(d.get("death_handled", false))
	c.encounter_id = str(d.get("encounter", ""))
	# Новые персонажи не должны получить uid, уже занятый загруженными.
	var n := int(c.uid.get_slice("#", 1))
	if n >= _next_uid:
		_next_uid = n + 1
	return c

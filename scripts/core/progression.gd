class_name Progression
extends RefCounted
## Прокачка в стиле D:OS1: опыт -> уровни -> очки атрибутов, способностей, талантов.
## Все числа в data/progression.json.


static func cfg() -> Dictionary:
	GameData.ensure_loaded()
	return GameData.progression


static func xp_to_next(level: int) -> int:
	var curve: Dictionary = cfg().get("xp_curve", {"base": 100, "growth": 1.5})
	return roundi(float(curve.get("base", 100)) * pow(float(curve.get("growth", 1.5)), level - 1))


## Даёт персонажу стартовые очки (для созданного игроком героя).
static func grant_start_points(c: Character) -> void:
	c.unspent_attribute_points += int(cfg().get("start_attribute_points", 0))
	c.unspent_ability_points += int(cfg().get("start_ability_points", 0))
	c.unspent_talent_points += int(cfg().get("start_talent_points", 0))


## Добавляет опыт, возвращает число полученных уровней.
static func add_xp(c: Character, amount: int) -> int:
	var gained := 0
	var max_level := int(cfg().get("max_level", 20))
	c.xp += amount
	while c.level < max_level and c.xp >= xp_to_next(c.level):
		c.xp -= xp_to_next(c.level)
		level_up(c)
		gained += 1
	return gained


static func level_up(c: Character) -> void:
	var hp_ratio := c.hp / c.max_hp()
	c.level += 1
	c.unspent_attribute_points += int(cfg().get("attribute_points_per_level", 1))
	c.unspent_ability_points += int(cfg().get("ability_points_per_level", 1))
	var talent_levels: Array = cfg().get("talent_point_levels", [])
	for lv in talent_levels:
		if int(lv) == c.level:
			c.unspent_talent_points += 1
	if bool(cfg().get("heal_on_level_up", true)):
		c.hp = c.max_hp()
	else:
		c.hp = c.max_hp() * hp_ratio
	GameLog.add("%s достигает уровня %d!" % [c.display_name, c.level])
	GameEvents.add("level_up", {"unit": c.uid, "level": c.level})


# --- Атрибуты -------------------------------------------------------------------

static func can_raise_attribute(c: Character, attr: String) -> bool:
	var max_v := int(GameData.rule("attribute_max", 15))
	return c.unspent_attribute_points > 0 and c.attributes.has(attr) and int(c.attributes[attr]) < max_v


static func raise_attribute(c: Character, attr: String) -> bool:
	if not can_raise_attribute(c, attr):
		return false
	var hp_missing := c.max_hp() - c.hp
	c.attributes[attr] = int(c.attributes[attr]) + 1
	c.unspent_attribute_points -= 1
	c.hp = c.max_hp() - hp_missing   # рост телосложения сразу добавляет ОЗ
	return true


# --- Способности ----------------------------------------------------------------

## Стоимость повышения способности до ранга next_rank (1..max).
static func ability_cost(next_rank: int) -> int:
	var costs: Array = cfg().get("ability_rank_cost", [1])
	if costs.is_empty():
		return 1
	return int(costs[clampi(next_rank - 1, 0, costs.size() - 1)])


static func can_raise_ability(c: Character, ability_id: String) -> bool:
	if GameData.ability(ability_id).is_empty():
		return false
	var next_rank := c.ability_rank(ability_id) + 1
	if next_rank > int(cfg().get("ability_max_rank", 5)):
		return false
	return c.unspent_ability_points >= ability_cost(next_rank)


static func raise_ability(c: Character, ability_id: String) -> bool:
	if not can_raise_ability(c, ability_id):
		return false
	var next_rank := c.ability_rank(ability_id) + 1
	c.unspent_ability_points -= ability_cost(next_rank)
	c.abilities[ability_id] = next_rank
	return true


# --- Таланты ------------------------------------------------------------------

## Пустая строка — можно взять; иначе причина отказа.
static func talent_block_reason(c: Character, talent_id: String) -> String:
	var t := GameData.talent(talent_id)
	if t.is_empty():
		return "нет такого таланта"
	if c.talents.has(talent_id):
		return "уже изучен"
	if c.unspent_talent_points <= 0:
		return "нет очков талантов"
	var req: Dictionary = t.get("requirements", {})
	if c.level < int(req.get("level", 1)):
		return "нужен уровень %d" % int(req.get("level", 1))
	var req_attrs: Dictionary = req.get("attributes", {})
	for a in req_attrs:
		if int(c.attributes.get(a, 0)) < int(req_attrs[a]):
			return "нужно %s %d" % [a, int(req_attrs[a])]
	var req_ab: Dictionary = req.get("abilities", {})
	for ab in req_ab:
		if c.ability_rank(ab) < int(req_ab[ab]):
			return "нужно %s %d" % [ab, int(req_ab[ab])]
	return ""


static func learn_talent(c: Character, talent_id: String) -> bool:
	if talent_block_reason(c, talent_id) != "":
		return false
	c.unspent_talent_points -= 1
	c.talents.append(talent_id)
	var on_learn: Dictionary = GameData.talent(talent_id).get("on_learn", {})
	c.unspent_attribute_points += int(on_learn.get("attribute_points", 0))
	c.unspent_ability_points += int(on_learn.get("ability_points", 0))
	return true


# --- Навыки (как книги навыков в D:OS1) --------------------------------------

static func skill_block_reason(c: Character, skill_id: String) -> String:
	var s := GameData.skill(skill_id)
	if s.is_empty():
		return "нет такого навыка"
	if c.skills.has(skill_id):
		return "уже изучен"
	var ab := str(s.get("ability", ""))
	if ab != "" and c.ability_rank(ab) < int(s.get("ability_rank", 0)):
		return "нужен ранг %d в %s" % [int(s.get("ability_rank", 0)), ab]
	return ""


static func learn_skill(c: Character, skill_id: String) -> bool:
	if skill_block_reason(c, skill_id) != "":
		return false
	c.skills.append(skill_id)
	return true

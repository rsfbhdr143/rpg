class_name DamageCalc
extends RefCounted
## Расчёт урона в стиле D:OS1:
## - физический урон режется бронёй (процент зависит от уровня атакующего);
## - стихийный урон режется сопротивлением стихии (может быть отрицательным);
## - оружейные атаки могут промахнуться (точность - уклонение) и критовать;
## - урон заклинаний растёт с уровнем заклинателя и бонусом от Интеллекта.


static func base_skill_damage(level: int) -> float:
	var cfg: Dictionary = GameData.rule("skill_damage", {})
	return GameData.scaled(cfg, level)


static func with_variance(v: float) -> float:
	var cfg: Dictionary = GameData.rule("skill_damage", {})
	var var_pct := float(cfg.get("variance", 0.0))
	return v * GameData.rng.randf_range(1.0 - var_pct, 1.0 + var_pct)


static func hit_chance(attacker: Character, target: Character) -> float:
	var cfg: Dictionary = GameData.rule("hit_chance", {"min": 5, "max": 95})
	var chance := attacker.get_stat("accuracy") - target.get_stat("dodge")
	return clampf(chance, float(cfg.get("min", 5)), float(cfg.get("max", 95)))


static func effective_armor(target: Character) -> float:
	return maxf(0.0, target.get_stat("armor") * (1.0 + target.get_stat("armor_bonus_pct") / 100.0))


## Процент снижения физического урона бронёй.
static func armor_reduction_pct(target: Character, attacker_level: int) -> float:
	var cfg: Dictionary = GameData.rule("armor_formula", {})
	var armor := effective_armor(target)
	if armor <= 0.0:
		return 0.0
	var denom := armor + float(cfg.get("flat", 10)) + float(cfg.get("per_attacker_level", 8)) * attacker_level
	return minf(float(cfg.get("cap_pct", 75)), armor / denom * 100.0)


## Урон после брони/сопротивлений (без применения).
static func mitigate(target: Character, amount: float, element: String, attacker_level: int) -> float:
	if element == "physical":
		return amount * (1.0 - armor_reduction_pct(target, attacker_level) / 100.0)
	return amount * (1.0 - target.get_resistance(element) / 100.0)


## Разброс урона навыка без бросков, для подсказок: {"min", "max", "element", "crit_chance", "crit_multiplier",
## "hit_chance"}. С целью — уже после её брони или сопротивления (и с шансом попасть по ней).
static func preview(attacker: Character, skill_def: Dictionary, target: Character = null) -> Dictionary:
	var dmg: Dictionary = skill_def.get("damage", {})
	if dmg.is_empty():
		return {}
	var element := str(dmg.get("element", "physical"))
	var lo := 0.0
	var hi := 0.0
	if str(dmg.get("source", "skill")) == "weapon":
		var w := attacker.effective_weapon()
		lo = float(w.get("min", 1))
		hi = float(w.get("max", 2))
		if not dmg.has("element"):
			element = str(w.get("element", "physical"))
	else:
		var cfg: Dictionary = GameData.rule("skill_damage", {})
		var base := base_skill_damage(attacker.level)
		lo = base * (1.0 - float(cfg.get("variance", 0.0)))
		hi = base * (1.0 + float(cfg.get("variance", 0.0)))
	var bonus_stat: String = "physical_damage_pct" if element == "physical" else "magic_damage_pct"
	var k := (1.0 + attacker.get_stat(bonus_stat) / 100.0) * float(dmg.get("multiplier", 1.0))
	if target != null and target.is_undead():
		for st in attacker.statuses:
			k *= 1.0 + float(GameData.status(str(st)).get("vs_undead_damage", 0)) / 100.0
	lo *= k
	hi *= k
	var out := {"element": element, "crit_chance": 0.0, "crit_multiplier": maxf(1.0, attacker.get_stat("crit_multiplier")),
		"hit_chance": 100.0}
	if bool(skill_def.get("can_crit", false)):
		out["crit_chance"] = clampf(attacker.get_stat("crit_chance"), 0.0, 100.0)
	if target != null:
		lo = maxf(0.0, mitigate(target, lo, element, attacker.level))
		hi = maxf(0.0, mitigate(target, hi, element, attacker.level))
		if bool(skill_def.get("can_miss", false)):
			out["hit_chance"] = hit_chance(attacker, target)
	out["min"] = roundi(lo)
	out["max"] = roundi(hi)
	return out


## Разброс лечения навыка: [min, max].
static func heal_preview(caster: Character, skill_def: Dictionary) -> Array:
	var cfg: Dictionary = GameData.rule("skill_damage", {})
	var v := float(cfg.get("variance", 0.0))
	var base := base_skill_damage(caster.level) * float((skill_def.get("heal", {}) as Dictionary).get("multiplier", 1.0))
	return [roundi(base * (1.0 - v)), roundi(base * (1.0 + v))]


## Полный расчёт атаки навыком. Возвращает
## {"hit": bool, "crit": bool, "amount": float, "element": String}
static func roll_attack(attacker: Character, target: Character, skill_def: Dictionary) -> Dictionary:
	var dmg: Dictionary = skill_def.get("damage", {})
	var result := {"hit": true, "crit": false, "amount": 0.0, "element": "physical"}

	if bool(skill_def.get("can_miss", false)):
		if GameData.rng.randf() * 100.0 >= hit_chance(attacker, target):
			result["hit"] = false
			return result

	var element := str(dmg.get("element", "physical"))
	var raw := 0.0
	if str(dmg.get("source", "skill")) == "weapon":
		var w := attacker.effective_weapon()
		raw = GameData.rng.randf_range(float(w.get("min", 1)), float(w.get("max", 2)))
		if not dmg.has("element"):
			element = str(w.get("element", "physical"))
	else:
		raw = with_variance(base_skill_damage(attacker.level))

	var bonus_stat: String = "physical_damage_pct" if element == "physical" else "magic_damage_pct"
	raw *= 1.0 + attacker.get_stat(bonus_stat) / 100.0
	raw *= float(dmg.get("multiplier", 1.0))
	if target.is_undead():   # благословлённые бьют нежить сильнее
		for st in attacker.statuses:
			raw *= 1.0 + float(GameData.status(str(st)).get("vs_undead_damage", 0)) / 100.0

	if bool(skill_def.get("can_crit", false)) and GameData.rng.randf() * 100.0 < attacker.get_stat("crit_chance"):
		result["crit"] = true
		raw *= maxf(1.0, attacker.get_stat("crit_multiplier"))

	result["element"] = element
	result["amount"] = maxf(0.0, mitigate(target, raw, element, attacker.level))
	return result


## Наносит уже посчитанный урон. Учитывает таланты вроде "poison_heals".
## Возвращает фактически нанесённый урон (отрицательный = лечение).
static func apply_damage(target: Character, amount: float, element: String) -> float:
	var rounded := float(roundi(amount))
	if element == "poison" and target.has_flag("poison_heals"):
		target.heal(rounded)
		return -rounded
	target.take_damage(rounded)
	return rounded


## Урон от «окружения»: тик статуса, взрыв поверхности. Без промахов и критов.
static func environment_damage(target: Character, f: Dictionary, source_level: int) -> float:
	var element := str(f.get("element", "physical"))
	var raw := GameData.scaled(f, source_level)
	return apply_damage(target, mitigate(target, raw, element, source_level), element)

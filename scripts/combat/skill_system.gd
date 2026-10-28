class_name SkillSystem
extends RefCounted
## Выполнение навыков из data/skills.json.
## Поля навыка:
##   ap, cooldown, range, target ("enemy" | "ally" | "self" | "cell"),
##   aoe_radius, affects ("all" | "enemies" | "allies"),
##   damage {source: "weapon"|"skill", element, multiplier}, can_miss, can_crit,
##   heal {multiplier}, statuses [{id, chance, duration?, on: "target"|"self"}],
##   surface {element, radius, create},
##   vs_undead {damage, statuses} — что навык делает с нежитью вместо обычного (лечение и благословение жгут её)


static func skill_range(u: Character, def: Dictionary) -> int:
	var r := int(def.get("range", 1))
	if r > 1:   # ближний бой талант дальности не увеличивает
		r += u.get_int("range_bonus")
	return r


static func target_block_reason(combat: CombatManager, u: Character, def: Dictionary, target_cell: Vector2i) -> String:
	if not combat.grid.in_bounds(target_cell):
		return "вне поля"
	var tt := str(def.get("target", "enemy"))
	if tt == "self":
		return "" if target_cell == u.cell else "только на себя"
	if SurfaceGrid.distance(u.cell, target_cell) > skill_range(u, def):
		return "слишком далеко"
	var t := combat.unit_at(target_cell)
	match tt:
		"enemy":
			if t == null or t.faction == u.faction:
				return "нужна вражеская цель"
		"ally":
			if t == null or (t.faction != u.faction and not (def.has("vs_undead") and t.is_undead())):
				return "нужна союзная цель"
		"cell":
			if combat.grid.blocked.has(target_cell):
				return "клетка занята стеной"
	return ""


static func execute(combat: CombatManager, caster: Character, def: Dictionary, target_cell: Vector2i) -> void:
	var center: Vector2i = caster.cell if str(def.get("target", "")) == "self" else target_cell
	var targets := _collect_targets(combat, caster, def, center)

	for t in targets:
		var target: Character = t
		if def.has("vs_undead") and target.is_undead() and target.faction != caster.faction:
			_smite_undead(caster, target, def["vs_undead"])
			continue
		if def.has("damage"):
			var res := DamageCalc.roll_attack(caster, target, def)
			if not bool(res["hit"]):
				GameLog.add("%s промахивается по %s." % [caster.display_name, target.display_name])
				GameEvents.add("miss", {"unit": target.uid, "src": caster.uid})
				continue
			var dealt := DamageCalc.apply_damage(target, float(res["amount"]), str(res["element"]))
			GameEvents.add("hit", {"unit": target.uid, "src": caster.uid, "amount": int(dealt),
				"element": str(res["element"]), "crit": bool(res["crit"])})
			GameLog.add("%s%s наносит %d урона (%s) по %s." % [
				"Крит! " if bool(res["crit"]) else "", caster.display_name, dealt, res["element"], target.display_name])
		if def.has("heal"):
			var heal_def: Dictionary = def["heal"]
			var amount := float(roundi(DamageCalc.with_variance(DamageCalc.base_skill_damage(caster.level)) * float(heal_def.get("multiplier", 1.0))))
			target.heal(amount)
			GameLog.add("%s восстанавливает %d ОЗ." % [target.display_name, amount])
			GameEvents.add("heal", {"unit": target.uid, "amount": int(amount)})
		if target.is_alive():
			_apply_statuses(caster, target, def, "target")

	_apply_statuses(caster, caster, def, "self")

	if def.has("surface"):
		var s: Dictionary = def["surface"]
		var radius := int(s.get("radius", 0))
		var explosions := combat.grid.apply_element(center, radius, str(s.get("element", "")), bool(s.get("create", false)), caster.level)
		for e in explosions:
			GameEvents.add("explosion", {"cell": GameEvents.cell(e["cell"])})
			var victim := combat.unit_at(e["cell"])
			if victim != null:
				var dealt := DamageCalc.environment_damage(victim, e["damage"], int(e["level"]))
				GameLog.add("%s получает %d урона от взрыва." % [victim.display_name, dealt])
				GameEvents.add("hit", {"unit": victim.uid, "amount": int(dealt), "element": "fire", "crit": false})
		# Персонажи в изменённых клетках сразу получают эффекты поверхности.
		for c in combat.grid.cells_in_radius(center, radius):
			var u := combat.unit_at(c)
			if u != null:
				combat.apply_cell_effects(u)


## Святой свет по нежити: урон без промаха и, если заданы, состояния.
static func _smite_undead(caster: Character, target: Character, vs: Dictionary) -> void:
	var res := DamageCalc.roll_attack(caster, target, vs)
	var dealt := DamageCalc.apply_damage(target, float(res["amount"]), str(res["element"]))
	GameEvents.add("hit", {"unit": target.uid, "src": caster.uid, "amount": int(dealt),
		"element": str(res["element"]), "crit": bool(res["crit"])})
	GameLog.add("Святой свет жжёт %s: %d урона." % [target.display_name, dealt])
	if target.is_alive():
		_apply_statuses(caster, target, vs, "target")


static func _collect_targets(combat: CombatManager, caster: Character, def: Dictionary, center: Vector2i) -> Array:
	var radius := int(def.get("aoe_radius", 0))
	var tt := str(def.get("target", "enemy"))
	if radius <= 0:
		if tt == "cell":
			var u := combat.unit_at(center)
			return [] if u == null else [u]
		var single := combat.unit_at(center)
		return [] if single == null else [single]
	var affects := str(def.get("affects", "all"))
	var out: Array = []
	for c in combat.grid.cells_in_radius(center, radius):
		var u := combat.unit_at(c)
		if u == null:
			continue
		if tt == "self" and u == caster:
			continue
		if affects == "enemies" and u.faction == caster.faction:
			continue
		if affects == "allies" and u.faction != caster.faction:
			continue
		out.append(u)
	return out


static func _apply_statuses(caster: Character, target: Character, def: Dictionary, on: String) -> void:
	var list: Array = def.get("statuses", [])
	for s in list:
		var sd: Dictionary = s
		if str(sd.get("on", "target")) != on:
			continue
		StatusSystem.apply(target, str(sd.get("id", "")), int(sd.get("duration", -1)), caster.level, float(sd.get("chance", 100)))

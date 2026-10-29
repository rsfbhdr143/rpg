class_name SkillSystem
extends RefCounted
## Выполнение навыков из data/skills.json.
## Поля навыка:
##   ap, cooldown, range, target ("enemy" | "ally" | "self" | "cell" | "fallen" — павший союзник),
##   aoe_radius, affects ("all" | "enemies" | "allies"), include_self — навык на себя с областью задевает и самого,
##   damage {source: "weapon"|"skill", element, multiplier}, can_miss, can_crit,
##   heal {multiplier}, statuses [{id, chance, duration?, on: "target"|"self"}],
##   surface {element, radius, create},
##   vs_undead {damage, statuses} — что навык делает с нежитью вместо обычного (лечение и благословение жгут её),
##   cleanse: true — снимает с цели все вредные состояния, revive {hp_pct} — поднимает павшего союзника,
##   move: "charge" — рывок: заклинатель бежит к цели (путь не длиннее дальности) и бьёт её с разбега;
##         "leap" — прыжок в выбранную свободную клетку (target "cell")
## Навык с уроном или стихией, задевший клетку взведённой ловушки, подрывает её; найденную ловушку можно
## выбрать целью вместо врага.


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
			if t == null and def.has("damage") and str(combat.grid.traps.get(target_cell, {}).get("state", "")) == "found":
				return ""   # подорвать найденную ловушку издалека
			if t == null or t.faction == u.faction:
				return "нужна вражеская цель"
		"ally":
			if t == null or (t.faction != u.faction and not (def.has("vs_undead") and t.is_undead())):
				return "нужна союзная цель"
		"cell":
			if combat.grid.blocked.has(target_cell):
				return "клетка занята стеной"
		"fallen":
			if fallen_at(combat, u, target_cell) == null:
				return "нужен павший союзник"
	match str(def.get("move", "")):
		"leap":
			if combat.occupied_cells(u).has(target_cell):
				return "клетка занята"
		"charge":
			if SurfaceGrid.distance(u.cell, target_cell) > 1 and charge_path(combat, u, target_cell, skill_range(u, def)).is_empty():
				return "не подобраться к цели"
	return ""


## Путь рывка к цели: до ближайшей свободной клетки рядом с ней, не длиннее max_steps. Уже рядом — пустой путь.
## Найденные ловушки герои обходят, как и при обычной ходьбе.
static func charge_path(combat: CombatManager, u: Character, target_cell: Vector2i, max_steps: int) -> Array:
	if SurfaceGrid.distance(u.cell, target_cell) <= 1:
		return []
	var avoid := combat.occupied_cells(u)
	if u.faction == "player":
		avoid.merge(combat.grid.known_traps())
	var best: Array = []
	for c in combat.grid.cells_in_radius(target_cell, 1):
		if c == target_cell or avoid.has(c):
			continue
		var p := combat.grid.find_path(u.cell, c, avoid)
		if not p.is_empty() and p.size() <= max_steps and (best.is_empty() or p.size() < best.size()):
			best = p
	return best


## Павший союзник в клетке (для воскрешения) или null.
static func fallen_at(combat: CombatManager, u: Character, c: Vector2i) -> Character:
	for o in combat.units:
		var f: Character = o
		if not f.is_alive() and f.cell == c and f.faction == u.faction and f != u:
			return f
	return null


static func execute(combat: CombatManager, caster: Character, def: Dictionary, target_cell: Vector2i) -> void:
	if def.has("revive"):
		var f := fallen_at(combat, caster, target_cell)
		if f != null:
			var rv: Dictionary = def["revive"]
			f.hp = maxf(1.0, roundf(f.max_hp() * float(rv.get("hp_pct", 30)) / 100.0))
			f.death_handled = false
			f.statuses.clear()
			f.ap = 0
			GameLog.add("%s поднимается на ноги!" % f.display_name)
			GameEvents.add("revive", {"unit": f.uid, "amount": int(f.hp)})
		return
	if def.has("move"):
		_move_caster(combat, caster, def, target_cell)
		if not caster.can_act():   # прыгнул в ловушку или в лёд: удар уже не состоится
			return
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
		if bool(def.get("cleanse", false)):
			var bad: Array = target.statuses.keys().filter(func(st): return bool(GameData.status(str(st)).get("negative", false)))
			for st in bad:
				target.remove_status(str(st))
			GameLog.add("%s: %s" % [target.display_name, "снято: " + ", ".join(bad.map(func(st): return str(GameData.status(str(st)).get("name", st)))) if not bad.is_empty() else "снимать нечего"])
			GameEvents.add("cleanse", {"unit": target.uid, "count": bad.size()})
		if target.is_alive():
			_apply_statuses(caster, target, def, "target")

	_apply_statuses(caster, caster, def, "self")

	if def.has("surface"):
		apply_surface(combat, center, def["surface"], caster.level)

	if def.has("damage") or def.has("surface"):
		for c in combat.grid.cells_in_radius(center, int(def.get("aoe_radius", 0))):
			if not combat.grid.armed_trap(c).is_empty():
				TrapSystem.spring(combat, c)


## Рывок или прыжок: заклинатель переносится, фигурка бежит (или летит дугой), поверхность и ловушка в клетке
## приземления срабатывают как при ходьбе.
static func _move_caster(combat: CombatManager, caster: Character, def: Dictionary, target_cell: Vector2i) -> void:
	var leap := str(def["move"]) == "leap"
	var path: Array = [target_cell] if leap else charge_path(combat, caster, target_cell, skill_range(caster, def))
	if path.is_empty():
		return
	caster.cell = path[-1]
	GameEvents.add("move", {"paths": {caster.uid: path.map(func(c): return GameEvents.cell(c))}, "leap": leap})
	if not combat.grid.armed_trap(caster.cell).is_empty():
		TrapSystem.spring(combat, caster.cell)
	combat.apply_cell_effects(caster)


## Стихия на клетки вокруг center (навык, ловушка): реакции поверхностей, взрывы, эффекты на стоящих.
## Вне боя (поле не активно) взрывы никого не добивают.
static func apply_surface(combat: CombatManager, center: Vector2i, s: Dictionary, level: int) -> void:
	var radius := int(s.get("radius", 0))
	var explosions := combat.grid.apply_element(center, radius, str(s.get("element", "")), bool(s.get("create", false)), level)
	for e in explosions:
		GameEvents.add("explosion", {"cell": GameEvents.cell(e["cell"])})
		var victim := combat.unit_at(e["cell"])
		if victim != null:
			var dealt := DamageCalc.environment_damage(victim, e["damage"], int(e["level"]))
			if not combat.active and victim.hp < 1.0:
				victim.hp = 1.0
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
		if tt == "self" and u == caster and not bool(def.get("include_self", false)):
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

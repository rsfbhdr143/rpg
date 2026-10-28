class_name SimpleAI
extends RefCounted
## Простейший ИИ: лечится при низком здоровье, бьёт ближайшего врага лучшим
## доступным навыком, иначе подходит ближе. Заменяй на свой, интерфейс один:
## take_turn(combat, unit) должен в конце вызвать combat.end_turn().

const MAX_ACTIONS := 8


static func take_turn(combat: CombatManager, unit: Character) -> void:
	var actions := 0
	while combat.active and combat.current == unit and actions < MAX_ACTIONS:
		actions += 1
		if not _act(combat, unit):
			break
	if combat.active and combat.current == unit:
		combat.end_turn()


## Одно действие. false — делать больше нечего.
static func _act(combat: CombatManager, unit: Character) -> bool:
	var enemies := combat.enemies_of(unit)
	if enemies.is_empty():
		return false

	# 1. Лечение/баф себя, если ОЗ меньше половины.
	if unit.hp < unit.max_hp() * 0.5:
		for sk in unit.skills:
			var def := GameData.skill(sk)
			if def.has("heal") and combat.skill_block_reason(unit, sk, unit.cell) == "":
				return combat.use_skill(unit, sk, unit.cell)

	# 2. Лучшая атака по любому врагу в досягаемости.
	var best_skill := ""
	var best_cell := Vector2i.ZERO
	var best_score := -1.0
	for sk in unit.skills:
		var def := GameData.skill(sk)
		var smite := def.has("vs_undead") and not def.has("damage")   # лечение и благословение по нежити
		if not def.has("damage") and str(def.get("target", "")) != "enemy" and not smite:
			continue
		for e in enemies:
			if smite and not e.is_undead():
				continue
			var cell: Vector2i = unit.cell if str(def.get("target", "")) == "self" else e.cell
			if combat.skill_block_reason(unit, sk, cell) != "":
				continue
			if cell == unit.cell and SurfaceGrid.distance(unit.cell, e.cell) > int(def.get("aoe_radius", 0)):
				continue
			var score := _score(def["vs_undead"] if smite else def, unit, e)
			if score > best_score:
				best_score = score
				best_skill = sk
				best_cell = cell
	if best_skill != "":
		return combat.use_skill(unit, best_skill, best_cell)

	# 3. Подойти к ближайшему врагу на дистанцию лучшего навыка.
	var target: Character = enemies[0]
	for e in enemies:
		if SurfaceGrid.distance(unit.cell, e.cell) < SurfaceGrid.distance(unit.cell, target.cell):
			target = e
	var want_range := 1
	for sk in unit.skills:
		var def := GameData.skill(sk)
		if def.has("damage") and int(def.get("ap", 0)) <= unit.ap:
			want_range = maxi(want_range, SkillSystem.skill_range(unit, def))
	var path := combat.grid.find_path(unit.cell, target.cell, combat.occupied_cells(unit), true)
	if path.size() <= 1:
		return false
	path.pop_back()   # клетка самой цели
	var steps := mini(path.size(), combat.max_move_steps(unit))
	# Останавливаемся, как только цель в досягаемости.
	for i in range(steps):
		if SurfaceGrid.distance(path[i], target.cell) <= want_range:
			steps = i + 1
			break
	if steps <= 0:
		return false
	return combat.move(unit, path[steps - 1])


static func _score(def: Dictionary, _unit: Character, enemy: Character) -> float:
	var score := 1.0
	if def.has("damage"):
		var dmg: Dictionary = def["damage"]
		score += float(dmg.get("multiplier", 1.0)) * 10.0
	var sts: Array = def.get("statuses", [])
	score += sts.size() * 3.0
	score += (1.0 - enemy.hp / enemy.max_hp()) * 5.0    # добиваем раненых
	score -= int(def.get("ap", 0)) * 0.5
	return score

class_name StatusSystem
extends RefCounted
## Статусы и их реакции (data/statuses.json):
## - "resist_by": шанс наложения снижается сопротивлением (fire/water/.../tenacity);
## - "blocked_by": не накладывается, если на цели уже есть указанный статус;
## - "removes": при наложении снимает перечисленные статусы;
## - "reactions": пары статусов, порождающие новый (мокрый + озноб = заморозка).

const MAX_REACTION_DEPTH := 4


## Пытается наложить статус. duration < 0 — длительность по умолчанию.
## Возвращает true, если статус (или результат реакции) был наложен.
static func apply(target: Character, status_id: String, duration: int = -1, source_level: int = 1, chance: float = 100.0, depth: int = 0) -> bool:
	var def := GameData.status(status_id)
	if def.is_empty():
		push_warning("StatusSystem: неизвестный статус '%s'" % status_id)
		return false
	if not target.is_alive() or depth > MAX_REACTION_DEPTH:
		return false
	var sname := str(def.get("name", status_id))

	if target.has_flag("immune_" + status_id):
		GameLog.add("%s невосприимчив к «%s»." % [target.display_name, sname])
		return false

	# Реакции с уже висящими статусами.
	for r in GameData.status_reactions:
		var reaction: Dictionary = r
		if str(reaction.get("incoming", "")) != status_id or not target.has_status(str(reaction.get("has", ""))):
			continue
		if not _roll(target, def, chance):
			GameLog.add("%s сопротивляется «%s»." % [target.display_name, sname])
			return false
		var consume: Array = reaction.get("consume", [])
		for c in consume:
			target.remove_status(str(c))
		if reaction.has("text"):
			GameLog.add("%s: %s" % [target.display_name, reaction["text"]])
		var result := str(reaction.get("result", ""))
		var applied := false
		if result != "":
			applied = apply(target, result, -1, source_level, 100.0, depth + 1)
		if bool(reaction.get("keep_incoming", false)):
			_put(target, status_id, duration, source_level)
			applied = true
		return applied

	var blocked_by: Array = def.get("blocked_by", [])
	for b in blocked_by:
		if target.has_status(str(b)):
			GameLog.add("«%s» не действует на %s (%s)." % [sname, target.display_name, GameData.status(str(b)).get("name", b)])
			return false

	if not _roll(target, def, chance):
		GameLog.add("%s сопротивляется «%s»." % [target.display_name, sname])
		return false

	_put(target, status_id, duration, source_level)
	return true


static func _roll(target: Character, def: Dictionary, chance: float) -> bool:
	var final_chance := chance
	var resist_by := str(def.get("resist_by", ""))
	if resist_by != "":
		final_chance *= 1.0 - clampf(target.get_resistance(resist_by), 0.0, 100.0) / 100.0
	return GameData.rng.randf() * 100.0 < final_chance


static func _put(target: Character, status_id: String, duration: int, source_level: int) -> void:
	var def := GameData.status(status_id)
	if duration < 0:
		duration = int(def.get("duration", 1))
	if bool(def.get("negative", false)) and target.has_flag("status_duration_minus_1"):
		duration = maxi(1, duration - 1)
	var removes: Array = def.get("removes", [])
	for r in removes:
		if str(r) != status_id:
			target.remove_status(str(r))
	if target.statuses.has(status_id):
		var existing: Dictionary = target.statuses[status_id]
		existing["turns"] = maxi(int(existing["turns"]), duration)
		existing["level"] = maxi(int(existing["level"]), source_level)
	else:
		target.statuses[status_id] = {"turns": duration, "level": source_level}
		GameLog.add("%s: %s (%d х.)" % [target.display_name, def.get("name", status_id), duration])


## Начало хода персонажа: урон/лечение от статусов (горение, яд, регенерация).
static func on_turn_start(target: Character) -> void:
	for id in target.statuses.keys():
		if not target.is_alive():
			return
		var def := GameData.status(str(id))
		if not def.has("tick"):
			continue
		var tick: Dictionary = def["tick"]
		var st: Dictionary = target.statuses[id]
		var lvl := int(st.get("level", 1))
		if str(tick.get("element", "")) == "heal":
			var amount := float(roundi(GameData.scaled(tick, lvl)))
			target.heal(amount)
			GameLog.add("%s восстанавливает %d ОЗ (%s)." % [target.display_name, amount, def.get("name", id)])
		else:
			var dealt := DamageCalc.environment_damage(target, tick, lvl)
			if dealt >= 0.0:
				GameLog.add("%s получает %d урона (%s)." % [target.display_name, dealt, def.get("name", id)])
			else:
				GameLog.add("%s лечится на %d (%s)." % [target.display_name, -dealt, def.get("name", id)])


## Конец хода персонажа: уменьшаем длительности.
static func on_turn_end(target: Character) -> void:
	for id in target.statuses.keys():
		var st: Dictionary = target.statuses[id]
		st["turns"] = int(st["turns"]) - 1
		if int(st["turns"]) <= 0:
			target.statuses.erase(id)

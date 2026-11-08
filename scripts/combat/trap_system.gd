class_name TrapSystem
extends RefCounted
## Ловушки, как в D:OS: спрятаны в клетках, герои замечают их Восприятием, найденную можно обезвредить
## (Ловкость, Плут) или подорвать издалека ударом по её клетке; кто наступил на взведённую — тот попался.
## Виды — data/traps.json, настройки — "traps" в data/rules.json, где стоят — буква {"trap": "вид"} в карте.
## Состояние живёт в SurfaceGrid.traps, поэтому сохраняется и уходит клиентам вместе с полем.
## Вне боя (поле не активно) ловушки никого не добивают: оставляют 1 ОЗ.


static func _cfg(key: String, default: float) -> float:
	return float((GameData.rule("traps", {}) as Dictionary).get(key, default))


static func _clamp_chance(v: float) -> float:
	return clampf(v, _cfg("min_chance", 5), _cfg("max_chance", 95))


static func name_of(trap_type: String) -> String:
	return str(GameData.trap(trap_type).get("name", trap_type))


## Шанс заметить ловушку, в процентах.
static func detect_chance(h: Character, trap_type: String) -> float:
	var base := float(GameData.rule("attribute_base", 5))
	var per := float(h.attributes.get("perception", base))
	return _clamp_chance(_cfg("detect_base", 45) + (per - base) * _cfg("detect_per_perception", 10)
		- float(GameData.trap(trap_type).get("hide", 0)) + h.get_stat("trap_detect"))


## Шанс обезвредить ловушку, в процентах.
static func disarm_chance(h: Character, trap_type: String) -> float:
	var base := float(GameData.rule("attribute_base", 5))
	var dex := float(h.attributes.get("dexterity", base))
	return _clamp_chance(_cfg("disarm_base", 55) + (dex - base) * _cfg("disarm_per_dexterity", 6)
		+ float(h.abilities.get("scoundrel", 0)) * _cfg("disarm_per_scoundrel", 12)
		- float(GameData.trap(trap_type).get("difficulty", 0)) + h.get_stat("trap_disarm"))


## Герой осматривается: спрятанные ловушки рядом замечает с шансом (каждую — один бросок за визит).
## Возвращает клетки найденных; события для экрана — announce().
static func look_around(grid: SurfaceGrid, h: Character) -> Array:
	var found: Array = []
	if not h.is_alive():
		return found
	var r := int(_cfg("detect_radius", 2))
	for c in grid.traps:
		var t: Dictionary = grid.traps[c]
		if str(t["state"]) != "hidden" or SurfaceGrid.distance(h.cell, c) > r:
			continue
		var rolled: Dictionary = t.get("rolled", {})
		if rolled.has(h.uid):
			continue
		rolled[h.uid] = true
		t["rolled"] = rolled
		if GameData.rng.randf() * 100.0 < detect_chance(h, str(t["type"])):
			t["state"] = "found"
			found.append(c)
			GameLog.add("%s замечает ловушку: %s." % [h.display_name, name_of(str(t["type"]))])
	return found


static func announce(grid: SurfaceGrid, h: Character, cells: Array) -> void:
	for c in cells:
		GameEvents.add("trap_found", {"cell": GameEvents.cell(c), "unit": h.uid, "type": str(grid.traps[c]["type"])})


## Ловушка срабатывает: урон и состояния всем в радиусе, стихия на клетки вокруг.
static func spring(field: CombatManager, cell: Vector2i) -> void:
	var t: Dictionary = field.grid.traps.get(cell, {})
	if t.is_empty():
		return
	var d := GameData.trap(str(t["type"]))
	t["state"] = "sprung"
	var lvl := int(d.get("level", 1))
	GameLog.add("Срабатывает ловушка: %s!" % name_of(str(t["type"])))
	GameEvents.add("trap", {"cell": GameEvents.cell(cell), "type": str(t["type"])})
	for c in field.grid.cells_in_radius(cell, int(d.get("radius", 0))):
		var v := field.unit_at(c)
		if v == null:
			continue
		if d.has("damage"):
			var dmg: Dictionary = d["damage"]
			var dealt := DamageCalc.environment_damage(v, dmg, lvl)
			if not field.active and v.hp < 1.0:
				v.hp = 1.0
			GameEvents.add("hit", {"unit": v.uid, "amount": int(dealt), "element": str(dmg.get("element", "physical")), "crit": false})
			GameLog.add("%s получает %d урона от ловушки." % [v.display_name, dealt])
		if v.is_alive():
			for s in d.get("statuses", []):
				var sd: Dictionary = s
				StatusSystem.apply(v, str(sd.get("id", "")), int(sd.get("duration", -1)), lvl, float(sd.get("chance", 100)))
	if d.has("surface"):
		SkillSystem.apply_surface(field, cell, d["surface"], lvl)


## Попытка обезвредить найденную ловушку: "disarmed", "failed" (можно ещё раз) или "sprung" (задел механизм).
static func try_disarm(field: CombatManager, h: Character, cell: Vector2i) -> String:
	var t := field.grid.armed_trap(cell)
	if t.is_empty():
		return ""
	var tt := str(t["type"])
	if GameData.rng.randf() * 100.0 < disarm_chance(h, tt):
		t["state"] = "disarmed"
		GameLog.add("%s обезвреживает ловушку: %s." % [h.display_name, name_of(tt)])
		GameEvents.add("trap_disarmed", {"cell": GameEvents.cell(cell), "unit": h.uid, "type": tt})
		return "disarmed"
	if GameData.rng.randf() * 100.0 < _cfg("fail_spring_pct", 50):
		GameLog.add("%s задевает механизм!" % h.display_name)
		spring(field, cell)
		return "sprung"
	GameLog.add("%s не может обезвредить ловушку. Можно попробовать ещё." % h.display_name)
	GameEvents.add("trap_fail", {"cell": GameEvents.cell(cell), "unit": h.uid})
	return "failed"

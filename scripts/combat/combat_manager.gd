class_name CombatManager
extends RefCounted
## Пошаговый бой в стиле D:OS1.
## - Порядок ходов по инициативе, пересчитывается каждый раунд.
## - Очки действия (ОД): в начале боя start_ap, в начале каждого следующего
##   хода +ap_recovery, но не больше max_ap. Неистраченные ОД сохраняются.
## - Передвижение стоит ОД: ceil(клетки / move_per_ap).
## - В начале хода: тики статусов, эффекты поверхности под ногами, кулдауны.
## UI и ИИ управляют боем через move(), use_skill(), end_turn().

signal turn_started(unit: Character)
signal unit_died(unit: Character)
signal combat_ended(winner_faction: String)
signal state_changed

var grid: SurfaceGrid
var units: Array = []          # все участники (живые и павшие)
var turn_order: Array = []     # очередь текущего раунда
var turn_index := -1
var round_number := 0
var active := false
var current: Character = null
var winner_faction := ""
var _had_turn := {}            # uid -> true, кто уже ходил в этом бою
var bystanders: Array = []     # персонажи на карте, не участвующие в бою (мешают проходу)


func _init(p_grid: SurfaceGrid) -> void:
	grid = p_grid


func start(p_units: Array) -> void:
	units = p_units.duplicate()
	active = true
	round_number = 0
	winner_faction = ""
	_had_turn.clear()
	for u in units:
		var c: Character = u
		c.ap = mini(c.get_int("start_ap"), c.get_int("max_ap"))
		c.cooldowns.clear()
	GameLog.add("=== Бой начинается ===")
	_start_round()
	_advance()


# --- Очередь ходов --------------------------------------------------------------

func _start_round() -> void:
	round_number += 1
	if round_number > 1:
		grid.tick_round()
	var rolls := {}
	turn_order.clear()
	for u in living_units():
		var c: Character = u
		rolls[c.uid] = c.get_stat("initiative") + GameData.rng.randf()   # случайный тай-брейк
		turn_order.append(c)
	turn_order.sort_custom(func(a, b): return rolls[a.uid] > rolls[b.uid])
	turn_index = -1
	var names: Array = []
	for c in turn_order:
		names.append(c.display_name)
	GameLog.add("--- Раунд %d: %s ---" % [round_number, ", ".join(names)])


func _advance() -> void:
	# Цикл вместо рекурсии: пропускаем павших и тех, кто пропускает ход.
	var guard := 0
	while active and guard < 1000:
		guard += 1
		if _check_end():
			return
		turn_index += 1
		if turn_index >= turn_order.size():
			_start_round()
			continue
		var unit: Character = turn_order[turn_index]
		if not unit.is_alive():
			continue
		current = unit
		if _begin_turn(unit):
			state_changed.emit()
			return
		# ход пропущен (оглушение, смерть от горения и т.п.)
		StatusSystem.on_turn_end(unit)


## Возвращает true, если персонаж может действовать в этот ход.
func _begin_turn(u: Character) -> bool:
	if _had_turn.has(u.uid):
		u.ap = mini(u.get_int("max_ap"), u.ap + u.get_int("ap_recovery"))
	_had_turn[u.uid] = true
	for sk in u.cooldowns.keys():
		u.cooldowns[sk] = int(u.cooldowns[sk]) - 1
		if int(u.cooldowns[sk]) <= 0:
			u.cooldowns.erase(sk)
	GameLog.add("Ход: %s (ОЗ %d/%d, ОД %d)" % [u.display_name, u.hp, u.max_hp(), u.ap])
	GameEvents.add("turn", {"unit": u.uid, "faction": u.faction})
	StatusSystem.on_turn_start(u)
	apply_cell_effects(u)
	_cleanup_dead()
	if not u.is_alive():
		return false
	turn_started.emit(u)
	if not u.can_act():
		GameLog.add("%s пропускает ход." % u.display_name)
		return false
	return true


func end_turn() -> void:
	if not active or current == null:
		return
	StatusSystem.on_turn_end(current)
	_advance()
	state_changed.emit()


func _check_end() -> bool:
	if not active:
		return true
	var factions := {}
	for u in living_units():
		factions[u.faction] = true
	if factions.size() > 1:
		return false
	active = false
	current = null
	winner_faction = str(factions.keys()[0]) if factions.size() == 1 else ""
	GameLog.add("=== Бой окончен. Победа: %s ===" % (winner_faction if winner_faction != "" else "никто"))
	GameEvents.add("combat_end", {"winner": winner_faction})
	_award_xp()
	combat_ended.emit(winner_faction)
	return true


func _award_xp() -> void:
	var total := 0
	for u in units:
		if not u.is_alive() and u.faction != winner_faction:
			total += u.xp_reward
	if total <= 0:
		return
	for u in living_units():
		GameLog.add("%s получает %d опыта." % [u.display_name, total])
		GameEvents.add("xp", {"unit": u.uid, "amount": total})
		Progression.add_xp(u, total)


# --- Запросы ------------------------------------------------------------------

func living_units() -> Array:
	return units.filter(func(u): return u.is_alive())


func enemies_of(u: Character) -> Array:
	return living_units().filter(func(o): return o.faction != u.faction)


func allies_of(u: Character) -> Array:
	return living_units().filter(func(o): return o.faction == u.faction)


## Кто стоит на клетке: участник боя, а если нет — враг вне боя (по нему можно ударить, и его отряд
## вступит в бой, см. GameSession._pull_into_combat). Жители-NPC целями не бывают.
func unit_at(c: Vector2i) -> Character:
	for u in living_units():
		if u.cell == c:
			return u
	for b in bystanders:
		var o: Character = b
		if o.cell == c and o.is_alive() and o.faction == "enemy":
			return o
	return null


func occupied_cells(except: Character = null) -> Dictionary:
	var out := {}
	for u in living_units():
		if u != except:
			out[u.cell] = true
	for b in bystanders:
		if b.is_alive():
			out[b.cell] = true
	return out


## Новые участники посреди боя (по ним ударили или их задело): ходят уже в этом раунде, в конце очереди,
## с ОД начала боя.
func join(new_units: Array) -> void:
	for u in new_units:
		var c: Character = u
		if units.has(c):
			continue
		units.append(c)
		bystanders.erase(c)
		c.ap = mini(c.get_int("start_ap"), c.get_int("max_ap"))
		c.cooldowns.clear()
		if c.is_alive():
			turn_order.append(c)
	state_changed.emit()


## Убрать павших (например, вступивших в бой уже убитыми) без проверки конца хода.
func refresh() -> void:
	_cleanup_dead()
	state_changed.emit()


func move_cost(u: Character, steps: int) -> int:
	if steps <= 0:
		return 0
	return int(ceil(float(steps) / maxf(0.5, u.get_stat("move_per_ap"))))


## Сколько клеток можно пройти за текущие ОД.
func max_move_steps(u: Character) -> int:
	return int(floor(u.ap * maxf(0.5, u.get_stat("move_per_ap"))))


# --- Действия -----------------------------------------------------------------

func move(u: Character, target_cell: Vector2i) -> bool:
	if not active or u != current or not u.can_act():
		return false
	var avoid := occupied_cells(u)
	if u.faction == "player":   # найденные ловушки герои обходят, если не идут на них нарочно
		for c in grid.known_traps():
			if c != target_cell:
				avoid[c] = true
	var path := grid.find_path(u.cell, target_cell, avoid)
	if path.is_empty():
		return false
	var cost := move_cost(u, path.size())
	if cost > u.ap:
		return false
	u.ap -= cost
	var walked: Array = []
	var trap := Vector2i(-1, -1)
	for step in path:
		u.cell = step
		walked.append(GameEvents.cell(step))
		if not grid.armed_trap(step).is_empty():
			trap = step
			break
		apply_cell_effects(u)
		if not u.can_act():
			GameLog.add("%s остановлен на %s." % [u.display_name, str(step)])
			break
	GameEvents.add("move", {"paths": {u.uid: walked}})
	if trap.x >= 0:
		TrapSystem.spring(self, trap)
		apply_cell_effects(u)
	elif u.faction == "player":
		TrapSystem.announce(grid, u, TrapSystem.look_around(grid, u))
	_cleanup_dead()
	state_changed.emit()
	if active and current == u and not u.can_act():
		end_turn()
	return true


## Пустая строка — навык можно применить; иначе причина.
func skill_block_reason(u: Character, skill_id: String, target_cell: Vector2i) -> String:
	if not active or u != current:
		return "не ваш ход"
	if not u.can_act():
		return "не может действовать"
	if not u.skills.has(skill_id):
		return "навык не изучен"
	var def := GameData.skill(skill_id)
	if def.is_empty():
		return "нет такого навыка"
	if u.ap < int(def.get("ap", 0)):
		return "не хватает ОД"
	if u.cooldowns.has(skill_id):
		return "перезарядка %d" % int(u.cooldowns[skill_id])
	return SkillSystem.target_block_reason(self, u, def, target_cell)


func use_skill(u: Character, skill_id: String, target_cell: Vector2i) -> bool:
	var reason := skill_block_reason(u, skill_id, target_cell)
	if reason != "":
		GameLog.add("Нельзя: %s" % reason)
		return false
	var def := GameData.skill(skill_id)
	u.ap -= int(def.get("ap", 0))
	if int(def.get("cooldown", 0)) > 0:
		u.cooldowns[skill_id] = int(def.get("cooldown", 0)) + 1   # +1: тикает в начале нашего же следующего хода
	GameLog.add("%s использует «%s»." % [u.display_name, def.get("name", skill_id)])
	GameEvents.add("cast", {"unit": u.uid, "skill": skill_id, "cell": GameEvents.cell(target_cell),
		"from": GameEvents.cell(u.cell)})
	SkillSystem.execute(self, u, def, target_cell)
	_cleanup_dead()
	state_changed.emit()
	if _check_end():
		return true
	if not u.can_act():   # например, сам себя заморозил
		end_turn()
	return true


## После действия не через use_skill (предмет-навык): убрать павших и проверить конец боя.
func after_external_action(u: Character) -> void:
	_cleanup_dead()
	state_changed.emit()
	if _check_end():
		return
	if not u.can_act():
		end_turn()


## После навыка вне боя (GameSession.explore_field): убрать павших, ходов и конца боя нет.
func after_explore_action() -> void:
	_cleanup_dead()
	state_changed.emit()


## Эффекты поверхностей в клетке персонажа (вход в клетку или начало хода).
func apply_cell_effects(u: Character) -> void:
	if not u.is_alive():
		return
	var lvl := grid.surface_level(u.cell)
	for s in grid.statuses_for_cell(u.cell):
		StatusSystem.apply(u, str(s.get("id", "")), -1, lvl, float(s.get("chance", 100)))


func _cleanup_dead() -> void:
	for u in units:
		var c: Character = u
		if c.is_alive() or c.death_handled:
			continue
		c.death_handled = true
		c.statuses.clear()
		GameLog.add("%s погибает!" % c.display_name)
		GameEvents.add("death", {"unit": c.uid, "faction": c.faction})
		var ds := str(GameData.rule("death_surface", ""))
		if ds != "" and grid.get_ground(c.cell) == "none" and not c.is_undead():   # мертвецы не кровоточат
			grid.set_surface(c.cell, ds, c.level)
		unit_died.emit(c)


# --- Сериализация -------------------------------------------------------------
# Сервер рассылает снимок боя клиентам; клиенты только рисуют его,
# сами ничего не считают (сервер — единственный источник истины).

func to_dict() -> Dictionary:
	var unit_dicts: Array = []
	for u in units:
		unit_dicts.append(u.to_dict())
	var order: Array = []
	for u in turn_order:
		order.append(u.uid)
	return {
		"grid": grid.to_dict(), "units": unit_dicts, "order": order,
		"turn_index": turn_index, "round": round_number, "active": active,
		"current": current.uid if current != null else "",
		"winner": winner_faction, "had_turn": _had_turn.keys(),
	}


static func from_dict(d: Dictionary) -> CombatManager:
	var cm := CombatManager.new(SurfaceGrid.from_dict(d.get("grid", {})))
	var by_uid := {}
	var unit_dicts: Array = d.get("units", [])
	for ud in unit_dicts:
		var c := Character.from_dict(ud)
		cm.units.append(c)
		by_uid[c.uid] = c
	var order: Array = d.get("order", [])
	for id in order:
		if by_uid.has(id):
			cm.turn_order.append(by_uid[id])
	cm.turn_index = int(d.get("turn_index", -1))
	cm.round_number = int(d.get("round", 0))
	cm.active = bool(d.get("active", false))
	cm.current = by_uid.get(str(d.get("current", "")), null)
	cm.winner_faction = str(d.get("winner", ""))
	var had: Array = d.get("had_turn", [])
	for id in had:
		cm._had_turn[id] = true
	return cm

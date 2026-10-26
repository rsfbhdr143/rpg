class_name GameSession
extends RefCounted
## Игровая сессия: игроки, их герои, мир (локации) и текущий бой.
## Не знает про сеть: принимает команды от id игрока и проверяет, что игрок
## управляет нужным героем. На сервере (или в одиночной игре) сессия «живая»;
## у клиентов это зеркало, собранное из снимка load_snapshot().
##
## Режимы (mode):
##   "explore" — исследование локации: герои ходят без ОД, кликом;
##   "combat"  — пошаговый бой прямо на карте локации;
##   "defeat"  — партия пала, ждём команду restart.
## Бой начинается, когда герой подходит к группе врагов ближе trigger_radius.
## Переход: герой встал на клетку выхода — вся партия переходит в другую локацию.
## Каждая посещённая локация помнит своё состояние (поверхности, павшие враги).
##
## Команды (Dictionary):
##   {"type": "move", "unit": uid, "cell": [x, y]}     в бою unit можно не указывать
##   {"type": "skill", "skill": id, "cell": [x, y]}     только в бою
##   {"type": "end_turn"}
##   {"type": "raise_attribute", "unit": uid, "attribute": "strength"}   вне боя
##   {"type": "raise_ability",   "unit": uid, "ability": "pyrokinetic"}  вне боя
##   {"type": "learn_talent",    "unit": uid, "talent": "lone_wolf"}     вне боя
##   {"type": "learn_skill",     "unit": uid, "skill": "fireball"}       вне боя
##   {"type": "restart"}                       после поражения: ко входу в локацию
##   {"type": "save"} / {"type": "load"}       только лидер и только вне боя

const AI_OWNER := 0   # персонажами с этим владельцем управляет ИИ
const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 1

var players: Dictionary = {}   # peer_id (int) -> {"name": String}
var owners: Dictionary = {}    # uid героя -> peer_id
var heroes: Array = []         # Character, переходят из локации в локацию
var mode := "explore"
var location_id := ""
var entry_spawn := ""          # точка входа в текущую локацию (туда возвращаемся после поражения)
var grid: SurfaceGrid = null   # поле текущей локации
var enemies: Array = []        # враги текущей локации, включая павших
var combat: CombatManager = null
var combat_encounter := ""

var _locations: Dictionary = {}    # id -> {"grid": SurfaceGrid, "enemies": Array, "defeated": Array}
var _mirror_defeated: Array = []   # у клиента: побеждённые группы текущей локации


static func max_players() -> int:
	return int(GameData.rule("max_players", 4))


# --- Игроки -------------------------------------------------------------------

func add_player(pid: int, player_name: String) -> bool:
	if players.has(pid) or players.size() >= max_players():
		return false
	players[pid] = {"name": player_name}
	return true


## Игрок ушёл: его героев забирает первый оставшийся игрок (или ИИ, если никого нет).
func remove_player(pid: int) -> void:
	players.erase(pid)
	var heir := leader_id()
	for uid in owners.keys():
		if int(owners[uid]) == pid:
			owners[uid] = heir


## Лидер — игрок с наименьшим id. Он сохраняет и загружает игру.
func leader_id() -> int:
	if players.is_empty():
		return AI_OWNER
	var ids := players.keys()
	ids.sort()
	return int(ids[0])


func player_name(pid: int) -> String:
	if pid == AI_OWNER:
		return "ИИ"
	return str(players.get(pid, {}).get("name", "игрок %d" % pid))


func owner_of(u: Character) -> int:
	if u == null:
		return AI_OWNER
	return int(owners.get(u.uid, AI_OWNER))


func heroes_of(pid: int) -> Array:
	return heroes.filter(func(h): return owner_of(h) == pid)


# --- Новая игра и партия --------------------------------------------------------

func new_game() -> void:
	_locations.clear()
	create_party()
	enter_location(str(GameData.rule("start_location", "")), str(GameData.rule("start_spawn", "")))


## Создаёт героев: по одному на игрока, но не меньше min_party_size
## (одиночка, как в D:OS1, ведёт двоих).
func create_party() -> void:
	heroes.clear()
	var templates: Array = GameData.rule("party_templates", ["knight", "wizard"])
	var size := clampi(maxi(players.size(), int(GameData.rule("min_party_size", 2))), 1, templates.size())
	for i in size:
		heroes.append(Character.from_template(str(templates[i])))
	_assign_owners()


## Раздаёт героев игрокам по кругу.
func _assign_owners() -> void:
	owners.clear()
	var ids := players.keys()
	ids.sort()
	for i in heroes.size():
		var h: Character = heroes[i]
		owners[h.uid] = int(ids[i % ids.size()]) if not ids.is_empty() else AI_OWNER


# --- Локации ------------------------------------------------------------------

func location_data() -> Dictionary:
	return GameData.location(location_id)


func defeated_encounters() -> Array:
	if _locations.has(location_id):
		return _locations[location_id]["defeated"]
	return _mirror_defeated


func all_units() -> Array:
	return heroes + enemies


func unit_at(c: Vector2i) -> Character:
	for u in all_units():
		if u.is_alive() and u.cell == c:
			return u
	return null


func unit_by_uid(uid: String) -> Character:
	for u in all_units():
		if u.uid == uid:
			return u
	return null


func enter_location(id: String, spawn: String) -> void:
	var data := GameData.location(id)
	if data.is_empty():
		push_error("GameSession: нет локации '%s' в locations.json" % id)
		return
	if not _locations.has(id):
		_locations[id] = _build_location(data)
	var st: Dictionary = _locations[id]
	location_id = id
	entry_spawn = spawn
	grid = st["grid"]
	enemies = st["enemies"]
	combat = null
	mode = "explore"
	_place_heroes(spawn)
	GameLog.add("Партия входит: %s." % data.get("name", id))


func _build_location(data: Dictionary) -> Dictionary:
	var size: Array = data.get("size", [12, 10])
	var g := SurfaceGrid.new(int(size[0]), int(size[1]))
	var walls: Array = data.get("walls", [])
	for w in walls:
		g.blocked[Vector2i(int(w[0]), int(w[1]))] = true
	var rects: Array = data.get("wall_rects", [])
	for r in rects:
		for dx in int(r[2]):
			for dy in int(r[3]):
				g.blocked[Vector2i(int(r[0]) + dx, int(r[1]) + dy)] = true
	var surfs: Array = data.get("surfaces", [])
	for s in surfs:
		var sc: Array = s["cell"]
		for c in g.cells_in_radius(Vector2i(int(sc[0]), int(sc[1])), int(s.get("radius", 0))):
			g.set_surface(c, str(s["id"]))

	var foes: Array = []
	var encounters: Array = data.get("encounters", [])
	for enc in encounters:
		var list: Array = enc.get("enemies", [])
		for e in list:
			if heroes.size() < int(e.get("min_party", 0)):
				continue
			var c := Character.from_template(str(e["template"]))
			var ec: Array = e["cell"]
			c.cell = Vector2i(int(ec[0]), int(ec[1]))
			c.encounter_id = str(enc.get("id", ""))
			foes.append(c)
	return {"grid": g, "enemies": foes, "defeated": []}


func _place_heroes(spawn: String) -> void:
	var spawns: Dictionary = location_data().get("spawns", {})
	var cells: Array = spawns.get(spawn, [])
	if cells.is_empty() and not spawns.is_empty():
		cells = spawns.values()[0]
	var taken := {}
	for e in enemies:
		if e.is_alive():
			taken[e.cell] = true
	for i in heroes.size():
		var h: Character = heroes[i]
		var want := Vector2i(i, 0)
		if not cells.is_empty():
			var sc: Array = cells[i % cells.size()]
			want = Vector2i(int(sc[0]), int(sc[1]))
		h.cell = _free_cell_near(want, taken)
		taken[h.cell] = true


func _free_cell_near(c: Vector2i, taken: Dictionary) -> Vector2i:
	for r in range(0, 6):
		for cell in grid.cells_in_radius(c, r):
			if grid.is_walkable(cell) and not taken.has(cell):
				return cell
	return c


func _occupied(except: Character) -> Dictionary:
	var out := {}
	for u in all_units():
		if u != except and u.is_alive():
			out[u.cell] = true
	return out


func exit_at(c: Vector2i) -> Dictionary:
	var exits: Array = location_data().get("exits", [])
	for ex in exits:
		var cells: Array = ex.get("cells", [])
		for ec in cells:
			if Vector2i(int(ec[0]), int(ec[1])) == c:
				return ex
	return {}


## Радиус, с которого группа врагов замечает партию (0 — уже побеждена или нет такой).
func trigger_radius(encounter: String) -> int:
	if defeated_encounters().has(encounter):
		return 0
	var encounters: Array = location_data().get("encounters", [])
	for enc in encounters:
		if str(enc.get("id", "")) == encounter:
			return int(enc.get("trigger_radius", 4))
	return 0


## Какая группа врагов заметила партию ("" — никто).
func _aggro_check() -> String:
	for e in enemies:
		var foe: Character = e
		if not foe.is_alive():
			continue
		var r := trigger_radius(foe.encounter_id)
		if r <= 0:
			continue
		for h in heroes:
			if h.is_alive() and SurfaceGrid.distance(h.cell, foe.cell) <= r:
				return foe.encounter_id
	return ""


# --- Бой ----------------------------------------------------------------------

func _start_combat(encounter: String) -> void:
	combat_encounter = encounter
	var units: Array = []
	var others: Array = []
	for h in heroes:
		if h.is_alive():
			units.append(h)
	for e in enemies:
		if not e.is_alive():
			continue
		if e.encounter_id == encounter:
			units.append(e)
		else:
			others.append(e)
	mode = "combat"
	combat = CombatManager.new(grid)
	combat.bystanders = others
	GameLog.add("Враги заметили партию!")
	combat.start(units)
	_after_action()


## Проверяет, не закончился ли бой, и переключает режим.
func _after_action() -> void:
	if mode != "combat" or combat == null or combat.active:
		return
	if combat.winner_faction == "player":
		var st: Dictionary = _locations.get(location_id, {})
		if not st.is_empty() and not st["defeated"].has(combat_encounter):
			st["defeated"].append(combat_encounter)
		var revive_hp := float(GameData.rule("revive_after_combat_hp", 1))
		var clear := bool(GameData.rule("clear_statuses_after_combat", true))
		for h in heroes:
			var hero: Character = h
			if not hero.is_alive() and revive_hp > 0.0:
				hero.hp = minf(revive_hp, hero.max_hp())
				hero.death_handled = false
				GameLog.add("%s поднимается на ноги." % hero.display_name)
			if clear:
				hero.statuses.clear()
			hero.cooldowns.clear()
		mode = "explore"
		GameLog.add("Победа! Можно идти дальше.")
	else:
		mode = "defeat"
		GameLog.add("Партия пала. R — вернуться ко входу в локацию.")
	combat = null


func _restart_after_defeat() -> void:
	for h in heroes:
		h.full_restore()
	for e in enemies:
		var foe: Character = e
		if foe.is_alive() and foe.encounter_id == combat_encounter:
			foe.hp = foe.max_hp()
			foe.statuses.clear()
			foe.cooldowns.clear()
	mode = "explore"
	_place_heroes(entry_spawn)
	GameLog.add("Партия собирается у входа в локацию.")


func is_ai_turn() -> bool:
	return mode == "combat" and combat != null and combat.active and combat.current != null \
		and owner_of(combat.current) == AI_OWNER


## Ход ИИ. force=true — ИИ сыграет и за героя (удобно для тестов и автобоя).
func run_ai_turn(force: bool = false) -> void:
	if is_ai_turn() or (force and mode == "combat" and combat != null and combat.active):
		SimpleAI.take_turn(combat, combat.current)
	_after_action()


# --- Команды ------------------------------------------------------------------

## Выполняет команду игрока pid. Пустая строка — успех, иначе причина отказа.
func submit(pid: int, cmd: Dictionary) -> String:
	if grid == null:
		return "игра не начата"
	var kind := str(cmd.get("type", ""))
	var err := ""
	match kind:
		"move":
			err = _cmd_move(pid, cmd)
		"skill", "end_turn":
			err = _cmd_combat(pid, cmd, kind)
		"raise_attribute", "raise_ability", "learn_talent", "learn_skill":
			err = _cmd_progression(pid, cmd, kind)
		"restart":
			if mode != "defeat":
				return "партия ещё жива"
			_restart_after_defeat()
		"save":
			err = "сохранять может только лидер" if pid != leader_id() else save_game()
			if err == "":
				GameLog.add("Игра сохранена.")
		"load":
			err = "загружать может только лидер" if pid != leader_id() else load_game()
			if err == "":
				GameLog.add("Игра загружена.")
		_:
			err = "неизвестная команда '%s'" % kind
	_after_action()
	return err


func _cmd_move(pid: int, cmd: Dictionary) -> String:
	if mode == "combat":
		return _cmd_combat(pid, cmd, "move")
	if mode != "explore":
		return "партия пала"
	var u := unit_by_uid(str(cmd.get("unit", "")))
	if u == null or not heroes.has(u):
		return "нет такого героя"
	if owner_of(u) != pid:
		return "это не ваш герой"
	if not u.is_alive():
		return "герой пал"
	var path := grid.find_path(u.cell, _cell(cmd), _occupied(u))
	if path.is_empty():
		return "туда не дойти"
	for step in path:
		u.cell = step
		var enc := _aggro_check()
		if enc != "":
			_start_combat(enc)
			return ""
	var ex := exit_at(u.cell)
	if not ex.is_empty():
		enter_location(str(ex.get("to", "")), str(ex.get("spawn", "")))
	return ""


func _cmd_combat(pid: int, cmd: Dictionary, kind: String) -> String:
	if mode != "combat" or combat == null or not combat.active:
		return "сейчас не бой"
	var u := combat.current
	if u == null or owner_of(u) != pid:
		return "сейчас ходит не ваш персонаж"
	match kind:
		"move":
			if not combat.move(u, _cell(cmd)):
				return "туда не дойти (ОД: %d)" % u.ap
		"skill":
			var skill_id := str(cmd.get("skill", ""))
			var reason := combat.skill_block_reason(u, skill_id, _cell(cmd))
			if reason != "":
				return reason
			combat.use_skill(u, skill_id, _cell(cmd))
		"end_turn":
			combat.end_turn()
	return ""


func _cmd_progression(pid: int, cmd: Dictionary, kind: String) -> String:
	if mode == "combat":
		return "во время боя нельзя"
	var u := unit_by_uid(str(cmd.get("unit", "")))
	if u == null or not heroes.has(u):
		return "нет такого героя"
	if owner_of(u) != pid:
		return "это не ваш герой"
	match kind:
		"raise_attribute":
			if not Progression.raise_attribute(u, str(cmd.get("attribute", ""))):
				return "нельзя повысить атрибут"
		"raise_ability":
			if not Progression.raise_ability(u, str(cmd.get("ability", ""))):
				return "не хватает очков способностей"
		"learn_talent":
			var reason := Progression.talent_block_reason(u, str(cmd.get("talent", "")))
			if reason != "":
				return reason
			Progression.learn_talent(u, str(cmd.get("talent", "")))
		"learn_skill":
			var reason := Progression.skill_block_reason(u, str(cmd.get("skill", "")))
			if reason != "":
				return reason
			Progression.learn_skill(u, str(cmd.get("skill", "")))
	return ""


static func _cell(cmd: Dictionary) -> Vector2i:
	var c: Array = cmd.get("cell", [0, 0])
	return Vector2i(int(c[0]), int(c[1]))


# --- Сохранение ---------------------------------------------------------------

func save_game(path: String = SAVE_PATH) -> String:
	if mode != "explore":
		return "сохраняться можно только вне боя"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "не удалось записать сохранение"
	f.store_string(JSON.stringify(to_save(), "\t"))
	return ""


func load_game(path: String = SAVE_PATH) -> String:
	if mode == "combat":
		return "загружаться можно только вне боя"
	if not FileAccess.file_exists(path):
		return "сохранения нет"
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return "сохранение повреждено"
	from_save(parsed)
	return ""


func to_save() -> Dictionary:
	var locs := {}
	for id in _locations:
		var st: Dictionary = _locations[id]
		var g: SurfaceGrid = st["grid"]
		locs[id] = {
			"grid": g.to_dict(),
			"enemies": st["enemies"].map(func(e): return e.to_dict()),
			"defeated": st["defeated"].duplicate(),
		}
	return {
		"version": SAVE_VERSION,
		"location": location_id,
		"entry_spawn": entry_spawn,
		"heroes": heroes.map(func(h): return h.to_dict()),
		"locations": locs,
	}


func from_save(d: Dictionary) -> void:
	heroes = []
	var hero_dicts: Array = d.get("heroes", [])
	for hd in hero_dicts:
		heroes.append(Character.from_dict(hd))
	_assign_owners()
	_locations = {}
	var locs: Dictionary = d.get("locations", {})
	for id in locs:
		var ld: Dictionary = locs[id]
		var foes: Array = []
		var enemy_dicts: Array = ld.get("enemies", [])
		for ed in enemy_dicts:
			foes.append(Character.from_dict(ed))
		var defeated: Array = ld.get("defeated", [])
		_locations[id] = {"grid": SurfaceGrid.from_dict(ld.get("grid", {})), "enemies": foes, "defeated": defeated.duplicate()}
	location_id = str(d.get("location", ""))
	entry_spawn = str(d.get("entry_spawn", ""))
	var st: Dictionary = _locations.get(location_id, {})
	grid = st.get("grid", null)
	enemies = st.get("enemies", [])
	combat = null
	mode = "explore"


# --- Снимки для сети ------------------------------------------------------------

func snapshot(log_tail: int = 40) -> Dictionary:
	var s := {
		"players": players.duplicate(true),
		"owners": owners.duplicate(),
		"mode": mode,
		"location": location_id,
		"defeated": defeated_encounters().duplicate(),
		"heroes": heroes.map(func(h): return h.to_dict()),
		"enemies": enemies.map(func(e): return e.to_dict()),
		"log": GameLog.lines.slice(maxi(0, GameLog.lines.size() - log_tail)),
	}
	if combat != null:
		s["combat"] = combat.to_dict()   # поле боя уже внутри
	elif grid != null:
		s["grid"] = grid.to_dict()
	return s


## Клиент: заменить своё состояние снимком с сервера.
func load_snapshot(s: Dictionary) -> void:
	players = {}
	var ps: Dictionary = s.get("players", {})
	for pid in ps:
		players[int(pid)] = ps[pid]
	owners = {}
	var ow: Dictionary = s.get("owners", {})
	for uid in ow:
		owners[str(uid)] = int(ow[uid])
	mode = str(s.get("mode", "explore"))
	location_id = str(s.get("location", ""))
	var defeated: Array = s.get("defeated", [])
	_mirror_defeated = defeated.duplicate()

	var by_uid := {}
	combat = null
	var cd: Dictionary = s.get("combat", {})
	if not cd.is_empty():
		combat = CombatManager.from_dict(cd)
		grid = combat.grid
		for u in combat.units:
			by_uid[u.uid] = u
	else:
		var gd: Dictionary = s.get("grid", {})
		grid = SurfaceGrid.from_dict(gd) if not gd.is_empty() else null
	heroes = _mirror_units(s.get("heroes", []), by_uid)
	enemies = _mirror_units(s.get("enemies", []), by_uid)
	var lines: Array = s.get("log", [])
	GameLog.lines = lines.duplicate()


static func _mirror_units(dicts: Array, by_uid: Dictionary) -> Array:
	var out: Array = []
	for d in dicts:
		var uid := str(d.get("uid", ""))
		out.append(by_uid[uid] if by_uid.has(uid) else Character.from_dict(d))
	return out

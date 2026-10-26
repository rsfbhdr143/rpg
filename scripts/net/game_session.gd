class_name GameSession
extends RefCounted
## Игровая сессия: игроки, их герои и текущий бой.
## Не знает про сеть: принимает команды от id игрока и проверяет, что игрок
## действительно управляет текущим персонажем. На сервере (или в одиночной игре)
## сессия «живая»; у клиентов это зеркало, собранное из снимка load_snapshot().
##
## Команды (Dictionary):
##   {"type": "move",     "cell": [x, y]}
##   {"type": "skill",    "skill": "fireball", "cell": [x, y]}
##   {"type": "end_turn"}
##   {"type": "restart"}   — новый бой после окончания текущего

const AI_OWNER := 0   # персонажами с этим владельцем управляет ИИ

var players: Dictionary = {}   # peer_id (int) -> {"name": String}
var owners: Dictionary = {}    # uid персонажа -> peer_id
var heroes: Array = []         # Character, сохраняются между боями (опыт, уровни)
var combat: CombatManager = null
var encounter_id := ""


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
	var heir := AI_OWNER
	if not players.is_empty():
		var ids := players.keys()
		ids.sort()
		heir = int(ids[0])
	for uid in owners.keys():
		if int(owners[uid]) == pid:
			owners[uid] = heir


func player_name(pid: int) -> String:
	if pid == AI_OWNER:
		return "ИИ"
	return str(players.get(pid, {}).get("name", "игрок %d" % pid))


func owner_of(u: Character) -> int:
	if u == null:
		return AI_OWNER
	return int(owners.get(u.uid, AI_OWNER))


# --- Партия и бой -------------------------------------------------------------

## Создаёт героев: по одному на игрока, но не меньше min_party_size
## (одиночка, как в D:OS1, ведёт двоих). Герои раздаются игрокам по кругу.
func create_party() -> void:
	heroes.clear()
	owners.clear()
	var templates: Array = GameData.rule("party_templates", ["knight", "wizard"])
	var size := clampi(maxi(players.size(), int(GameData.rule("min_party_size", 2))), 1, templates.size())
	var ids := players.keys()
	ids.sort()
	for i in size:
		var h := Character.from_template(str(templates[i]))
		heroes.append(h)
		owners[h.uid] = int(ids[i % ids.size()]) if not ids.is_empty() else AI_OWNER


func start_encounter(id: String = "") -> void:
	if id == "":
		id = str(GameData.rule("default_encounter", ""))
	encounter_id = id
	var enc := GameData.encounter(id)
	if enc.is_empty():
		push_error("GameSession: нет столкновения '%s' в encounters.json" % id)
		return
	GameLog.clear()
	var size: Array = enc.get("size", [12, 10])
	var grid := SurfaceGrid.new(int(size[0]), int(size[1]))
	var walls: Array = enc.get("walls", [])
	for w in walls:
		grid.blocked[Vector2i(int(w[0]), int(w[1]))] = true
	var surfs: Array = enc.get("surfaces", [])
	for s in surfs:
		var sc: Array = s["cell"]
		for c in grid.cells_in_radius(Vector2i(int(sc[0]), int(sc[1])), int(s.get("radius", 0))):
			grid.set_surface(c, str(s["id"]))

	var spawns: Array = enc.get("hero_spawns", [])
	for i in heroes.size():
		var h: Character = heroes[i]
		h.full_restore()
		var sp: Array = spawns[i % spawns.size()] if not spawns.is_empty() else [0, i]
		h.cell = Vector2i(int(sp[0]), int(sp[1]))

	var all_units: Array = heroes.duplicate()
	var enemies: Array = enc.get("enemies", [])
	for e in enemies:
		if heroes.size() < int(e.get("min_party", 0)):
			continue
		var c := Character.from_template(str(e["template"]))
		var ec: Array = e["cell"]
		c.cell = Vector2i(int(ec[0]), int(ec[1]))
		all_units.append(c)
		owners[c.uid] = AI_OWNER

	combat = CombatManager.new(grid)
	combat.start(all_units)


func is_ai_turn() -> bool:
	return combat != null and combat.active and combat.current != null and owner_of(combat.current) == AI_OWNER


func run_ai_turn() -> void:
	if is_ai_turn():
		SimpleAI.take_turn(combat, combat.current)


# --- Команды ------------------------------------------------------------------

## Выполняет команду игрока pid. Пустая строка — успех, иначе причина отказа.
func submit(pid: int, cmd: Dictionary) -> String:
	if combat == null:
		return "игра не начата"
	var kind := str(cmd.get("type", ""))
	if kind == "restart":
		if combat.active:
			return "бой ещё идёт"
		start_encounter(encounter_id)
		return ""
	if not combat.active:
		return "бой окончен"
	var u := combat.current
	if u == null or owner_of(u) != pid:
		return "сейчас ходит не ваш персонаж"
	match kind:
		"move":
			if not combat.move(u, _cell(cmd)):
				return "туда не дойти"
		"skill":
			var skill_id := str(cmd.get("skill", ""))
			var reason := combat.skill_block_reason(u, skill_id, _cell(cmd))
			if reason != "":
				return reason
			combat.use_skill(u, skill_id, _cell(cmd))
		"end_turn":
			combat.end_turn()
		_:
			return "неизвестная команда '%s'" % kind
	return ""


static func _cell(cmd: Dictionary) -> Vector2i:
	var c: Array = cmd.get("cell", [0, 0])
	return Vector2i(int(c[0]), int(c[1]))


# --- Снимки для сети ------------------------------------------------------------

func snapshot(log_tail: int = 40) -> Dictionary:
	var hero_ids: Array = []
	for h in heroes:
		hero_ids.append(h.uid)
	return {
		"players": players.duplicate(true),
		"owners": owners.duplicate(),
		"heroes": hero_ids,
		"encounter": encounter_id,
		"combat": combat.to_dict() if combat != null else {},
		"log": GameLog.lines.slice(maxi(0, GameLog.lines.size() - log_tail)),
	}


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
	encounter_id = str(s.get("encounter", ""))
	var cd: Dictionary = s.get("combat", {})
	combat = CombatManager.from_dict(cd) if not cd.is_empty() else null
	heroes = []
	var hero_ids: Array = s.get("heroes", [])
	if combat != null:
		for u in combat.units:
			if hero_ids.has(u.uid):
				heroes.append(u)
	var lines: Array = s.get("log", [])
	GameLog.lines = lines.duplicate()

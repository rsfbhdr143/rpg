class_name GameSession
extends RefCounted
## Игровая сессия: игроки, их герои, мир (локации), сюжет и текущий бой.
## Не знает про сеть: принимает команды от id игрока и проверяет, что игрок
## управляет нужным героем. На сервере (или в одиночной игре) сессия «живая»;
## у клиентов это зеркало, собранное из снимка load_snapshot().
##
## Режимы (mode):
##   "explore"  — исследование локации: герои ходят без ОД, кликом; спутники идут следом;
##   "dialogue" — идёт разговор (или заставка), ходить нельзя, отвечает тот, кто начал разговор;
##   "combat"   — пошаговый бой прямо на карте локации;
##   "defeat"   — партия пала, ждём команду restart.
## Бой начинается, когда герой подходит к группе врагов ближе trigger_radius, или эффектом сюжета.
## Переход: герой встал на клетку выхода — вся партия переходит в другую локацию (мимо выходов пути не ведут).
## Путевые камни (предметы с "waypoint": true), как в D:OS: найденный камень переносит партию к любому другому
## найденному камню, в том числе в другой локации.
## Каждая посещённая локация помнит своё состояние (поверхности, павшие враги).
## Встречи с "respawn": true оживают при новом входе в локацию — на них можно качаться.
## Ловушки (TrapSystem): герои замечают их по дороге, найденные обходят; наступил — сработала.
##
## Команды (Dictionary):
##   {"type": "move", "unit": uid, "cell": [x, y]}     в бою unit можно не указывать
##   {"type": "talk", "unit": uid, "target": uid NPC | "object": id}   подойти и заговорить
##   {"type": "dialogue_next"} / {"type": "dialogue_choice", "index": i} / {"type": "dialogue_skip"}
##   {"type": "use_item", "unit": uid, "item": id}       зелья и прочее; в бою стоит ОД
##   {"type": "use_item", "unit": uid, "item": id, "cell": [x, y]}   масло, факел: в бою и вне боя, как навык
##   {"type": "disarm", "unit": uid, "cell": [x, y]}     подойти к найденной ловушке и обезвредить
##   {"type": "travel", "to": id камня}                  перенестись к найденному путевому камню
##   {"type": "equip"/"unequip", "unit": uid, "item": id}   надеть в свою ячейку (прежний предмет — в сумку) / снять
##   {"type": "loot", "unit": uid, "corpse": uid}        подойти к телу и обыскать (откроется окно добычи)
##   {"type": "loot_take", "unit": uid, "corpse": uid, "item": id | "all"}   взять с тела
##   {"type": "trade_buy"/"trade_sell", "unit": uid, "npc": id, "item": id}  купить у торговца / продать ему
##   {"type": "skill", "skill": id, "cell": [x, y]}     в бою — навык текущего героя;
##   {"type": "skill", "unit": uid, "skill": id, "cell": [x, y]}  вне боя: без ОД, удар по врагу начинает бой
##   {"type": "end_turn"}
##   {"type": "raise_attribute", "unit": uid, "attribute": "strength"}   вне боя
##   {"type": "raise_ability",   "unit": uid, "ability": "pyrokinetic"}  вне боя
##   {"type": "learn_talent",    "unit": uid, "talent": "lone_wolf"}     вне боя
##   {"type": "learn_skill",     "unit": uid, "skill": "fireball"}       вне боя
##   {"type": "restart"}                       после поражения: ко входу в локацию
##   {"type": "save"} / {"type": "load"}       только лидер и только вне боя

const AI_OWNER := 0   # персонажами с этим владельцем управляет ИИ
const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 2

var players: Dictionary = {}   # peer_id (int) -> {"name": String}
var owners: Dictionary = {}    # uid героя -> peer_id
var heroes: Array = []         # Character, переходят из локации в локацию
var mode := "explore"
var location_id := ""
var entry_spawn := ""          # точка входа в текущую локацию (туда возвращаемся после поражения)
var grid: SurfaceGrid = null   # поле текущей локации
var enemies: Array = []        # враги текущей локации, включая павших
var npcs: Array = []           # NPC текущей локации, которые сейчас видны
var combat: CombatManager = null
var combat_encounter := ""

# Сюжет
var flags: Dictionary = {}     # имя -> true
var quests: Dictionary = {}    # id задания -> id текущего этапа
var quest_order: Array = []    # в каком порядке задания получены (для журнала)
var items: Dictionary = {}     # id предмета -> количество (общая сумка партии)
var gold := 0
var loot: Dictionary = {}      # добыча на телах текущей локации: uid тела -> {"cell", "name", "items": {id: n}, "gold"}
var trade_stock: Dictionary = {}   # товар торговцев: id жителя -> {id предмета: сколько}
var dialogue: Dictionary = {}  # {"id", "node", "pid", "hero", "npc", "pending"} или {}

var _locations: Dictionary = {}    # id -> {"grid", "enemies", "defeated", "spawned", "npcs", "loot", "rolled"}
var _mirror_defeated: Array = []   # у клиента: побеждённые группы (все локации)
var _mode_before_dialogue := "explore"
var _explore_clock := 0.0          # секунды вне боя до следующего «хода» (перезарядка, состояния)
var _walks: Dictionary = {}        # pid -> {"loc", "cells": {uid: [Vector2i]}} — последний проход партии игрока


static func max_players() -> int:
	return int(GameData.rule("max_players", 4))


# --- Игроки -------------------------------------------------------------------

func add_player(pid: int, player_name: String) -> bool:
	if players.has(pid) or players.size() >= max_players():
		return false
	players[pid] = {"name": player_name}
	return true


## Игрок ушёл: его героев (и разговор) забирает первый оставшийся игрок (или ИИ, если никого нет).
func remove_player(pid: int) -> void:
	players.erase(pid)
	var heir := leader_id()
	for uid in owners.keys():
		if int(owners[uid]) == pid:
			owners[uid] = heir
	if not dialogue.is_empty() and int(dialogue.get("pid", 0)) == pid:
		dialogue["pid"] = heir


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

## choices: peer_id -> [шаблоны героев], которых выбрал игрок (можно пустой словарь).
func new_game(choices: Dictionary = {}) -> void:
	_locations.clear()
	flags.clear()
	quests.clear()
	quest_order.clear()
	items.clear()
	trade_stock.clear()
	gold = int(GameData.rule("start_gold", 0))
	dialogue = {}
	var start_items: Dictionary = GameData.rule("start_items", {})
	for it in start_items:
		items[str(it)] = int(start_items[it])
	create_party(choices)
	enter_location(str(GameData.rule("start_location", "")), str(GameData.rule("start_spawn", "")))


## Создаёт героев: по одному на игрока, но не меньше min_party_size
## (одиночка, как в D:OS1, ведёт двоих). Выбор игроков учитывается, если шаблон свободен.
func create_party(choices: Dictionary = {}) -> void:
	heroes.clear()
	owners.clear()
	var templates: Array = GameData.rule("party_templates", ["knight", "wizard"])
	var size := clampi(maxi(players.size(), int(GameData.rule("min_party_size", 2))), 1, templates.size())
	var ids := players.keys()
	ids.sort()
	var picks: Array = []   # [шаблон, владелец]
	# сначала то, что выбрали игроки (по одному герою на игрока, одиночке — сколько выбрал); классы могут повторяться
	for pid in ids:
		var want: Array = choices.get(pid, choices.get(str(pid), []))
		var limit := 1 if ids.size() > 1 else size
		for t in want:
			if picks.size() >= size or limit <= 0:
				break
			if templates.has(str(t)):
				picks.append([str(t), int(pid)])
				limit -= 1
	# у кого нет героя — даём класс, которого ещё нет в отряде
	for pid in ids:
		if picks.size() >= size:
			break
		if not picks.any(func(p): return p[1] == int(pid)):
			picks.append([_free_template(picks, templates), int(pid)])
	# добиваем до минимального размера партии, раздавая по кругу
	var i := 0
	while picks.size() < size:
		picks.append([_free_template(picks, templates), int(ids[i % ids.size()]) if not ids.is_empty() else AI_OWNER])
		i += 1
	for p in picks:
		var h := Character.from_template(str(p[0]))
		h.display_name = hero_name(str(p[0]), heroes)
		heroes.append(h)
		owners[h.uid] = int(p[1])


## Класс, которого ещё нет в отряде (если все уже есть — первый).
func _free_template(picks: Array, templates: Array) -> String:
	for t in templates:
		if not picks.any(func(p): return p[0] == str(t)):
			return str(t)
	return str(templates[0])


## Имя героя: у каждого класса свой список (чуть изменённые имена духов Гоэтии, см. docs/story.md);
## второй герой того же класса берёт следующее имя.
static func hero_name(template: String, party: Array) -> String:
	var names: Array = (GameData.rule("hero_names", {}) as Dictionary).get(template, [])
	if names.is_empty():
		return str(GameData.character(template).get("name", template))
	var same := party.filter(func(h): return h.template_id == template).size()
	return str(names[same % names.size()])


## Раздаёт героев игрокам по кругу (после загрузки сохранения).
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


## Побеждена ли встреча в любой локации.
func encounter_defeated(enc_id: String) -> bool:
	if _locations.is_empty():
		return _mirror_defeated.has(enc_id)
	for id in _locations:
		if (_locations[id]["defeated"] as Array).has(enc_id):
			return true
	return false


func all_units() -> Array:
	return heroes + enemies + npcs


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


func is_npc(u: Character) -> bool:
	return u != null and npcs.has(u)


func enter_location(id: String, spawn: String) -> void:
	var data := GameData.location(id)
	if data.is_empty():
		push_error("GameSession: нет локации '%s' в locations.json" % id)
		return
	var first_visit := not _locations.has(id)
	if first_visit:
		_locations[id] = _build_location(data)
	else:
		_on_reenter(_locations[id], data)
	var st: Dictionary = _locations[id]
	location_id = id
	entry_spawn = spawn
	grid = st["grid"]
	enemies = st["enemies"]
	loot = st["loot"]
	combat = null
	if mode != "dialogue":
		mode = "explore"
	refresh_world()
	_place_heroes(spawn)
	for h in heroes:
		TrapSystem.announce(grid, h, TrapSystem.look_around(grid, h))
	_discover_waypoints()
	GameLog.add("Партия входит: %s." % data.get("name", id))
	GameEvents.add("location", {"id": id, "first": first_visit})
	if first_visit:
		var title := str(data.get("name", id))
		var text := str(data.get("enter_text", ""))
		GameEvents.add("narrate", {"title": title, "text": text})
		if str(data.get("on_enter", "")) != "":
			start_dialogue(str(data["on_enter"]), leader_id())


## Переход по эффекту сюжета: та же локация — просто переставить героев.
func goto_location(id: String, spawn: String) -> void:
	if id == location_id and _locations.has(id):
		_place_heroes(spawn)
		return
	_collect_all_loot()   # сюжет уводит партию сразу после боя: добычу с поля она успевает собрать
	enter_location(id, spawn)


func _build_location(data: Dictionary) -> Dictionary:
	var size: Array = data.get("size", [12, 10])
	var g := SurfaceGrid.new(int(size[0]), int(size[1]))
	for key in ["walls", "solid"]:
		var cells: Array = data.get(key, [])
		for w in cells:
			g.blocked[Vector2i(int(w[0]), int(w[1]))] = true
	var rects: Array = data.get("wall_rects", [])
	for r in rects:
		for dx in int(r[2]):
			for dy in int(r[3]):
				g.blocked[Vector2i(int(r[0]) + dx, int(r[1]) + dy)] = true
	for key in ["props", "objects"]:
		var list: Array = data.get(key, [])
		for p in list:
			if not p.has("cell") or not bool(p.get("block", true)):
				continue
			var pc := Vector2i(int(p["cell"][0]), int(p["cell"][1]))
			var ps: Array = p.get("size", [1, 1])
			for dx in int(ps[0]):
				for dy in int(ps[1]):
					g.blocked[pc + Vector2i(dx, dy)] = true
	var surfs: Array = data.get("surfaces", [])
	for s in surfs:
		var sc: Array = s["cell"]
		var layer := str(GameData.surface(str(s["id"])).get("layer", "ground"))
		for c in g.cells_in_radius(Vector2i(int(sc[0]), int(sc[1])), int(s.get("radius", 0))):
			g.set_surface(c, str(s["id"]))
			if (g.layers[layer] as Dictionary).has(c):
				g.layers[layer][c]["turns"] = -1   # болото с картой не высыхает, пока его не сожгут или не заморозят
	var trap_list: Array = data.get("traps", [])
	for t in trap_list:
		g.traps[_cell_of(t["cell"])] = {"type": str(t["type"]), "state": "hidden", "rolled": {}}
	return {"grid": g, "enemies": [], "defeated": [], "spawned": [], "npcs": {}, "loot": {}, "rolled": []}


## Повторный вход: живые враги отдыхают, а встречи с respawn оживают заново.
func _on_reenter(st: Dictionary, data: Dictionary) -> void:
	var encounters: Array = data.get("encounters", [])
	for enc in encounters:
		var eid := str(enc.get("id", ""))
		if not bool(enc.get("respawn", false)) or not (st["defeated"] as Array).has(eid):
			continue
		st["defeated"].erase(eid)
		st["spawned"].erase(eid)
		st["enemies"] = (st["enemies"] as Array).filter(func(e): return e.encounter_id != eid)
	for e in st["enemies"]:
		var foe: Character = e
		if foe.is_alive():
			foe.hp = foe.max_hp()
			foe.statuses.clear()
			foe.cooldowns.clear()


func encounter_def(enc_id: String, loc: String = "") -> Dictionary:
	var data := GameData.location(location_id if loc == "" else loc)
	var encounters: Array = data.get("encounters", [])
	for enc in encounters:
		if str(enc.get("id", "")) == enc_id:
			return enc
	return {}


## После любого изменения флагов: появились ли новые враги, кто из NPC виден.
func refresh_world() -> void:
	if not _locations.has(location_id):
		return
	_spawn_encounters(_locations[location_id])
	_refresh_npcs(_locations[location_id])


func _spawn_encounters(st: Dictionary, force_id: String = "") -> void:
	var encounters: Array = location_data().get("encounters", [])
	for enc in encounters:
		var eid := str(enc.get("id", ""))
		if (st["spawned"] as Array).has(eid) or (st["defeated"] as Array).has(eid):
			continue
		# сценарная встреча появляется только по эффекту combat (до того на её месте обычно стоит NPC)
		if eid != force_id and (bool(enc.get("script", false)) or not Story.check(self, enc.get("if"))):
			continue
		st["spawned"].append(eid)
		var taken := _occupied(null)
		var list: Array = enc.get("enemies", [])
		var cells: Array = enc.get("cells", [])
		var anchors: Dictionary = location_data().get("anchors", {})
		var anchor := Vector2i(grid.width >> 1, grid.height >> 1)
		if not cells.is_empty():
			anchor = _cell_of(cells[0])
		elif anchors.has(str(enc.get("anchor", ""))):
			anchor = _cell_of(anchors[str(enc["anchor"])])
		for e in list:
			if heroes.size() < int(e.get("min_party", 0)) or not Story.check(self, e.get("if")):
				continue
			var c := Character.from_template(str(e.get("template", "")))
			c.encounter_id = eid
			var want: Vector2i = _cell_of(e["cell"]) if e.has("cell") else anchor
			c.cell = _free_cell_near(want, taken)
			taken[c.cell] = true
			st["enemies"].append(c)


## Кто из NPC сейчас в локации и где стоит. Где NPC живёт и у какой точки стоит, говорит сюжет
## (location и anchor, можно списком условий); клетку на карте — "npcs" или "anchors" локации.
func _refresh_npcs(st: Dictionary) -> void:
	var cache: Dictionary = st["npcs"]
	var out: Array = []
	var ids: Array = GameData.npcs.keys()
	var placements: Array = location_data().get("npcs", [])
	for p in placements:
		if not ids.has(str(p.get("id", ""))):
			ids.append(str(p.get("id", "")))
	var taken := {}
	for u in heroes + enemies:
		if u.is_alive():
			taken[u.cell] = true
	for nid in ids:
		var want: Variant = npc_spot(str(nid))
		if want == null:
			continue
		var ch: Character = cache.get(nid)
		if ch == null or Vector2i(ch.get_meta("spot", Vector2i(-99, -99))) != want:
			if ch == null:
				ch = Character.from_template(str(nid))
				ch.faction = "npc"
				cache[nid] = ch
			ch.set_meta("spot", want)
			ch.cell = _free_cell_near(want, taken)
		taken[ch.cell] = true
		out.append(ch)
	npcs = out


## Клетка, у которой стоит NPC в текущей локации, или null, если его здесь нет.
func npc_spot(nid: String) -> Variant:
	if flags.has("hide:" + nid) or flags.has("attacked:" + nid):
		return null
	var def := GameData.npc(nid)
	var placement: Dictionary = {}
	for p in location_data().get("npcs", []):
		if str(p.get("id", "")) == nid and Story.check(self, p.get("if")):
			placement = p
			break
	if (bool(def.get("hidden", false)) or bool(placement.get("hidden", false))) and not flags.has("show:" + nid):
		return null
	if not Story.check(self, def.get("if")):
		return null
	if def.has("location"):
		var where := _pick_conditional(def["location"])
		if where != location_id:
			return null
	elif placement.is_empty():
		return null
	if placement.has("cell"):
		return _cell_of(placement["cell"])
	var anchor := _pick_conditional(def.get("anchor", ""))
	var anchors: Dictionary = location_data().get("anchors", {})
	if anchors.has(anchor):
		return _cell_of(anchors[anchor])
	var spawns: Dictionary = location_data().get("spawns", {})
	if not spawns.is_empty():
		return _cell_of((spawns.values()[0] as Array)[0])
	return Vector2i(grid.width >> 1, grid.height >> 1)


## Строка или список [{"if", "id"}] -> первый подходящий id ("" — нет, null тоже).
func _pick_conditional(v: Variant) -> String:
	if typeof(v) == TYPE_ARRAY:
		for opt in v:
			if typeof(opt) == TYPE_DICTIONARY:
				if Story.check(self, opt.get("if")):
					var id: Variant = opt.get("id")
					return "" if id == null else str(id)
			else:
				return str(opt)
		return ""
	return "" if v == null else str(v)


## Предметы локации, которые сейчас видны (с ними можно поговорить).
func visible_objects() -> Array:
	var list: Array = location_data().get("objects", [])
	return list.filter(func(o): return o.has("cell") and not flags.has("hide:" + str(o.get("id", ""))) \
		and Story.check(self, o.get("if")))


func object_at(c: Vector2i) -> Dictionary:
	for o in visible_objects():
		var oc := _cell_of(o["cell"])
		var size: Array = o.get("size", [1, 1])
		if c.x >= oc.x and c.y >= oc.y and c.x < oc.x + int(size[0]) and c.y < oc.y + int(size[1]):
			return o
	return {}


func _place_heroes(spawn: String) -> void:
	var spawns: Dictionary = location_data().get("spawns", {})
	var cells: Array = spawns.get(spawn, [])
	if spawn.begins_with("wp:"):   # у путевого камня: на клетках вокруг него
		var stone := waypoint(spawn.substr(3))
		if not stone.is_empty():
			cells = []
			for d in SurfaceGrid.DIRS:
				var nb: Vector2i = _cell_of(stone["cell"]) + d
				if grid.is_walkable(nb) and exit_at(nb).is_empty():
					cells.append([nb.x, nb.y])
	if cells.is_empty() and not spawns.is_empty():
		cells = spawns.values()[0]
	var taken := {}
	for u in enemies + npcs:
		if u.is_alive():
			taken[u.cell] = true
	var spots := _spawn_order(cells)
	for i in heroes.size():
		var h: Character = heroes[i]
		var want := Vector2i(i, 0)
		if not spots.is_empty():
			want = spots[i % spots.size()]
		h.cell = _free_cell_near(want, taken)
		taken[h.cell] = true


## Точки появления по рядам экрана (в изометрии ряд — клетки с одинаковым x + y): сначала самый длинный
## ряд слева направо, потом остальные, — первые герои встают бок о бок, а не друг за другом.
func _spawn_order(cells: Array) -> Array:
	var rows := {}
	for c in cells:
		var cell := _cell_of(c)
		var key := cell.x + cell.y
		if not rows.has(key):
			rows[key] = []
		(rows[key] as Array).append(cell)
	var keys: Array = []
	for k in rows:
		keys.append([(rows[k] as Array).size() * 1000 + int(k), k])   # длинный ряд, при равенстве — ближний
	keys.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	var out: Array = []
	for kk in keys:
		var k: Variant = kk[1]
		var row: Array = rows[k]
		row.sort_custom(func(a, b): return a.x - a.y < b.x - b.y)
		out.append_array(row)
	return out


func _free_cell_near(c: Vector2i, taken: Dictionary) -> Vector2i:
	for r in range(0, 8):
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


## Дом, в прямоугольнике которого клетка (стены, двери, комнаты), или пустой словарь.
func building_at(c: Vector2i) -> Dictionary:
	for b in location_data().get("buildings", []):
		var r: Array = b["rect"]
		if c.x >= int(r[0]) and c.y >= int(r[1]) and c.x < int(r[0]) + int(r[2]) and c.y < int(r[1]) + int(r[3]):
			return b
	return {}


func exit_at(c: Vector2i) -> Dictionary:
	var exits: Array = location_data().get("exits", [])
	for ex in exits:
		var cells: Array = ex.get("cells", [])
		for ec in cells:
			if _cell_of(ec) == c:
				if ex.has("if") and not Story.check(self, ex["if"]):
					return {}
				return ex
	return {}


## Радиус, с которого группа врагов замечает партию (0 — уже побеждена или нет такой).
func trigger_radius(encounter: String) -> int:
	if defeated_encounters().has(encounter):
		return 0
	var enc := encounter_def(encounter)
	if enc.is_empty():
		return 0
	if (bool(enc.get("script", false)) or (enc.has("aggro") and not bool(enc["aggro"]))) \
			and not flags.has("aggro:" + encounter):
		return 0   # бой только по сюжету (после поражения — уже и при сближении)
	return maxi(1, int(enc.get("trigger_radius", 4)))


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


# --- Сюжет: задания, предметы, опыт --------------------------------------------------

func set_quest_stage(quest_id: String, stage: String) -> void:
	if GameData.quest(quest_id).is_empty():
		push_warning("GameSession: нет задания '%s'" % quest_id)
	var was := str(quests.get(quest_id, ""))
	if was == stage:
		return
	# стадия не откатывается назад
	if was != "":
		var order: Array = Story.stages(quest_id).map(func(st): return str(st.get("id", "")))
		if order.find(stage) >= 0 and order.find(stage) < order.find(was):
			return
	quests[quest_id] = stage
	if not quest_order.has(quest_id):
		quest_order.append(quest_id)
	var done := Story.is_done_stage(quest_id, stage)
	var qd := GameData.quest(quest_id)
	GameEvents.add("quest", {"quest": quest_id, "stage": stage, "new": was == "", "done": done,
		"failed": Story.is_failed_stage(quest_id, stage)})
	GameLog.add("Задание «%s»: %s" % [qd.get("name", quest_id), "выполнено" if done else "обновлено"])
	if done and not flags.has("rewarded:" + quest_id):
		flags["rewarded:" + quest_id] = true
		var rewards: Dictionary = qd.get("rewards", {})
		var sd := Story.stage_def(quest_id, stage)
		var stage_rewards: Dictionary = sd.get("rewards", {})
		for r in [rewards, stage_rewards]:
			if int(r.get("xp", 0)) > 0:
				give_xp(int(r["xp"]))
			if int(r.get("gold", 0)) != 0:
				give_gold(int(r["gold"]))
			var its: Variant = r.get("items", r.get("item", []))
			if typeof(its) == TYPE_DICTIONARY:
				for it in its:
					give_item(str(it), int(its[it]))
			elif typeof(its) == TYPE_ARRAY:
				for it in its:
					give_item(str(it), 1)
			elif typeof(its) == TYPE_STRING and str(its) != "":
				give_item(str(its), 1)


## Предмет в общую сумку. to — шаблон героя, которому вручить: надеваемый предмет он сразу надевает.
func give_item(item_id: String, count: int = 1, to: String = "") -> void:
	if count == 0:
		return
	var def := GameData.item(item_id)
	var name := str(def.get("name", item_id))
	if count > 0 and is_equippable(item_id):
		var who := to if to != "" else str(def.get("for", ""))
		for h in heroes:
			var hero: Character = h
			if who != "" and hero.template_id == who and not hero.equipment.has(item_id):
				_equip(hero, item_id)
				GameEvents.add("item", {"item": item_id, "count": 1, "unit": hero.uid})
				GameLog.add("%s получает: %s" % [hero.display_name, name])
				count -= 1
				break
		if count <= 0:
			return
	var n := maxi(0, int(items.get(item_id, 0)) + count)
	if n == 0:
		items.erase(item_id)
	else:
		items[item_id] = n
	GameEvents.add("item", {"item": item_id, "count": count})
	GameLog.add("%s: %s ×%d" % ["Получено" if count > 0 else "Отдано", name, absi(count)])


static func is_equippable(item_id: String) -> bool:
	var def := GameData.item(item_id)
	return def.has("slot") or def.has("stats") or def.has("weapon")


## Надеть предмет в его ячейку, как в D:OS1. Что там было — в сумку; двуручное оружие освобождает вторую руку,
## щит во вторую руку снимает двуручное оружие. Сам предмет из сумки не берётся (это делает вызывающий).
func _equip(u: Character, item_id: String) -> void:
	var slot := Character.slot_of(item_id)
	var off: Array = []
	var same := u.in_slot(slot)
	if same.size() >= Character.slot_capacity(slot):
		off.append(same[0])
	if slot == "weapon" and bool((GameData.item(item_id).get("weapon", {}) as Dictionary).get("two_handed", false)):
		off.append_array(u.in_slot("offhand"))
	if slot == "offhand" and u.two_handed():
		off.append_array(u.in_slot("weapon"))
	for it in off:
		u.equipment.erase(it)
		items[str(it)] = int(items.get(str(it), 0)) + 1
	u.equipment.append(item_id)


## Сколько предметов есть у партии: в сумке и надетых.
func item_count(item_id: String) -> int:
	var n := int(items.get(item_id, 0))
	for h in heroes:
		n += (h.equipment as Array).count(item_id)
	return n


func give_gold(amount: int) -> void:
	if amount == 0:
		return
	gold = maxi(0, gold + amount)
	GameEvents.add("gold", {"amount": amount})
	GameLog.add("Золото: %+d (всего %d)." % [amount, gold])


func give_xp(amount: int) -> void:
	if amount <= 0:
		return
	for h in heroes:
		var hero: Character = h
		GameEvents.add("xp", {"unit": hero.uid, "amount": amount})
		Progression.add_xp(hero, amount)
	GameLog.add("Партия получает %d опыта." % amount)


# --- Диалоги ------------------------------------------------------------------

## Начать разговор. pid — кто будет отвечать, hero_uid — какой герой говорит.
func start_dialogue(id: String, pid: int, hero_uid: String = "", npc_id: String = "") -> bool:
	var def := GameData.dialogue(id)
	if def.is_empty():
		push_warning("GameSession: нет диалога '%s'" % id)
		return false
	if hero_uid == "":
		var mine: Array = heroes_of(pid).filter(func(h): return h.is_alive())
		if mine.is_empty():
			mine = heroes.filter(func(h): return h.is_alive())
		hero_uid = mine[0].uid if not mine.is_empty() else ""
	if mode != "dialogue":
		_mode_before_dialogue = mode
	dialogue = {"id": id, "node": "", "pid": pid, "hero": hero_uid, "npc": npc_id, "pending": []}
	mode = "dialogue"
	GameEvents.add("dialogue", {"id": id, "npc": npc_id})
	var hero := Story.speaking_hero(self)
	var start := Story.resolve_next(self, def.get("start", ""), hero)
	if start == "":
		var nodes: Dictionary = def.get("nodes", {})
		start = str(nodes.keys()[0]) if not nodes.is_empty() else ""
	_enter_node(start)
	return true


func _enter_node(node_id: String) -> void:
	var guard := 0
	while guard < 64:
		guard += 1
		var nodes: Dictionary = Story.dialogue_def(str(dialogue["id"])).get("nodes", {})
		if not nodes.has(node_id):
			if node_id != "":
				push_warning("GameSession: в диалоге %s нет узла '%s'" % [dialogue["id"], node_id])
			_end_dialogue(dialogue.get("pending", []))
			return
		dialogue["node"] = node_id
		var node: Dictionary = nodes[node_id]
		var hero := Story.speaking_hero(self)
		var deferred := Story.apply(self, node.get("do", []), hero, true)
		(dialogue["pending"] as Array).append_array(deferred)
		if mode != "dialogue" or dialogue.is_empty():
			return
		var has_text := str(node.get("text", "")) != ""
		var has_choices := not (node.get("choices", []) as Array).is_empty()
		if has_text or has_choices:
			return
		# узел без текста — только эффекты и переход
		if not (dialogue["pending"] as Array).is_empty():
			_end_dialogue(dialogue["pending"])
			return
		node_id = Story.resolve_next(self, node.get("next"), hero)
	_end_dialogue(dialogue.get("pending", []))


func _leave_node(next_id: String) -> void:
	var pending: Array = dialogue.get("pending", [])
	if not pending.is_empty() or next_id == "":
		_end_dialogue(pending)
		return
	_enter_node(next_id)


func _end_dialogue(pending: Array = []) -> void:
	var hero := Story.speaking_hero(self)
	dialogue = {}
	mode = "explore"
	GameEvents.add("dialogue_end", {})
	Story.apply(self, pending, hero, false)
	refresh_world()


func _cmd_dialogue(pid: int, cmd: Dictionary, kind: String) -> String:
	if mode != "dialogue" or dialogue.is_empty():
		return "сейчас нет разговора"
	if int(dialogue.get("pid", 0)) != pid:
		return "отвечает %s" % player_name(int(dialogue.get("pid", 0)))
	var node := Story.node_def(self)
	var hero := Story.speaking_hero(self)
	var visible := Story.visible_choices(self)
	match kind:
		"dialogue_next":
			if not visible.is_empty():
				return "выберите ответ"
			_leave_node(Story.resolve_next(self, node.get("next"), hero))
		"dialogue_choice":
			var idx := int(cmd.get("index", -1))
			if not visible.any(func(v): return int(v["index"]) == idx):
				return "нет такого ответа"
			var choice: Dictionary = node["choices"][idx]
			(dialogue["pending"] as Array).append_array(Story.apply(self, choice.get("do", []), hero, true))
			if dialogue.is_empty():
				return ""
			var next: Variant = choice.get("next")
			var chk: Dictionary = choice.get("check", {})
			if not chk.is_empty() and hero != null:
				var attr := Story.attribute_id(str(chk.get("attr", "")))
				var ok := int(hero.attributes.get(attr, 0)) >= int(chk.get("min", 0))
				GameEvents.add("check", {"unit": hero.uid, "attr": attr, "success": ok})
				if not ok:
					next = chk.get("fail")
			if bool(choice.get("end", false)):
				next = null
			_leave_node(Story.resolve_next(self, next, hero))
		"dialogue_skip":
			# пролистать реплики без выбора (заставку), остановиться на первом выборе
			var guard := 0
			while mode == "dialogue" and not dialogue.is_empty() and guard < 200:
				guard += 1
				if not Story.visible_choices(self).is_empty():
					break
				_leave_node(Story.resolve_next(self, Story.node_def(self).get("next"), Story.speaking_hero(self)))
	return ""


func npc_dialogue(nid: String) -> String:
	var dl: Variant = GameData.npc(nid).get("dialogue", "")
	for p in location_data().get("npcs", []):
		if str(p.get("id", "")) == nid and p.has("dialogue"):
			dl = p["dialogue"]
	return _pick_dialogue(dl)


func _pick_dialogue(dl: Variant) -> String:
	return _pick_conditional(dl)


# --- Бой ----------------------------------------------------------------------

## Бой с встречей по эффекту сюжета (враги появляются, если их ещё не было).
func start_encounter(enc_id: String) -> void:
	if not _locations.has(location_id):
		return
	var st: Dictionary = _locations[location_id]
	if (st["defeated"] as Array).has(enc_id):
		push_warning("GameSession: встреча %s уже побеждена" % enc_id)
		return
	_spawn_encounters(st, enc_id)
	if enemies.any(func(e): return e.encounter_id == enc_id and e.is_alive()):
		_start_combat(enc_id)


func _start_combat(encounter: String) -> void:
	combat_encounter = encounter
	var units: Array = []
	var others: Array = npcs.duplicate()
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
	var enc := encounter_def(encounter)
	var music := str(enc.get("music", ""))
	if music == "":
		music = str(GameData.rule("boss_music", "boss_lado")) if bool(enc.get("boss", false)) \
			else str(location_data().get("combat_music", GameData.rule("combat_music", "combat")))
	GameEvents.add("combat_start", {"encounter": encounter, "boss": bool(enc.get("boss", false)), "music": music})
	if not flags.has("tips:" + encounter):
		flags["tips:" + encounter] = true
		for tip in enc.get("tips", []):
			GameEvents.add("tip", {"text": str(tip)})
	GameLog.add("Враги заметили партию!")
	combat.start(units)
	_after_action()


## Проверяет, не закончился ли бой, и переключает режим.
func _after_action() -> void:
	_roll_loot()
	if mode != "combat" or combat == null or combat.active:
		return
	var won := combat.winner_faction == "player"
	combat = null
	if won:
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
		var enc := encounter_def(combat_encounter)
		Story.apply(self, enc.get("do", []))
		if str(enc.get("on_defeat", "")) != "":
			start_dialogue(str(enc["on_defeat"]), leader_id())
	else:
		mode = "defeat"
		flags["aggro:" + combat_encounter] = true
		GameEvents.add("defeat", {})
		GameLog.add("Партия пала. R — вернуться ко входу в локацию.")


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
	GameEvents.add("location", {"id": location_id, "first": false})
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
	var undo: Dictionary = _rewind(pid, cmd.get("from")) if cmd.has("from") else {}
	match kind:
		"move":
			err = _cmd_move(pid, cmd)
		"talk":
			err = _cmd_talk(pid, cmd)
		"dialogue_next", "dialogue_choice", "dialogue_skip":
			err = _cmd_dialogue(pid, cmd, kind)
		"use_item":
			err = _cmd_use_item(pid, cmd)
		"disarm":
			err = _cmd_disarm(pid, cmd)
		"travel":
			err = _cmd_travel(pid, cmd)
		"equip", "unequip":
			err = _cmd_equip(pid, cmd, kind)
		"loot":
			err = _cmd_loot(pid, cmd)
		"loot_take":
			err = _cmd_loot_take(pid, cmd)
		"trade_buy", "trade_sell":
			err = _cmd_trade(pid, cmd, kind)
		"skill", "end_turn":
			err = _cmd_explore_skill(pid, cmd) if kind == "skill" and mode == "explore" else _cmd_combat(pid, cmd, kind)
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
				GameEvents.add("saved", {})
		"load":
			err = "загружать может только лидер" if pid != leader_id() else load_game()
			if err == "":
				GameLog.add("Игра загружена.")
		_:
			err = "неизвестная команда '%s'" % kind
	if err != "" and not undo.is_empty():
		_undo_rewind(undo)
	_after_action()
	return err


## Смена цели на ходу. Сервер проводит партию сразу до конца пути, а клиент ещё показывает, как герои идут.
## Новая команда приходит с from = {uid: [x, y]} — клетки, к которым герои идут на экране. Если эти клетки
## лежат на последнем пути партии, герои возвращаются на них, и новая команда ведёт уже оттуда:
## на экране партия просто сворачивает, без лишнего похода к старой цели и без рывков.
## Возвращает данные для отмены ({"seq", "cells": {uid: прежняя клетка}}) или {}, если возвращать некого.
func _rewind(pid: int, from: Variant) -> Dictionary:
	var walk: Dictionary = _walks.get(pid, {})
	if typeof(from) != TYPE_DICTIONARY or mode != "explore" or walk.get("loc", "") != location_id:
		return {}
	var trails: Dictionary = walk["cells"]
	var movers := {}   # uid -> [герой, путь, индекс клетки from]
	for key in from:
		var h := unit_by_uid(str(key))
		var tr: Array = trails.get(str(key), [])
		var fc: Variant = from[key]
		if h == null or not heroes.has(h) or owner_of(h) != pid or tr.is_empty() or h.cell != tr[-1] \
				or typeof(fc) != TYPE_ARRAY or (fc as Array).size() < 2:
			continue
		var idx := tr.find(Vector2i(int(fc[0]), int(fc[1])))
		if idx >= 0 and idx < tr.size() - 1:
			movers[h.uid] = [h, tr, idx]
	if movers.is_empty():
		return {}
	var taken := {}
	for x in all_units():
		var ch: Character = x
		if ch.is_alive() and not movers.has(ch.uid):
			taken[ch.cell] = true
	var cells := {}
	var shown := {}
	for uid in movers:
		var h: Character = movers[uid][0]
		var tr: Array = movers[uid][1]
		var idx: int = movers[uid][2]
		while idx > 0 and taken.has(tr[idx]):
			idx -= 1          # клетку уже занял другой: шаг назад по тому же пути
		if taken.has(tr[idx]):
			continue
		taken[tr[idx]] = true
		cells[uid] = h.cell
		h.cell = tr[idx]
		shown[uid] = GameEvents.cell(h.cell)
	if shown.is_empty():
		return {}
	GameEvents.add("rewind", {"units": shown})
	return {"seq": GameEvents.seq, "cells": cells}


## Команда после возврата не прошла (например, «туда не дойти»): герои снова там, где их оставил прошлый путь.
func _undo_rewind(undo: Dictionary) -> void:
	var cells: Dictionary = undo["cells"]
	for uid in cells:
		var h := unit_by_uid(str(uid))
		if h != null:
			h.cell = cells[uid]
	var s := int(undo["seq"])
	GameEvents.list = GameEvents.list.filter(func(e): return int(e["seq"]) != s)


func _my_hero(pid: int, cmd: Dictionary) -> Variant:
	var u := unit_by_uid(str(cmd.get("unit", "")))
	if u == null or not heroes.has(u):
		return "нет такого героя"
	if owner_of(u) != pid:
		return "это не ваш герой"
	if not u.is_alive():
		return "герой пал"
	return u


func _cmd_move(pid: int, cmd: Dictionary) -> String:
	if mode == "combat":
		return _cmd_combat(pid, cmd, "move")
	if mode == "dialogue":
		return "идёт разговор"
	if mode != "explore":
		return "партия пала"
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var dest := _cell(cmd)
	var path := grid.find_path(u.cell, dest, _avoid(u, dest))
	if path.is_empty():
		return "туда не дойти"
	_walk_party(u, path)
	return ""


## Все спрятанные ловушки локации становятся видны (проводник показал, эффект сюжета "reveal_traps").
func reveal_traps() -> void:
	for c in grid.traps:
		if str(grid.traps[c]["state"]) == "hidden":
			grid.traps[c]["state"] = "found"
			GameEvents.add("trap_found", {"cell": GameEvents.cell(c), "unit": "", "type": str(grid.traps[c]["type"])})


## Куда герою не наступать по пути: занятые клетки, найденные ловушки и выходы (кроме цели — туда можно нарочно).
func _avoid(u: Character, dest: Vector2i) -> Dictionary:
	var out := _occupied(u)
	for c in grid.known_traps():
		if c != dest:
			out[c] = true
	if exit_at(dest).is_empty():
		for ex in location_data().get("exits", []):
			for ec in ex.get("cells", []):
				out[_cell_of(ec)] = true
	return out


## Ведёт героя по пути, спутники того же игрока идут следом. По дороге враги могут заметить партию,
## на клетке выхода вся партия переходит в другую локацию. Герои осматриваются: заметили ловушку на пути —
## партия останавливается; наступили на взведённую — она срабатывает.
## Возвращает "combat", "exit", "trap" (сработала), "trap_seen" (заметили на пути) или "" (дошли).
func _walk_party(u: Character, path: Array) -> String:
	var pid := owner_of(u)
	var followers: Array = heroes.filter(func(h): return h != u and h.is_alive() and owner_of(h) == pid)
	var dest: Vector2i = path[-1]
	var fpaths := {}
	var reserved := {dest: true}
	var blockers := {}
	for o in enemies + npcs:
		if o.is_alive():
			blockers[o.cell] = true
	for c in grid.known_traps():
		blockers[c] = true
	for f in followers:
		var fc: Character = f
		var spot := _follow_spot(path, reserved, blockers)
		reserved[spot] = true
		# Через клетку цели ведущего спутник не идёт, иначе встанет туда первым (и на ловушку под ней).
		var fblock := blockers.duplicate()
		fblock[dest] = true
		var fp := grid.find_path(fc.cell, spot, fblock)
		if fp.is_empty():
			fp = grid.find_path(fc.cell, spot, blockers)
		if not fp.is_empty():
			fpaths[fc.uid] = fp
	var walked := {u.uid: []}
	var trail := {u.uid: [u.cell]}   # клетки каждого героя от старта: по ним сервер вернёт партию при смене цели на ходу
	var fstep := {}                  # uid спутника -> сколько клеток своего пути он уже прошёл
	for f in followers:
		walked[f.uid] = []
		trail[f.uid] = [f.cell]
		fstep[f.uid] = 0
	var regen := float(GameData.rule("explore_regen_pct", 0)) / 100.0
	var result := ""
	var sprung := Vector2i(-1, -1)
	var spotted: Array = []   # [герой, клетки найденных ловушек]
	var party: Array = [u] + followers
	var steps := path.size()
	for k in fpaths:
		steps = maxi(steps, (fpaths[k] as Array).size())
	steps += 4   # запас: спутник, которому на шаг загородили дорогу, подождёт и догонит, а не перепрыгнет клетку
	for i in steps:
		var moved := false
		if i < path.size():
			u.cell = path[i]
			walked[u.uid].append(GameEvents.cell(u.cell))
			trail[u.uid].append(u.cell)
			moved = true
			if regen > 0.0:
				u.heal(u.max_hp() * regen)
		for f in followers:
			var fc: Character = f
			var fp: Array = fpaths.get(fc.uid, [])
			var j := int(fstep[fc.uid])
			if j < fp.size() and not _occupied(fc).has(fp[j]):
				fc.cell = fp[j]
				fstep[fc.uid] = j + 1
				walked[fc.uid].append(GameEvents.cell(fc.cell))
				trail[fc.uid].append(fc.cell)
				moved = true
				if regen > 0.0:
					fc.heal(fc.max_hp() * regen)
		if not moved:
			break
		for h in party:
			if not grid.armed_trap(h.cell).is_empty():
				sprung = h.cell
		if sprung.x >= 0:
			result = "trap"
			break
		if mode == "explore" and _aggro_check() != "":
			result = "combat"
			break
		var ahead: Array = path.slice(i + 1)
		for k in fpaths:
			ahead.append_array((fpaths[k] as Array).slice(int(fstep[k])))
		for h in party:
			var seen := TrapSystem.look_around(grid, h)
			if not seen.is_empty():
				spotted.append([h, seen])
				if seen.any(func(c): return ahead.has(c)):
					result = "trap_seen"
		if result != "":
			break
		_discover_waypoints()
		if i < path.size() and not exit_at(u.cell).is_empty():
			result = "exit"
			break
	var paths := {}
	for k in walked:
		if not (walked[k] as Array).is_empty():
			paths[k] = walked[k]
	if not paths.is_empty():
		GameEvents.add("move", {"paths": paths})
	_walks[pid] = {"loc": location_id, "cells": trail}
	for sp in spotted:
		TrapSystem.announce(grid, sp[0], sp[1])
	match result:
		"trap":
			var field := explore_field()
			var before := _enemy_marks()
			TrapSystem.spring(field, sprung)
			field.after_explore_action()
			_explore_consequences(before)
			if mode == "explore" and _aggro_check() != "":
				_start_combat(_aggro_check())
		"combat":
			_start_combat(_aggro_check())
		"exit":
			var ex := exit_at(u.cell)
			GameEvents.add("transition", {"to": str(ex.get("to", ""))})
			enter_location(str(ex.get("to", "")), str(ex.get("spawn", "")))
	return result


## Куда встать спутнику: позади ведущего, на свободной клетке рядом с концом пути.
func _follow_spot(path: Array, reserved: Dictionary, blockers: Dictionary) -> Vector2i:
	# Спутник встаёт рядом с ведущим, но не прямо за ним по экрану (в изометрии он бы спрятался за спину):
	# выбираем ближнюю свободную клетку, лучше всего — сбоку на том же уровне экрана.
	var dest: Vector2i = path[-1]
	var best := dest
	var best_score := 1e9
	var dest_house := building_at(dest)
	for r in [1, 2, 3]:
		for c in grid.cells_in_radius(dest, r):
			var cell: Vector2i = c
			if cell == dest or not grid.is_walkable(cell) or reserved.has(cell) or blockers.has(cell) \
					or not exit_at(cell).is_empty():
				continue
			var dx := cell.x - dest.x
			var dy := cell.y - dest.y
			var sx := absi(dx - dy)      # сдвиг по экрану вбок (в полуклетках)
			var sy := dx + dy            # < 0 — выше по экрану, то есть за спиной
			var score := float(SurfaceGrid.distance(cell, dest)) * 10.0
			if sx == 0:
				score += 30.0 if sy < 0 else 12.0
			elif sx == 1 and sy < 0:
				score += 6.0             # наискосок за спиной — наполовину спрятан
			score -= float(mini(sx, 2)) * 2.0   # чем дальше вбок, тем лучше видно обоих
			if building_at(cell) != dest_house:
				score += 60.0                    # за стену дома (внутрь или наружу) спутник не встаёт
			if score < best_score:
				best_score = score
				best = cell
		if best_score < 25.0:
			break
	return best


func _cmd_talk(pid: int, cmd: Dictionary) -> String:
	if mode != "explore":
		return "сейчас нельзя" if mode != "dialogue" else "идёт разговор"
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var dl := ""
	var npc_id := ""
	var cells: Array = []
	if cmd.has("object"):
		var oid := str(cmd["object"])
		var obj: Dictionary = {}
		for o in visible_objects():
			if str(o.get("id", "")) == oid:
				obj = o
		if obj.is_empty():
			return "нет такого предмета"
		dl = _pick_dialogue(obj.get("dialogue", ""))
		var oc := _cell_of(obj["cell"])
		var size: Array = obj.get("size", [1, 1])
		for dx in int(size[0]):
			for dy in int(size[1]):
				cells.append(oc + Vector2i(dx, dy))
		if bool(obj.get("waypoint", false)):
			if not cells.any(func(c): return SurfaceGrid.distance(u.cell, c) <= 1):
				var path := _path_next_to(u, cells)
				if path.is_empty():
					return "не подойти"
				if _walk_party(u, path) != "":
					return ""
			flags["wp:" + oid] = true
			GameEvents.add("waypoint_menu", {"pid": pid, "from": oid})
			return ""
		if dl == "":
			GameEvents.add("narrate", {"title": "", "text": str(obj.get("name", oid)), "short": true})
			return ""
	else:
		var n := unit_by_uid(str(cmd.get("target", "")))
		if n == null or not npcs.has(n):
			return "не с кем говорить"
		npc_id = n.template_id
		dl = npc_dialogue(npc_id)
		cells = [n.cell]
		if dl == "" and (GameData.npc(npc_id).get("barks", []) as Array).is_empty():
			return "%s молчит" % n.display_name
	# подойти вплотную
	var near := cells.any(func(c): return SurfaceGrid.distance(u.cell, c) <= 1)
	if not near:
		var best := _path_next_to(u, cells)
		if best.is_empty():
			return "не подойти"
		if _walk_party(u, best) != "":
			return ""   # по дороге начался бой, переход или ловушка
	if dl == "" and GameData.npc(npc_id).has("trade"):   # торговец без разговора сразу раскладывает товар
		open_trade(npc_id, pid, u.uid)
		return ""
	if dl == "":   # житель без разговора отвечает одной из своих реплик
		var barks: Array = GameData.npc(npc_id).get("barks", [])
		GameEvents.add("bark", {"unit": str(cmd.get("target", "")), "text": str(barks[randi() % barks.size()])})
		return ""
	start_dialogue(dl, pid, u.uid, npc_id)
	return ""


## Кратчайший путь героя на клетку рядом с одной из cells (в обход найденных ловушек); [] — не подойти.
func _path_next_to(u: Character, cells: Array) -> Array:
	var best: Array = []
	var occ := _avoid(u, Vector2i(-99, -99))
	for c in cells:
		for d in SurfaceGrid.DIRS:
			var nb: Vector2i = c + d
			if grid.is_walkable(nb) and not occ.has(nb) and not cells.has(nb):
				var p := grid.find_path(u.cell, nb, occ)
				if not p.is_empty() and (best.is_empty() or p.size() < best.size()):
					best = p
	return best


## Путевой камень по id (из любой локации): запись предмета и "location", или пустой словарь.
func waypoint(id: String) -> Dictionary:
	for loc in GameData.locations:
		for o in (GameData.locations[loc] as Dictionary).get("objects", []):
			if str(o.get("id", "")) == id and bool(o.get("waypoint", false)):
				var out: Dictionary = (o as Dictionary).duplicate()
				out["location"] = str(loc)
				return out
	return {}


## Найденные путевые камни всех локаций: [{"id", "name", "location", "location_name"}] в порядке локаций.
func known_waypoints() -> Array:
	var out: Array = []
	for loc in GameData.locations:
		var data: Dictionary = GameData.locations[loc]
		for o in data.get("objects", []):
			var id := str(o.get("id", ""))
			if bool(o.get("waypoint", false)) and flags.has("wp:" + id):
				out.append({"id": id, "name": str(o.get("name", id)), "location": str(loc), "location_name": str(data.get("name", loc))})
	return out


## Камень замечен, когда герой подошёл на 3 клетки: с этого момента к нему можно переноситься.
func _discover_waypoints() -> void:
	for o in visible_objects():
		var id := str(o.get("id", ""))
		if not bool(o.get("waypoint", false)) or flags.has("wp:" + id):
			continue
		var oc := _cell_of(o["cell"])
		if heroes.any(func(h): return h.is_alive() and SurfaceGrid.distance(h.cell, oc) <= 3):
			flags["wp:" + id] = true
			GameLog.add("Найден путевой камень: %s." % o.get("name", id))
			GameEvents.add("waypoint_found", {"id": id, "name": str(o.get("name", id))})


## Перенос партии к найденному путевому камню (как путевые святилища D:OS).
func _cmd_travel(pid: int, cmd: Dictionary) -> String:
	if mode != "explore":
		return "сейчас нельзя" if mode != "combat" else "в бою не до этого"
	if not players.has(pid):
		return "нет такого игрока"
	var id := str(cmd.get("to", ""))
	var stone := waypoint(id)
	if stone.is_empty() or not flags.has("wp:" + id):
		return "этот камень ещё не найден"
	GameEvents.add("transition", {"to": str(stone["location"])})
	GameLog.add("Партия переносится: %s." % stone.get("name", id))
	if str(stone["location"]) == location_id:
		_place_heroes("wp:" + id)
		GameEvents.add("teleport", {"heroes": heroes.map(func(h): return h.uid)})
	else:
		enter_location(str(stone["location"]), "wp:" + id)
	return ""


## Подойти к найденной ловушке и обезвредить её (Ловкость, Плут). Неудача может её задеть.
func _cmd_disarm(pid: int, cmd: Dictionary) -> String:
	if mode != "explore":
		return "сейчас нельзя" if mode != "combat" else "в бою не до этого"
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var cell := _cell(cmd)
	if str(grid.traps.get(cell, {}).get("state", "")) != "found":
		return "здесь нет найденной ловушки"
	if SurfaceGrid.distance(u.cell, cell) > 1:
		var path := _path_next_to(u, [cell])
		if path.is_empty():
			return "не подойти"
		if _walk_party(u, path) != "" or mode != "explore" or grid.armed_trap(cell).is_empty():
			return ""   # по дороге что-то случилось
	var tt := str(grid.traps[cell]["type"])
	var field := explore_field()
	var before := _enemy_marks()
	if TrapSystem.try_disarm(field, u, cell) == "disarmed":
		give_xp(int(GameData.trap(tt).get("xp", 0)))
	field.after_explore_action()
	_explore_consequences(before)
	return ""


func _cmd_use_item(pid: int, cmd: Dictionary) -> String:
	var item_id := str(cmd.get("item", ""))
	var def := GameData.item(item_id)
	if int(items.get(item_id, 0)) <= 0:
		return "нет такого предмета"
	if mode == "dialogue" or mode == "defeat":
		return "сейчас нельзя"
	var use: Dictionary = def.get("use", def.get("effect", {}))
	if use.is_empty() and not def.has("dialogue"):
		return "это нельзя использовать"
	if use.has("skill"):
		return _use_item_skill(pid, cmd, item_id, str(use["skill"]))
	var u: Character
	if mode == "combat":
		if combat == null or combat.current == null or owner_of(combat.current) != pid:
			return "сейчас ходит не ваш персонаж"
		u = combat.current
		var cost := int(def.get("ap", GameData.rule("item_ap", 2)))
		if u.ap < cost:
			return "не хватает ОД"
		u.ap -= cost
	else:
		var r: Variant = _my_hero(pid, cmd)
		if typeof(r) == TYPE_STRING:
			return r
		u = r
	if not use.is_empty():
		_apply_item(u, use)
		if bool(def.get("consumable", true)):
			give_item(item_id, -1)
	if def.has("dialogue") and mode == "explore":
		start_dialogue(str(def["dialogue"]), pid, u.uid)
	return ""


## Предмет, который действует как навык (масло — масляное пятно, факел — огонь). Вне боя — без ОД.
func _use_item_skill(pid: int, cmd: Dictionary, item_id: String, skill_id: String) -> String:
	if mode == "explore":
		return _cmd_explore_skill(pid, cmd, item_id)
	if mode != "combat" or combat == null or not combat.active:
		return "сейчас нельзя"
	var u := combat.current
	if u == null or owner_of(u) != pid:
		return "сейчас ходит не ваш персонаж"
	var def := GameData.skill(skill_id)
	var target := _cell(cmd)
	var cost := int(GameData.item(item_id).get("ap", def.get("ap", 2)))
	if u.ap < cost:
		return "не хватает ОД"
	var reason := SkillSystem.target_block_reason(combat, u, def, target)
	if reason != "":
		return reason
	u.ap -= cost
	give_item(item_id, -1)
	GameEvents.add("cast", {"unit": u.uid, "skill": skill_id, "cell": GameEvents.cell(target), "from": GameEvents.cell(u.cell)})
	GameLog.add("%s использует «%s»." % [u.display_name, GameData.item(item_id).get("name", item_id)])
	SkillSystem.execute(combat, u, def, target)
	combat.after_external_action(u)
	return ""


func _cmd_equip(pid: int, cmd: Dictionary, kind: String) -> String:
	if mode == "combat":
		return "во время боя нельзя"
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var item_id := str(cmd.get("item", ""))
	if kind == "equip":
		if not is_equippable(item_id) or int(items.get(item_id, 0)) <= 0:
			return "это нельзя надеть"
		items[item_id] = int(items[item_id]) - 1
		if int(items[item_id]) <= 0:
			items.erase(item_id)
		_equip(u, item_id)
	else:
		if not u.equipment.has(item_id):
			return "этот предмет не надет"
		u.equipment.erase(item_id)
		items[item_id] = int(items.get(item_id, 0)) + 1
	GameEvents.add("sfx", {"id": "pickup"})
	return ""


# --- Добыча с тел --------------------------------------------------------------

## Павшие враги, которых ещё не обыскивали, получают добычу по data/story/loot.json: на теле остаётся мешок.
func _roll_loot() -> void:
	var st: Dictionary = _locations.get(location_id, {})
	if st.is_empty():
		return
	var rolled: Array = st["rolled"]
	for e in enemies:
		var foe: Character = e
		if foe.is_alive() or rolled.has(foe.uid):
			continue
		rolled.append(foe.uid)
		var npc := foe.encounter_id.begins_with("hostile:")
		if npc:
			flags["dead:" + foe.template_id] = true
		var bag := {"cell": [foe.cell.x, foe.cell.y], "name": foe.display_name, "items": {}, "gold": 0}
		for row in GameData.loot_table(foe.template_id, npc):
			var r: Dictionary = row
			if GameData.rng.randf() * 100.0 >= float(r.get("chance", 100)):
				continue
			if r.has("gold"):
				bag["gold"] = int(bag["gold"]) + _roll_count(r["gold"])
			elif not GameData.item(str(r.get("item", ""))).is_empty():
				var id := str(r["item"])
				bag["items"][id] = int((bag["items"] as Dictionary).get(id, 0)) + _roll_count(r.get("count", 1))
		if int(bag["gold"]) > 0 or not (bag["items"] as Dictionary).is_empty():
			loot[foe.uid] = bag
			GameEvents.add("loot_drop", {"corpse": foe.uid, "cell": bag["cell"]})


static func _roll_count(v: Variant) -> int:
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
		return GameData.rng.randi_range(int(v[0]), int(v[1]))
	return maxi(1, int(v))


## Взять с тела всё или один предмет ("gold" — деньги). Пустой мешок исчезает.
func _take_loot(corpse: String, what: String) -> void:
	var bag: Dictionary = loot.get(corpse, {})
	if bag.is_empty():
		return
	var its: Dictionary = bag["items"]
	if (what == "all" or what == "gold") and int(bag["gold"]) > 0:
		give_gold(int(bag["gold"]))
		bag["gold"] = 0
	for id in its.keys():
		if what == "all" or what == str(id):
			give_item(str(id), int(its[id]))
			its.erase(id)
	if int(bag["gold"]) <= 0 and its.is_empty():
		loot.erase(corpse)
	GameEvents.add("loot_taken", {"corpse": corpse, "empty": not loot.has(corpse)})
	GameEvents.add("sfx", {"id": "pickup"})


## Перед уходом по сюжету: всё, что лежит на телах в этой локации, — в сумку.
func _collect_all_loot() -> void:
	if loot.is_empty():
		return
	GameLog.add("Перед уходом вы обыскиваете тела.")
	for corpse in loot.keys():
		_take_loot(str(corpse), "all")


func _cmd_loot(pid: int, cmd: Dictionary) -> String:
	if mode != "explore":
		return "в бою не до этого" if mode == "combat" else "сейчас нельзя"
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var corpse := str(cmd.get("corpse", ""))
	var bag: Dictionary = loot.get(corpse, {})
	if bag.is_empty():
		return "здесь пусто"
	var c := _cell_of(bag["cell"])
	if SurfaceGrid.distance(u.cell, c) > 1:
		var path := grid.find_path(u.cell, c, _avoid(u, c)) if not _occupied(u).has(c) else _path_next_to(u, [c])
		if path.is_empty():
			return "не подойти"
		if path[-1] == c:
			path.pop_back()   # встать рядом с телом, а не на него
		if not path.is_empty() and _walk_party(u, path) != "":
			return ""   # по дороге что-то случилось
	GameEvents.add("loot_open", {"pid": pid, "corpse": corpse, "unit": u.uid})
	GameEvents.add("sfx", {"id": "chest_open"})
	return ""


func _cmd_loot_take(pid: int, cmd: Dictionary) -> String:
	if mode != "explore":
		return "сейчас нельзя"
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var corpse := str(cmd.get("corpse", ""))
	var bag: Dictionary = loot.get(corpse, {})
	if bag.is_empty():
		return "здесь пусто"
	if SurfaceGrid.distance(u.cell, _cell_of(bag["cell"])) > 2:
		return "слишком далеко"
	_take_loot(corpse, str(cmd.get("item", "all")))
	return ""


# --- Торговля ----------------------------------------------------------------

## Товар торговца (из "trade" в npcs.json, дальше живёт в сессии: купленное убывает, проданное ему — прибывает).
func trader_stock(nid: String) -> Dictionary:
	if not trade_stock.has(nid):
		var stock: Dictionary = (GameData.npc(nid).get("trade", {}) as Dictionary).get("stock", {})
		trade_stock[nid] = stock.duplicate()
	return trade_stock[nid]


## Цена: торговец продаёт по "value" × buy, покупает по "value" × sell (из "trade" жителя).
static func price(nid: String, item_id: String, selling: bool) -> int:
	var t: Dictionary = GameData.npc(nid).get("trade", {})
	var v := float(GameData.item(item_id).get("value", 0))
	if selling:
		return maxi(1, floori(v * float(t.get("sell", 0.4)))) if v > 0.0 else 0
	return maxi(1, ceili(v * float(t.get("buy", 1.0))))


static func can_sell(item_id: String) -> bool:
	var d := GameData.item(item_id)
	return str(d.get("type", "")) != "quest" and int(d.get("value", 0)) > 0


func open_trade(nid: String, pid: int, hero_uid := "") -> void:
	trader_stock(nid)
	GameEvents.add("trade_open", {"pid": pid, "npc": nid, "unit": hero_uid})


func _cmd_trade(pid: int, cmd: Dictionary, kind: String) -> String:
	if mode != "explore":
		return "сейчас не до торговли"
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var nid := str(cmd.get("npc", ""))
	if not GameData.npc(nid).has("trade"):
		return "это не торговец"
	var trader: Character = null
	for n in npcs:
		if (n as Character).template_id == nid:
			trader = n
	if trader == null:
		return "торговца здесь нет"
	if SurfaceGrid.distance(u.cell, trader.cell) > 3:
		return "подойдите к торговцу"
	var item_id := str(cmd.get("item", ""))
	var stock := trader_stock(nid)
	if kind == "trade_buy":
		if int(stock.get(item_id, 0)) == 0:
			return "этого товара нет"
		var cost := price(nid, item_id, false)
		if gold < cost:
			return "не хватает золота"
		if int(stock[item_id]) > 0:
			stock[item_id] = int(stock[item_id]) - 1
			if int(stock[item_id]) <= 0:
				stock.erase(item_id)
		give_gold(-cost)
		give_item(item_id, 1)
		GameEvents.add("sfx", {"id": "coin"})
	else:
		if int(items.get(item_id, 0)) <= 0:
			return "такого в сумке нет"
		if not can_sell(item_id):
			return "это не продаётся"
		give_item(item_id, -1)
		give_gold(price(nid, item_id, true))
		if int(stock.get(item_id, 0)) >= 0:
			stock[item_id] = int(stock.get(item_id, 0)) + 1
		GameEvents.add("sfx", {"id": "coin"})
	GameEvents.add("trade_done", {"npc": nid})
	return ""


func _apply_item(u: Character, use: Dictionary) -> void:
	var amount := float(use.get("heal", 0)) + u.max_hp() * float(use.get("heal_pct", 0)) / 100.0
	if amount > 0.0:
		u.heal(roundf(amount))
		GameEvents.add("heal", {"unit": u.uid, "amount": int(roundf(amount))})
	for st in use.get("cure", use.get("remove_status", [])):
		u.remove_status(str(st))
	if use.has("status"):
		StatusSystem.apply(u, str(use["status"]), int(use.get("duration", -1)), u.level)
	GameEvents.add("sfx", {"id": str(use.get("sfx", "potion"))})


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
			if bool(cmd.get("force", false)):
				var enc := _provoke_npc(u, GameData.skill(skill_id), _cell(cmd))
				if enc != "":
					_join_combat(enc)
			var reason := combat.skill_block_reason(u, skill_id, _cell(cmd))
			if reason != "":
				return reason
			var before := _enemy_marks()
			_pull_into_combat(u, GameData.skill(skill_id), _cell(cmd))
			combat.use_skill(u, skill_id, _cell(cmd))
			_join_hurt(before)
		"end_turn":
			combat.end_turn()
	return ""


## Как в D:OS, бой общий: ударил по врагу вне боя или задел его навыком — его отряд вступает в идущий бой.
## Вызывается до навыка: отряд цели и всех врагов в зоне навыка становятся участниками и получают удар как все.
func _pull_into_combat(u: Character, def: Dictionary, cell: Vector2i) -> void:
	if combat == null or not combat.active or not (def.has("damage") or def.has("statuses") or def.has("surface")):
		return
	var tt := str(def.get("target", "enemy"))
	if tt == "ally" or tt == "self" and not def.has("damage"):
		return
	var center := u.cell if tt == "self" else cell
	var radius := maxi(int(def.get("aoe_radius", 0)), int((def.get("surface", {}) as Dictionary).get("radius", 0)))
	var groups := {}
	for e in enemies:
		var foe: Character = e
		if foe.is_alive() and not combat.units.has(foe) and SurfaceGrid.distance(foe.cell, center) <= radius:
			groups[foe.encounter_id] = true
	for g in groups:
		_join_combat(str(g))


## После действия в бою: враги вне боя, которых задело (огонь растёкся, взрыв), тоже вступают в бой.
func _join_hurt(before: Dictionary) -> void:
	if combat == null:
		return
	var groups := {}
	for e in enemies:
		var foe: Character = e
		if before.has(foe.uid) and not combat.units.has(foe) \
				and (not foe.is_alive() or foe.hp != float(before[foe.uid][0]) or foe.statuses.size() != int(before[foe.uid][1])):
			groups[foe.encounter_id] = true
	for g in groups:
		_join_combat(str(g))
	if not groups.is_empty() and combat != null:
		combat.refresh()


## Отряд врагов encounter вступает в идущий бой.
func _join_combat(encounter: String) -> void:
	if combat == null or not combat.active:
		return
	var fresh: Array = enemies.filter(func(e): return e.encounter_id == encounter and not combat.units.has(e) \
		and (e.is_alive() or not e.death_handled))
	if fresh.is_empty():
		return
	flags["aggro:" + encounter] = true
	combat.join(fresh)
	GameLog.add("В бой вступают: %s." % ", ".join(fresh.map(func(e): return e.display_name)))
	GameEvents.add("combat_join", {"encounter": encounter, "units": fresh.map(func(e): return e.uid)})


## Удар по жителю, как в D:OS (Ctrl+ЛКМ или навыком прямо в него): житель хватается за оружие и становится врагом.
## У кого в npcs.json есть "on_attack" (Шмыг, Мухоглот), вместо этого начинается их сюжетная встреча.
## "attackable": false — на этого не напасть (призрак). Возвращает id отряда врагов или "".
func _provoke_npc(u: Character, def: Dictionary, cell: Vector2i) -> String:
	var n: Character = null
	for c in npcs:
		if (c as Character).is_alive() and (c as Character).cell == cell:
			n = c
	if n == null or u == null or not heroes.has(u):
		return ""
	var tt := str(def.get("target", "enemy"))
	if tt == "ally" or tt == "self" or not (def.has("damage") or def.has("statuses")):
		return ""
	if SurfaceGrid.distance(u.cell, cell) > SkillSystem.skill_range(u, def):
		return ""
	var nid := n.template_id
	var nd := GameData.npc(nid)
	if not bool(nd.get("attackable", true)):
		return ""
	var st: Dictionary = _locations.get(location_id, {})
	if st.is_empty():
		return ""
	npcs.erase(n)
	(st["npcs"] as Dictionary).erase(nid)
	flags["hide:" + nid] = true
	flags["attacked:" + nid] = true
	var enc := str(nd.get("on_attack", ""))
	if enc != "" and not encounter_def(enc).is_empty() and not (st["defeated"] as Array).has(enc):
		_spawn_encounters(st, enc)
		var first: Array = enemies.filter(func(e): return e.encounter_id == enc and e.is_alive())
		if not first.is_empty():
			var taken := _occupied(first[0])
			if not taken.has(n.cell):
				(first[0] as Character).cell = n.cell
		GameLog.add("%s принимает бой!" % n.display_name)
		return enc
	enc = "hostile:" + nid
	n.faction = "enemy"
	n.encounter_id = enc
	if n.skills.is_empty():
		n.skills = ["attack"]
	n.xp_reward = maxi(n.xp_reward, 15 * n.level)
	enemies.append(n)
	if not (st["spawned"] as Array).has(enc):
		st["spawned"].append(enc)
	var angry: Array = nd.get("angry", ["Да ты что творишь?!", "Стража! Убивают!", "Ах ты ж…"])
	GameEvents.add("bark", {"unit": n.uid, "text": str(angry[GameData.rng.randi() % angry.size()])})
	GameLog.add("%s хватается за что попало: теперь это враг." % n.display_name)
	return enc


## Навык вне боя, как в D:OS: лечение, благословение, дождь на огонь, масло под ноги. ОД не тратит,
## перезарядка идёт по времени (pass_time). Жителей навыки не задевают; задели врага — начинается бой.
## item_id — навык из предмета (масло, факел): тратится предмет, а не перезарядка.
func _cmd_explore_skill(pid: int, cmd: Dictionary, item_id := "") -> String:
	var r: Variant = _my_hero(pid, cmd)
	if typeof(r) == TYPE_STRING:
		return r
	var u: Character = r
	var skill_id := str(cmd.get("skill", ""))
	if item_id != "":
		skill_id = str((GameData.item(item_id).get("use", {}) as Dictionary).get("skill", ""))
	var def := GameData.skill(skill_id)
	if def.is_empty() or (item_id == "" and not u.skills.has(skill_id)):
		return "навык не изучен"
	if not u.can_act():
		return "не может действовать"
	if item_id == "" and u.cooldowns.has(skill_id):
		return "перезарядка %d" % int(u.cooldowns[skill_id])
	var target := u.cell if str(def.get("target", "")) == "self" else _cell(cmd)
	if bool(cmd.get("force", false)):
		_provoke_npc(u, def, target)
	var field := explore_field()
	var reason := SkillSystem.target_block_reason(field, u, def, target)
	if reason != "":
		return reason
	var before := _enemy_marks()
	var aimed := field.unit_at(target)   # в кого целились: промах по врагу тоже начинает бой
	var provoked := aimed.encounter_id if aimed != null and enemies.has(aimed) and def.has("damage") else ""
	if item_id != "":
		give_item(item_id, -1)
	elif int(def.get("cooldown", 0)) > 0:
		u.cooldowns[skill_id] = int(def.get("cooldown", 0))
	var what: Variant = GameData.item(item_id).get("name", item_id) if item_id != "" else def.get("name", skill_id)
	GameLog.add("%s использует «%s»." % [u.display_name, what])
	GameEvents.add("cast", {"unit": u.uid, "skill": skill_id, "cell": GameEvents.cell(target), "from": GameEvents.cell(u.cell)})
	SkillSystem.execute(field, u, def, target)
	field.after_explore_action()
	_explore_consequences(before, provoked)
	return ""


## Здоровье и число состояний живых врагов: потом видно, кого задело.
func _enemy_marks() -> Dictionary:
	var before := {}
	for e in enemies:
		var foe: Character = e
		if foe.is_alive():
			before[foe.uid] = [foe.hp, foe.statuses.size()]
	return before


## После навыка или ловушки вне боя: убитые враги дают опыт, задетая группа начинает бой
## (или считается побеждённой, если её перебили сразу). provoked — группа того, в кого целились (даже если промах).
func _explore_consequences(before: Dictionary, provoked := "") -> void:
	var hits: Array = [provoked] if provoked != "" else []
	var killed := 0
	for e in enemies:
		var foe: Character = e
		if before.has(foe.uid) and (not foe.is_alive() or foe.hp != float(before[foe.uid][0]) or foe.statuses.size() != int(before[foe.uid][1])):
			if not hits.has(foe.encounter_id):
				hits.append(foe.encounter_id)
			if not foe.is_alive():
				killed += foe.xp_reward
	give_xp(killed)   # убитые до боя: в бою их уже не посчитают
	# задело несколько отрядов — бой начинает первый, остальные вступают в тот же бой
	for hit in hits:
		if hit == "" or defeated_encounters().has(hit):
			continue
		if enemies.any(func(e): return e.encounter_id == hit and e.is_alive()):
			flags["aggro:" + hit] = true
			if mode == "combat" and combat != null and combat.active:
				_join_combat(hit)
			else:
				_start_combat(hit)
		else:   # отряд перебит одним ударом, до боя дело не дошло
			defeated_encounters().append(hit)
			Story.apply(self, encounter_def(hit).get("do", []))


## Поле для навыков вне боя: те же правила, что в бою; в нём герои и враги, жителей навыки обходят.
func explore_field() -> CombatManager:
	var field := CombatManager.new(grid)
	field.units = heroes.filter(func(h): return h.is_alive()) + enemies.filter(func(e): return e.is_alive())
	field.bystanders = npcs.duplicate()
	return field


## Время вне боя: каждые explore_turn_seconds проходит «ход» — остывают навыки, кончаются состояния
## (без урона: горение и яд вне боя не тикают), прогорают поверхности. true — что-то изменилось, надо разослать состояние.
func pass_time(delta: float) -> bool:
	if mode != "explore":
		_explore_clock = 0.0
		return false
	_explore_clock += delta
	var turn := float(GameData.rule("explore_turn_seconds", 4.0))
	if _explore_clock < turn:
		return false
	_explore_clock -= turn
	var changed := grid != null and grid.has_timed_surfaces()
	if changed:
		grid.tick_round()   # огонь прогорает, пар рассеивается, лёд тает и вне боя
	for h in heroes:
		var hero: Character = h
		if hero.cooldowns.is_empty() and hero.statuses.is_empty():
			continue
		changed = true
		for sk in hero.cooldowns.keys():
			hero.cooldowns[sk] = int(hero.cooldowns[sk]) - 1
			if int(hero.cooldowns[sk]) <= 0:
				hero.cooldowns.erase(sk)
		StatusSystem.on_turn_end(hero)
	return changed


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
	GameEvents.add("sfx", {"id": "ui_confirm"})
	return ""


static func _cell(cmd: Dictionary) -> Vector2i:
	var c: Array = cmd.get("cell", [0, 0])
	return Vector2i(int(c[0]), int(c[1]))


static func _cell_of(v: Variant) -> Vector2i:
	if typeof(v) == TYPE_VECTOR2I:
		return v
	var a: Array = v
	return Vector2i(int(a[0]), int(a[1]))


# --- Сохранение ---------------------------------------------------------------

func save_game(path: String = SAVE_PATH) -> String:
	if mode != "explore":
		return "сохраняться можно только вне боя и разговора"
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


static func has_save(path: String = SAVE_PATH) -> bool:
	return FileAccess.file_exists(path)


func to_save() -> Dictionary:
	var locs := {}
	for id in _locations:
		var st: Dictionary = _locations[id]
		var g: SurfaceGrid = st["grid"]
		locs[id] = {
			"grid": g.to_dict(),
			"enemies": st["enemies"].map(func(e): return e.to_dict()),
			"defeated": st["defeated"].duplicate(),
			"spawned": st["spawned"].duplicate(),
			"loot": (st["loot"] as Dictionary).duplicate(true),
			"rolled": (st["rolled"] as Array).duplicate(),
		}
	return {
		"version": SAVE_VERSION,
		"location": location_id,
		"entry_spawn": entry_spawn,
		"heroes": heroes.map(func(h): return h.to_dict()),
		"locations": locs,
		"flags": flags.duplicate(),
		"quests": quests.duplicate(),
		"quest_order": quest_order.duplicate(),
		"items": items.duplicate(),
		"gold": gold,
		"trade_stock": trade_stock.duplicate(true),
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
		var spawned: Array = ld.get("spawned", [])
		if not ld.has("spawned"):   # старые сохранения: всё, что было в локации, уже появилось
			for f in foes:
				if not spawned.has(f.encounter_id):
					spawned.append(f.encounter_id)
		var rolled: Array = ld.get("rolled", foes.filter(func(f): return not f.is_alive()).map(func(f): return f.uid))
		_locations[id] = {"grid": SurfaceGrid.from_dict(ld.get("grid", {})), "enemies": foes,
			"defeated": defeated.duplicate(), "spawned": spawned.duplicate(), "npcs": {},
			"loot": (ld.get("loot", {}) as Dictionary).duplicate(true), "rolled": rolled.duplicate()}
	flags = (d.get("flags", {}) as Dictionary).duplicate()
	quests = (d.get("quests", {}) as Dictionary).duplicate()
	quest_order = (d.get("quest_order", []) as Array).duplicate()
	items = {}
	var its: Dictionary = d.get("items", {})
	for k in its:
		items[str(k)] = int(its[k])
	gold = int(d.get("gold", 0))
	trade_stock = (d.get("trade_stock", {}) as Dictionary).duplicate(true)
	location_id = str(d.get("location", ""))
	entry_spawn = str(d.get("entry_spawn", ""))
	var st: Dictionary = _locations.get(location_id, {})
	grid = st.get("grid", null)
	enemies = st.get("enemies", [])
	loot = st.get("loot", {})
	combat = null
	dialogue = {}
	mode = "explore"
	npcs = []
	refresh_world()
	GameEvents.add("location", {"id": location_id, "first": false})


# --- Снимки для сети ------------------------------------------------------------

func snapshot(log_tail: int = 40) -> Dictionary:
	var all_defeated: Array = []
	for id in _locations:
		all_defeated.append_array(_locations[id]["defeated"])
	var s := {
		"players": players.duplicate(true),
		"owners": owners.duplicate(),
		"mode": mode,
		"location": location_id,
		"defeated": all_defeated,
		"heroes": heroes.map(func(h): return h.to_dict()),
		"enemies": enemies.map(func(e): return e.to_dict()),
		"npcs": npcs.map(func(n): return n.to_dict()),
		"log": GameLog.lines.slice(maxi(0, GameLog.lines.size() - log_tail)),
		"events": GameEvents.tail(60),
		"flags": flags.duplicate(),
		"quests": quests.duplicate(),
		"quest_order": quest_order.duplicate(),
		"items": items.duplicate(),
		"gold": gold,
		"loot": loot.duplicate(true),
		"trade_stock": trade_stock.duplicate(true),
		"dialogue": dialogue.duplicate(true),
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
	flags = (s.get("flags", {}) as Dictionary).duplicate()
	quests = (s.get("quests", {}) as Dictionary).duplicate()
	quest_order = (s.get("quest_order", []) as Array).duplicate()
	items = (s.get("items", {}) as Dictionary).duplicate()
	gold = int(s.get("gold", 0))
	loot = (s.get("loot", {}) as Dictionary).duplicate(true)
	trade_stock = (s.get("trade_stock", {}) as Dictionary).duplicate(true)
	dialogue = (s.get("dialogue", {}) as Dictionary).duplicate(true)

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
	npcs = _mirror_units(s.get("npcs", []), by_uid)
	if combat != null:   # у клиента: кто не в бою, тот рядом (по врагам вне боя можно ударить)
		combat.bystanders = npcs + enemies.filter(func(e): return not combat.units.has(e))
	var lines: Array = s.get("log", [])
	GameLog.lines = lines.duplicate()
	GameEvents.load_tail(s.get("events", []))


static func _mirror_units(dicts: Array, by_uid: Dictionary) -> Array:
	var out: Array = []
	for d in dicts:
		var uid := str(d.get("uid", ""))
		out.append(by_uid[uid] if by_uid.has(uid) else Character.from_dict(d))
	return out

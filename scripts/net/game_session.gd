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
## Переход: герой встал на клетку выхода — вся партия переходит в другую локацию.
## Каждая посещённая локация помнит своё состояние (поверхности, павшие враги).
## Встречи с "respawn": true оживают при новом входе в локацию — на них можно качаться.
##
## Команды (Dictionary):
##   {"type": "move", "unit": uid, "cell": [x, y]}     в бою unit можно не указывать
##   {"type": "talk", "unit": uid, "target": uid NPC | "object": id}   подойти и заговорить
##   {"type": "dialogue_next"} / {"type": "dialogue_choice", "index": i} / {"type": "dialogue_skip"}
##   {"type": "use_item", "unit": uid, "item": id}       зелья и прочее; в бою стоит ОД
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
var dialogue: Dictionary = {}  # {"id", "node", "pid", "hero", "npc", "pending"} или {}

var _locations: Dictionary = {}    # id -> {"grid", "enemies", "defeated", "spawned", "npcs"}
var _mirror_defeated: Array = []   # у клиента: побеждённые группы (все локации)
var _mode_before_dialogue := "explore"


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
	var used := {}
	var picks: Array = []   # [шаблон, владелец]
	# сначала то, что выбрали игроки (по одному герою на игрока, одиночке — сколько выбрал)
	for pid in ids:
		var want: Array = choices.get(pid, choices.get(str(pid), []))
		var limit := 1 if ids.size() > 1 else size
		for t in want:
			var ts := str(t)
			if picks.size() >= size or limit <= 0:
				break
			if templates.has(ts) and not used.has(ts):
				used[ts] = true
				picks.append([ts, int(pid)])
				limit -= 1
	# у кого нет героя — даём свободный шаблон
	for pid in ids:
		if picks.size() >= size:
			break
		if not picks.any(func(p): return p[1] == int(pid)):
			for t in templates:
				if not used.has(str(t)):
					used[str(t)] = true
					picks.append([str(t), int(pid)])
					break
	# добиваем до минимального размера партии, раздавая по кругу
	var i := 0
	for t in templates:
		if picks.size() >= size:
			break
		if not used.has(str(t)):
			used[str(t)] = true
			picks.append([str(t), int(ids[i % ids.size()]) if not ids.is_empty() else AI_OWNER])
			i += 1
	for p in picks:
		var h := Character.from_template(str(p[0]))
		heroes.append(h)
		owners[h.uid] = int(p[1])


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
	combat = null
	if mode != "dialogue":
		mode = "explore"
	refresh_world()
	_place_heroes(spawn)
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
		for c in g.cells_in_radius(Vector2i(int(sc[0]), int(sc[1])), int(s.get("radius", 0))):
			g.set_surface(c, str(s["id"]))
	return {"grid": g, "enemies": [], "defeated": [], "spawned": [], "npcs": {}}


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
	if flags.has("hide:" + nid):
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
	if cells.is_empty() and not spawns.is_empty():
		cells = spawns.values()[0]
	var taken := {}
	for u in enemies + npcs:
		if u.is_alive():
			taken[u.cell] = true
	for i in heroes.size():
		var h: Character = heroes[i]
		var want := Vector2i(i, 0)
		if not cells.is_empty():
			want = _cell_of(cells[i % cells.size()])
		h.cell = _free_cell_near(want, taken)
		taken[h.cell] = true


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
				hero.equipment.append(item_id)
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
	return def.has("stats") or def.has("weapon")


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
	match kind:
		"move":
			err = _cmd_move(pid, cmd)
		"talk":
			err = _cmd_talk(pid, cmd)
		"dialogue_next", "dialogue_choice", "dialogue_skip":
			err = _cmd_dialogue(pid, cmd, kind)
		"use_item":
			err = _cmd_use_item(pid, cmd)
		"equip", "unequip":
			err = _cmd_equip(pid, cmd, kind)
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
				GameEvents.add("saved", {})
		"load":
			err = "загружать может только лидер" if pid != leader_id() else load_game()
			if err == "":
				GameLog.add("Игра загружена.")
		_:
			err = "неизвестная команда '%s'" % kind
	_after_action()
	return err


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
	var path := grid.find_path(u.cell, _cell(cmd), _occupied(u))
	if path.is_empty():
		return "туда не дойти"
	_walk_party(u, path)
	return ""


## Ведёт героя по пути, спутники того же игрока идут следом. По дороге враги могут заметить партию,
## на клетке выхода вся партия переходит в другую локацию.
## Возвращает "combat", "exit" или "" (дошли).
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
	for f in followers:
		var fc: Character = f
		var spot := _follow_spot(path, reserved, blockers)
		reserved[spot] = true
		var fp := grid.find_path(fc.cell, spot, blockers)
		if not fp.is_empty():
			fpaths[fc.uid] = fp
	var walked := {u.uid: []}
	for f in followers:
		walked[f.uid] = []
	var regen := float(GameData.rule("explore_regen_pct", 0)) / 100.0
	var result := ""
	var steps := path.size()
	for k in fpaths:
		steps = maxi(steps, (fpaths[k] as Array).size())
	for i in steps:
		if i < path.size():
			u.cell = path[i]
			walked[u.uid].append(GameEvents.cell(u.cell))
			if regen > 0.0:
				u.heal(u.max_hp() * regen)
		for f in followers:
			var fc: Character = f
			var fp: Array = fpaths.get(fc.uid, [])
			if i < fp.size() and not _occupied(fc).has(fp[i]):
				fc.cell = fp[i]
				walked[fc.uid].append(GameEvents.cell(fc.cell))
				if regen > 0.0:
					fc.heal(fc.max_hp() * regen)
		if mode == "explore" and _aggro_check() != "":
			result = "combat"
			break
		if i < path.size() and not exit_at(u.cell).is_empty():
			result = "exit"
			break
	var paths := {}
	for k in walked:
		if not (walked[k] as Array).is_empty():
			paths[k] = walked[k]
	if not paths.is_empty():
		GameEvents.add("move", {"paths": paths})
	match result:
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
			score -= float(mini(sx, 2)) * 2.0   # чем дальше вбок, тем лучше видно обоих
			if path.size() >= 2 and cell == path[-2]:
				score -= 4.0             # шаг назад по пути — естественно, если он не прячет спутника
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
		if dl == "":
			return "%s молчит" % n.display_name
	# подойти вплотную
	var near := cells.any(func(c): return SurfaceGrid.distance(u.cell, c) <= 1)
	if not near:
		var best: Array = []
		var occ := _occupied(u)
		for c in cells:
			for d in SurfaceGrid.DIRS:
				var nb: Vector2i = c + d
				if grid.is_walkable(nb) and not occ.has(nb):
					var p := grid.find_path(u.cell, nb, occ)
					if not p.is_empty() and (best.is_empty() or p.size() < best.size()):
						best = p
		if best.is_empty():
			return "не подойти"
		if _walk_party(u, best) != "":
			return ""   # по дороге начался бой или переход
	start_dialogue(dl, pid, u.uid, npc_id)
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


## Предмет, который действует как навык (масло — масляное пятно, факел — вспышка). Только в бою.
func _use_item_skill(pid: int, cmd: Dictionary, item_id: String, skill_id: String) -> String:
	if mode != "combat" or combat == null or not combat.active:
		return "это пригодится в бою"
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
		if GameData.item(item_id).has("weapon"):   # оружие одно
			for it in u.equipment.duplicate():
				if GameData.item(str(it)).has("weapon"):
					u.equipment.erase(it)
					items[str(it)] = int(items.get(str(it), 0)) + 1
		u.equipment.append(item_id)
		give_item(item_id, -1)
	else:
		if not u.equipment.has(item_id):
			return "этот предмет не надет"
		u.equipment.erase(item_id)
		items[item_id] = int(items.get(item_id, 0)) + 1
	GameEvents.add("sfx", {"id": "pickup"})
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
		_locations[id] = {"grid": SurfaceGrid.from_dict(ld.get("grid", {})), "enemies": foes,
			"defeated": defeated.duplicate(), "spawned": spawned.duplicate(), "npcs": {}}
	flags = (d.get("flags", {}) as Dictionary).duplicate()
	quests = (d.get("quests", {}) as Dictionary).duplicate()
	quest_order = (d.get("quest_order", []) as Array).duplicate()
	items = {}
	var its: Dictionary = d.get("items", {})
	for k in its:
		items[str(k)] = int(its[k])
	gold = int(d.get("gold", 0))
	location_id = str(d.get("location", ""))
	entry_spawn = str(d.get("entry_spawn", ""))
	var st: Dictionary = _locations.get(location_id, {})
	grid = st.get("grid", null)
	enemies = st.get("enemies", [])
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
	var lines: Array = s.get("log", [])
	GameLog.lines = lines.duplicate()
	GameEvents.load_tail(s.get("events", []))


static func _mirror_units(dicts: Array, by_uid: Dictionary) -> Array:
	var out: Array = []
	for d in dicts:
		var uid := str(d.get("uid", ""))
		out.append(by_uid[uid] if by_uid.has(uid) else Character.from_dict(d))
	return out

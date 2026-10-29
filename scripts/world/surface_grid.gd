class_name SurfaceGrid
extends RefCounted
## Боевое поле: клетки, стены, поверхности на двух слоях ("ground" и "cloud").
## Реакции поверхностей и стихий берутся из data/surfaces.json.
## Расстояние — по Чебышёву (диагональ = 1 клетка), движение в 8 направлениях.

const LAYERS := ["ground", "cloud"]
const DIRS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var width: int
var height: int
var blocked: Dictionary = {}                  # Vector2i -> true (стены, препятствия)
var layers: Dictionary = {"ground": {}, "cloud": {}}   # layer -> {Vector2i -> {"id","turns","level"}}
var traps: Dictionary = {}                    # Vector2i -> {"type", "state": hidden|found|disarmed|sprung, "rolled": {uid: true}}


func _init(w: int = 12, h: int = 10) -> void:
	width = w
	height = h


# --- Геометрия ----------------------------------------------------------------

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < width and c.y < height


func is_walkable(c: Vector2i) -> bool:
	return in_bounds(c) and not blocked.has(c)


## Ловушка, которая ещё может сработать (спрятанная или найденная); иначе пустой словарь.
func armed_trap(c: Vector2i) -> Dictionary:
	var t: Dictionary = traps.get(c, {})
	return t if str(t.get("state", "")) in ["hidden", "found"] else {}


## Клетки найденных и ещё не обезвреженных ловушек: пути героев их обходят.
func known_traps() -> Dictionary:
	var out := {}
	for c in traps:
		if str(traps[c]["state"]) == "found":
			out[c] = true
	return out


static func distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func cells_in_radius(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var c := center + Vector2i(dx, dy)
			if in_bounds(c) and not blocked.has(c):
				out.append(c)
	return out


## Путь от from до to (без стартовой клетки) за наименьшее число шагов; из таких путей — самый короткий на экране
## (в изометрии шаг по диагонали (1,-1) вдвое длиннее, чем по (1,1)), поэтому фигурки идут прямо, без зигзагов.
## По диагонали мимо угла стены не срезать (can_step). occupied: {Vector2i: true}.
## allow_occupied_goal — путь до занятой клетки (удобно для ИИ: «подойти к врагу»).
func find_path(from: Vector2i, to: Vector2i, occupied: Dictionary = {}, allow_occupied_goal: bool = false) -> Array:
	if from == to or not is_walkable(to):
		return []
	if occupied.has(to) and not allow_occupied_goal:
		return []
	var came_from := {from: from}
	var length := {from: 0.0}
	var frontier: Array = [from]
	while not frontier.is_empty() and not came_from.has(to):
		var level := {}   # клетки этого шага: из какой клетки прийти, чтобы путь на экране был короче
		for cur in frontier:
			var cv: Vector2i = cur
			for d in DIRS:
				var n: Vector2i = cv + d
				if (came_from.has(n) and not level.has(n)) or not can_step(cv, d):
					continue
				if occupied.has(n) and n != to:
					continue
				var l: float = float(length[cv]) + step_length(d)
				if not level.has(n) or l < float(length[n]):
					level[n] = true
					came_from[n] = cv
					length[n] = l
		frontier = level.keys()
	if not came_from.has(to):
		return []
	var path: Array = []
	var step: Vector2i = to
	while step != from:
		path.push_front(step)
		step = came_from[step]
	return path


## Можно ли шагнуть из клетки c в сторону d: клетка проходима, а по диагонали — ещё и не мимо угла стены.
func can_step(c: Vector2i, d: Vector2i) -> bool:
	if not is_walkable(c + d):
		return false
	if d.x != 0 and d.y != 0:
		return is_walkable(c + Vector2i(d.x, 0)) and is_walkable(c + Vector2i(0, d.y))
	return true


## Длина шага на экране в клетках по стороне: (1,1) — вниз на 16 px, (1,-1) — вбок на 32 px, по стороне — ~18 px.
static func step_length(d: Vector2i) -> float:
	if d.x != 0 and d.y != 0:
		return 0.9 if d.x == d.y else 1.8
	return 1.0


# --- Поверхности --------------------------------------------------------------

func get_surface(layer: String, c: Vector2i) -> String:
	var d: Dictionary = layers[layer]
	if d.has(c):
		return str(d[c]["id"])
	return "none"


func get_ground(c: Vector2i) -> String:
	return get_surface("ground", c)


func get_cloud(c: Vector2i) -> String:
	return get_surface("cloud", c)


## Ставит поверхность; слой берётся из её описания. "none" ничего не ставит.
func set_surface(c: Vector2i, surface_id: String, level: int = 1) -> void:
	var def := GameData.surface(surface_id)
	if def.is_empty():
		return
	set_layer(str(def.get("layer", "ground")), c, surface_id, level)


func set_layer(layer: String, c: Vector2i, surface_id: String, level: int = 1) -> void:
	var d: Dictionary = layers[layer]
	if surface_id == "" or surface_id == "none" or not in_bounds(c) or blocked.has(c):
		d.erase(c)
		return
	var def := GameData.surface(surface_id)
	d[c] = {"id": surface_id, "turns": int(def.get("duration", -1)), "level": level}


func surface_level(c: Vector2i) -> int:
	var lvl := 1
	for layer in LAYERS:
		var d: Dictionary = layers[layer]
		if d.has(c):
			lvl = maxi(lvl, int(d[c]["level"]))
	return lvl


## Воздействует стихией на область. Если create=true и реакции нет,
## создаётся поверхность этой стихии (element_surfaces).
## Возвращает список взрывов: [{"cell": Vector2i, "damage": {...}, "level": int}].
func apply_element(center: Vector2i, radius: int, element: String, create: bool, level: int = 1) -> Array:
	var explosions: Array = []
	var touched := {}   # чтобы растекание не срабатывало повторно на тех же клетках
	for c in cells_in_radius(center, radius):
		if not touched.has(c):
			_apply_element_cell(c, element, create, level, explosions, touched)
	for e in explosions:
		GameLog.add("Взрыв в клетке %s!" % str(e["cell"]))
	return explosions


func _apply_element_cell(c: Vector2i, element: String, create: bool, level: int, explosions: Array, touched: Dictionary) -> void:
	touched[c] = true
	# Снимок до изменений, чтобы результат одной реакции не реагировал повторно.
	var before := {"ground": get_ground(c), "cloud": get_cloud(c)}
	var reacted := false
	for layer in LAYERS:
		var cur: String = before[layer]
		if cur == "none":
			continue
		var r := GameData.surface_reaction(cur, element)
		if r.is_empty():
			continue
		reacted = true
		if r.has("text"):
			GameLog.add(str(r["text"]))
			GameEvents.add("reaction", {"cell": GameEvents.cell(c), "text": str(r["text"])})
		var affected: Array = [c]
		if bool(r.get("spread", false)):
			affected = flood_fill(layer, c, cur)
		for a in affected:
			touched[a] = true
			if r.has("ground"):
				set_layer("ground", a, str(r["ground"]), level)
			if r.has("cloud"):
				set_layer("cloud", a, str(r["cloud"]), level)
			if r.has("explosion"):
				explosions.append({"cell": a, "damage": r["explosion"], "level": level})
	if not reacted and create:
		var sid := GameData.element_surface(element)
		if sid != "":
			set_surface(c, sid, level)


## Все связанные (8 направлений) клетки слоя с той же поверхностью.
func flood_fill(layer: String, start: Vector2i, surface_id: String) -> Array:
	var out: Array = []
	var seen := {start: true}
	var queue: Array = [start]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		out.append(cur)
		for d in DIRS:
			var n: Vector2i = cur + d
			if not seen.has(n) and get_surface(layer, n) == surface_id:
				seen[n] = true
				queue.append(n)
	return out


## Конец раунда: поверхности с ограниченной длительностью истекают.
## "revert_to" — во что превращается поверхность по истечении (вода под током -> вода).
func tick_round() -> void:
	for layer in LAYERS:
		var d: Dictionary = layers[layer]
		for c in d.keys():
			var s: Dictionary = d[c]
			if int(s["turns"]) < 0:
				continue
			s["turns"] = int(s["turns"]) - 1
			if int(s["turns"]) <= 0:
				var revert := str(GameData.surface(str(s["id"])).get("revert_to", ""))
				if revert != "":
					set_layer(layer, c, revert, int(s["level"]))
				else:
					d.erase(c)


## Есть ли поверхности с конечным сроком (огонь, пар, лёд): им нужно время.
func has_timed_surfaces() -> bool:
	for layer in LAYERS:
		for c in layers[layer]:
			if int(layers[layer][c]["turns"]) >= 0:
				return true
	return false


## Статусы, которые накладывают поверхности клетки: [{"id","chance"}].
func statuses_for_cell(c: Vector2i) -> Array:
	var out: Array = []
	for layer in LAYERS:
		var sid := get_surface(layer, c)
		if sid == "none":
			continue
		var sts: Array = GameData.surface(sid).get("statuses", [])
		out.append_array(sts)
	return out


# --- Сериализация -------------------------------------------------------------

func to_dict() -> Dictionary:
	var walls: Array = []
	for c in blocked:
		walls.append([c.x, c.y])
	var out_layers := {}
	for layer in LAYERS:
		var entries: Array = []
		var d: Dictionary = layers[layer]
		for c in d:
			var s: Dictionary = d[c]
			entries.append([c.x, c.y, s["id"], s["turns"], s["level"]])
		out_layers[layer] = entries
	var trap_list: Array = []
	for c in traps:
		var t: Dictionary = traps[c]
		trap_list.append([c.x, c.y, t["type"], t["state"], (t.get("rolled", {}) as Dictionary).keys()])
	return {"w": width, "h": height, "blocked": walls, "layers": out_layers, "traps": trap_list}


static func from_dict(d: Dictionary) -> SurfaceGrid:
	var g := SurfaceGrid.new(int(d.get("w", 12)), int(d.get("h", 10)))
	var walls: Array = d.get("blocked", [])
	for w in walls:
		g.blocked[Vector2i(int(w[0]), int(w[1]))] = true
	var in_layers: Dictionary = d.get("layers", {})
	for layer in LAYERS:
		var entries: Array = in_layers.get(layer, [])
		var target: Dictionary = g.layers[layer]
		for e in entries:
			target[Vector2i(int(e[0]), int(e[1]))] = {"id": str(e[2]), "turns": int(e[3]), "level": int(e[4])}
	var trap_list: Array = d.get("traps", [])
	for e in trap_list:
		var rolled := {}
		for uid in (e[4] if e.size() > 4 else []):
			rolled[str(uid)] = true
		g.traps[Vector2i(int(e[0]), int(e[1]))] = {"type": str(e[2]), "state": str(e[3]), "rolled": rolled}
	return g

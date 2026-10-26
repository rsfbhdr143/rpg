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


func _init(w: int = 12, h: int = 10) -> void:
	width = w
	height = h


# --- Геометрия ----------------------------------------------------------------

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < width and c.y < height


func is_walkable(c: Vector2i) -> bool:
	return in_bounds(c) and not blocked.has(c)


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


## BFS-путь от from до to (без стартовой клетки). occupied: {Vector2i: true}.
## allow_occupied_goal — путь до занятой клетки (удобно для ИИ: «подойти к врагу»).
func find_path(from: Vector2i, to: Vector2i, occupied: Dictionary = {}, allow_occupied_goal: bool = false) -> Array:
	if from == to or not is_walkable(to):
		return []
	if occupied.has(to) and not allow_occupied_goal:
		return []
	var came_from := {from: from}
	var queue: Array = [from]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		if cur == to:
			break
		for d in DIRS:
			var n: Vector2i = cur + d
			if came_from.has(n) or not is_walkable(n):
				continue
			if occupied.has(n) and n != to:
				continue
			came_from[n] = cur
			queue.append(n)
	if not came_from.has(to):
		return []
	var path: Array = []
	var step: Vector2i = to
	while step != from:
		path.push_front(step)
		step = came_from[step]
	return path


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

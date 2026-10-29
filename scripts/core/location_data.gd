class_name LocationData
extends RefCounted
## Разбор карт локаций (data/locations.json) и слияние с сюжетом (data/story/locations.json).
##
## Карту удобно рисовать строками: каждая буква — клетка, её смысл задаёт "legend".
##   "rows": ["TTTTTT", "T..gaT", …],
##   "legend": {
##     "T": {"wall": true},                  стена (как выглядит — tiles/wall локации или "style")
##     "h": {"solid": true},                 непроходимо, но не рисуется (под зданием)
##     "g": {"prop": "grave"},               декорация на клетке, по умолчанию непроходима ("block": false — проходима)
##     "H": {"prop": "tavern", "size": [3, 3]}   здание на несколько клеток: буква в его дальнем углу (меньшие x и y)
##     "~": {"surface": "water"},            поверхность
##     "`": {"deco": "path"},                рисунок на земле, ходить не мешает: path — тропа, square — мостовая,
##                                           field — грядки, bridge_x / bridge_y — мост вдоль x / y, stones — камни брода
##     "a": {"spawn": "start"},              клетка точки появления (по клетке на героя, по порядку)
##     "1": {"exit": "to_village"},          клетка выхода; сам выход описан в "exits" с этим "id"
##     "P": {"npc": "tadeush"},              где стоит NPC (можно с "if")
##     "c": {"object": "coffin"},            предмет, с которым можно поговорить (описание в сюжете)
##     "w": {"encounter": "forest_wolves", "template": "wolf"}   враг встречи (template можно не писать,
##                                                               если состав встречи задан в сюжете)
##     "A": {"anchor": "tavern"}             именованная точка: у неё сюжет ставит NPC и встречи ("anchor")
##     "^": {"trap": "fire_rune"}            спрятанная ловушка (виды — data/traps.json)
##     "R": {"building": "tavern", "size": [7, 6], "name": "Таверна", "material": "timber", "roof": "shingle",
##           "sprite": "tavern"}           дом, в который можно войти: буква в дальнем углу, по краю прямоугольника
##                                           стены (рисуй "="), "+" — дверь, внутри "_" — пол, мебель, жители;
##                                           sprite — рисунок дома снаружи (props/<id>), без него дом рисуется кодом
##   }
## Буквы можно совмещать в одной записи: {"surface": "water", "spawn": "start"}.
## "#" — стена и "." — пол действуют без легенды.
## Всё это превращается в обычные поля: size, walls, solid, surfaces, spawns, exits, props, anchors, npcs, objects,
## encounters, traps.

const DEFAULT_LEGEND := {"#": {"wall": true}, ".": {}, " ": {}, "=": {}, "_": {}, "+": {"door": true}}


static func normalize(id: String, d: Dictionary, warnings: Array) -> Dictionary:
	var loc := d.duplicate(true)
	var walls: Array = loc.get("walls", [])
	var solid: Array = loc.get("solid", [])
	var surfaces: Array = loc.get("surfaces", [])
	var spawns: Dictionary = loc.get("spawns", {})
	var props: Array = loc.get("props", [])
	var anchors: Dictionary = loc.get("anchors", {})
	var npcs: Array = loc.get("npcs", [])
	var objects: Array = loc.get("objects", [])
	var traps: Array = loc.get("traps", [])
	var buildings: Array = loc.get("buildings", [])
	var deco: Array = loc.get("deco", [])
	var door_cells := {}
	var exit_cells := {}
	var enc_cells := {}       # id встречи -> [[x, y], …]
	var enc_templates := {}   # id встречи -> [шаблон или "", …]
	var placed_objects := {}  # id предмета -> запись из легенды

	var rows: Array = loc.get("rows", [])
	if not rows.is_empty():
		var legend: Dictionary = DEFAULT_LEGEND.duplicate(true)
		var user_legend: Dictionary = loc.get("legend", {})
		legend.merge(user_legend, true)
		var w := 0
		for r in rows:
			w = maxi(w, str(r).length())
		loc["size"] = [w, rows.size()]
		for y in rows.size():
			var row := str(rows[y])
			for x in row.length():
				var ch := row[x]
				if not legend.has(ch):
					warnings.append("%s: буква «%s» в клетке [%d, %d] не описана в legend" % [id, ch, x, y])
					continue
				var e: Dictionary = legend[ch]
				var c := [x, y]
				if _flag(e, "wall"):
					walls.append(c)
				if _flag(e, "solid"):
					solid.append(c)
				if e.has("prop"):
					var p: Dictionary = e.duplicate()
					p.erase("prop")
					p["id"] = str(e["prop"])
					p["cell"] = c
					props.append(p)
				if e.has("surface"):
					surfaces.append({"id": str(e["surface"]), "cell": c, "radius": 0})
				if e.has("deco"):
					deco.append([x, y, str(e["deco"])])
				if e.has("anchor"):
					anchors[str(e["anchor"])] = c
				if _flag(e, "door"):
					door_cells[Vector2i(x, y)] = true
				if e.has("building"):
					var bs: Array = e.get("size", [3, 3])
					if not _walled(rows, legend, x, y, int(bs[0]), int(bs[1]), ch):
						# та же буква в другом месте (например, мебель внутри другого дома) — это не дом:
						# иначе посреди комнаты вырастают стены чужого дома
						warnings.append("%s: буква дома «%s» в клетке [%d, %d] не в углу стен — не дом" % [id, ch, x, y])
						continue
					var b: Dictionary = e.duplicate()
					b.erase("building")
					b["id"] = str(e["building"])
					b.erase("size")
					b["rect"] = [x, y, int(bs[0]), int(bs[1])]
					buildings.append(b)
				if e.has("trap"):
					if not GameData.traps.has(str(e["trap"])):   # не GameData.trap(): данные ещё грузятся
						warnings.append("%s: ловушки «%s» нет в data/traps.json" % [id, e["trap"]])
					traps.append({"type": str(e["trap"]), "cell": c})
				if e.has("spawn"):
					var sp := str(e["spawn"])
					if not spawns.has(sp):
						spawns[sp] = []
					spawns[sp].append(c)
				if e.has("exit"):
					var ex := str(e["exit"])
					if not exit_cells.has(ex):
						exit_cells[ex] = []
					exit_cells[ex].append(c)
				if e.has("npc"):
					var n := {"id": str(e["npc"]), "cell": c}
					if e.has("if"):
						n["if"] = e["if"]
					npcs.append(n)
				if e.has("object"):
					var o: Dictionary = e.duplicate()
					o.erase("object")
					o["id"] = str(e["object"])
					o["cell"] = c
					placed_objects[o["id"]] = o
				if e.has("encounter"):
					var en := str(e["encounter"])
					if not enc_cells.has(en):
						enc_cells[en] = []
						enc_templates[en] = []
					enc_cells[en].append(c)
					enc_templates[en].append(str(e.get("template", "")))

	# Выходы: клетки из легенды по id выхода.
	var exits: Array = loc.get("exits", [])
	for ex in exits:
		var ex_id := str(ex.get("id", ""))
		if exit_cells.has(ex_id):
			var cells: Array = ex.get("cells", [])
			cells.append_array(exit_cells[ex_id])
			ex["cells"] = cells
	for ex_id in exit_cells:
		if not exits.any(func(e): return str(e.get("id", "")) == ex_id):
			warnings.append("%s: клетки выхода «%s» есть, а описания в exits нет" % [id, ex_id])

	# Предметы: описание из списка objects + клетка из легенды.
	for o in objects:
		var oid := str(o.get("id", ""))
		if placed_objects.has(oid):
			var placed: Dictionary = placed_objects[oid]
			for k in placed:
				if not o.has(k):
					o[k] = placed[k]
			placed_objects.erase(oid)
	for oid in placed_objects:
		objects.append(placed_objects[oid])

	# Встречи: клетки врагов из легенды.
	var encounters: Array = loc.get("encounters", [])
	for en in enc_cells:
		var enc: Dictionary = {}
		for e in encounters:
			if str(e.get("id", "")) == en:
				enc = e
		if enc.is_empty():
			enc = {"id": en}
			encounters.append(enc)
		var cells: Array = enc.get("cells", [])
		cells.append_array(enc_cells[en])
		enc["cells"] = cells
		var templates: Array = enc_templates[en]
		if not enc.has("enemies") and templates.any(func(t): return t != ""):
			var list: Array = []
			for i in templates.size():
				if templates[i] != "":
					list.append({"template": templates[i]})
			enc["enemies"] = list
	for enc in encounters:
		_assign_cells(enc)

	loc["walls"] = walls
	loc["solid"] = solid
	loc["surfaces"] = surfaces
	loc["deco"] = deco
	loc["spawns"] = spawns
	loc["exits"] = exits
	loc["props"] = props
	loc["anchors"] = anchors
	loc["npcs"] = npcs
	loc["objects"] = objects
	loc["encounters"] = encounters
	# Дома: стены по краю прямоугольника (непроходимы, рисуются домом), двери — проходы в стене.
	for b in buildings:
		var r: Array = b["rect"]
		var doors: Array = b.get("doors", [])
		for c in building_perimeter(r):
			var cell := Vector2i(int(c[0]), int(c[1]))
			if door_cells.has(cell):
				doors.append(c)
			else:
				solid.append(c)
		if doors.is_empty():
			warnings.append("%s: у дома «%s» нет двери (+ на стене)" % [id, b["id"]])
		b["doors"] = doors
	loc["buildings"] = buildings
	loc["traps"] = traps
	loc.erase("rows")
	loc.erase("legend")
	return loc


## Ключ-признак легенды: только настоящее true (у домов, например, "material" — строка, и строки признаком не считаются).
## Буква дома стоит в дальнем углу прямоугольника, весь край которого — стены "=" и двери (угол — сама буква).
static func _walled(rows: Array, legend: Dictionary, x: int, y: int, w: int, h: int, corner: String) -> bool:
	if y + h > rows.size():
		return false
	for yy in range(y, y + h):
		var row := str(rows[yy])
		if x + w > row.length():
			return false
		for xx in range(x, x + w):
			if xx != x and xx != x + w - 1 and yy != y and yy != y + h - 1:
				continue
			var ch := row[xx]
			var door := legend.has(ch) and _flag(legend[ch], "door")
			if not (ch == "=" or door or (xx == x and yy == y and ch == corner)):
				return false
	return true


static func _flag(e: Dictionary, key: String) -> bool:
	return typeof(e.get(key)) == TYPE_BOOL and bool(e[key])


## Клетки стен дома [x, y, w, h]: край прямоугольника.
static func building_perimeter(r: Array) -> Array:
	var out: Array = []
	var x0 := int(r[0])
	var y0 := int(r[1])
	var w := int(r[2])
	var h := int(r[3])
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if x == x0 or y == y0 or x == x0 + w - 1 or y == y0 + h - 1:
				out.append([x, y])
	return out


## Врагам без клетки раздаёт клетки встречи по порядку.
static func _assign_cells(enc: Dictionary) -> void:
	var cells: Array = enc.get("cells", [])
	var enemies: Array = enc.get("enemies", [])
	var used := 0
	for e in enemies:
		if e.has("cell"):
			continue
		if used < cells.size():
			e["cell"] = cells[used]
			used += 1


## Слияние карты с описанием из сюжета: название, тексты, музыка — из сюжета;
## встречи и предметы объединяются по id (состав и диалоги — сюжет, клетки — карта).
static func merge_story(mine: Dictionary, story: Dictionary, id: String, warnings: Array) -> Dictionary:
	var out := mine.duplicate(true)
	if mine.is_empty():
		warnings.append("%s: локация есть в сюжете, но нет карты в data/locations.json" % id)
	for key in story:
		match str(key):
			"encounters":
				var anchors: Dictionary = out.get("anchors", {})
				out["encounters"] = _merge_by_id(out.get("encounters", []), story[key], id, "встреча", warnings, anchors)
				for enc in out["encounters"]:
					_assign_cells(enc)
					if anchors.has(str(enc.get("anchor", ""))):
						continue   # враги без клетки встанут у именованной точки карты
					for e in enc.get("enemies", []):
						if not e.has("cell"):
							warnings.append("%s: врагу %s встречи %s не хватило клетки на карте" % [id, e.get("template", "?"), enc.get("id", "?")])
			"objects":
				out["objects"] = _merge_by_id(out.get("objects", []), story[key], id, "предмет", warnings)
				for o in out["objects"]:
					if not o.has("cell"):
						warnings.append("%s: предмет %s не стоит на карте" % [id, o.get("id", "?")])
			"npcs":
				var placed: Array = out.get("npcs", [])
				for n in story[key]:
					var nid := str(n.get("id", "")) if typeof(n) == TYPE_DICTIONARY else str(n)
					if not placed.any(func(p): return str(p.get("id", "")) == nid):
						warnings.append("%s: NPC %s не стоит на карте" % [id, nid])
			"size", "rows", "legend", "walls", "solid", "wall_rects", "spawns", "exits", "props", "anchors", "deco":
				if mine.is_empty():
					out[key] = story[key]
			_:
				out[key] = story[key]
	return out


## anchors — именованные точки карты: запись с "anchor" на одну из них рисовать на карте не нужно.
static func _merge_by_id(mine: Array, theirs: Array, loc: String, what: String, warnings: Array, anchors: Dictionary = {}) -> Array:
	var out: Array = mine.duplicate(true)
	for t in theirs:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var tid := str(t.get("id", ""))
		var found: Dictionary = {}
		for m in out:
			if str(m.get("id", "")) == tid:
				found = m
		if found.is_empty():
			if not anchors.has(str(t.get("anchor", ""))):
				warnings.append("%s: %s %s из сюжета не нарисован на карте" % [loc, what, tid])
			out.append(t.duplicate(true))
			continue
		for k in t:
			if str(k) == "enemies":
				# состав из сюжета, клетки — с карты (по порядку)
				var cells: Array = found.get("cells", [])
				if cells.is_empty():
					for e in found.get("enemies", []):
						if e.has("cell"):
							cells.append(e["cell"])
				found["cells"] = cells
				var list: Array = []
				for e in t[k]:
					var ed: Dictionary = (e as Dictionary).duplicate(true)
					ed.erase("cell")
					list.append(ed)
				found["enemies"] = list
			elif not (str(k) == "cell" or str(k) == "trigger_radius" and found.has(k)):
				found[k] = t[k]
	return out

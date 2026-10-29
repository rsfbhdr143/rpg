class_name WorldView
extends Node2D
## Мир на экране: земля локации, стены, дома, декорации, фигурки, снаряды, частицы и всплывающие цифры.
## Живёт в маленьком SubViewport (640×360 при пиксельности 2), который потом увеличивается без
## сглаживания, поэтому всё выглядит пиксельным. Логики игры тут нет: состояние берётся из сессии,
## а анимации запускает GameScreen по событиям GameEvents (walk, lunge, hit_fx, death_fx...).
##
## Координаты: клетка — ромб 32×16 пикселей мира, точка сетки (0, 0) — в начале координат.
## Земля рисуется шейдером shaders/ground.gdshader, остальное — PixelArt (заглушки) или картинками
## из SpriteLibrary, если они есть в data/sprites.json.

const TW := 32
const TH := 16
const WALK_SPEED := 120.0         # пикселей мира в секунду
const SHELL_FIT := 0.25           # насколько рисунок дома может быть шире или уже дома (доля; свесы крыши шире стен)
const SURFACE_COLORS := {
	"water": ["2f5a8a", 1], "blood": ["6e1a1a", 6], "oil": ["2e2618", 5], "poison": ["4f8a2e", 1],
	"fire": ["e8641e", 2], "ice": ["a8d8e8", 3], "electrified_water": ["4a78b8", 4], "electrified_blood": ["8a2a5a", 4],
}
const CLOUD_COLORS := {"steam": "d8dce0", "electrified_steam": "d0d4ff", "poison_cloud": "8acc5a"}
const LIGHT_PROPS := {"funeral_candles": [26.0, "ffb050"], "campfire": [44.0, "ff8a30"], "pyre": [56.0, "ff8a30"]}

static var _images := {}          # Texture2D -> Image (image_of)

var session: GameSession
var loc_id := ""
var grid_w := 0
var grid_h := 0
var time := 0.0
var zoom := 1
var focus := Vector2.ZERO          # за чем следит камера (точка мира)
var bg_color := Color("0b0a0c")    # цвет за краем карты (фон экрана подбирается под него)
var pan := Vector2.ZERO            # сдвиг камеры игроком
var idle := true                   # GameScreen: события проиграны, можно ставить всех на их клетки
var hover_cell := Vector2i(-99, -99)
var hover_uid := ""
var hover_object := ""
var hover_point := Vector2(-9999, -9999)   # курсор в координатах мира: фигуры, за которыми он, просвечивают
var hover_house := ""                      # дом с рисунком снаружи под курсором: подсвечивается
var pick_prefer := "foe"   # кого выбирать, когда фигуры перекрываются: "foe" — врагов и жителей, "ally" — своих
var selected_uid := ""
var current_uid := ""
var target_uids: Dictionary = {}   # uid -> true: кого заденет навык под курсором
var hl_move: Dictionary = {}       # клетка -> true
var hl_range: Dictionary = {}
var hl_aoe: Dictionary = {}
var hl_path: Array = []
var grid_lines := false
var lit_flags: Dictionary = {}     # id предмета -> горит ли (костёр)

var units: Dictionary = {}         # uid -> UnitNode
var props: Array = []              # PropNode
var objects: Dictionary = {}       # id предмета -> PropNode
var buildings: Array = []          # PropNode размером больше клетки (порядок рисования считается каждый кадр)
var houses: Array = []             # дома, в которые можно войти: {"def", "rect", "doors", "open", "ghost", "nodes", "shell"}
var floaters: Array = []
var speech: Dictionary = {}        # uid -> {"text", "t", "dur"}: реплика над головой (облачко)
var projectiles: Array = []
var particles: Array = []
var lights: Array = []             # [{"pos", "radius", "color", "node"}]

var camera: Camera2D
var _cam_pos := Vector2.ZERO
var _shake_t := 0.0
var _shake_dur := 0.0
var _shake_power := 0.0
var _ground: Node2D
var _floors: Node2D
var _traps: Node2D
var _ground_mat: ShaderMaterial
var _entities: Node2D
var _over: Node2D
var _glow: Node2D
var _cells_img: Image
var _cells_tex: ImageTexture
var _hl_img: Image
var _hl_tex: ImageTexture
var _pal_tex: ImageTexture
var _noise_tex: ImageTexture
var _surf_index: Dictionary = {}
var _cells_key := ""
var _hl_key := ""
var _anim_acc := 0.0
var _font: Font
var _labels: Array = []   # надписи над миром за этот кадр: их рисует экран игры в полном разрешении (labels())
var _bounds := Rect2()
var _building := false


# --- Координаты -------------------------------------------------------------------

static func grid_point(gx: float, gy: float) -> Vector2:
	return Vector2((gx - gy) * TW * 0.5, (gx + gy) * TH * 0.5)


static func cell_center(c: Vector2i) -> Vector2:
	return grid_point(c.x + 0.5, c.y + 0.5)


static func world_to_cell(p: Vector2) -> Vector2i:
	var gx := (p.x / (TW * 0.5) + p.y / (TH * 0.5)) * 0.5
	var gy := (p.y / (TH * 0.5) - p.x / (TW * 0.5)) * 0.5
	return Vector2i(floori(gx), floori(gy))


static func corners(c: Vector2i, size := Vector2i.ONE) -> PackedVector2Array:
	return PackedVector2Array([grid_point(c.x, c.y), grid_point(c.x + size.x, c.y),
		grid_point(c.x + size.x, c.y + size.y), grid_point(c.x, c.y + size.y)])


## Картинка текстуры в памяти (для проверки прозрачности под курсором), с кэшем.
static func image_of(tex: Texture2D) -> Image:
	if tex == null:
		return null
	if not _images.has(tex):
		var img := tex.get_image()
		if img != null and img.is_compressed():
			img.decompress()
		_images[tex] = img
	return _images[tex]


static func variant_of(c: Vector2i) -> int:
	return absi((c.x * 73856093) ^ (c.y * 19349663)) % 9973


# --- Создание ------------------------------------------------------------------------

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_font = UiTheme.font("bold")
	_ground = Node2D.new()
	_ground.z_index = -20
	add_child(_ground)
	_ground.draw.connect(_draw_ground)
	_ground_mat = ShaderMaterial.new()
	_ground_mat.shader = load("res://shaders/ground.gdshader")
	_ground.material = _ground_mat
	_floors = Node2D.new()
	_floors.z_index = -15
	add_child(_floors)
	_floors.draw.connect(_draw_floors)
	_traps = Node2D.new()
	_traps.z_index = -10
	add_child(_traps)
	_traps.draw.connect(_draw_traps)
	_entities = Node2D.new()
	_entities.y_sort_enabled = true
	add_child(_entities)
	_glow = Node2D.new()
	_glow.z_index = 40
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add_mat
	add_child(_glow)
	_glow.draw.connect(_draw_glow)
	_over = Node2D.new()
	_over.z_index = 50
	add_child(_over)
	_over.draw.connect(_draw_over)
	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	var fnl := FastNoiseLite.new()
	fnl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fnl.frequency = 0.012
	fnl.fractal_octaves = 4
	fnl.seed = 7
	_noise_tex = ImageTexture.create_from_image(fnl.get_seamless_image(256, 256))
	_build_palette()


func _build_palette() -> void:
	var img := Image.create(16, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_surf_index.clear()
	var i := 1
	for id in GameData.surfaces:
		var def := GameData.surface(str(id))
		if str(def.get("layer", "ground")) != "ground" or i >= 16:
			continue
		var e: Array = SURFACE_COLORS.get(str(id), [str(def.get("color", "#808080")).trim_prefix("#"), 0])
		var col := Color(str(e[0]))
		col.a = float(int(e[1])) / 255.0
		img.set_pixel(i, 0, col)
		_surf_index[str(id)] = i
		i += 1
	_pal_tex = ImageTexture.create_from_image(img)


## Собрать локацию заново (вход, загрузка, переход).
func build(s: GameSession) -> void:
	session = s
	loc_id = s.location_id
	for n in _entities.get_children():
		n.queue_free()
	units.clear()
	props.clear()
	objects.clear()
	buildings.clear()
	houses.clear()
	lights.clear()
	floaters.clear()
	speech.clear()
	projectiles.clear()
	particles.clear()
	if s.grid == null:
		return
	var data := s.location_data()
	grid_w = s.grid.width
	grid_h = s.grid.height
	_bounds = Rect2(-grid_h * TW * 0.5, 0, (grid_w + grid_h) * TW * 0.5, (grid_w + grid_h) * TH * 0.5)
	_setup_ground(data)
	_build_props(data)
	_build_houses(data)
	_floors.queue_redraw()
	_building = true
	sync_units()
	_building = false
	for u in units.values():
		(u as UnitNode).snap()
	_cam_pos = focus
	camera.position = _cam_pos.round()
	_ground.queue_redraw()


func _setup_ground(data: Dictionary) -> void:
	_cells_img = Image.create(grid_w, grid_h, false, Image.FORMAT_RGBA8)
	_cells_tex = ImageTexture.create_from_image(_cells_img)
	_hl_img = Image.create(grid_w, grid_h, false, Image.FORMAT_RGBA8)
	_hl_img.fill(Color(0, 0, 0, 0))
	_hl_tex = ImageTexture.create_from_image(_hl_img)
	_cells_key = ""
	_hl_key = ""
	var style: Dictionary = data.get("style", {})
	var floor_cols: Array = style.get("floor", ["3b4232", "353c2d"])
	var a := Color(str(floor_cols[0]))
	var b := Color(str(floor_cols[1] if floor_cols.size() > 1 else floor_cols[0]))
	var m := _ground_mat
	m.set_shader_parameter("cells_tex", _cells_tex)
	m.set_shader_parameter("hl_tex", _hl_tex)
	m.set_shader_parameter("surf_pal", _pal_tex)
	m.set_shader_parameter("noise_tex", _noise_tex)
	m.set_shader_parameter("grid_size", Vector2i(grid_w, grid_h))
	m.set_shader_parameter("floor_a", a)
	m.set_shader_parameter("floor_b", b)
	m.set_shader_parameter("floor_dark", Color(str(style.get("dark", a.darkened(0.28).to_html(false)))))
	m.set_shader_parameter("floor_light", Color(str(style.get("light", a.lightened(0.12).to_html(false)))))
	m.set_shader_parameter("speck", Color(str(style.get("speck", Color(a.r * 1.15, a.g * 1.4, a.b * 1.05).to_html(false)))))
	bg_color = Color(str(style["bg"])) if style.has("bg") else a.darkened(0.8)
	m.set_shader_parameter("outer_color", bg_color)
	# своя текстура пола из data/sprites.json (только если она задана именно для этой локации)
	var tex: Texture2D = null
	var locs: Dictionary = SpriteLibrary.bindings.get("locations", {})
	if (locs.get(loc_id, {}) as Dictionary).has("floor"):
		var fr := SpriteLibrary.frame("tiles", "floor", "idle", 0.0, "", 0, loc_id)
		if not fr.is_empty():
			tex = fr["texture"]
	m.set_shader_parameter("use_floor_tex", tex != null)
	if tex != null:
		m.set_shader_parameter("floor_tex", tex)
		m.set_shader_parameter("floor_tex_cells", float(SpriteLibrary.setting("texture_cells", 3)))
	update_cells(true)


func _draw_ground() -> void:
	if grid_w > 0:
		_ground.draw_rect(_bounds.grow(TW * 12), Color.WHITE)


## Клетки -> маленькая текстура для шейдера: стены, поверхности, выходы.
func update_cells(force := false) -> void:
	if session == null or session.grid == null or _cells_img == null:
		return
	var g := session.grid
	var parts := PackedStringArray()
	for c in g.layers["ground"]:
		parts.append("%d,%d:%s" % [c.x, c.y, g.get_ground(c)])
	parts.sort()
	var key := ",".join(parts) + "|" + str(session.flags.size())
	if key == _cells_key and not force:
		return
	_cells_key = key
	for y in grid_h:
		for x in grid_w:
			var c := Vector2i(x, y)
			var surf := g.get_ground(c)
			var idx := int(_surf_index.get(surf, 0))
			var blocked := 1.0 if g.blocked.has(c) else 0.0
			var ex := 1.0 if not session.exit_at(c).is_empty() else 0.0
			_cells_img.set_pixel(x, y, Color(blocked, float(idx) / 255.0, ex, 1.0))
	_cells_tex.update(_cells_img)


func _update_highlights() -> void:
	if _hl_img == null:
		return
	var key := "%s|%s|%s|%s|%s" % [hl_move.size(), hl_range.size(), str(hl_aoe.keys()), str(hl_path), grid_lines]
	if key != _hl_key:
		_hl_key = key
		_hl_img.fill(Color(0, 0, 0, 0))
		for c in hl_move:
			_hl_or(c, 0)
		for c in hl_range:
			_hl_or(c, 1)
		for c in hl_aoe:
			_hl_or(c, 2)
		for c in hl_path:
			_hl_or(c, 3)
		_hl_tex.update(_hl_img)
	_ground_mat.set_shader_parameter("grid_alpha", 0.18 if grid_lines else 0.0)
	_ground_mat.set_shader_parameter("hover", Vector2(hover_cell) if hover_uid == "" and hover_object == "" else Vector2(-99, -99))


func _hl_or(c: Vector2i, channel: int) -> void:
	if c.x < 0 or c.y < 0 or c.x >= grid_w or c.y >= grid_h:
		return
	var col := _hl_img.get_pixel(c.x, c.y)
	match channel:
		0: col.r = 1.0
		1: col.g = 1.0
		2: col.b = 1.0
		3: col.a = 1.0
	_hl_img.set_pixel(c.x, c.y, col)


func _build_props(data: Dictionary) -> void:
	var style: Dictionary = data.get("style", {})
	var wall_style := str(style.get("wall", "stone"))
	var walls: Array = data.get("walls", [])
	for w in walls:
		var c := Vector2i(int(w[0]), int(w[1]))
		var p := _add_prop("wall", wall_style, c, Vector2i.ONE)
		p.style = wall_style
		p.animated = wall_style == "tree"
	var list: Array = data.get("props", [])
	for pd in list:
		if not pd.has("cell"):
			continue
		var c := Vector2i(int(pd["cell"][0]), int(pd["cell"][1]))
		var size_a: Array = pd.get("size", [1, 1])
		_add_prop("prop", str(pd.get("id", "")), c, Vector2i(int(size_a[0]), int(size_a[1])))
	var objs: Array = data.get("objects", [])
	for od in objs:
		if not od.has("cell"):
			continue
		var c := Vector2i(int(od["cell"][0]), int(od["cell"][1]))
		var size_a: Array = od.get("size", [1, 1])
		var p := _add_prop("object", str(od.get("id", "")), c, Vector2i(int(size_a[0]), int(size_a[1])))
		p.look = str(od.get("look", ""))
		objects[p.id] = p


## Дома, в которые можно войти: по узлу на клетку стены и двери (сортируются с фигурками) и крыша над домом.
## Если у дома есть рисунок (props/<sprite>), снаружи виден он, а стены и пол комнат появляются, когда внутри герой.
func _build_houses(data: Dictionary) -> void:
	var list: Array = data.get("buildings", [])
	for b in list:
		var r: Array = b["rect"]
		var rect := Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3]))
		var doors := {}
		for d in b.get("doors", []):
			doors[Vector2i(int(d[0]), int(d[1]))] = true
		var sprite := _house_sprite(b)
		var house := {"def": b, "rect": rect, "doors": doors, "open": 0.0, "ghost": 0.0, "nodes": [], "shell": sprite != ""}
		for cell in LocationData.building_perimeter(r):
			var c := Vector2i(int(cell[0]), int(cell[1]))
			var p := _add_prop("hdoor" if doors.has(c) else "hwall", "house:" + str(b["id"]), c, Vector2i.ONE)
			p.house = house
			p.animated = false
			p.visible = sprite == ""
			house["nodes"].append(p)
		var top: PropNode
		if sprite != "":
			top = _add_prop("hshell", sprite, rect.position, rect.size)
			top.animated = doors.keys().any(func(dc): return BuildingArt.is_front(house, dc))   # фонарь у двери мерцает
		else:
			top = _add_prop("roof", "roof:" + str(b["id"]), rect.position, rect.size)
			buildings.erase(top)   # крыша выше роста героев и стоящих перед домом не закрывает: порядок постоянный
			top.animated = bool(b.get("chimney", false))
		top.house = house
		house["nodes"].append(top)
		houses.append(house)


## Рисунок дома снаружи: первый из "sprite" (строка или список), что есть в data/sprites.json и подходит по размеру;
## "" — дом рисуется кодом. Рисунок не растягивается: его ширина в родном масштабе должна совпадать с шириной
## дома на карте ((w + h) * TW / 2) с точностью SHELL_FIT, иначе пиксели расплываются в кашу — тогда лучше стены кодом.
func _house_sprite(b: Dictionary) -> String:
	var v: Variant = b.get("sprite", "")
	var ids: Array = v if typeof(v) == TYPE_ARRAY else [v]
	var size: Array = b.get("size", [b["rect"][2], b["rect"][3]])
	var want := (float(size[0]) + float(size[1])) * TW * 0.5
	for id in ids:
		var fr := SpriteLibrary.frame("props", str(id)) if str(id) != "" else {}
		if fr.is_empty():
			continue
		var w := (fr["region"] as Rect2).size.x * float(fr["scale"])
		if absf(w / want - 1.0) <= SHELL_FIT:
			return str(id)
	return ""


## Дверь дома, к которой идти по клику на дом: сначала дверь на видимой стороне.
func house_door(h: Dictionary) -> Vector2i:
	var best := Vector2i(-99, -99)
	for d in h["doors"]:
		var dc: Vector2i = d
		if best.x < -90 or (BuildingArt.is_front(h, dc) and not BuildingArt.is_front(h, best)):
			best = dc
	return best


## Дом, в котором клетка (комната или дверь), или пустой словарь.
func house_at(c: Vector2i) -> Dictionary:
	for h in houses:
		if BuildingArt.is_room(h, c) or (h["doors"] as Dictionary).has(c):
			return h
	return {}


## Крыша тает, когда в доме герой; дом просвечивает, когда за ним стоит герой; жителей под крышей не видно.
## У дома с рисунком снаружи тает рисунок, а стены комнат и пол проявляются.
func _update_houses(delta: float) -> void:
	if houses.is_empty() or session == null:
		return
	for h in houses:
		var house: Dictionary = h
		var rect: Rect2i = house["rect"]
		var inside := false
		var behind := false
		var top: PropNode = (house["nodes"] as Array)[-1]
		var shape := Rect2(top.position + Vector2(0, top.base.y - top.position.y) + top.rect.position, top.rect.size)
		for hero in session.heroes:
			var hc: Character = hero
			# где герой на экране (сервер уже довёл его до цели, а фигурка ещё идёт): крыша тает, когда он у двери
			var at := world_to_cell((units[hc.uid] as UnitNode).position) if units.has(hc.uid) else hc.cell
			if BuildingArt.is_room(house, at) or (house["doors"] as Dictionary).has(at):
				inside = true
			elif (hc.cell.x < rect.position.x or hc.cell.y < rect.position.y) and units.has(hc.uid) \
					and shape.has_point((units[hc.uid] as UnitNode).position + Vector2(0, -16)):
				behind = true
		var open := move_toward(float(house["open"]), 1.0 if inside else 0.0, delta * 5.0)
		var ghost := move_toward(float(house["ghost"]), 1.0 if behind and not inside else 0.0, delta * 4.0)
		var shell := bool(house["shell"])
		var changed := open != float(house["open"]) or ghost != float(house["ghost"])
		house["open"] = open
		house["ghost"] = ghost
		for n in house["nodes"]:
			var pn: PropNode = n
			if pn.kind == "hshell":
				var lit := 1.15 if hover_house == str(house["def"]["id"]) else 1.0
				pn.modulate = Color(lit, lit, lit * 0.95, (1.0 - open) * (1.0 - 0.55 * ghost))
				pn.visible = pn.modulate.a > 0.01
			elif shell:
				pn.modulate.a = open
				pn.visible = open > 0.01
			else:
				pn.modulate.a = 1.0 - 0.5 * ghost
			if changed:
				pn.queue_redraw()
		if changed and shell:
			_floors.queue_redraw()
	for u in units.values():
		var n: UnitNode = u
		var c := n.ch()
		if c == null:
			continue
		var hs := house_at(c.cell)
		n.visible = hs.is_empty() or float(hs["open"]) > 0.5 or session.heroes.has(c)


## Пол комнат: доски (tiles/planks), в каменных домах кладка (tiles/masonry); без картинок — рисованные доски.
func _draw_floors() -> void:
	for h in houses:
		var alpha := float(h["open"]) if bool(h["shell"]) else 1.0
		if alpha <= 0.01:
			continue
		var stone := str((h["def"] as Dictionary).get("material", "")) == "stone"
		var fr := SpriteLibrary.frame("tiles", "masonry" if stone else "planks")
		var rect: Rect2i = h["rect"]
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var c := Vector2i(x, y)
				if not (BuildingArt.is_room(h, c) or (h["doors"] as Dictionary).has(c)):
					continue
				if fr.is_empty():
					BuildingArt.draw_floor(_floors, corners(c), variant_of(c), alpha)
					continue
				var tex: Texture2D = fr["texture"]
				var reg: Rect2 = fr["region"]
				var u0 := Vector2(posmod(x, 3), posmod(y, 3)) / 3.0
				var uvs := PackedVector2Array()
				for k in [Vector2.ZERO, Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
					uvs.append((reg.position + (u0 + k / 3.0) * reg.size) / tex.get_size())
				_floors.draw_polygon(corners(c), PackedColorArray([Color(0.85, 0.8, 0.75, alpha)]), uvs, tex)


func _add_prop(kind: String, id: String, c: Vector2i, size: Vector2i) -> PropNode:
	var p := PropNode.new()
	p.view = self
	p.kind = kind
	p.id = id
	p.cell = c
	p.size = size
	p.variant = variant_of(c)
	if size.x > 1 or size.y > 1:
		p.base = grid_point(c.x + size.x, c.y + size.y)
		p.sort_key = p.base.y - 1.0
		buildings.append(p)
	else:
		p.base = cell_center(c)
		p.sort_key = p.base.y
	p.corners = corners(c, size)
	for i in p.corners.size():
		p.corners[i] -= p.base
	p.position = Vector2(p.base.x, p.sort_key)
	p.animated = LIGHT_PROPS.has(id) or id.begins_with("waystone") \
		or id in ["smithy", "tavern", "church", "house", "bell_tower", "tree", "reeds", "bush", "goat_stump", "hearth", "altar",
			"oven", "cauldron"]
	if LIGHT_PROPS.has(id):
		var lp: Array = LIGHT_PROPS[id]
		lights.append({"pos": p.base + Vector2(0, -8), "radius": float(lp[0]), "color": Color(str(lp[1])), "node": p})
	_entities.add_child(p)
	props.append(p)
	return p


# --- Фигурки -----------------------------------------------------------------------------

## Создать фигурки для новых персонажей и убрать ушедших.
func sync_units() -> void:
	if session == null:
		return
	var seen := {}
	for u in session.all_units():
		var ch: Character = u
		seen[ch.uid] = true
		if not units.has(ch.uid):
			var n := UnitNode.new()
			n.view = self
			n.uid = ch.uid
			n.template = ch.template_id
			n.is_hero = session.heroes.has(ch)
			n.facing = 1 if n.is_hero else -1
			n.shown_hp = ch.hp
			n.position = cell_center(ch.cell)
			n.appear = 1.0 if _building else 0.0
			n.rising = ch.template_id in ["risen", "skeleton", "drowned", "lado_body"] \
				or str(GameData.character(ch.template_id).get("type", "")) == "undead"
			units[ch.uid] = n
			_entities.add_child(n)
	for uid in units.keys():
		if not seen.has(uid):
			(units[uid] as UnitNode).queue_free()
			units.erase(uid)


func unit_node(uid: String) -> UnitNode:
	return units.get(uid) as UnitNode


func unit_pos(uid: String) -> Vector2:
	var n := unit_node(uid)
	return n.position if n != null else Vector2.ZERO


# --- Анимации (их вызывает GameScreen по событиям) ------------------------------------

## Пройти по клеткам. Возвращает длительность.
func walk(uid: String, cells: Array, speed_k := 1.0) -> float:
	var n := unit_node(uid)
	if n == null or cells.is_empty():
		return 0.0
	var dist := 0.0
	var last := n.position if n.path.is_empty() else (n.path[-1] as Vector2)
	for c in cells:
		var p := cell_center(Vector2i(int(c[0]), int(c[1])))
		dist += last.distance_to(p)
		last = p
		n.path.append(p)
	n.speed = WALK_SPEED * speed_k
	return dist / n.speed


## Прыжок навыком (Отскок): фигурка летит дугой в клетку, тень остаётся на земле. Возвращает время полёта.
func leap(uid: String, cells: Array) -> float:
	var n := unit_node(uid)
	if n == null or cells.is_empty():
		return 0.0
	var c: Array = cells[-1]
	var p := cell_center(Vector2i(int(c[0]), int(c[1])))
	var dist := n.position.distance_to(p)
	n.path = [p]
	n.hop_len = maxf(1.0, dist)
	n.hop = clampf(dist * 0.35, 10.0, 40.0)
	n.speed = maxf(WALK_SPEED, dist / 0.45)
	return dist / n.speed


## Смена цели на ходу: сервер вернул героя на клетку cell. Фигурка доходит до неё и дальше идёт уже новым путём.
func cut_walk(uid: String, cell: Vector2i) -> void:
	var n := unit_node(uid)
	if n == null:
		return
	var p := cell_center(cell)
	var i := n.path.find(p)
	if i >= 0:
		n.path.resize(i + 1)
	elif n.position.distance_to(p) > 0.5:
		n.path = [p]   # ответ по сети опоздал и фигурка уже прошла эту клетку: вернётся к ней


## Клетки, к которым сейчас идут фигурки героев uids: {uid: [x, y]} (для смены цели на ходу).
func walk_heads(uids: Array) -> Dictionary:
	var out := {}
	for uid in uids:
		var n := unit_node(str(uid))
		if n != null and not n.path.is_empty():
			var c := world_to_cell(n.path[0])
			out[str(uid)] = [c.x, c.y]
	return out


## Сколько ещё секунд фигуркам идти.
func walk_time_left() -> float:
	var t := 0.0
	for u in units.values():
		var n: UnitNode = u
		var d := 0.0
		var last := n.position
		for p in n.path:
			d += last.distance_to(p)
			last = p
		t = maxf(t, d / maxf(1.0, n.speed))
	return t


## Заняты только ходьбой (нет снарядов и выпадов): новую команду можно слать сразу, со сменой цели.
func only_walking() -> bool:
	if not projectiles.is_empty():
		return false
	for u in units.values():
		var n: UnitNode = u
		if n.lunge_t >= 0.0 and n.lunge_t < 0.3:
			return false
	return true


func lunge(uid: String, toward: Vector2) -> void:
	var n := unit_node(uid)
	if n == null:
		return
	n.face_to(toward)
	n.lunge_dir = (toward - n.position).normalized()
	n.lunge_t = 0.0


func cast_glow(uid: String, col: Color) -> void:
	var n := unit_node(uid)
	if n != null:
		n.flash(col, 0.35)


## Снаряд от a до b. kind: "arrow", "bolt", "orb". Возвращает время полёта.
func shoot(a: Vector2, b: Vector2, col: Color, kind := "bolt") -> float:
	var dur := clampf(a.distance_to(b) / 260.0, 0.12, 0.45)
	projectiles.append({"from": a, "to": b, "t": 0.0, "dur": dur, "col": col, "kind": kind})
	return dur


func hit_fx(uid: String, amount: int, element: String, crit: bool) -> void:
	var n := unit_node(uid)
	if n == null:
		return
	n.shown_hp = maxf(0.0, n.shown_hp - amount)
	n.hurt_t = 0.0
	n.flash(Color(1, 0.3, 0.25) if element in ["physical", ""] else UiTheme.element_color(element), 0.18)
	var col := UiTheme.element_color(element)
	if element in ["physical", ""]:
		col = Color("f0e0c0")
	float_text(n.head(), ("%d!" % amount) if crit else str(amount), col, 16 if crit else 8)
	var burst_col := Color("8a1c1c") if element in ["physical", ""] else col
	burst(n.position + Vector2(0, -12), burst_col, 10 if crit else 6, 50.0)
	if crit:
		shake(2.0, 0.2)


func miss_fx(uid: String) -> void:
	var n := unit_node(uid)
	if n != null:
		float_text(n.head(), "Промах", Color("b8b0a0"), 8)
		n.dodge_t = 0.0


func heal_fx(uid: String, amount: int) -> void:
	var n := unit_node(uid)
	if n == null:
		return
	n.shown_hp = minf(n.shown_hp + amount, 9999.0)
	float_text(n.head(), "+%d" % amount, UiTheme.GREEN, 8)
	for i in 8:
		particles.append({"pos": n.position + Vector2(randf_range(-8, 8), randf_range(-24, 0)),
			"vel": Vector2(0, randf_range(-26, -14)), "col": Color("a8f090"), "life": 0.0, "max": randf_range(0.5, 0.9),
			"size": 1.0, "grav": 0.0})


func death_fx(uid: String) -> void:
	var n := unit_node(uid)
	if n == null:
		return
	n.death_pending = false
	n.death_t = 0.0
	burst(n.position + Vector2(0, -8), Color("5a4a3a"), 8, 30.0)


func status_fx(uid: String, status_id: String, negative: bool) -> void:
	var n := unit_node(uid)
	if n == null:
		return
	var name := str(GameData.status(status_id).get("name", status_id))
	float_text(n.head() + Vector2(0, -10), name, IconArt.status_color(status_id) if negative else Color("d8e8ff"), 8)


func text_at_cell(c: Vector2i, text: String, col: Color) -> void:
	float_text(cell_center(c) + Vector2(0, -14), text, col, 8)


func explosion_fx(c: Vector2i) -> void:
	var p := cell_center(c)
	for i in 26:
		var a := randf() * TAU
		var sp := randf_range(30, 110)
		particles.append({"pos": p + Vector2(0, -6), "vel": Vector2(cos(a), sin(a) * 0.6) * sp,
			"col": [Color("fff0a0"), Color("ff9a30"), Color("e04a10")][i % 3], "life": 0.0, "max": randf_range(0.3, 0.7),
			"size": 2.0 if i % 4 == 0 else 1.0, "grav": 40.0})
	lights.append({"pos": p, "radius": 70.0, "color": Color("ff9a40"), "until": time + 0.35})
	shake(3.0, 0.3)


func trap_fx(c: Vector2i, trap_type: String) -> void:
	var col := Color(str(GameData.trap(trap_type).get("color", "#d0c0a0")))
	burst(cell_center(c) + Vector2(0, -4), col, 22, 70.0)
	lights.append({"pos": cell_center(c), "radius": 50.0, "color": col, "until": time + 0.3})
	shake(2.0, 0.25)


func level_up_fx(uid: String, level := 0) -> void:
	var n := unit_node(uid)
	if n == null:
		return
	float_text(n.head() + Vector2(0, -12), "Ур. %d!" % level if level > 0 else "Уровень!", Color("ffd860"), 8)
	for i in 24:
		particles.append({"pos": n.position + Vector2(randf_range(-10, 10), 0),
			"vel": Vector2(0, randf_range(-60, -25)), "col": Color("ffe080") if i % 2 else Color("fff8d0"),
			"life": 0.0, "max": randf_range(0.6, 1.2), "size": 1.0, "grav": 0.0})
	lights.append({"pos": n.position, "radius": 48.0, "color": Color("ffd060"), "until": time + 0.8})


func burst(p: Vector2, col: Color, count: int, speed: float) -> void:
	for i in count:
		var a := randf_range(PI * 1.1, PI * 1.9)
		particles.append({"pos": p, "vel": Vector2(cos(a), sin(a)) * randf_range(speed * 0.4, speed),
			"col": col.lightened(randf() * 0.2), "life": 0.0, "max": randf_range(0.25, 0.5), "size": 1.0, "grav": 160.0})


## Надписи над миром (цифры урона, названия выходов): [{"pos" — точка мира, "text", "col", "size" — в пикселях мира}].
## Мир рисуется мелко и увеличивается, а текст так расплывается, поэтому его рисует экран игры поверх, в полном разрешении.
func labels() -> Array:
	return _labels


## Ширина надписи в пикселях мира (на экране она в pixel_scale × zoom раз крупнее).
func _label_width(text: String, size: int) -> float:
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size * 2).x * 0.5


func float_text(p: Vector2, text: String, col: Color, size := 8) -> void:
	# свежие надписи не накладываются: если задевает соседнюю, встаёт выше, пока не найдёт свободное место
	var w := _label_width(text, size)
	for _i in 8:
		var moved := false
		for f in floaters:
			var fp: Vector2 = f["pos"] + _float_rise(f)
			var near_x := absf(fp.x - p.x) < (w + float(f["w"])) * 0.5 + 4.0
			if float(f["t"]) < 0.6 and near_x and absf(fp.y - p.y) < 10.0:
				p.y = fp.y - 11.0
				moved = true
		if not moved:
			break
	floaters.append({"pos": p, "text": text, "col": col, "t": 0.0, "dur": 1.1, "size": size, "w": w})


## Насколько надпись уже поднялась: быстро в первую половину жизни, потом медленно.
func _float_rise(f: Dictionary) -> Vector2:
	var k := float(f["t"]) / float(f["dur"])
	return Vector2(0, -16.0 * minf(k * 2.0, 1.0) - k * 4.0)


func shake(power: float, dur: float) -> void:
	if not bool(GameSettings.get_value("shake")):
		return
	_shake_power = maxf(_shake_power if _shake_t < _shake_dur else 0.0, power)
	_shake_t = 0.0
	_shake_dur = dur


func busy_fx() -> bool:
	if not projectiles.is_empty():
		return true
	for u in units.values():
		var n: UnitNode = u
		if not n.path.is_empty() or (n.lunge_t >= 0.0 and n.lunge_t < 0.3):
			return true
	return false


# --- Кадр --------------------------------------------------------------------------------

func _process(delta: float) -> void:
	time += delta
	if session == null:
		return
	_anim_acc += delta
	if _anim_acc >= 0.125:   # декорации живут на 8 кадрах в секунду, как в старых играх
		_anim_acc = 0.0
		for p in props:
			if (p as PropNode).animated:
				(p as PropNode).queue_redraw()
	_update_houses(delta)
	_sort_buildings()
	_update_fx(delta)
	_update_highlights()
	_update_camera(delta)
	_over.queue_redraw()
	_glow.queue_redraw()
	_traps.queue_redraw()


func _sort_buildings() -> void:
	for b in buildings:
		var p: PropNode = b
		var key := p.base.y - 1.0
		var half_w := p.size.x * TW * 0.5 + p.size.y * TW * 0.5
		var cx := grid_point(p.cell.x + p.size.x * 0.5, p.cell.y + p.size.y * 0.5).x
		for u in units.values():
			var n: UnitNode = u
			if absf(n.position.x - cx) > half_w * 0.5 + 14.0:
				continue
			var uc := world_to_cell(n.position)
			if uc.x >= p.cell.x + p.size.x or uc.y >= p.cell.y + p.size.y:
				key = minf(key, n.position.y - 0.5)
		if not is_equal_approx(p.position.y, key):
			p.position.y = key
			p.queue_redraw()


func _update_fx(delta: float) -> void:
	for f in floaters:
		f["t"] = float(f["t"]) + delta
	floaters = floaters.filter(func(f): return float(f["t"]) < float(f["dur"]))
	for uid in speech.keys():
		speech[uid]["t"] = float(speech[uid]["t"]) + delta
		if float(speech[uid]["t"]) >= float(speech[uid]["dur"]) or unit_node(uid) == null:
			speech.erase(uid)
	for pr in projectiles:
		pr["t"] = float(pr["t"]) + delta
		if float(pr["t"]) >= float(pr["dur"]):
			burst(pr["to"], pr["col"], 6, 40.0)
	projectiles = projectiles.filter(func(pr): return float(pr["t"]) < float(pr["dur"]))
	for pa in particles:
		pa["life"] = float(pa["life"]) + delta
		pa["vel"] = (pa["vel"] as Vector2) + Vector2(0, float(pa["grav"]) * delta)
		pa["pos"] = (pa["pos"] as Vector2) + (pa["vel"] as Vector2) * delta
	particles = particles.filter(func(pa): return float(pa["life"]) < float(pa["max"]))
	lights = lights.filter(func(l): return not l.has("until") or float(l["until"]) > time)
	# огонь на земле светится и дымит
	if session.grid != null and randf() < 0.5:
		for c in session.grid.layers["ground"]:
			if session.grid.get_ground(c) == "fire" and randf() < 0.08:
				particles.append({"pos": cell_center(c) + Vector2(randf_range(-8, 8), randf_range(-3, 3)),
					"vel": Vector2(randf_range(-4, 4), randf_range(-30, -16)), "col": Color("ffb040") if randf() < 0.6 else Color("6a6060"),
					"life": 0.0, "max": randf_range(0.4, 0.8), "size": 1.0, "grav": -10.0})


func _update_camera(delta: float) -> void:
	var target := focus + pan
	var view_size := get_viewport_rect().size / float(zoom)
	var margin := Vector2(48, 48)
	var lo := _bounds.position - margin + view_size * 0.5
	var hi := _bounds.end + margin - view_size * 0.5
	target.x = clampf(target.x, minf(lo.x, hi.x), maxf(lo.x, hi.x)) if lo.x <= hi.x else _bounds.get_center().x
	target.y = clampf(target.y, minf(lo.y, hi.y), maxf(lo.y, hi.y)) if lo.y <= hi.y else _bounds.get_center().y
	_cam_pos = _cam_pos.lerp(target, 1.0 - exp(-delta * 7.0))
	# камера и фигурка, за которой она следит, округляются до пикселя одинаково (округляется отставание камеры,
	# а не её место): иначе на ходу герой дрожит на пиксель взад-вперёд относительно земли
	camera.position = target.round() + (_cam_pos - target).round()
	camera.zoom = Vector2(zoom, zoom)
	if _shake_t < _shake_dur:
		_shake_t += delta
		var k := 1.0 - _shake_t / _shake_dur
		camera.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)).round() * _shake_power * k
	else:
		camera.offset = Vector2.ZERO


func snap_camera() -> void:
	_cam_pos = focus + pan
	camera.position = _cam_pos.round()


## Точка мира под точкой экрана SubViewport (в пикселях вьюпорта).
func viewport_to_world(vp: Vector2) -> Vector2:
	return (vp - get_viewport_rect().size * 0.5) / float(zoom) + camera.position + camera.offset


func world_to_viewport(p: Vector2) -> Vector2:
	return (p - camera.position - camera.offset) * float(zoom) + get_viewport_rect().size * 0.5


## Что под курсором: {"uid"} | {"object"} | {"cell"}. Фигурки и предметы выше клетки, поэтому сначала они.
## Что под курсором. Фигуры высокие и заслоняют клетки позади, поэтому: нужная сторона (враги и жители,
## а при союзном навыке — свои) выбирается по силуэту; иначе — тот, кто стоит на клетке под курсором;
## свой герой, заслоняющий свободную клетку, её не перекрывает — туда можно встать.
func pick(p: Vector2) -> Dictionary:
	hover_point = p
	var c := world_to_cell(p)
	var first: UnitNode = null     # по силуэту, нужная сторона
	var on_cell: UnitNode = null   # стоит на клетке под курсором
	var other: UnitNode = null     # по силуэту, остальные
	var bag: UnitNode = null       # мешок с добычей на месте тела
	for u in units.values():
		var n: UnitNode = u
		var ch := n.ch()
		if ch == null or not n.visible or n.appear < 0.5:
			continue
		if ch.cell == c and ch.is_alive():
			on_cell = n
		var r := Rect2(n.position + n.rect.position, n.rect.size).grow(2.0)
		if not ch.is_alive() and session.loot.has(ch.uid) and (r.has_point(p) or ch.cell == c):
			bag = n
		if not r.has_point(p):
			continue
		var preferred := ch.is_alive() and session.heroes.has(ch) == (pick_prefer == "ally")
		if preferred:
			if first == null or n.position.y > first.position.y:
				first = n
		elif other == null or n.position.y > other.position.y:
			other = n
	var best := first if first != null else on_cell
	if best == null and bag != null and session.mode == "explore":
		best = bag
	if best == null and other != null and not _free_floor(c):
		best = other
	if best != null:
		return {"uid": best.uid, "cell": best.ch().cell}
	for id in objects:
		var o: PropNode = objects[id]
		var r := Rect2(o.position + Vector2(0, o.base.y - o.position.y) + o.rect.position, o.rect.size)
		if r.has_point(p) or (c.x >= o.cell.x and c.y >= o.cell.y and c.x < o.cell.x + o.size.x and c.y < o.cell.y + o.size.y):
			return {"object": id, "cell": c}
	# закрытый дом с рисунком: курсор на самом рисунке — значит, к его двери. Улица за домом остаётся улицей
	# (герой зайдёт за дом, дом просветит), а из перекрывающихся рисунков берётся передний.
	if session.grid.is_walkable(c) and session.building_at(c).is_empty():
		return {"cell": c}
	var hit: Dictionary = {}
	var hit_y := -1e9
	for h in houses:
		if not bool(h["shell"]) or float(h["open"]) > 0.5 or float(h["ghost"]) > 0.5 or house_door(h).x < -90:
			continue
		var top: PropNode = (h["nodes"] as Array)[-1]
		if top.base.y > hit_y and top.shell_hit(p):
			hit = h
			hit_y = top.base.y
	if not hit.is_empty():
		return {"house": str(hit["def"]["id"]), "cell": house_door(hit)}
	return {"cell": c}


func _free_floor(c: Vector2i) -> bool:
	return session.grid.in_bounds(c) and session.grid.is_walkable(c) and session.unit_at(c) == null


# --- Рисование поверх: облака, снаряды, частицы, цифры ----------------------------------------

func _draw_over() -> void:
	_labels = []
	if session == null or session.grid == null:
		return
	var g := session.grid
	for c in g.layers["cloud"]:
		var cl := g.get_cloud(c)
		if cl != "none":
			_draw_cloud(c, cl)
	_draw_exits()
	for pr in projectiles:
		var k := float(pr["t"]) / float(pr["dur"])
		var a: Vector2 = pr["from"]
		var b: Vector2 = pr["to"]
		var p := a.lerp(b, k) + Vector2(0, -sin(k * PI) * 10.0)
		var col: Color = pr["col"]
		match str(pr["kind"]):
			"arrow":
				var dir := (b - a).normalized()
				_over.draw_line(p.round(), (p - dir * 6.0).round(), Color("d8c8a0"), 1.0)
				_over.draw_rect(Rect2(p.round() - Vector2(1, 1), Vector2(2, 2)), Color("e8e8f0"))
			_:
				for i in 4:
					var tp := a.lerp(b, maxf(0.0, k - i * 0.05)) + Vector2(0, -sin(maxf(0.0, k - i * 0.05) * PI) * 10.0)
					var s := 3.0 - i * 0.6
					_over.draw_rect(Rect2(tp.round() - Vector2(s, s) * 0.5, Vector2(s, s)), col.lightened(0.3) if i == 0 else Color(col, 0.7 - i * 0.15))
	for pa in particles:
		var pc: Color = pa["col"]
		var fade := 1.0 - float(pa["life"]) / float(pa["max"])
		var s := float(pa["size"])
		_over.draw_rect(Rect2((pa["pos"] as Vector2).round(), Vector2(s, s)), Color(pc, clampf(fade * 1.4, 0.0, 1.0)))
	for f in floaters:
		var k := float(f["t"]) / float(f["dur"])
		var p: Vector2 = (f["pos"] as Vector2) + _float_rise(f)
		var col: Color = f["col"]
		col.a = 1.0 if k < 0.7 else (1.0 - k) / 0.3
		_labels.append({"pos": p, "text": str(f["text"]), "col": col, "size": int(f["size"])})
	for uid in speech:
		var n := unit_node(uid)
		if n == null or not n.visible or n.modulate.a < 0.5:
			continue
		var sp: Dictionary = speech[uid]
		var k := float(sp["t"]) / float(sp["dur"])
		var a := clampf(float(sp["t"]) * 6.0, 0.0, 1.0) * (1.0 if k < 0.85 else (1.0 - k) / 0.15)
		_labels.append({"pos": n.head() + Vector2(0, -10), "text": str(sp["text"]), "col": Color(0.17, 0.11, 0.06, a),
			"size": 7, "bubble": true})


## Реплика над головой персонажа (облачко с текстом).
func say(uid: String, text: String, dur := -1.0) -> void:
	if unit_node(uid) == null or text == "":
		return
	speech[uid] = {"text": text, "t": 0.0, "dur": dur if dur > 0.0 else clampf(2.0 + text.length() * 0.06, 3.0, 6.5)}


## Выходы: стрелка наружу и название места, куда ведёт дорога (видно издалека, как указатели в D:OS).
func _draw_exits() -> void:
	var center := grid_point(grid_w * 0.5, grid_h * 0.5)
	for ex in session.location_data().get("exits", []):
		var cells: Array = ex.get("cells", [])
		if cells.is_empty() or session.exit_at(Vector2i(int(cells[0][0]), int(cells[0][1]))).is_empty():
			continue
		var p := Vector2.ZERO
		for c in cells:
			p += cell_center(Vector2i(int(c[0]), int(c[1])))
		p /= float(cells.size())
		var dir := (p - center).normalized()
		var bob := sin(time * 3.0) * 1.5
		var tip := p + dir * (6.0 + bob)
		var side := Vector2(-dir.y, dir.x) * 4.0
		var col := Color("f0c860")
		_over.draw_colored_polygon(PackedVector2Array([tip + dir * 5.0, tip + side, tip - side]), col)
		_over.draw_polyline(PackedVector2Array([tip + dir * 5.0, tip + side, tip - side, tip + dir * 5.0]), Color("120c0a"), 1.0)
		var dest := str(GameData.location(str(ex.get("to", ""))).get("name", ex.get("to", "")))
		_labels.append({"pos": p + Vector2(0, -14), "text": dest, "col": Color("ecdfc2"), "size": 8})


## Найденные ловушки на земле: ромбик цвета ловушки с мерцающей рамкой; обезвреженные и сработавшие тусклые.
func _draw_traps() -> void:
	if session == null or session.grid == null:
		return
	for c in session.grid.traps:
		var t: Dictionary = session.grid.traps[c]
		var state := str(t["state"])
		if state == "hidden":
			continue
		var p := cell_center(c).round()
		var col := Color(str(GameData.trap(str(t["type"])).get("color", "#d0c0a0")))
		var pts := PackedVector2Array([p + Vector2(0, -5), p + Vector2(10, 0), p + Vector2(0, 5), p + Vector2(-10, 0)])
		var loop := pts.duplicate()
		loop.append(pts[0])
		match state:
			"found":
				var pulse := 0.55 + 0.4 * sin(time * 5.0 + float(c.x))
				_traps.draw_colored_polygon(pts, Color(0.08, 0.06, 0.05, 0.85))
				_traps.draw_polyline(loop, Color("ff6a40") if hover_cell == c else Color(col, pulse), 1.0)
				for i in 3:
					_traps.draw_rect(Rect2(p + Vector2(-4 + i * 3, -1), Vector2(1, 2)), col)
			"disarmed":
				_traps.draw_colored_polygon(pts, Color(0.1, 0.09, 0.08, 0.5))
				_traps.draw_line(p + Vector2(-4, -2), p + Vector2(4, 2), Color(col, 0.45), 1.0)
				_traps.draw_line(p + Vector2(-4, 2), p + Vector2(4, -2), Color(col, 0.45), 1.0)
			_:
				_traps.draw_colored_polygon(pts, Color(0.06, 0.05, 0.04, 0.45))


func _draw_cloud(c: Vector2i, id: String) -> void:
	var col := Color(str(CLOUD_COLORS.get(id, str(GameData.surface(id).get("color", "#dddddd")).trim_prefix("#"))))
	var p := cell_center(c) + Vector2(0, -10)
	var v := variant_of(c)
	for i in 3:
		var ph := time * 0.8 + v * 0.37 + i * 2.1
		var o := Vector2(sin(ph) * 5.0 + (i - 1) * 7.0, cos(ph * 0.7) * 2.0 - i * 2.0)
		var r := 7.0 + float((v + i) % 3)
		var alpha := 0.32 + 0.08 * sin(ph * 1.3)
		PixelArt._blob_soft(_over, (p + o).round(), r, r * 0.6, Color(col, alpha))
	if id.begins_with("electrified") and fmod(time * 7.0 + v, 3.0) < 0.4:
		var a := p + Vector2(-6, -2)
		_over.draw_line(a.round(), (a + Vector2(5, 4)).round(), Color("fffde0"), 1.0)
		_over.draw_line((a + Vector2(5, 4)).round(), (a + Vector2(9, 1)).round(), Color("fffde0"), 1.0)


func _draw_glow() -> void:
	for l in lights:
		var node: Variant = l.get("node")
		if node is PropNode and not (node as PropNode).is_lit():
			continue
		var r := float(l["radius"]) * (1.0 + 0.06 * sin(time * 9.0 + float(l["radius"])))
		var col: Color = l["color"]
		var p: Vector2 = l["pos"]
		for i in 3:
			var rr := r * (1.0 - i * 0.3)
			_glow.draw_set_transform(p.round(), 0.0, Vector2(1.0, 0.55))
			_glow.draw_circle(Vector2.ZERO, rr, Color(col, 0.07))
		_glow.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if session != null and session.grid != null:
		for c in session.grid.layers["ground"]:
			if session.grid.get_ground(c) == "fire":
				_glow.draw_set_transform(cell_center(c).round(), 0.0, Vector2(1.0, 0.55))
				_glow.draw_circle(Vector2.ZERO, 22.0 + 2.0 * sin(time * 11.0 + c.x), Color(1.0, 0.5, 0.15, 0.09))
				_glow.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for pr in projectiles:
		var k := float(pr["t"]) / float(pr["dur"])
		var p := (pr["from"] as Vector2).lerp(pr["to"], k)
		if str(pr["kind"]) != "arrow":
			_glow.draw_circle(p.round(), 10.0, Color(pr["col"], 0.18))


# =========================================================================================

## Декорация, стена, дом или предмет на карте.
class PropNode extends Node2D:
	var view: WorldView
	var kind := "prop"        # wall | prop | object | hwall | hdoor | roof | hshell (дом снаружи рисунком)
	var id := ""
	var look := ""            # как выглядит предмет, если не по своему id (сундуки в домах — "chest")
	var style := ""
	var cell := Vector2i.ZERO
	var size := Vector2i.ONE
	var variant := 0
	var base := Vector2.ZERO  # точка опоры в мире (центр клетки или ближний угол дома)
	var sort_key := 0.0
	var corners := PackedVector2Array()
	var animated := false
	var rect := Rect2()
	var house: Dictionary = {}   # для частей дома (hwall, hdoor, roof): общий словарь дома из WorldView.houses

	func is_lit() -> bool:
		if id.begins_with("waystone"):
			return view.session != null and view.session.flags.has("wp:" + id)
		if id == "pyre":
			return view.session != null and (view.session.flags.has("pyre_lit") or view.session.flags.has("lado_farewell") \
				or view.lit_flags.has(id))
		return true

	func _draw() -> void:
		var off := Vector2(0, base.y - position.y)
		var hovered := kind == "object" and view.hover_object == id
		var t := view.time
		if kind == "wall":
			draw_set_transform(off)
			PixelArt.draw_wall(self, style, corners, 1.0, t, variant)
			rect = Rect2(-16, -40, 32, 44)
			draw_set_transform(Vector2.ZERO)
			return
		if kind == "hshell":
			draw_set_transform(off)
			rect = _draw_shell(off, t)
			draw_set_transform(Vector2.ZERO)
			return
		if kind in ["hwall", "hdoor", "roof"]:
			draw_set_transform(off)
			match kind:
				"hwall":
					rect = BuildingArt.draw_wall(self, house, cell, corners, variant, t)
				"hdoor":
					rect = BuildingArt.draw_door(self, house, cell, corners, t)
				_:
					rect = BuildingArt.draw_roof(self, house, corners, t)
			draw_set_transform(Vector2.ZERO)
			return
		var art := look if look != "" else ("waystone" if id.begins_with("waystone") else id)
		var fr := SpriteLibrary.frame("props", art, "idle", t, "", variant)
		if hovered:
			modulate = Color(1.35, 1.3, 1.1)
		else:
			modulate = Color.WHITE
		draw_set_transform(off)
		if not fr.is_empty():
			var region: Rect2 = fr["region"]
			var sc := float(fr["scale"])
			if size.x > 1 or size.y > 1:   # постройка не уже своего места на карте, иначе жители выше домов
				sc = maxf(sc, (size.x + size.y) * WorldView.TW * 0.5 * 0.95 / maxf(1.0, region.size.x))
			var sz: Vector2 = region.size * sc
			var dest := Rect2(Vector2(-sz.x * 0.5, -sz.y) + (fr["offset"] as Vector2), sz)
			draw_texture_rect_region(fr["texture"], dest, region)
			rect = dest
		elif size.x > 1 or size.y > 1:
			rect = PixelArt.draw_prop(self, art, Vector2.ZERO, 1.0, t, variant, corners, is_lit())
		else:
			rect = PixelArt.draw_prop(self, art, Vector2.ZERO, 1.0, t, variant, PackedVector2Array(), is_lit())
		if kind == "object" and view.session != null and _interactive():
			# маркер «здесь есть что посмотреть»
			var bob := roundf(sin(t * 3.0) * 1.5)
			var top := rect.position.y - 6.0 + bob
			var gold := Color("f0c860") if not hovered else Color("fff4c0")
			draw_rect(Rect2(-1, top, 3, 3), Color("120c0a"))
			draw_rect(Rect2(-2, top + 1, 5, 1), Color("120c0a"))
			draw_rect(Rect2(0, top + 1, 1, 1), gold)
			draw_rect(Rect2(-1, top + 1, 1, 1), gold.darkened(0.2))
			draw_rect(Rect2(1, top + 1, 1, 1), gold.darkened(0.2))
			draw_rect(Rect2(0, top, 1, 1), gold.darkened(0.2))
			draw_rect(Rect2(0, top + 2, 1, 1), gold.darkened(0.2))
		draw_set_transform(Vector2.ZERO)

	## Дом снаружи: рисунок на всё место дома (не уже, иначе жители выше домов) и двери поверх — там, где они на карте.
	func _draw_shell(off: Vector2, t: float) -> Rect2:
		var fr := SpriteLibrary.frame("props", id, "idle", t, "", variant)
		if fr.is_empty():
			return Rect2()
		var region: Rect2 = fr["region"]
		var sc := float(fr["scale"])   # родной масштаб: рисунок подобран по размеру дома (_house_sprite)
		var sz: Vector2 = region.size * sc
		# низ рисунка — ближний угол дома, середина по ширине — середина ромба дома (у вытянутого дома она сбоку от угла)
		var mid := float(size.y - size.x) * WorldView.TW * 0.25
		var dest := Rect2(Vector2(mid - sz.x * 0.5, -sz.y) + (fr["offset"] as Vector2), sz)
		if bool((house.get("def", {}) as Dictionary).get("flip", false)):
			draw_set_transform(off, 0.0, Vector2(-1, 1))
		draw_texture_rect_region(fr["texture"], dest, region)
		draw_set_transform(off)
		var drawn := bool(fr.get("doors", false))   # двери нарисованы на самом доме: поверх только свет фонаря
		for d in house.get("doors", {}):
			var dc: Vector2i = d
			if BuildingArt.is_front(house, dc):
				var c := WorldView.corners(dc)
				for i in c.size():
					c[i] -= base
				if drawn:
					BuildingArt.draw_door_glow(self, house, dc, c, t)
				else:
					BuildingArt.draw_shell_door(self, house, dc, c, t)
		return dest

	## Курсор (точка мира p) на непрозрачной части рисунка дома, а не на пустом месте вокруг.
	func shell_hit(p: Vector2) -> bool:
		var q := p - Vector2(position.x, base.y)
		if bool((house.get("def", {}) as Dictionary).get("flip", false)):
			q.x = -q.x
		if not rect.has_point(q):
			return false
		var fr := SpriteLibrary.frame("props", id, "idle", view.time, "", variant)
		if fr.is_empty():
			return false
		var img := WorldView.image_of(fr["texture"])
		if img == null:
			return true
		var region: Rect2 = fr["region"]
		var px := Vector2i(region.position + (q - rect.position) / maxf(0.01, float(fr["scale"])))
		px = px.clamp(Vector2i.ZERO, img.get_size() - Vector2i.ONE)
		return img.get_pixelv(px).a > 0.3

	func _interactive() -> bool:
		for o in view.session.visible_objects():
			if str(o.get("id", "")) == id:
				return true
		return false


## Фигурка персонажа: тень, кольцо выбора, сам персонаж, полоска здоровья, статусы.
class UnitNode extends Node2D:
	var view: WorldView
	var uid := ""
	var template := ""
	var is_hero := false
	var facing := 1
	var path: Array = []
	var speed := 120.0
	var lunge_t := -1.0
	var lunge_dir := Vector2.ZERO
	var hop := 0.0        # высота дуги прыжка (WorldView.leap), 0 — идёт ногами
	var hop_len := 1.0
	var hurt_t := 9.0
	var dodge_t := 9.0
	var flash_t := 9.0
	var flash_dur := 0.2
	var flash_col := Color.WHITE
	var death_t := 9.0
	var death_pending := false
	var appear := 1.0
	var rising := false
	var shown_hp := 0.0
	var rect := Rect2(-9, -36, 18, 36)
	var _walk_t := 0.0
	var _last_cell := Vector2i(-999, -999)

	func ch() -> Character:
		return view.session.unit_by_uid(uid) if view.session != null else null

	func head() -> Vector2:
		return position + Vector2(0, rect.position.y - 4.0)

	func face_to(p: Vector2) -> void:
		var dx := p.x - position.x
		if absf(dx) > 0.5:
			facing = 1 if dx > 0.0 else -1

	func flash(col: Color, dur: float) -> void:
		flash_col = col
		flash_dur = dur
		flash_t = 0.0

	func snap() -> void:
		var c := ch()
		if c != null:
			position = WorldView.cell_center(c.cell)
			shown_hp = c.hp
			_last_cell = c.cell

	func _process(delta: float) -> void:
		var c := ch()
		if c == null:
			return
		var moving := not path.is_empty()
		if moving:
			var target: Vector2 = path[0]
			face_to(target)
			var step := speed * delta
			var d := position.distance_to(target)
			if d <= step:
				position = target
				path.pop_front()
				if path.is_empty():
					hop = 0.0
					GameAudio.sfx("footstep", -4.0)
				elif randf() < 0.35:
					GameAudio.sfx("footstep", -8.0)
			else:
				position += (target - position) / d * step
			_walk_t += delta
		elif view.idle:
			var want := WorldView.cell_center(c.cell)
			if position.distance_to(want) > 0.5:
				position = want
			shown_hp = move_toward(shown_hp, c.hp, maxf(1.0, absf(shown_hp - c.hp)) * delta * 6.0)
		if lunge_t >= 0.0:
			lunge_t += delta
			if lunge_t > 0.3:
				lunge_t = -1.0
		hurt_t += delta
		dodge_t += delta
		flash_t += delta
		death_t += delta
		if appear < 1.0:
			appear = minf(1.0, appear + delta * (1.2 if rising else 2.5))
			if rising and randf() < 0.5:
				view.particles.append({"pos": position + Vector2(randf_range(-8, 8), 0), "vel": Vector2(randf_range(-20, 20), randf_range(-50, -20)),
					"col": Color("4a3a26"), "life": 0.0, "max": 0.5, "size": 1.0, "grav": 140.0})
		queue_redraw()

	func _draw() -> void:
		var c := ch()
		if c == null:
			return
		var t := view.time + float(absi(uid.hash()) % 97) * 0.071
		var dead := not c.is_alive() and not death_pending
		var off := Vector2.ZERO
		if lunge_t >= 0.0:
			off += lunge_dir * sin(lunge_t / 0.3 * PI) * 7.0
		if hurt_t < 0.2:
			off += Vector2(-facing * 2.0 * (1.0 - hurt_t / 0.2), 0)
		if dodge_t < 0.25:
			off += Vector2(-facing * 4.0 * sin(dodge_t / 0.25 * PI), 0)
		var walking := not path.is_empty()
		if walking and hop > 0.0:
			off.y -= sin(clampf(1.0 - position.distance_to(path[-1]) / hop_len, 0.0, 1.0) * PI) * hop
		elif walking:
			off.y -= 1.0 if int(_walk_t * 10.0) % 2 == 0 else 0.0
		off = off.round()
		var tint := Color.WHITE
		if flash_t < flash_dur:
			var k := 1.0 - flash_t / flash_dur
			tint = Color.WHITE.lerp(flash_col * 1.6, k * 0.8)
		if appear < 1.0:
			tint.a = appear
			if rising:
				off.y += roundf((1.0 - appear) * 12.0)
		# курсор за фигурой и метит не в неё: фигура просвечивает, видно клетку или цель позади
		if view.hover_uid != uid and Rect2(position + rect.position, rect.size).has_point(view.hover_point):
			tint.a *= 0.4
		# тень
		if not dead:
			_shadow(Vector2(0, 0), 7.0 if not PixelArt.look(template).has("beast") else 9.0)
		# кольца: текущий ход, выбранный, под курсором, цель навыка
		var ring := Color(0, 0, 0, 0)
		if view.current_uid == uid and not dead:
			ring = Color("f0c860").lerp(Color("fff4c0"), 0.5 + 0.5 * sin(view.time * 6.0))
		elif view.target_uids.has(uid):
			ring = Color("ff6a4a")
		elif view.selected_uid == uid and not dead:
			ring = Color("e8e0d0")
		elif view.hover_uid == uid and not dead:
			ring = Color("b8b0a0")
		if ring.a > 0.0:
			_ring(ring)
		# сам персонаж. Павший враг краснеет и тает за секунду (на земле не остаётся непонятного пятна);
		# если на теле есть добыча — на его месте лежит мешок. Павший герой лежит серым: его можно поднять.
		var fallen_hero := dead and is_hero
		if dead and not fallen_hero:
			if death_t < 0.35:
				tint = tint.lerp(Color(1, 0.5, 0.4), 1.0 - death_t / 0.35)
			var fade := clampf(1.0 - (death_t - 0.2) / 0.8, 0.0, 1.0)
			if view.session.loot.has(uid):
				_loot_bag(clampf(death_t / 0.6, 0.0, 1.0))
			else:
				rect = Rect2()
			if fade <= 0.0:
				return
			tint.a *= fade
			off.y += roundf((1.0 - fade) * 4.0)
		var fr: Dictionary = {}
		fr = SpriteLibrary.frame("units", template, "walk" if walking else "idle", t, "right" if facing > 0 else "left")
		if fallen_hero:
			tint = Color(0.55, 0.55, 0.6, 0.75)
			if not fr.is_empty():
				# лежит на боку: тот же кадр, повёрнутый на 90°
				var region0: Rect2 = fr["region"]
				var sz0: Vector2 = (region0.size * float(fr["scale"])).round()
				draw_set_transform(Vector2(-sz0.y * 0.5, -2.0), -PI * 0.5, Vector2(1, 1))
				draw_texture_rect_region(fr["texture"], Rect2(Vector2(-sz0.x * 0.5, 0), sz0), region0, tint)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
				rect = Rect2(-sz0.y * 0.5, -sz0.x * 0.5 - 2.0, sz0.y, sz0.x * 0.5 + 4.0)
			else:
				rect = PixelArt.draw_unit(self, template, off, facing, t, 1.0, tint, true)
			return
		if not fr.is_empty():
			var region: Rect2 = fr["region"]
			var sz: Vector2 = (region.size * float(fr["scale"])).round()
			var bob := roundf(sin(t * 2.6) * 0.5 + 0.5) if not walking else 0.0
			var dest := Rect2(off + Vector2(-roundf(sz.x * 0.5), -sz.y + 1.0 - bob) + (fr["offset"] as Vector2), sz)
			if bool(fr["flip"]):
				draw_set_transform(Vector2(dest.position.x + dest.size.x, dest.position.y), 0.0, Vector2(-1, 1))
				draw_texture_rect_region(fr["texture"], Rect2(Vector2.ZERO, dest.size), region, tint)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			else:
				draw_texture_rect_region(fr["texture"], dest, region, tint)
			rect = dest
		else:
			var r0 := PixelArt.draw_unit(self, template, off, facing, t, 1.0, tint, false)
			if not dead:
				rect = r0
		if dead:
			return
		# здоровье и статусы (у NPC не показываем)
		if view.session.is_npc(c) or appear < 1.0:
			return
		var show_bar := view.session.mode == "combat" or view.hover_uid == uid or shown_hp < c.max_hp() - 0.5
		if show_bar:
			var w := 16.0
			var top := rect.position.y - 5.0
			var bar := Rect2(-w * 0.5, top, w, 3)
			draw_rect(bar.grow(1.0), Color("120c0a"))
			draw_rect(bar, Color("3a1410"))
			var k := clampf(shown_hp / maxf(1.0, c.max_hp()), 0.0, 1.0)
			var fill := Color("6ac04a") if is_hero else Color("d0402c")
			draw_rect(Rect2(bar.position, Vector2(roundf(w * k), 3)), fill)
			draw_rect(Rect2(bar.position, Vector2(roundf(w * k), 1)), fill.lightened(0.3))
			var x := -w * 0.5
			for sid in c.statuses:
				draw_rect(Rect2(x, top - 4, 3, 3), Color("120c0a"))
				draw_rect(Rect2(x + 0.0, top - 4, 2, 2), IconArt.status_color(str(sid)))
				x += 4.0

	## Мешок с добычей на месте тела: картинка props/loot_bag или холщовый мешок кодом. k — появление (0..1).
	func _loot_bag(k: float) -> void:
		var bob := roundf(sin(view.time * 2.0) * 0.5)
		var fr := SpriteLibrary.frame("props", "loot_bag")
		if not fr.is_empty():
			var region: Rect2 = fr["region"]
			var sz: Vector2 = (region.size * float(fr["scale"])).round()
			var dest := Rect2(Vector2(-roundf(sz.x * 0.5), -sz.y + 2.0), sz)
			draw_texture_rect_region(fr["texture"], dest, region, Color(1, 1, 1, k))
			rect = dest
			return
		var a := k
		var sack := Color(0.55, 0.42, 0.26, a)
		var dark := Color(0.32, 0.22, 0.13, a)
		_shadow(Vector2(0, 0), 6.0)
		draw_colored_polygon(PackedVector2Array([Vector2(-6, 0), Vector2(-7, -5), Vector2(-4, -9), Vector2(4, -9),
			Vector2(7, -5), Vector2(6, 0)]), sack)
		draw_polyline(PackedVector2Array([Vector2(-6, 0), Vector2(-7, -5), Vector2(-4, -9), Vector2(4, -9),
			Vector2(7, -5), Vector2(6, 0), Vector2(-6, 0)]), dark, 1.0)
		draw_colored_polygon(PackedVector2Array([Vector2(-3, -9), Vector2(-2, -12), Vector2(2, -12), Vector2(3, -9)]), sack.darkened(0.1))
		draw_line(Vector2(-3, -9.5), Vector2(3, -9.5), Color(0.75, 0.6, 0.3, a), 1.0)   # завязка
		var glint := 0.5 + 0.5 * sin(view.time * 3.0)
		draw_rect(Rect2(Vector2(3, -4 + bob), Vector2(2, 2)), Color(1.0, 0.85, 0.35, a * (0.5 + 0.5 * glint)))
		rect = Rect2(-8, -13, 16, 14)

	func _shadow(p: Vector2, r: float) -> void:
		var col := Color(0, 0, 0, 0.32)
		draw_rect(Rect2(p + Vector2(-r, -1), Vector2(r * 2, 2)), col)
		draw_rect(Rect2(p + Vector2(-r + 2, -2), Vector2(r * 2 - 4, 4)), col)

	func _ring(col: Color) -> void:
		# ромб клетки, урезанный к центру: читается как кольцо на земле
		var hw := 12.0
		var hh := 6.0
		var pts := PackedVector2Array([Vector2(0, -hh), Vector2(hw, 0), Vector2(0, hh), Vector2(-hw, 0), Vector2(0, -hh)])
		draw_polyline(pts, Color("120c0a"), 3.0)
		draw_polyline(pts, col, 1.0)

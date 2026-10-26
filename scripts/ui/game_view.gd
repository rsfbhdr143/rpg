extends Node2D
## Временная визуализация: исследование, бой, экран персонажа.
## Вся логика — в scripts/core, combat, world, net; состояние приходит из Net.session
## (на сервере — живое, у клиента — снимок). Действия уходят командами Net.send_command().
##
## Карта рисуется в изометрии (как в D:OS) или сверху, настройка projection в data/sprites.json.
## Картинки берутся из SpriteLibrary; если у героя, клетки или навыка картинки нет, рисуется заглушка.
##
## Управление:
##   Исследование: ЛКМ по клетке — идти выбранным героем, ЛКМ по своему герою — выбрать,
##                 Tab — следующий свой герой. Клетки-выходы подсвечены жёлтым.
##   Бой (ваш ход): ЛКМ — идти / применить навык, 1..9 — навык, 0 — перемещение, Пробел — конец хода.
##   Камера: колесо — масштаб, ПКМ или средняя кнопка с перетаскиванием — сдвиг, Z — сбросить,
##           V — изометрия / вид сверху.
##   Везде: C — экран персонажа, K — сохранить, L — загрузить (лидер), R — после поражения,
##          Esc — закрыть экран персонажа / отменить навык, F10 — выйти в меню.

const MAP_AREA := Rect2(16, 16, 860, 688)
const PANEL_X := 896.0
const MENU_SCENE := "res://scenes/menu.tscn"
const SHEET_RECT := Rect2(30, 30, 900, 660)
const FLOOR_COLOR := Color(0.22, 0.24, 0.2)
const WALL_COLORS := [Color(0.34, 0.33, 0.36), Color(0.2, 0.19, 0.21), Color(0.26, 0.25, 0.28)]   # верх, лево, право

var session: GameSession
var grid: SurfaceGrid
var combat: CombatManager
var selected_uid := ""
var selected_skill := ""
var hovered := Vector2i(-1, -1)
var sheet_open := false
var iso := true
var zoom := 1.0
var pan := Vector2.ZERO
var tile_w := 48.0                # ширина клетки на экране (в изометрии — ширина ромба)
var tile_h := 48.0                # высота клетки (в изометрии — половина ширины)
var origin := Vector2.ZERO        # экранная точка угла (0, 0) карты
var _font: Font
var _notice := ""
var _last_current := ""
var _time := 0.0
var _dragging := false
var _mouse := Vector2.ZERO
var _buttons: Array = []          # [{"rect": Rect2, "cmd": Dictionary}] — кнопки экрана персонажа
var _unit_rects: Array = []       # [{"rect": Rect2, "cell": Vector2i}] — где нарисованы юниты (для кликов)


func _ready() -> void:
	GameData.ensure_loaded()
	SpriteLibrary.ensure_loaded()
	iso = str(SpriteLibrary.setting("projection", "isometric")) != "topdown"
	if bool(SpriteLibrary.setting("pixel_art", false)):
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_font = ThemeDB.fallback_font
	Net.notice.connect(_on_notice)
	Net.disconnected.connect(_on_disconnected)
	_sync()


## Берём актуальное состояние (клиент получает новые объекты с каждым снимком).
func _sync() -> void:
	session = Net.session
	if session == null or session.grid == null:
		grid = null
		return
	grid = session.grid
	combat = session.combat
	_layout()
	var cur_uid: String = combat.current.uid if combat != null and combat.current != null else ""
	if cur_uid != _last_current:
		_last_current = cur_uid
		selected_skill = ""
	var mine := session.heroes_of(Net.my_id())
	var sel := session.unit_by_uid(selected_uid)
	if (sel == null or not mine.has(sel)) and not mine.is_empty():
		selected_uid = mine[0].uid


func _process(delta: float) -> void:
	_time += delta
	_sync()
	queue_redraw()


func _on_notice(text: String) -> void:
	_notice = text


func _on_disconnected(_reason: String) -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


func _send(cmd: Dictionary) -> void:
	_notice = ""
	Net.send_command(cmd)


func _is_my_combat_turn() -> bool:
	return session.mode == "combat" and combat != null and combat.active and combat.current != null \
		and session.owner_of(combat.current) == Net.my_id()


## Чей лист персонажа показываем: в бою — текущего, иначе — выбранного героя.
func _sheet_unit() -> Character:
	if session.mode == "combat" and combat != null and combat.current != null and session.heroes.has(combat.current):
		return combat.current
	return session.unit_by_uid(selected_uid)


# --- Проекция: клетки сетки <-> экран ------------------------------------------

## Размер клетки и положение карты: вся карта помещается в MAP_AREA, дальше масштаб и сдвиг камеры.
func _layout() -> void:
	var w := float(grid.width)
	var h := float(grid.height)
	if iso:
		var fit := minf(MAP_AREA.size.x / ((w + h) * 0.5), MAP_AREA.size.y / ((w + h) * 0.25 + 1.5))
		tile_w = clampf(fit, 24.0, 160.0) * zoom
		tile_h = tile_w * 0.5
		origin = MAP_AREA.get_center() - Vector2((w - h) * tile_w * 0.25, (w + h) * tile_h * 0.25) \
			+ Vector2(0, tile_w * 0.4) + pan
	else:
		tile_w = clampf(minf(MAP_AREA.size.x / w, MAP_AREA.size.y / h), 16.0, 64.0) * zoom
		tile_h = tile_w
		origin = MAP_AREA.get_center() - Vector2(w, h) * tile_w * 0.5 + pan


## Точка сетки (в клетках, 0,0 — угол карты) на экране.
func _grid_point(gx: float, gy: float) -> Vector2:
	if iso:
		return origin + Vector2((gx - gy) * tile_w * 0.5, (gx + gy) * tile_h * 0.5)
	return origin + Vector2(gx, gy) * tile_w


func _cell_center(c: Vector2i) -> Vector2:
	return _grid_point(c.x + 0.5, c.y + 0.5)


## Где стоят ноги юнита: в изометрии — центр ромба, сверху — чуть ниже центра клетки.
func _feet(c: Vector2i) -> Vector2:
	return _cell_center(c) if iso else _grid_point(c.x + 0.5, c.y + 0.9)


func _cell_poly(c: Vector2i) -> PackedVector2Array:
	return PackedVector2Array([_grid_point(c.x, c.y), _grid_point(c.x + 1, c.y),
		_grid_point(c.x + 1, c.y + 1), _grid_point(c.x, c.y + 1)])


## Квадрат клеток сетки (в изометрии — ромб) от a до b включительно.
func _area_poly(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	return PackedVector2Array([_grid_point(a.x, a.y), _grid_point(b.x + 1, a.y),
		_grid_point(b.x + 1, b.y + 1), _grid_point(a.x, b.y + 1), _grid_point(a.x, a.y)])


func _cell_bounds(c: Vector2i) -> Rect2:
	if iso:
		var top := _grid_point(c.x, c.y)
		return Rect2(top.x - tile_w * 0.5, top.y, tile_w, tile_h)
	return Rect2(_grid_point(c.x, c.y), Vector2(tile_w, tile_w))


func _cell_at(p: Vector2) -> Vector2i:
	var local := p - origin
	if iso:
		var u := local.x / (tile_w * 0.5)
		var v := local.y / (tile_h * 0.5)
		return Vector2i(floori((u + v) * 0.5), floori((v - u) * 0.5))
	return Vector2i(floori(local.x / tile_w), floori(local.y / tile_w))


## Клетка под мышью: сначала юниты (их картинка выше клетки), потом сама клетка.
func _pick(p: Vector2) -> Vector2i:
	for i in range(_unit_rects.size() - 1, -1, -1):   # с переднего плана
		var ur: Dictionary = _unit_rects[i]
		if Rect2(ur["rect"]).has_point(p):
			return ur["cell"]
	return _cell_at(p)


# --- Ввод ---------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if grid == null:
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		if _dragging:
			pan += motion.position - _mouse
		_mouse = motion.position
		hovered = _pick(motion.position)
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		_on_mouse_button(mb)
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	_on_key(key.keycode)


func _on_mouse_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_click(mb.position)
		MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
			_mouse = mb.position
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed and not sheet_open and MAP_AREA.has_point(mb.position):
				var old := zoom
				zoom = clampf(zoom * (1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12), 0.5, 4.0)
				# масштаб вокруг курсора
				var c := MAP_AREA.get_center()
				pan = (pan + c - mb.position) * (zoom / old) - (c - mb.position)


func _on_key(k: Key) -> void:
	match k:
		KEY_F10:
			Net.leave()
		KEY_C:
			sheet_open = not sheet_open
		KEY_V:
			iso = not iso
			pan = Vector2.ZERO
		KEY_Z:
			zoom = 1.0
			pan = Vector2.ZERO
		KEY_ESCAPE:
			if sheet_open:
				sheet_open = false
			else:
				selected_skill = ""
		KEY_K:
			_send({"type": "save"})
		KEY_L:
			_send({"type": "load"})
		KEY_R:
			if session.mode == "defeat":
				_send({"type": "restart"})
		KEY_TAB:
			var mine := session.heroes_of(Net.my_id())
			if not mine.is_empty():
				var idx := mine.find(session.unit_by_uid(selected_uid))
				selected_uid = mine[(idx + 1) % mine.size()].uid
		_:
			if _is_my_combat_turn():
				_on_combat_key(k)


func _on_combat_key(k: Key) -> void:
	var u := combat.current
	if k == KEY_SPACE:
		selected_skill = ""
		_send({"type": "end_turn"})
	elif k == KEY_0:
		selected_skill = ""
	elif k >= KEY_1 and k <= KEY_9:
		var idx: int = k - KEY_1
		if idx < u.skills.size():
			selected_skill = u.skills[idx]
			var def := GameData.skill(selected_skill)
			if str(def.get("target", "")) == "self":   # навыки на себя применяются сразу
				_send({"type": "skill", "skill": selected_skill, "cell": [u.cell.x, u.cell.y]})
				selected_skill = ""


func _on_click(pos: Vector2) -> void:
	if sheet_open:
		for b in _buttons:
			if Rect2(b["rect"]).has_point(pos):
				_send(b["cmd"])
				return
		if SHEET_RECT.has_point(pos):
			return
	if not MAP_AREA.has_point(pos):
		return
	var c := _pick(pos)
	if not grid.in_bounds(c):
		return
	if session.mode == "explore":
		var u := session.unit_at(c)
		if u != null and session.owner_of(u) == Net.my_id() and session.heroes.has(u):
			selected_uid = u.uid
		elif selected_uid != "":
			_send({"type": "move", "unit": selected_uid, "cell": [c.x, c.y]})
	elif _is_my_combat_turn():
		if selected_skill == "":
			_send({"type": "move", "unit": combat.current.uid, "cell": [c.x, c.y]})
		else:
			_send({"type": "skill", "skill": selected_skill, "cell": [c.x, c.y]})
			selected_skill = ""


# --- Отрисовка ----------------------------------------------------------------

func _text(pos: Vector2, s: String, col := Color.WHITE, size := 14) -> void:
	draw_string(_font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw() -> void:
	var screen := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, screen), Color(0.08, 0.08, 0.1))
	if grid == null:
		_text(Vector2(40, 40), "Ожидание состояния от сервера...")
		return
	_buttons.clear()
	_draw_ground()
	_draw_objects()
	draw_rect(Rect2(PANEL_X - 12, 0, screen.x - PANEL_X + 12, screen.y), Color(0.08, 0.08, 0.1, 0.94))
	_draw_panel()
	if sheet_open:
		_draw_sheet()


## Нарисовать кадр SpriteLibrary в прямоугольник (с отражением по горизонтали).
func _blit(fr: Dictionary, dest: Rect2, modulate := Color.WHITE) -> void:
	var tex: Texture2D = fr["texture"]
	if bool(fr["flip"]):
		draw_set_transform(Vector2(dest.position.x + dest.size.x, dest.position.y), 0.0, Vector2(-1, 1))
		draw_texture_rect_region(tex, Rect2(Vector2.ZERO, dest.size), fr["region"], modulate)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_texture_rect_region(tex, dest, fr["region"], modulate)


## Картинка на полу клетки. Квадратная текстура (вид сверху) натягивается на ромб,
## изометрическая плитка (вдвое шире высоты) рисуется как есть.
func _draw_ground_sprite(fr: Dictionary, c: Vector2i, alpha: float) -> void:
	var region: Rect2 = fr["region"]
	var mode := str(fr["draw"])
	if mode == "":
		mode = "ground" if region.size.x < region.size.y * 1.6 else "tile"
	var mod := Color(1, 1, 1, alpha)
	if not iso:
		_blit(fr, _cell_bounds(c), mod)
	elif mode == "ground":
		_textured_quad(_cell_poly(c), fr, mod)
	else:
		var b := _cell_bounds(c)
		var hgt := tile_w * region.size.y / region.size.x
		_blit(fr, Rect2(b.position.x, b.end.y - hgt, tile_w, hgt), mod)


## Картинка, стоящая на клетке (юнит, стена, дерево): вписывается в рамку box, низом к точке feet.
func _draw_upright(fr: Dictionary, feet: Vector2, box: Vector2, modulate := Color.WHITE) -> Rect2:
	var region: Rect2 = fr["region"]
	var ppc := float(SpriteLibrary.setting("pixels_per_cell", 0))
	var s: float
	if ppc > 0:
		s = tile_w / ppc / float(fr["pixels"])        # единый масштаб для всего пака: волк меньше великана
	else:
		s = minf(box.x / region.size.x, box.y / region.size.y)
	s *= float(fr["scale"])
	var size := region.size * s
	var off: Vector2 = fr["offset"]
	var dest := Rect2(feet - Vector2(size.x * 0.5, size.y) + off * s, size)
	_blit(fr, dest, modulate)
	return dest


func _variant(c: Vector2i) -> int:
	return absi(c.x * 73856093 ^ c.y * 19349663)


func _draw_ground() -> void:
	var cur: Character = combat.current if combat != null else null
	var skill_def: Dictionary = GameData.skill(selected_skill) if selected_skill != "" else {}
	var show_range := cur != null and not skill_def.is_empty() and _is_my_combat_turn()
	var loc := session.location_id
	var surface_alpha := float(SpriteLibrary.setting("surface_alpha", 0.85))
	for y in grid.height:
		for x in grid.width:
			var c := Vector2i(x, y)
			var poly := _cell_poly(c)
			var floor_fr := SpriteLibrary.frame("tiles", "floor", "idle", 0.0, "", _variant(c), loc)
			if not floor_fr.is_empty():
				_draw_ground_sprite(floor_fr, c, 1.0)
			else:
				draw_colored_polygon(poly, FLOOR_COLOR.darkened(0.06 * ((x + y) % 2)))
			var g := grid.get_ground(c)
			if g != "none":
				var sfr := SpriteLibrary.frame("surfaces", g, "idle", _time + (x * 7 + y * 3) * 0.13)
				if not sfr.is_empty():
					_draw_ground_sprite(sfr, c, sfr["alpha"] if float(sfr["alpha"]) >= 0 else surface_alpha)
				else:
					draw_colored_polygon(poly, Color.html(str(GameData.surface(g).get("color", "#ff00ff"))))
			if not session.exit_at(c).is_empty():
				draw_polyline(_shrink(poly, 0.12), Color(1.0, 0.85, 0.2, 0.7), 2.0)
			if show_range and SurfaceGrid.distance(cur.cell, c) <= SkillSystem.skill_range(cur, skill_def):
				draw_colored_polygon(poly, Color(1, 1, 0.3, 0.14))
			var closed := poly.duplicate()
			closed.append(poly[0])
			draw_polyline(closed, Color(0, 0, 0, 0.3), 1.0)
	if grid.in_bounds(hovered):
		var hp := _cell_poly(hovered)
		hp.append(hp[0])
		draw_polyline(hp, Color(1, 1, 1, 0.85), 2.0)


## Многоугольник клетки, сжатый к центру (рамка выхода внутри клетки).
func _shrink(poly: PackedVector2Array, k: float) -> PackedVector2Array:
	var center := (poly[0] + poly[2]) * 0.5
	var out := PackedVector2Array()
	for p in poly:
		out.append(p.lerp(center, k))
	out.append(out[0])
	return out


## Стены, юниты и облака рисуются от дальних к ближним, чтобы ближние их перекрывали.
func _draw_objects() -> void:
	var items: Array = []
	for c in grid.blocked:
		items.append([_depth(c) * 4, "wall", c])
	for u in session.all_units():
		var ch: Character = u
		items.append([_depth(ch.cell) * 4 + 1, "unit", ch])
	for y in grid.height:
		for x in grid.width:
			var c := Vector2i(x, y)
			if grid.get_cloud(c) != "none":
				items.append([_depth(c) * 4 + 2, "cloud", c])
	items.sort_custom(func(a, b): return a[0] < b[0])
	_unit_rects.clear()
	for it in items:
		match str(it[1]):
			"wall":
				_draw_wall(it[2])
			"unit":
				_draw_unit(it[2])
			"cloud":
				_draw_cloud(it[2])
	if session.mode == "explore":
		for u in session.all_units():
			var ch: Character = u
			var tr := session.trigger_radius(ch.encounter_id) if ch.is_alive() and not session.heroes.has(ch) else 0
			if tr > 0:   # с какого расстояния группа врагов заметит партию
				draw_polyline(_area_poly(ch.cell - Vector2i(tr, tr), ch.cell + Vector2i(tr, tr)), Color(1, 0.3, 0.3, 0.3), 1.0)


func _depth(c: Vector2i) -> int:
	return (c.x + c.y) * 1000 + c.x if iso else c.y * 1000 + c.x


func _draw_wall(c: Vector2i) -> void:
	var fr := SpriteLibrary.frame("tiles", "wall", "idle", 0.0, "", _variant(c), session.location_id)
	var mode := str(fr.get("draw", ""))
	if not fr.is_empty() and not iso and mode != "upright":
		_blit(fr, _cell_bounds(c))
		return
	if not fr.is_empty() and (mode == "upright" or mode == "tile" or not bool(fr["opaque"])):
		# готовая картинка стены, дерева, камня: стоит на клетке
		var b := _cell_bounds(c)
		_draw_upright(fr, Vector2(b.get_center().x, b.end.y), Vector2(tile_w, tile_w * 3.0))
		return
	if not iso:
		draw_rect(_cell_bounds(c), Color(0.1, 0.1, 0.1))
		return
	# блок высотой в клетку: сплошная текстура натягивается на грани, без картинки — серые грани
	var lift := Vector2(0, -tile_h * 1.2)
	var p := _cell_poly(c)   # верх, право, низ, лево
	var left := PackedVector2Array([p[3] + lift, p[2] + lift, p[2], p[3]])
	var right := PackedVector2Array([p[2] + lift, p[1] + lift, p[1], p[2]])
	var top := PackedVector2Array([p[0] + lift, p[1] + lift, p[2] + lift, p[3] + lift])
	if fr.is_empty():
		draw_colored_polygon(left, WALL_COLORS[1])
		draw_colored_polygon(right, WALL_COLORS[2])
		draw_colored_polygon(top, WALL_COLORS[0])
	else:
		_textured_quad(left, fr, Color(0.55, 0.55, 0.58))
		_textured_quad(right, fr, Color(0.75, 0.75, 0.78))
		_textured_quad(top, fr, Color.WHITE)
	top.append(top[0])
	draw_polyline(top, Color(0, 0, 0, 0.35), 1.0)


## Натянуть кадр на четырёхугольник (точки по часовой стрелке от левого верхнего угла картинки).
func _textured_quad(points: PackedVector2Array, fr: Dictionary, modulate: Color) -> void:
	var tex: Texture2D = fr["texture"]
	var region: Rect2 = fr["region"]
	var ts := tex.get_size()
	var uv := PackedVector2Array([region.position / ts, Vector2(region.end.x, region.position.y) / ts,
		region.end / ts, Vector2(region.position.x, region.end.y) / ts])
	draw_polygon(points, PackedColorArray([modulate]), uv, tex)


func _draw_cloud(c: Vector2i) -> void:
	var cl := grid.get_cloud(c)
	var alpha := float(SpriteLibrary.setting("cloud_alpha", 0.6))
	var fr := SpriteLibrary.frame("surfaces", cl, "idle", _time + (c.x * 5 + c.y * 11) * 0.17)
	if not fr.is_empty():
		_draw_upright(fr, _feet(c), Vector2(tile_w * 1.1, tile_w * 1.1), Color(1, 1, 1, alpha))
		return
	var col := Color.html(str(GameData.surface(cl).get("color", "#ffffff")))
	col.a = 0.45
	var lift := Vector2(0, -tile_h * 0.6) if iso else Vector2.ZERO
	var poly := _shrink(_cell_poly(c), 0.12)
	poly.remove_at(poly.size() - 1)
	for i in poly.size():
		poly[i] += lift
	draw_colored_polygon(poly, col)


## Овал (в изометрии — сплюснутый круг на полу).
func _ellipse(center: Vector2, r: float, col: Color, width := -1.0) -> void:
	var k := 0.5 if iso else 1.0
	draw_set_transform(center, 0.0, Vector2(1, k))
	if width < 0:
		draw_circle(Vector2.ZERO, r, col)
	else:
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, col, width / k)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Куда смотрит юнит: на ближайшего живого противника, иначе герои вправо, враги влево.
func _facing(ch: Character, is_hero: bool) -> String:
	var best: Character = null
	var best_d := 13
	for u in session.all_units():
		var o: Character = u
		if o == ch or not o.is_alive() or session.heroes.has(o) == is_hero:
			continue
		var d := SurfaceGrid.distance(ch.cell, o.cell)
		if d < best_d:
			best_d = d
			best = o
	var dx := (_cell_center(best.cell).x - _cell_center(ch.cell).x) if best != null else (1.0 if is_hero else -1.0)
	if is_zero_approx(dx):
		dx = 1.0 if is_hero else -1.0
	return "left" if dx < 0 else "right"


func _draw_unit(ch: Character) -> void:
	var cur: Character = combat.current if combat != null else null
	var is_hero := session.heroes.has(ch)
	var feet := _feet(ch.cell)
	var box := Vector2(tile_w * 0.9, tile_w * 1.25) if iso else Vector2(tile_w * 0.95, tile_w * 1.0)
	box *= float(SpriteLibrary.setting("unit_scale", 1.0))
	var phase := float(absi(ch.uid.hash()) % 97) * 0.071   # чтобы юниты не двигались в такт
	if not ch.is_alive():
		var dead := SpriteLibrary.frame("units", ch.template_id, "death", 999.0, _facing(ch, is_hero))
		if not dead.is_empty():
			_draw_upright(dead, feet, box, Color(0.85, 0.85, 0.85, 0.9))
		return
	var r := tile_w * 0.3
	if ch == cur:
		_ellipse(feet, r * 1.3, Color(1, 1, 0.4), 3.0)
	elif is_hero and ch.uid == selected_uid and session.mode != "combat":
		_ellipse(feet, r * 1.3, Color(1, 1, 1), 2.0)
	_ellipse(feet, r, Color(0, 0, 0, 0.35))
	var fr := SpriteLibrary.frame("units", ch.template_id, "idle", _time + phase, _facing(ch, is_hero))
	var rect: Rect2
	if not fr.is_empty():
		rect = _draw_upright(fr, feet, box)
	else:
		var col: Color = Color(0.3, 0.6, 1.0) if is_hero else Color(0.9, 0.3, 0.3)
		var center := feet - Vector2(0, r * 1.15) if iso else _cell_center(ch.cell)
		draw_circle(center, r * 1.05, col)
		var letter_size := int(r * 1.2)
		draw_string(_font, center + Vector2(-letter_size * 0.33, letter_size * 0.36), ch.display_name.substr(0, 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, letter_size)
		rect = Rect2(center - Vector2(r, r) * 1.05, Vector2(r, r) * 2.1)
	_unit_rects.append({"rect": rect, "cell": ch.cell})
	# полоска здоровья и значки статусов над головой
	var bar_w := tile_w * 0.7
	var bar := Rect2(feet.x - bar_w * 0.5, rect.position.y - 6, bar_w, 4)
	draw_rect(bar, Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(bar_w * clampf(ch.hp / ch.max_hp(), 0, 1), 4)), Color(0.2, 0.9, 0.3))
	var icon := maxf(10.0, tile_w * 0.24)
	var ix := feet.x - bar_w * 0.5
	for id in ch.statuses:
		var sfr := SpriteLibrary.frame("statuses", id)
		if not sfr.is_empty():
			_blit(sfr, Rect2(ix, bar.position.y - icon - 2, icon, icon))
		else:
			draw_circle(Vector2(ix + icon * 0.5, bar.position.y - icon * 0.5 - 2), icon * 0.3, Color(1, 0.6, 0.1))
		ix += icon + 2


func _draw_panel() -> void:
	var x := PANEL_X
	var y := 30.0
	var loc_name := str(session.location_data().get("name", session.location_id))
	_text(Vector2(x, y), "%s — %s" % [loc_name, _mode_name()], Color.YELLOW, 16)
	y += 24
	if session.mode == "combat" and combat != null and combat.current != null:
		y = _draw_combat_panel(x, y)
	else:
		y = _draw_explore_panel(x, y)
	if _notice != "":
		_text(Vector2(x, y), "Нельзя: " + _notice, Color(1, 0.5, 0.4))
		y += 18
	y += 8
	if grid.in_bounds(hovered):
		var info := "Клетка %s: %s / %s" % [str(hovered), _surface_name(grid.get_ground(hovered)), _surface_name(grid.get_cloud(hovered))]
		var ex := session.exit_at(hovered)
		if not ex.is_empty():
			info += " | выход: " + str(ex.get("name", ex.get("to", "")))
		var hu := session.unit_at(hovered)
		if hu != null:
			info += " | %s ОЗ %d/%d [%s]" % [hu.display_name, hu.hp, hu.max_hp(), _statuses_text(hu)]
		_text(Vector2(x, y), info, Color(0.8, 0.9, 1.0), 13)
		y += 22
	var log_lines: Array = GameLog.lines.slice(maxi(0, GameLog.lines.size() - 20))
	for line in log_lines:
		_text(Vector2(x, y), str(line), Color(0.85, 0.85, 0.85), 13)
		y += 17


func _mode_name() -> String:
	match session.mode:
		"combat":
			return "бой, раунд %d" % (combat.round_number if combat != null else 0)
		"defeat":
			return "поражение (R — ко входу)"
	return "исследование"


func _draw_explore_panel(x: float, y: float) -> float:
	_text(Vector2(x, y), "Ваши герои (Tab — переключить):")
	y += 18
	for h in session.heroes_of(Net.my_id()):
		var ch: Character = h
		var mark: String = "> " if ch.uid == selected_uid else "   "
		var pts := ch.unspent_attribute_points + ch.unspent_ability_points + ch.unspent_talent_points
		var extra: String = "  (+%d очков, C)" % pts if pts > 0 else ""
		_text(Vector2(x, y), "%s%s ур.%d  ОЗ %d/%d%s" % [mark, ch.display_name, ch.level, ch.hp, ch.max_hp(), extra])
		y += 18
	var others: Array = session.heroes.filter(func(h): return session.owner_of(h) != Net.my_id())
	for h in others:
		_text(Vector2(x, y), "   %s — %s" % [h.display_name, session.player_name(session.owner_of(h))], Color(0.7, 0.7, 0.7))
		y += 18
	y += 4
	_text(Vector2(x, y), "ЛКМ — идти, жёлтые клетки — выходы, C — персонаж", Color(0.7, 0.7, 0.7), 13)
	y += 16
	_text(Vector2(x, y), "Колесо, ПКМ — камера, Z — сброс, V — вид", Color(0.7, 0.7, 0.7), 13)
	y += 16
	_text(Vector2(x, y), "K — сохранить, L — загрузить, F10 — меню", Color(0.7, 0.7, 0.7), 13)
	return y + 20


func _draw_combat_panel(x: float, y: float) -> float:
	var u := combat.current
	_text(Vector2(x, y), "Ход: %s [%s]" % [u.describe(), session.player_name(session.owner_of(u))], Color.YELLOW)
	y += 20
	_text(Vector2(x, y), "ОЗ %d/%d   ОД %d/%d (+%d)   Броня %d" % [
		u.hp, u.max_hp(), u.ap, u.get_int("max_ap"), u.get_int("ap_recovery"), DamageCalc.effective_armor(u)])
	y += 20
	_text(Vector2(x, y), "Статусы: " + _statuses_text(u))
	y += 22
	if not _is_my_combat_turn():
		_text(Vector2(x, y), "Ходит другой игрок или ИИ...", Color(0.7, 0.7, 0.7))
		return y + 22
	_text(Vector2(x + 20, y), "[0] Перемещение" + ("  <" if selected_skill == "" else ""))
	y += 18
	for i in u.skills.size():
		var sk: String = u.skills[i]
		var def := GameData.skill(sk)
		var cd := ""
		if u.cooldowns.has(sk):
			cd = "  (перезарядка %d)" % int(u.cooldowns[sk])
		var mark: String = "  <" if sk == selected_skill else ""
		var usable := int(def.get("ap", 0)) <= u.ap and cd == ""
		var col: Color = Color.WHITE if usable else Color(0.55, 0.55, 0.55)
		var icon := SpriteLibrary.frame("skills", sk)
		if not icon.is_empty():
			_blit(icon, Rect2(x, y - 14, 16, 16), Color.WHITE if usable else Color(1, 1, 1, 0.4))
		_text(Vector2(x + 20, y), "[%d] %s — %d ОД%s%s" % [i + 1, def.get("name", sk), int(def.get("ap", 0)), cd, mark], col)
		y += 18
	_text(Vector2(x, y), "Пробел — конец хода", Color(0.7, 0.7, 0.7))
	return y + 22


# --- Экран персонажа ----------------------------------------------------------

func _draw_sheet() -> void:
	var h := _sheet_unit()
	draw_rect(SHEET_RECT, Color(0.05, 0.05, 0.07, 0.96))
	draw_rect(SHEET_RECT, Color(0.6, 0.6, 0.7), false, 2.0)
	if h == null:
		_text(SHEET_RECT.position + Vector2(20, 30), "Нет выбранного героя.")
		return
	var editable := session.owner_of(h) == Net.my_id() and session.mode != "combat"
	var x1 := SHEET_RECT.position.x + 20
	var x2 := SHEET_RECT.position.x + 460
	var y := SHEET_RECT.position.y + 30
	_text(Vector2(x1, y), "%s — уровень %d, опыт %d/%d" % [h.display_name, h.level, h.xp, Progression.xp_to_next(h.level)], Color.YELLOW, 16)
	_text(Vector2(x2 + 200, y), "C / Esc — закрыть", Color(0.6, 0.6, 0.6), 12)
	y += 22
	_text(Vector2(x1, y), "Свободные очки: атрибуты %d, способности %d, таланты %d" % [
		h.unspent_attribute_points, h.unspent_ability_points, h.unspent_talent_points])
	if not editable:
		_text(Vector2(x2 + 60, y), "(только просмотр)", Color(0.6, 0.6, 0.6), 12)
	y += 26
	var top := y

	# Левая колонка: атрибуты, производные, таланты
	y = _sheet_header(x1, y, "Атрибуты")
	var names: Dictionary = GameData.rule("attribute_names", {})
	for a in GameData.attribute_list():
		var can := editable and Progression.can_raise_attribute(h, a)
		y = _sheet_row(x1, y, "%s %d" % [names.get(a, a), int(h.attributes[a])], can,
			{"type": "raise_attribute", "unit": h.uid, "attribute": a})
	y += 6
	_text(Vector2(x1, y), "ОЗ %d/%d   ОД макс %d, +%d за ход   Инициатива %d" % [
		h.hp, h.max_hp(), h.get_int("max_ap"), h.get_int("ap_recovery"), h.get_int("initiative")], Color(0.8, 0.8, 0.8), 13)
	y += 16
	_text(Vector2(x1, y), "Броня %d   Точность %d   Уклонение %d   Крит %d%%" % [
		DamageCalc.effective_armor(h), h.get_int("accuracy"), h.get_int("dodge"), h.get_int("crit_chance")], Color(0.8, 0.8, 0.8), 13)
	y += 16
	var res: Array = []
	for r in GameData.rule("resistances", []):
		res.append("%s %d" % [r, h.get_resistance(r)])
	_text(Vector2(x1, y), "Сопротивления: " + ", ".join(res), Color(0.8, 0.8, 0.8), 13)
	y += 24

	y = _sheet_header(x1, y, "Таланты")
	for t in h.talents:
		_text(Vector2(x1 + 30, y), str(GameData.talent(t).get("name", t)), Color(0.7, 1.0, 0.7), 13)
		y += 16
	for t in GameData.talents:
		if h.talents.has(t):
			continue
		var reason := Progression.talent_block_reason(h, t)
		var label := "%s — %s" % [GameData.talent(t).get("name", t), GameData.talent(t).get("description", "")]
		if reason != "" and reason != "нет очков талантов":
			label += " (%s)" % reason
		y = _sheet_row(x1, y, label, editable and reason == "", {"type": "learn_talent", "unit": h.uid, "talent": t})

	# Правая колонка: способности и навыки
	y = top
	y = _sheet_header(x2, y, "Способности (ранг, цена следующего)")
	for ab in GameData.abilities:
		var rank := h.ability_rank(ab)
		var label := "%s %d  (%d)" % [GameData.ability(ab).get("name", ab), rank, Progression.ability_cost(rank + 1)]
		y = _sheet_row(x2, y, label, editable and Progression.can_raise_ability(h, ab),
			{"type": "raise_ability", "unit": h.uid, "ability": ab})
	y += 8
	y = _sheet_header(x2, y, "Навыки")
	var known: Array = []
	for sk in h.skills:
		known.append(str(GameData.skill(sk).get("name", sk)))
	_text(Vector2(x2 + 30, y), ", ".join(known), Color(0.7, 1.0, 0.7), 12)
	y += 18
	for sk in GameData.skills:
		if h.skills.has(sk) or Progression.skill_block_reason(h, sk) != "":
			continue
		y = _sheet_row(x2, y, "Выучить: " + str(GameData.skill(sk).get("name", sk)), editable,
			{"type": "learn_skill", "unit": h.uid, "skill": sk})


func _sheet_header(x: float, y: float, title: String) -> float:
	_text(Vector2(x, y), title, Color(0.9, 0.8, 0.5), 14)
	return y + 18


## Строка с кнопкой «+». Возвращает новую координату y.
func _sheet_row(x: float, y: float, label: String, enabled: bool, cmd: Dictionary) -> float:
	var btn := Rect2(x, y - 12, 22, 16)
	if enabled:
		draw_rect(btn, Color(0.25, 0.5, 0.25))
		_text(Vector2(x + 6, y), "+", Color.WHITE, 13)
		_buttons.append({"rect": Rect2(x, y - 12, 420, 16), "cmd": cmd})
	else:
		draw_rect(btn, Color(0.2, 0.2, 0.2))
	_text(Vector2(x + 30, y), label, Color.WHITE if enabled else Color(0.65, 0.65, 0.65), 13)
	return y + 17


func _statuses_text(u: Character) -> String:
	var parts: Array = []
	for id in u.statuses:
		parts.append("%s(%d)" % [GameData.status(id).get("name", id), int(u.statuses[id]["turns"])])
	return "—" if parts.is_empty() else ", ".join(parts)


func _surface_name(id: String) -> String:
	if id == "none":
		return "—"
	return str(GameData.surface(id).get("name", id))

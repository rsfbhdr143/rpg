class_name BuildingArt
extends RefCounted
## Дома, в которые можно войти (как в D:OS1): стены по клеткам, двери, крыша над всем домом, дощатый пол.
## Рисуется кодом в пиксельном стиле; вид задают поля дома в data/locations.json: "material" (timber | stone | log)
## и "roof" (thatch | shingle | slate | moss). Стены выше роста героя, чтобы жители не казались выше домов.
## Когда внутри герой, крыша тает, а ближние стены срезаются почти до пола — видно комнату.
## house — словарь дома из WorldView.houses: "rect" (Rect2i), "open" (0..1), "def" (данные дома).

const WALL_H := 52.0     # высота стены в пикселях мира (герой — около 40)
const CUT_H := 8.0       # ближняя стена, срезанная, когда внутри герой
const INNER_H := 40.0    # дальние стены, когда внутри герой: ниже, чтобы комната читалась
const DOOR_H := 36.0
const OUTLINE := Color("120c0a")
const STYLES := {
	"timber": {"wall": "c8b48c", "beam": "4a3220", "base": "6a6058", "inner": "b8a888"},
	"stone": {"wall": "8a8478", "beam": "5e5a52", "base": "4e4a44", "inner": "a09a8e"},
	"log": {"wall": "7a5634", "beam": "4a301c", "base": "4a3a2a", "inner": "8a6a48"},
}
const ROOFS := {"thatch": "a88a48", "shingle": "7a3a28", "slate": "4a4a5a", "moss": "6a7438"}


static func style_of(house: Dictionary) -> Dictionary:
	var d: Dictionary = house.get("def", {})
	return STYLES.get(str(d.get("material", "timber")), STYLES["timber"])


static func _rect(house: Dictionary) -> Rect2i:
	return house["rect"]


## Стоит ли клетка внутри дома (комнаты и двери, без стен).
static func is_room(house: Dictionary, c: Vector2i) -> bool:
	var r := _rect(house)
	return c.x > r.position.x and c.y > r.position.y and c.x < r.end.x - 1 and c.y < r.end.y - 1


## Ближняя к камере стена (нижний ряд или правый столбец): её срезают, когда внутри герой.
static func is_front(house: Dictionary, c: Vector2i) -> bool:
	var r := _rect(house)
	return c.y == r.end.y - 1 or c.x == r.end.x - 1


static func is_wall(house: Dictionary, c: Vector2i) -> bool:
	var r := _rect(house)
	if not r.has_point(c) or is_room(house, c):
		return false
	return not (house.get("doors", {}) as Dictionary).has(c)


## Стена дома в клетке. corners — ромб клетки относительно точки опоры (N, E, S, W).
static func draw_wall(ci: CanvasItem, house: Dictionary, cell: Vector2i, c: PackedVector2Array, variant: int, t: float) -> Rect2:
	var st := style_of(house)
	var front := is_front(house, cell)
	var h := lerpf(WALL_H, CUT_H if front else INNER_H, float(house.get("open", 0.0)))
	var hv := Vector2(0, -h)
	var below := cell + Vector2i(0, 1)
	var right := cell + Vector2i(1, 0)
	var r := _rect(house)
	# грань +y (влево-вниз) и грань +x (вправо-вниз): рисуем, только если за ними не стена того же дома
	if not is_wall(house, below):
		var inner := r.has_point(below)
		_face(ci, c[3], c[2], hv, st, inner, 0.28, variant, front and not inner and h > 30.0 and variant % 3 == 0, t)
	if not is_wall(house, right):
		var inner := r.has_point(right)
		_face(ci, c[2], c[1], hv, st, inner, 0.08, variant + 1, front and not inner and h > 30.0 and variant % 3 == 1, t)
	var top := PackedVector2Array([c[0] + hv, c[1] + hv, c[2] + hv, c[3] + hv])
	ci.draw_colored_polygon(top, Color(str(st["beam"])))
	top.append(top[0])
	ci.draw_polyline(top, OUTLINE, 1.0)
	return Rect2(Vector2(c[3].x, c[0].y - h), Vector2(c[1].x - c[3].x, c[2].y - c[0].y + h))


## Грань стены от a до b (низ), высотой hv. inner — смотрит в комнату (штукатурка), dark — затемнение грани.
static func _face(ci: CanvasItem, a: Vector2, b: Vector2, hv: Vector2, st: Dictionary, inner: bool, dark: float,
		variant: int, window: bool, t: float) -> void:
	var wall := Color(str(st["inner"] if inner else st["wall"])).darkened(dark)
	var beam := Color(str(st["beam"])).darkened(dark * 0.5)
	ci.draw_colored_polygon(PackedVector2Array([a, b, b + hv, a + hv]), wall)
	var hgt := -hv.y
	# цоколь
	var plinth := Vector2(0, -minf(5.0, hgt))
	ci.draw_colored_polygon(PackedVector2Array([a, b, b + plinth, a + plinth]), Color(str(st["base"])).darkened(dark))
	if inner:
		# комната: тёмная панель понизу, балка под потолком, стойки по краям, кое-где окно в ночь
		var wain := Vector2(0, -minf(14.0, hgt))
		ci.draw_colored_polygon(PackedVector2Array([a, b, b + wain, a + wain]), Color("5a4430").darkened(dark))
		ci.draw_line(a + wain, b + wain, beam, 1.0)
		ci.draw_line(a + hv, b + hv, beam, 3.0)
		ci.draw_line(a, a + hv, beam, 2.0)
		if hgt > 30.0 and variant % 4 == 1:
			var wa := a.lerp(b, 0.32) + hv * 0.5
			var wb := a.lerp(b, 0.68) + hv * 0.5
			var up := hv * 0.28
			ci.draw_colored_polygon(PackedVector2Array([wa, wb, wb + up, wa + up]), Color("1c2638"))
			ci.draw_polyline(PackedVector2Array([wa, wb, wb + up, wa + up, wa]), beam, 1.0)
			ci.draw_line(wa.lerp(wb, 0.5), (wa + up).lerp(wb + up, 0.5), beam, 1.0)
	elif hgt > 12.0:
		if str(st["wall"]) == str(STYLES["stone"]["wall"]):
			var rows := int(hgt / 7.0)
			for i in range(1, rows + 1):
				var k := float(i) * 7.0 / hgt
				ci.draw_line(a + hv * k, b + hv * k, wall.darkened(0.25), 1.0)
				var m := a.lerp(b, 0.33 if (i + variant) % 2 else 0.66) + hv * k
				ci.draw_line(m, m - hv * (7.0 / hgt), wall.darkened(0.25), 1.0)
		elif str(st["wall"]) == str(STYLES["log"]["wall"]):
			var rows := int(hgt / 5.0)
			for i in range(1, rows + 1):
				var k := float(i) * 5.0 / hgt
				ci.draw_line(a + hv * k, b + hv * k, beam, 1.0)
		else:   # фахверк: брус посередине и наверху, раскос через клетку
			ci.draw_line(a + hv * 0.45, b + hv * 0.45, beam, 2.0)
			ci.draw_line(a + hv, b + hv, beam, 2.0)
			if variant % 2 == 0 and not window:
				ci.draw_line(a + hv * 0.45, b + hv, beam, 1.0)
	if window:
		var lit := 0.78 + 0.22 * sin(t * 1.7 + float(variant))
		var wa := a.lerp(b, 0.3) + hv * 0.52
		var wb := a.lerp(b, 0.7) + hv * 0.52
		var up := hv * 0.22
		ci.draw_colored_polygon(PackedVector2Array([wa, wb, wb + up, wa + up]), Color(1.0, 0.78, 0.38, lit))
		var frame := PackedVector2Array([wa, wb, wb + up, wa + up, wa])
		ci.draw_polyline(frame, beam.darkened(0.3), 1.0)
		ci.draw_line(wa.lerp(wb, 0.5), (wa + up).lerp(wb + up, 0.5), beam.darkened(0.3), 1.0)
	ci.draw_line(a, a + hv, OUTLINE, 1.0)
	ci.draw_line(b, b + hv, OUTLINE, 1.0)
	ci.draw_line(a, b, OUTLINE, 1.0)


## Дверь в стене дома: проём на грани, вдоль которой идёт стена; закрыта, пока в доме никого нет.
static func draw_door(ci: CanvasItem, house: Dictionary, cell: Vector2i, c: PackedVector2Array, t: float) -> Rect2:
	var st := style_of(house)
	var r := _rect(house)
	var front := is_front(house, cell)
	var open := float(house.get("open", 0.0))
	var h := lerpf(WALL_H, CUT_H if front else INNER_H, open)
	var hv := Vector2(0, -h)
	# стена вдоль x (верхний или нижний ряд) — проём на грани +y, иначе на грани +x
	var along_x := cell.y == r.position.y or cell.y == r.end.y - 1
	var a: Vector2 = c[3] if along_x else c[2]
	var b: Vector2 = c[2] if along_x else c[1]
	var dark := 0.28 if along_x else 0.08
	var wall := Color(str(st["wall"])).darkened(dark)
	var beam := Color(str(st["beam"])).darkened(dark * 0.5)
	var da := a.lerp(b, 0.22)
	var db := a.lerp(b, 0.78)
	var dh := Vector2(0, -minf(DOOR_H, h))
	ci.draw_colored_polygon(PackedVector2Array([a, da, da + hv, a + hv]), wall)
	ci.draw_colored_polygon(PackedVector2Array([db, b, b + hv, db + hv]), wall)
	if h > DOOR_H:
		ci.draw_colored_polygon(PackedVector2Array([da + dh, db + dh, db + hv, da + hv]), wall)
	if open < 0.5:
		var wood := Color("6a4426").darkened(dark)
		ci.draw_colored_polygon(PackedVector2Array([da, db, db + dh, da + dh]), wood)
		for k in [0.33, 0.66]:
			ci.draw_line(da.lerp(db, k), da.lerp(db, k) + dh, wood.darkened(0.35), 1.0)
		var knob := da.lerp(db, 0.8) + dh * 0.45
		ci.draw_rect(Rect2(knob.round(), Vector2(1, 1)), Color("d8b860"))
	else:
		ci.draw_colored_polygon(PackedVector2Array([da, db, db + dh * 0.12, da + dh * 0.12]), Color("2a1a10"))
	ci.draw_line(da, da + dh, beam, 2.0)
	ci.draw_line(db, db + dh, beam, 2.0)
	ci.draw_line(da + dh, db + dh, beam, 2.0)
	ci.draw_line(a, a + hv, OUTLINE, 1.0)
	ci.draw_line(b, b + hv, OUTLINE, 1.0)
	var top := PackedVector2Array([c[0] + hv, c[1] + hv, c[2] + hv, c[3] + hv])
	ci.draw_colored_polygon(top, beam)
	return Rect2(Vector2(c[3].x, c[0].y - h), Vector2(c[1].x - c[3].x, c[2].y - c[0].y + h))


## Крыша над всем домом. c — углы прямоугольника дома (N, E, S, W) относительно точки опоры.
## Конёк идёт вдоль длинной стороны; свесы чуть шире стен.
static func draw_roof(ci: CanvasItem, house: Dictionary, c: PackedVector2Array, t: float) -> Rect2:
	var d: Dictionary = house.get("def", {})
	var col := Color(str(ROOFS.get(str(d.get("roof", "thatch")), ROOFS["thatch"])))
	var alpha := 1.0 - float(house.get("open", 0.0))
	if alpha <= 0.01:
		return Rect2()
	var hv := Vector2(0, -WALL_H)
	var n := c[0] + hv + Vector2(0, -3)
	var e := c[1] + hv + Vector2(4, 0)
	var s := c[2] + hv + Vector2(0, 3)
	var w := c[3] + hv + Vector2(-4, 0)
	var r := _rect(house)
	var along_x := r.size.x >= r.size.y
	var short := float(mini(r.size.x, r.size.y))
	var up := Vector2(0, -(10.0 + short * 6.0))
	var mod := Color(1, 1, 1, alpha)
	var r1: Vector2
	var r2: Vector2
	var near: PackedVector2Array    # скат к камере
	var side_l: PackedVector2Array
	var side_r: PackedVector2Array
	if along_x:   # конёк от западной кромки к восточной: скаты на юг и на север
		r1 = w.lerp(n, 0.5) + up
		r2 = s.lerp(e, 0.5) + up
		r1 = r1.lerp(r2, 0.06)
		r2 = r2.lerp(r1, 0.06)
		near = PackedVector2Array([w, s, r2, r1])
		side_r = PackedVector2Array([s, e, r2])
		side_l = PackedVector2Array([w, r1, n])
	else:
		r1 = n.lerp(e, 0.5) + up
		r2 = w.lerp(s, 0.5) + up
		r1 = r1.lerp(r2, 0.06)
		r2 = r2.lerp(r1, 0.06)
		near = PackedVector2Array([s, e, r1, r2])
		side_l = PackedVector2Array([w, s, r2])
		side_r = PackedVector2Array([e, n, r1])
	var far := PackedVector2Array([n, e, r2, r1]) if along_x else PackedVector2Array([n, r1, r2, w])
	ci.draw_colored_polygon(far, col.darkened(0.45) * mod)
	ci.draw_colored_polygon(side_l, col.darkened(0.18) * mod)
	ci.draw_colored_polygon(side_r, col.darkened(0.32) * mod)
	ci.draw_colored_polygon(near, col * mod)
	# ряды черепицы или соломы на ближнем скате
	var rows := 6
	for i in range(1, rows):
		var k := float(i) / float(rows)
		ci.draw_line(near[0].lerp(near[3], k), near[1].lerp(near[2], k), col.darkened(0.22) * mod, 1.0)
	if str(d.get("roof", "")) == "thatch":
		for i in 9:
			var k := (float(i) + 0.5) / 9.0
			ci.draw_line(near[0].lerp(near[1], k), near[0].lerp(near[1], k).lerp(near[3].lerp(near[2], k), 0.25), col.lightened(0.15) * mod, 1.0)
	ci.draw_line(r1, r2, col.lightened(0.3) * mod, 2.0)
	var outline := Color(OUTLINE, alpha)
	ci.draw_polyline(PackedVector2Array([w, s, e]), outline, 1.0)
	ci.draw_polyline(PackedVector2Array([w, r1, r2, e]) if along_x else PackedVector2Array([w, r2, r1, e]), outline, 1.0)
	ci.draw_line(s, r2, outline, 1.0)
	var apex := r1.lerp(r2, 0.5)
	if bool(d.get("chimney", false)):
		var ch := r1.lerp(r2, 0.75) + Vector2(0, 2)
		ci.draw_rect(Rect2(ch + Vector2(-3, -12), Vector2(6, 12)), Color("4a4448") * mod)
		var sm := fmod(t * 8.0, 16.0)
		ci.draw_circle(ch + Vector2(0, -14 - sm), 2.0 + sm * 0.2, Color(0.7, 0.7, 0.7, 0.4 * (1.0 - sm / 16.0) * alpha))
	if bool(d.get("cross", false)):
		ci.draw_rect(Rect2(apex + Vector2(-1, -16), Vector2(3, 16)), Color("d8c890") * mod)
		ci.draw_rect(Rect2(apex + Vector2(-5, -12), Vector2(11, 3)), Color("d8c890") * mod)
	var top := minf(apex.y, minf(r1.y, r2.y)) - 18.0
	return Rect2(Vector2(w.x, top), Vector2(e.x - w.x, s.y - top))


## Дверь поверх рисунка дома снаружи, там, где она на карте (сам рисунок про двери карты не знает): проём, створка,
## порог и фонарь над входом. c — ромб клетки двери относительно точки опоры рисунка.
static func draw_shell_door(ci: CanvasItem, house: Dictionary, cell: Vector2i, c: PackedVector2Array, t: float) -> void:
	var r := _rect(house)
	var along_x := cell.y == r.end.y - 1   # нижний ряд — грань +y (влево-вниз), иначе правый столбец — грань +x
	var a: Vector2 = c[3] if along_x else c[2]
	var b: Vector2 = c[2] if along_x else c[1]
	var dark := 0.28 if along_x else 0.08
	var da := a.lerp(b, 0.18)
	var db := a.lerp(b, 0.82)
	var dh := Vector2(0, -DOOR_H)
	var lift := Vector2(0, -3)
	ci.draw_colored_polygon(PackedVector2Array([da, db, db + dh + lift, da + dh + lift]), Color("24170e"))
	var ia := da.lerp(db, 0.12)
	var ib := da.lerp(db, 0.88)
	var wood := Color("7a5030").darkened(dark)
	ci.draw_colored_polygon(PackedVector2Array([ia, ib, ib + dh, ia + dh]), wood)
	for k in [0.33, 0.66]:
		ci.draw_line(ia.lerp(ib, k), ia.lerp(ib, k) + dh, wood.darkened(0.35), 1.0)
	ci.draw_line(ia + dh * 0.3, ib + dh * 0.3, wood.darkened(0.45), 1.0)
	ci.draw_line(ia + dh * 0.75, ib + dh * 0.75, wood.darkened(0.45), 1.0)
	var knob := ia.lerp(ib, 0.8) + dh * 0.45
	ci.draw_rect(Rect2(knob.round(), Vector2(2, 2)), Color("d8b860"))
	ci.draw_line(da + Vector2(0, 1), db + Vector2(0, 1), Color("8a8070"), 2.0)
	ci.draw_polyline(PackedVector2Array([da, da + dh + lift, db + dh + lift, db]), OUTLINE, 1.0)
	var lamp := da.lerp(db, 0.5) + dh + Vector2(0, -9)
	var fl := 0.75 + 0.25 * sin(t * 5.0 + float(cell.x * 7 + cell.y))
	ci.draw_circle(lamp, 9.0, Color(1.0, 0.7, 0.3, 0.16 * fl))
	ci.draw_rect(Rect2(lamp - Vector2(2, 3), Vector2(4, 5)), Color("2a2018"))
	ci.draw_rect(Rect2(lamp - Vector2(1, 2), Vector2(2, 3)), Color(1.0, 0.82, 0.42, fl))


## Только тёплый свет фонаря над дверью, когда сама дверь нарисована на рисунке дома.
static func draw_door_glow(ci: CanvasItem, house: Dictionary, cell: Vector2i, c: PackedVector2Array, t: float) -> void:
	var r := _rect(house)
	var along_x := cell.y == r.end.y - 1
	var a: Vector2 = c[3] if along_x else c[2]
	var b: Vector2 = c[2] if along_x else c[1]
	var lamp := a.lerp(b, 0.5) + Vector2(0, -DOOR_H - 12.0)
	var fl := 0.75 + 0.25 * sin(t * 5.0 + float(cell.x * 7 + cell.y))
	ci.draw_circle(lamp, 12.0, Color(1.0, 0.7, 0.3, 0.1 * fl))
	ci.draw_circle(lamp, 6.0, Color(1.0, 0.75, 0.35, 0.12 * fl))


## Дощатый пол комнаты. c — ромб клетки в координатах мира.
static func draw_floor(ci: CanvasItem, c: PackedVector2Array, variant: int, alpha := 1.0) -> void:
	var wood := Color("5a3e26") if variant % 2 else Color("624430")
	wood.a = alpha
	ci.draw_colored_polygon(c, wood)
	for k in [0.25, 0.5, 0.75]:
		ci.draw_line(c[3].lerp(c[0], k), c[2].lerp(c[1], k), wood.darkened(0.3), 1.0)
	if variant % 5 == 0:
		ci.draw_rect(Rect2(c[3].lerp(c[1], 0.5).round(), Vector2(1, 1)), wood.darkened(0.45))

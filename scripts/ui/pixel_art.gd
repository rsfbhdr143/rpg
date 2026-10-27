class_name PixelArt
extends RefCounted
## Заглушки в пиксельном стиле: фигурки героев, врагов и NPC, деревья, могилы, дома.
## Рисуются прямо на холсте мира, пока для id нет картинки в data/sprites.json.
## Как только картинка появится, вид возьмёт её, а эти заглушки перестанут рисоваться.
## Внешность фигурок задаётся таблицей LOOKS: цвета одежды, кожи, волос, шапка, оружие.

const OUTLINE := Color("120c0a")

const LOOKS := {
	"knight": {"cloth": "6f7f99", "trim": "d4d8e0", "pants": "3a3f4a", "skin": "e0b090", "hair": "5a3a20", "hat": "helm", "weapon": "greatsword"},
	"wizard": {"cloth": "5d3486", "trim": "d8a840", "pants": "3a2450", "skin": "e8c0a0", "hair": "d8d8e0", "hat": "pointy", "weapon": "staff", "robe": true},
	"ranger": {"cloth": "3d6b3a", "trim": "8a6a3a", "pants": "4a3a28", "skin": "d8a880", "hair": "7a4a20", "hat": "hood", "hood": "2e5230", "weapon": "bow"},
	"cleric": {"cloth": "e2d9c0", "trim": "d8a840", "pants": "a89a80", "skin": "f0c8a8", "hair": "d8a850", "weapon": "mace", "robe": true, "long_hair": true},
	"risen": {"cloth": "4a4636", "trim": "2e2a20", "pants": "3a3628", "skin": "8f9c78", "hair": "3a3a30", "hunch": true, "eyes": "c8e060"},
	"skeleton": {"bones": true, "skin": "ddd5bc", "cloth": "ddd5bc", "pants": "ddd5bc", "weapon": "sword", "eyes": "e04020"},
	"drowned": {"cloth": "2b4a4a", "trim": "4a8a5a", "pants": "1f3838", "skin": "6b9e9a", "hair": "2a5a40", "drip": true, "hunch": true, "eyes": "a0f0ff"},
	"goblin_warrior": {"cloth": "6a4426", "trim": "3a2a18", "pants": "4a3018", "skin": "6e9e3a", "small": true, "ears": true, "weapon": "cleaver", "eyes": "f0d040"},
	"goblin_scout": {"cloth": "4a5a2a", "trim": "3a2a18", "pants": "3a3018", "skin": "7aa840", "small": true, "ears": true, "weapon": "bow", "hat": "hood", "hood": "3a4a22", "eyes": "f0d040"},
	"goblin_shaman": {"cloth": "5a2e5a", "trim": "c8a040", "pants": "3a2038", "skin": "6e9e3a", "small": true, "ears": true, "weapon": "staff", "feathers": true, "robe": true, "eyes": "f0d040"},
	"boss_mukhoglot": {"cloth": "4a2648", "trim": "d8b048", "pants": "2a1830", "skin": "5f8e34", "ears": true, "weapon": "staff", "feathers": true, "robe": true, "big": true, "flies": true, "eyes": "ff6030"},
	"mukhoglot": {"cloth": "4a2648", "trim": "d8b048", "pants": "2a1830", "skin": "5f8e34", "ears": true, "weapon": "staff", "feathers": true, "robe": true, "big": true, "flies": true, "eyes": "ff6030"},
	"shmyg": {"cloth": "7a5a30", "trim": "4a3018", "pants": "4a3018", "skin": "86b04a", "small": true, "ears": true, "eyes": "f0d040"},
	"lado_body": {"cloth": "d6d2c4", "trim": "a8a294", "pants": "c4c0b0", "skin": "a8b4a8", "hair": "4a3a2a", "shroud": true, "hunch": true, "eyes": "202020"},
	"lado_ghost": {"cloth": "a8d8ff", "trim": "e0f4ff", "pants": "a8d8ff", "skin": "c8ecff", "hair": "a8d8ff", "ghost": true},
	"tadeush": {"cloth": "22202a", "trim": "e8e8e8", "pants": "1a1820", "skin": "e0b898", "hair": "8a8a8a", "robe": true, "hat": "cap"},
	"marta": {"cloth": "8a3a2a", "trim": "e2d8c0", "pants": "5a2a20", "skin": "f0c8a8", "hair": "c06a28", "robe": true, "long_hair": true, "apron": true},
	"pipin": {"cloth": "3a3a5c", "trim": "d8c890", "pants": "2a2a40", "skin": "f0c8a8", "hair": "6a5030", "hat": "tall", "small": true},
	"sych": {"cloth": "4a3a2a", "trim": "2a2018", "pants": "3a2e20", "skin": "d0a080", "hair": "5a5a5a", "weapon": "shovel", "hunch": true},
	"gunter": {"cloth": "5a4030", "trim": "2a1e16", "pants": "3a2a20", "skin": "d89870", "hair": "2a1a10", "weapon": "hammer", "big": true, "apron": true},
	"vetla": {"cloth": "5a6a3a", "trim": "a87a40", "pants": "3a4428", "skin": "e0b898", "hair": "c8c8a8", "hat": "hood", "hood": "4a5830", "robe": true, "long_hair": true, "weapon": "staff"},
	"zaraza": {"beast": "goat", "fur": "e0d8c4", "dark": "8a8270"},
	"wolf": {"beast": "wolf", "fur": "6e6e70", "dark": "3e3e42"},
}


static func look(id: String) -> Dictionary:
	if LOOKS.has(id):
		return LOOKS[id]
	if id.begins_with("goblin"):
		return LOOKS["goblin_warrior"]
	var h := absi(id.hash())
	var palette := ["6a4a3a", "3a5a6a", "6a6a3a", "5a3a5a", "3a6a4a"]
	return {"cloth": palette[h % palette.size()], "trim": "c8a060", "pants": "3a3028", "skin": "e0b090", "hair": "4a3020"}


static func _c(hex: Variant) -> Color:
	return Color(str(hex)) if hex != null else Color.MAGENTA


## Прямоугольник с контуром (пиксельная обводка в 1 пиксель мира).
static func _box(ci: CanvasItem, o: Vector2, x: float, y: float, w: float, h: float, col: Color, s: float, outline := true, tint := Color(1, 1, 1, 1)) -> void:
	var c := col * tint
	c.a = col.a * tint.a
	if outline:
		var oc := OUTLINE
		oc.a = c.a
		ci.draw_rect(Rect2(o + Vector2(x - 1, y - 1) * s, Vector2(w + 2, h + 2) * s), oc)
	ci.draw_rect(Rect2(o + Vector2(x, y) * s, Vector2(w, h) * s), c)


static func _px(ci: CanvasItem, o: Vector2, x: float, y: float, col: Color, s: float, w := 1.0, h := 1.0) -> void:
	ci.draw_rect(Rect2(o + Vector2(x, y) * s, Vector2(w, h) * s), col)


# --- Фигурки ------------------------------------------------------------------------

## Нарисовать фигурку. feet — точка ног (низ по центру), facing 1 — вправо, -1 — влево.
## Возвращает прямоугольник фигурки (для кликов и полоски здоровья).
static func draw_unit(ci: CanvasItem, id: String, feet: Vector2, facing: int, t: float, s: float,
		tint := Color(1, 1, 1, 1), dead := false) -> Rect2:
	var lk := look(id)
	var k := s
	if bool(lk.get("big", false)):
		k *= 1.25
	elif bool(lk.get("small", false)):
		k *= 0.82
	var o := feet.round()
	if dead:
		return _draw_dead(ci, lk, o, k, tint)
	if lk.has("beast"):
		return _draw_beast(ci, lk, o, facing, t, k, tint)
	return _draw_humanoid(ci, lk, o, facing, t, k, tint)


static func _draw_humanoid(ci: CanvasItem, lk: Dictionary, o: Vector2, f: int, t: float, k: float, tint: Color) -> Rect2:
	var cloth := _c(lk.get("cloth"))
	var trim := _c(lk.get("trim"))
	var pants := _c(lk.get("pants", "3a3028"))
	var skin := _c(lk.get("skin"))
	var hair := _c(lk.get("hair", "3a2a1a"))
	var ghost := bool(lk.get("ghost", false))
	var bones := bool(lk.get("bones", false))
	if ghost:
		tint = Color(tint.r, tint.g, tint.b, tint.a * 0.7)
	var bob := roundf(sin(t * 2.6) * 0.6 + 0.4) if not ghost else roundf(sin(t * 2.0) * 1.5) - 2.0
	var hunch := 2.0 if bool(lk.get("hunch", false)) else 0.0
	var hx := hunch * f   # голова и плечи вперёд
	var top := -30.0 + hunch + bob
	# ноги
	if not ghost:
		if bool(lk.get("robe", false)) or bool(lk.get("shroud", false)):
			_box(ci, o, -5, -10, 10, 10, cloth.darkened(0.1), k, true, tint)
			_px(ci, o, -5, -2, cloth.darkened(0.35) * tint, k, 10, 2)
		elif bones:
			_box(ci, o, -4, -9, 2, 9, skin, k, true, tint)
			_box(ci, o, 2, -9, 2, 9, skin, k, true, tint)
		else:
			_box(ci, o, -4, -9, 3, 9, pants, k, true, tint)
			_box(ci, o, 1, -9, 3, 9, pants, k, true, tint)
			_px(ci, o, -4, -2, pants.darkened(0.45) * tint, k, 3, 2)
			_px(ci, o, 1, -2, pants.darkened(0.45) * tint, k, 3, 2)
	else:
		for i in 3:
			var wv := sin(t * 4.0 + i) * 1.0
			_px(ci, o, -4 + i * 3 + wv, -6 + bob, Color(cloth.r, cloth.g, cloth.b, 0.5) * tint, k, 2, 4)
	# оружие за спиной (лук)
	var weapon := str(lk.get("weapon", ""))
	if weapon == "bow":
		var bx := -6.0 * f
		for i in 13:
			var yy := -24.0 + i + bob
			var xx := bx - f * (1.5 - absf(i - 6.0) / 4.0)
			_px(ci, o, xx, yy, Color("8a5a2a") * tint, k)
		_px(ci, o, bx + f * 1.0, -24 + bob, Color("d8d0b0") * tint, k, 1, 13)
	# туловище
	var ty := top + 9.0
	if bones:
		_box(ci, o, -1 + hx * 0.5, ty, 2, 12, skin, k, true, tint)
		for i in 4:
			_box(ci, o, -4 + hx * 0.5, ty + 1 + i * 3, 8, 1, skin, k, false, tint)
	else:
		_box(ci, o, -5 + hx * 0.5, ty, 10, 12, cloth, k, true, tint)
		_px(ci, o, -5 + hx * 0.5, ty + 8, trim * tint, k, 10, 1)
		if bool(lk.get("apron", false)):
			_px(ci, o, -3 + hx * 0.5, ty + 4, trim.lightened(0.1) * tint, k, 6, 8)
		if bool(lk.get("shroud", false)):
			for i in 3:
				_px(ci, o, -5 + hx * 0.5, ty + 2 + i * 4, trim * tint, k, 10, 1)
		_px(ci, o, -5 + hx * 0.5, ty, cloth.lightened(0.15) * tint, k, 10, 1)
	# руки
	var arm := cloth.darkened(0.2) if not bones else skin
	var reach := 2.0 * f if bool(lk.get("hunch", false)) else 0.0
	_box(ci, o, -7 + hx * 0.5 + minf(reach, 0), ty + 1, 2, 9, arm, k, true, tint)
	_box(ci, o, 5 + hx * 0.5 + maxf(reach, 0), ty + 1, 2, 9, arm, k, true, tint)
	_px(ci, o, -7 + hx * 0.5 + minf(reach, 0), ty + 9, skin * tint, k, 2, 2)
	_px(ci, o, 5 + hx * 0.5 + maxf(reach, 0), ty + 9, skin * tint, k, 2, 2)
	# голова
	var hx2 := -4.0 + hx
	if bool(lk.get("long_hair", false)):
		_box(ci, o, hx2 - 1, top - 1, 10, 13, hair, k, true, tint)
	_box(ci, o, hx2, top, 8, 8, skin, k, true, tint)
	if bool(lk.get("ears", false)):
		_box(ci, o, hx2 - 3, top + 2, 3, 2, skin, k, true, tint)
		_box(ci, o, hx2 + 8, top + 2, 3, 2, skin, k, true, tint)
	var eye := _c(lk.get("eyes", "1a1210"))
	var ex := hx2 + (4.0 if f > 0 else 1.0)
	_px(ci, o, ex, top + 3, eye * tint, k)
	_px(ci, o, ex + 2, top + 3, eye * tint, k)
	if bones:
		_px(ci, o, hx2 + 2, top + 6, OUTLINE * tint, k, 4, 1)
	# волосы и шапки
	var hat := str(lk.get("hat", ""))
	match hat:
		"helm":
			_box(ci, o, hx2 - 1, top - 2, 10, 5, Color("9aa4b4"), k, true, tint)
			_px(ci, o, hx2 - 1, top + 3, Color("9aa4b4") * tint, k, 2, 4)
			_px(ci, o, hx2 + 7, top + 3, Color("9aa4b4") * tint, k, 2, 4)
			_px(ci, o, hx2 + 3, top - 4, Color("c84030") * tint, k, 2, 2)
		"pointy":
			_box(ci, o, hx2 - 3, top - 1, 14, 2, cloth.darkened(0.15), k, true, tint)
			for i in 8:
				_px(ci, o, hx2 + 1 + i * 0.4 + f * i * 0.3, top - 2 - i, cloth.darkened(0.15) * tint, k, 6 - i * 0.6, 1)
			_px(ci, o, hx2 + 2, top - 2, trim * tint, k, 4, 1)
		"hood":
			var hood := _c(lk.get("hood", "3a4a2a"))
			_box(ci, o, hx2 - 1, top - 2, 10, 4, hood, k, true, tint)
			_px(ci, o, hx2 - 1, top + 2, hood * tint, k, 2, 6)
			_px(ci, o, hx2 + 7, top + 2, hood * tint, k, 2, 6)
		"tall":
			_box(ci, o, hx2 - 1, top - 1, 10, 2, Color("1a1a22"), k, true, tint)
			_box(ci, o, hx2 + 1, top - 8, 6, 7, Color("1a1a22"), k, true, tint)
			_px(ci, o, hx2 + 1, top - 3, Color("a02020") * tint, k, 6, 1)
		"cap":
			_px(ci, o, hx2, top - 1, hair * tint, k, 8, 2)
			_px(ci, o, hx2 + 2, top - 2, Color("1a1820") * tint, k, 4, 2)
		_:
			if not bones:
				_px(ci, o, hx2, top - 1, hair * tint, k, 8, 3)
				_px(ci, o, hx2 + (0.0 if f > 0 else 6.0), top + 1, hair * tint, k, 2, 3)
	if bool(lk.get("feathers", false)):
		var cols := [Color("d84030"), Color("e8c040"), Color("40a0d8")]
		for i in 3:
			_box(ci, o, hx2 + 1 + i * 2.5, top - 6 - (1 if i == 1 else 0), 1.5, 5, cols[i], k, true, tint)
	# оружие в руке
	var hand := Vector2((6.0 + hx * 0.5 + maxf(reach, 0)) * f if f > 0 else (-6.0 + hx * 0.5 + minf(reach, 0)), ty + 9)
	match weapon:
		"greatsword":
			_box(ci, o, hand.x - 0.5, hand.y - 20, 2, 18, Color("d0d8e0"), k, true, tint)
			_box(ci, o, hand.x - 3, hand.y - 2, 7, 1.5, Color("8a6a3a"), k, true, tint)
		"sword", "cleaver":
			_box(ci, o, hand.x - 0.5, hand.y - 9, 2 if weapon == "sword" else 3, 8, Color("b8b8b0"), k, true, tint)
			_px(ci, o, hand.x - 2, hand.y - 1, Color("6a4a2a") * tint, k, 5, 1)
		"staff":
			_box(ci, o, hand.x, hand.y - 22, 1.5, 30, Color("7a5230"), k, true, tint)
			var gem := trim if not bool(lk.get("flies", false)) else Color("80ff60")
			_box(ci, o, hand.x - 1, hand.y - 25, 3.5, 3, gem.lightened(0.2), k, true, tint)
		"mace":
			_box(ci, o, hand.x, hand.y - 9, 1.5, 10, Color("6a4a2a"), k, true, tint)
			_box(ci, o, hand.x - 1.5, hand.y - 13, 4.5, 4, Color("a8a8b0"), k, true, tint)
		"shovel":
			_box(ci, o, hand.x, hand.y - 18, 1.5, 22, Color("7a5230"), k, true, tint)
			_box(ci, o, hand.x - 1.5, hand.y + 3, 4.5, 5, Color("8a8a90"), k, true, tint)
		"hammer":
			_box(ci, o, hand.x, hand.y - 8, 1.5, 10, Color("6a4a2a"), k, true, tint)
			_box(ci, o, hand.x - 2.5, hand.y - 11, 6.5, 3.5, Color("5a5a62"), k, true, tint)
	if bool(lk.get("drip", false)):
		var dy := fmod(t * 14.0, 12.0)
		_px(ci, o, -3 + hx, top + 8 + dy, Color(0.5, 0.8, 1.0, 0.8) * tint, k)
		_px(ci, o, 4, ty + 6 + fmod(dy + 5.0, 12.0), Color(0.5, 0.8, 1.0, 0.8) * tint, k)
	if bool(lk.get("flies", false)):
		for i in 4:
			var a := t * 3.0 + i * 1.7
			_px(ci, o, hand.x + cos(a) * 5.0, hand.y - 26 + sin(a * 1.3) * 3.0, OUTLINE * tint, k)
	var h := 36.0 if not bool(lk.get("feathers", false)) else 40.0
	return Rect2(o + Vector2(-9, -h + bob) * k, Vector2(18, h) * k)


static func _draw_beast(ci: CanvasItem, lk: Dictionary, o: Vector2, f: int, t: float, k: float, tint: Color) -> Rect2:
	var fur := _c(lk.get("fur"))
	var dark := _c(lk.get("dark"))
	var goat := str(lk.get("beast", "")) == "goat"
	var bob := roundf(sin(t * 3.0) * 0.5 + 0.5)
	var sx := float(f)
	# ноги
	for lx in [-7.0, -4.0, 4.0, 7.0]:
		_box(ci, o, lx * sx - 1, -6, 2, 6, dark, k, true, tint)
	# хвост
	_box(ci, o, -11.0 * sx - (2 if sx > 0 else 0), -12 + bob, 3, 2, fur, k, true, tint)
	# туловище
	_box(ci, o, -9, -13 + bob, 18, 8, fur, k, true, tint)
	_px(ci, o, -9, -7 + bob, fur.darkened(0.2) * tint, k, 18, 2)
	# голова
	var hx := 8.0 * sx - (0.0 if sx > 0 else 7.0)
	_box(ci, o, hx, -17 + bob, 7, 6, fur, k, true, tint)
	_box(ci, o, hx + (5.0 if sx > 0 else -2.0), -14 + bob, 4, 3, fur.lightened(0.1), k, true, tint)
	_px(ci, o, hx + (4.0 if sx > 0 else 2.0), -16 + bob, Color("f0d040") * tint if not goat else OUTLINE * tint, k)
	if goat:
		_box(ci, o, hx + 1, -21 + bob, 1.5, 4, Color("b0a080"), k, true, tint)
		_box(ci, o, hx + 4, -21 + bob, 1.5, 4, Color("b0a080"), k, true, tint)
		_px(ci, o, hx + (6.0 if sx > 0 else 0.0), -11 + bob, fur.darkened(0.3) * tint, k, 1, 3)
	else:
		_box(ci, o, hx + 1, -20 + bob, 2, 3, dark, k, true, tint)
		_box(ci, o, hx + 4, -20 + bob, 2, 3, dark, k, true, tint)
	return Rect2(o + Vector2(-13, -22) * k, Vector2(26, 22) * k)


static func _draw_dead(ci: CanvasItem, lk: Dictionary, o: Vector2, k: float, tint: Color) -> Rect2:
	var cloth := _c(lk.get("cloth", lk.get("fur", "5a5a5a")))
	var skin := _c(lk.get("skin", lk.get("fur", "a0a0a0")))
	var t := Color(tint.r * 0.75, tint.g * 0.75, tint.b * 0.75, tint.a * 0.85)
	_box(ci, o, -9, -4, 13, 4, cloth, k, true, t)
	_box(ci, o, 4, -5, 5, 5, skin, k, true, t)
	return Rect2(o + Vector2(-10, -6) * k, Vector2(20, 6) * k)


# --- Портреты (для интерфейса) -----------------------------------------------------------

## Портрет-заглушка: крупная голова в рамке. Рисуется на Control в rect.
static func draw_portrait(ci: CanvasItem, id: String, rect: Rect2, t := 0.0) -> void:
	var lk := look(id)
	ci.draw_rect(rect, Color("221a14"))
	# по пояс: макушка чуть ниже верхнего края, ноги уходят за нижний (рамку надо обрезать, см. IconArt.PortraitView)
	var side := minf(rect.size.x, rect.size.y)
	var s := floorf(side / 24.0) if side >= 48.0 else side / 24.0
	var ghost := Color(1, 1, 1, 1)
	if lk.has("beast"):
		_draw_beast(ci, lk, rect.position + Vector2(rect.size.x * 0.5, rect.size.y - 2 * s), 1, t, s * 1.4, ghost)
		return
	var o := rect.position + Vector2(rect.size.x * 0.5, 35.0 * s)
	_draw_humanoid(ci, lk, o, 1, t, s, ghost)


# --- Декорации ------------------------------------------------------------------------

## Декорация на клетке. base — центр ромба клетки (или низ здания), s — масштаб (1 — обычный).
## Для зданий передаются углы основания (N, E, S, W).
static func draw_prop(ci: CanvasItem, id: String, base: Vector2, s: float, t: float, variant: int,
		corners: PackedVector2Array = PackedVector2Array(), lit := false) -> Rect2:
	var o := base.round()
	match id:
		"grave", "open_grave", "fresh_grave":
			var fresh := id != "grave"
			_iso_mound(ci, o, s, Color("4a3a26") if fresh else Color("3e4a2c"))
			if fresh:
				for i in 4:
					_px(ci, o, -6 + i * 4, -3 - (i % 2), Color("2a2016"), s, 2, 1)
				_box(ci, o, 7, -14, 1.5, 12, Color("7a5230"), s)
				_box(ci, o, 5.5, -3, 4.5, 3, Color("8a8a90"), s)
			else:
				_box(ci, o, -1, -14, 2, 12, Color("6a5a48"), s)
				_box(ci, o, -4, -11, 8, 2, Color("6a5a48"), s)
			return Rect2(o + Vector2(-10, -15) * s, Vector2(20, 18) * s)
		"tombstone":
			_box(ci, o, -5, -16, 10, 15, Color("7a7a80"), s)
			_px(ci, o, -4, -17, Color("7a7a80"), s, 8, 1)
			_px(ci, o, -3, -12, Color("4a4a50"), s, 6, 1)
			_px(ci, o, -3, -9, Color("4a4a50"), s, 6, 1)
			_px(ci, o, -5, -3, Color("4a6a30"), s, 4, 2)
			return Rect2(o + Vector2(-6, -18) * s, Vector2(12, 18) * s)
		"dead_tree":
			_box(ci, o, -2, -30, 4, 30, Color("3a2e26"), s)
			_box(ci, o, -9, -26, 7, 2, Color("3a2e26"), s)
			_box(ci, o, -10, -32, 2, 7, Color("3a2e26"), s)
			_box(ci, o, 2, -22, 8, 2, Color("3a2e26"), s)
			_box(ci, o, 8, -29, 2, 8, Color("3a2e26"), s)
			_box(ci, o, -1, -38, 2, 8, Color("3a2e26"), s)
			return Rect2(o + Vector2(-11, -39) * s, Vector2(22, 39) * s)
		"tree":
			return _tree(ci, o, s, t, variant, Color("2e5a2a"))
		"bush":
			var g := Color("3a6a2e") if variant % 2 == 0 else Color("446e30")
			_blob(ci, o + Vector2(0, -4) * s, 7.0 * s, 4.0 * s, g)
			_blob(ci, o + Vector2(-3, -6) * s, 4.0 * s, 3.0 * s, g.lightened(0.12))
			if variant % 3 == 0:
				_px(ci, o, 2, -7, Color("d84a5a"), s)
				_px(ci, o, -4, -5, Color("d84a5a"), s)
			return Rect2(o + Vector2(-8, -9) * s, Vector2(16, 10) * s)
		"reeds":
			for i in 5:
				var x := -6.0 + i * 3.0
				var hgt := 8.0 + float((variant + i * 7) % 6)
				var sway := sin(t * 1.5 + i + variant) * 1.0
				_px(ci, o, x + sway * 0.5, -hgt, Color("6a8a3a"), s, 1, hgt)
				_px(ci, o, x + sway, -hgt - 2, Color("8a6a3a"), s, 1, 3)
			return Rect2(o + Vector2(-7, -16) * s, Vector2(14, 16) * s)
		"funeral_candles":
			for i in 3:
				var x := -5.0 + i * 5.0
				var hgt := 5.0 + (i % 2) * 2.0
				_box(ci, o, x, -hgt, 2, hgt, Color("e8e0c8"), s)
				var fl := 0.6 + 0.4 * sin(t * 9.0 + i * 2.0)
				_px(ci, o, x, -hgt - 3, Color(1.0, 0.75, 0.3, 0.9), s, 2, 2 + fl)
				ci.draw_circle(o + Vector2(x + 1, -hgt - 2) * s, 4.0 * s, Color(1.0, 0.7, 0.3, 0.12 * fl))
			return Rect2(o + Vector2(-6, -11) * s, Vector2(14, 11) * s)
		"coffin":
			var pts := PackedVector2Array([o + Vector2(-12, -2) * s, o + Vector2(-2, -8) * s, o + Vector2(12, -2) * s, o + Vector2(2, 4) * s])
			var lift := Vector2(0, -5) * s
			ci.draw_colored_polygon(PackedVector2Array([pts[3], pts[0], pts[0] + lift, pts[3] + lift]), Color("4a2e1a"))
			ci.draw_colored_polygon(PackedVector2Array([pts[3], pts[2], pts[2] + lift, pts[3] + lift]), Color("5a3820"))
			var top := PackedVector2Array([pts[0] + lift, pts[1] + lift, pts[2] + lift, pts[3] + lift])
			ci.draw_colored_polygon(top, Color("7a4e2c"))
			top.append(top[0])
			ci.draw_polyline(top, OUTLINE, s)
			ci.draw_line(o + Vector2(-3, -6) * s + lift, o + Vector2(3, -2) * s + lift, Color("d8c890"), s)
			return Rect2(o + Vector2(-13, -14) * s, Vector2(26, 18) * s)
		"well":
			_box(ci, o, -8, -9, 16, 9, Color("6a6a70"), s)
			_px(ci, o, -6, -9, Color("1a2a3a"), s, 12, 2)
			_box(ci, o, -8, -24, 2, 15, Color("6a4a2a"), s)
			_box(ci, o, 6, -24, 2, 15, Color("6a4a2a"), s)
			_box(ci, o, -10, -27, 20, 3, Color("7a3a2a"), s)
			return Rect2(o + Vector2(-11, -28) * s, Vector2(22, 28) * s)
		"notice_board":
			_box(ci, o, -7, -24, 2, 24, Color("6a4a2a"), s)
			_box(ci, o, 5, -24, 2, 24, Color("6a4a2a"), s)
			_box(ci, o, -9, -22, 18, 12, Color("8a6038"), s)
			for i in 3:
				_px(ci, o, -7 + i * 5, -20 + (i % 2) * 2, Color("e8e0c8"), s, 4, 5)
			return Rect2(o + Vector2(-10, -25) * s, Vector2(20, 25) * s)
		"fence":
			_box(ci, o, -8, -10, 2, 10, Color("6a4a2a"), s)
			_box(ci, o, 6, -10, 2, 10, Color("6a4a2a"), s)
			_box(ci, o, -9, -8, 18, 2, Color("7a5a32"), s)
			_box(ci, o, -9, -4, 18, 2, Color("7a5a32"), s)
			return Rect2(o + Vector2(-10, -11) * s, Vector2(20, 11) * s)
		"rock":
			_blob(ci, o + Vector2(0, -5) * s, 9.0 * s, 6.0 * s, Color("5e5e64"))
			_blob(ci, o + Vector2(-2, -7) * s, 5.0 * s, 3.5 * s, Color("76767c"))
			return Rect2(o + Vector2(-9, -11) * s, Vector2(18, 12) * s)
		"tent":
			var a := o + Vector2(-12, 0) * s
			var b := o + Vector2(12, 0) * s
			var c := o + Vector2(0, -20) * s
			ci.draw_colored_polygon(PackedVector2Array([a, b, c]), Color("8a6a46"))
			ci.draw_colored_polygon(PackedVector2Array([o + Vector2(-3, 0) * s, o + Vector2(3, 0) * s, o + Vector2(0, -10) * s]), Color("2a1e14"))
			ci.draw_polyline(PackedVector2Array([a, c, b, a]), OUTLINE, s)
			_px(ci, o, -1, -24, Color("6a4a2a"), s, 2, 5)
			return Rect2(o + Vector2(-12, -24) * s, Vector2(24, 24) * s)
		"totem":
			_box(ci, o, -2, -28, 4, 28, Color("6a4a2a"), s)
			_box(ci, o, -4, -34, 8, 7, Color("e0d8c0"), s)
			_px(ci, o, -2, -32, OUTLINE, s, 1, 2)
			_px(ci, o, 1, -32, OUTLINE, s, 1, 2)
			_px(ci, o, -6, -24, Color("c84030"), s, 12, 2)
			return Rect2(o + Vector2(-6, -35) * s, Vector2(12, 35) * s)
		"campfire", "pyre":
			var big := id == "pyre"
			var w := 12.0 if big else 7.0
			for i in (4 if big else 2):
				_box(ci, o, -w + i * 2, -3 - i * 2, w * 2 - i * 4, 2, Color("6a4428"), s)
			if id == "campfire" or lit:
				for i in (6 if big else 3):
					var fl := sin(t * 11.0 + i * 1.9)
					var x := -w * 0.6 + i * (w * 1.2 / float(5 if big else 2))
					var hh := (8.0 if big else 5.0) + fl * 2.0 + float(i % 2) * 3.0
					_px(ci, o, x, -4 - hh - (8 if big else 0), Color(1.0, 0.55 + 0.2 * fl, 0.15, 0.9), s, 2, hh)
				ci.draw_circle(o + Vector2(0, -8) * s, (22.0 if big else 14.0) * s, Color(1.0, 0.6, 0.2, 0.1))
			return Rect2(o + Vector2(-w - 1, -20) * s, Vector2(w * 2 + 2, 20) * s)
		"bones":
			_px(ci, o, -5, -2, Color("e0d8c0"), s, 6, 1)
			_px(ci, o, 1, -4, Color("e0d8c0"), s, 1, 4)
			_box(ci, o, 3, -4, 3, 3, Color("e0d8c0"), s)
			return Rect2(o + Vector2(-6, -5) * s, Vector2(12, 5) * s)
		"bone_throne":
			_box(ci, o, -9, -10, 18, 10, Color("d8d0b8"), s)
			_box(ci, o, -9, -30, 4, 22, Color("d8d0b8"), s)
			_box(ci, o, 5, -30, 4, 22, Color("d8d0b8"), s)
			_box(ci, o, -6, -32, 12, 6, Color("e8e0c8"), s)
			_px(ci, o, -3, -30, OUTLINE, s, 2, 2)
			_px(ci, o, 1, -30, OUTLINE, s, 2, 2)
			_px(ci, o, -7, -9, Color("6a2a4a"), s, 14, 3)
			return Rect2(o + Vector2(-10, -33) * s, Vector2(20, 33) * s)
		"goat_stump":
			_box(ci, o, -5, -6, 10, 6, Color("6a4a2a"), s)
			_px(ci, o, -4, -6, Color("a07a4a"), s, 8, 2)
			_px(ci, o, 5, -4, Color("c8b890"), s, 6, 1)
			return Rect2(o + Vector2(-6, -7) * s, Vector2(12, 7) * s)
		"lado_tracks":
			for i in 3:
				_px(ci, o, -6 + i * 5, -1 - i * 2, Color(0.1, 0.08, 0.05, 0.7), s, 2, 3)
			return Rect2(o + Vector2(-7, -7) * s, Vector2(14, 8) * s)
		"tadeush_table":
			_box(ci, o, -8, -10, 16, 3, Color("7a5230"), s)
			_box(ci, o, -7, -7, 2, 7, Color("5a3a20"), s)
			_box(ci, o, 5, -7, 2, 7, Color("5a3a20"), s)
			_px(ci, o, -3, -12, Color("f0e8d0"), s, 6, 2)
			return Rect2(o + Vector2(-9, -13) * s, Vector2(18, 13) * s)
		"church_door", "tavern_door":
			var pulse := 0.5 + 0.5 * sin(t * 3.0)
			ci.draw_circle(o + Vector2(0, -2) * s, 5.0 * s, Color(1.0, 0.85, 0.4, 0.15 + 0.15 * pulse))
			_px(ci, o, -2, -4, Color(1.0, 0.85, 0.4, 0.6 + 0.4 * pulse), s, 4, 2)
			return Rect2(o + Vector2(-6, -8) * s, Vector2(12, 10) * s)
	if corners.size() == 4:
		return draw_building(ci, id, corners, s, t)
	# неизвестная декорация: камень с меткой
	_blob(ci, o + Vector2(0, -4) * s, 6.0 * s, 4.0 * s, Color("6a5a4a"))
	return Rect2(o + Vector2(-6, -8) * s, Vector2(12, 8) * s)


static func _tree(ci: CanvasItem, o: Vector2, s: float, t: float, variant: int, leaf: Color) -> Rect2:
	var v := variant % 4
	var hgt := 34.0 + v * 3.0
	var sway := sin(t * 1.2 + variant) * 0.8
	_box(ci, o, -2, -14, 4, 14, Color("4a3424"), s)
	var g := leaf.darkened(0.05 * v)
	_blob(ci, o + Vector2(sway, -hgt * 0.55) * s, 11.0 * s, 9.0 * s, g.darkened(0.25))
	_blob(ci, o + Vector2(-4 + sway, -hgt * 0.7) * s, 8.0 * s, 7.0 * s, g)
	_blob(ci, o + Vector2(4 + sway, -hgt * 0.72) * s, 7.0 * s, 6.0 * s, g.lightened(0.05))
	_blob(ci, o + Vector2(sway, -hgt * 0.92) * s, 6.0 * s, 5.0 * s, g.lightened(0.15))
	return Rect2(o + Vector2(-12, -hgt - 4) * s, Vector2(24, hgt + 4) * s)


## Пиксельный «овал» из полосок (без сглаживания).
static func _blob(ci: CanvasItem, c: Vector2, rx: float, ry: float, col: Color) -> void:
	var step := maxf(1.0, ry / 5.0)
	var y := -ry
	ci.draw_rect(Rect2(c + Vector2(-rx - 1, -ry - 1), Vector2(rx * 2 + 2, ry * 2 + 2)).grow(-maxf(1.0, rx * 0.3)), OUTLINE)
	while y < ry:
		var w := rx * sqrt(maxf(0.0, 1.0 - (y / ry) * (y / ry)))
		ci.draw_rect(Rect2(c + Vector2(-w, y).round(), Vector2(w * 2, step + 0.5).round()), col if y > -ry * 0.6 else col.lightened(0.1))
		y += step


## Полупрозрачный пиксельный «овал» без контура (облака, дым).
static func _blob_soft(ci: CanvasItem, c: Vector2, rx: float, ry: float, col: Color) -> void:
	var y := -ry
	while y < ry:
		var w := roundf(rx * sqrt(maxf(0.0, 1.0 - (y / ry) * (y / ry))))
		ci.draw_rect(Rect2(c + Vector2(-w, y).round(), Vector2(w * 2, 1)), col)
		y += 1.0


static func _iso_mound(ci: CanvasItem, o: Vector2, s: float, col: Color) -> void:
	var pts := PackedVector2Array([o + Vector2(-10, 0) * s, o + Vector2(0, -5) * s, o + Vector2(10, 0) * s, o + Vector2(0, 5) * s])
	ci.draw_colored_polygon(pts, col)
	var top := PackedVector2Array([o + Vector2(-7, -2) * s, o + Vector2(0, -6) * s, o + Vector2(7, -2) * s, o + Vector2(0, 2) * s])
	ci.draw_colored_polygon(top, col.lightened(0.1))
	pts.append(pts[0])
	ci.draw_polyline(pts, OUTLINE, s)


# --- Здания ------------------------------------------------------------------------------

const BUILDINGS := {
	"house":      {"wall": "8a6a48", "roof": "b89040", "height": 22, "roof_h": 16},
	"tavern":     {"wall": "7a5232", "roof": "8a2e22", "height": 26, "roof_h": 18, "sign": true},
	"smithy":     {"wall": "5e5e62", "roof": "3a3238", "height": 22, "roof_h": 12, "chimney": true},
	"church":     {"wall": "8a8478", "roof": "4a4a58", "height": 30, "roof_h": 20, "cross": true},
	"vetla_hut":  {"wall": "6a5034", "roof": "8a8a3a", "height": 18, "roof_h": 14},
	"bell_tower": {"wall": "8a8478", "roof": "4a4a58", "height": 58, "roof_h": 22, "bell": true},
}


## Здание по углам основания: N (дальний), E (правый), S (ближний), W (левый).
static func draw_building(ci: CanvasItem, id: String, c: PackedVector2Array, s: float, t: float) -> Rect2:
	var b: Dictionary = BUILDINGS.get(id, BUILDINGS["house"])
	var wall := Color(str(b["wall"]))
	var roof := Color(str(b["roof"]))
	var n := c[0]
	var e := c[1]
	var so := c[2]
	var w := c[3]
	var h := Vector2(0, -float(b["height"]) * s)
	var rh := float(b["roof_h"]) * s
	var left := PackedVector2Array([w, so, so + h, w + h])
	var right := PackedVector2Array([so, e, e + h, so + h])
	ci.draw_colored_polygon(left, wall.darkened(0.25))
	ci.draw_colored_polygon(right, wall)
	# брёвна / кладка
	var rows := int(float(b["height"]) / 5.0)
	for i in range(1, rows):
		var k := float(i) / float(rows)
		ci.draw_line(w + h * k, so + h * k, wall.darkened(0.4), s)
		ci.draw_line(so + h * k, e + h * k, wall.darkened(0.15), s)
	# дверь и окна на ближних гранях
	var door_c := w.lerp(so, 0.5)
	var dw := 4.0 * s
	ci.draw_colored_polygon(PackedVector2Array([door_c + Vector2(-dw, -dw * 0.5), door_c + Vector2(dw, dw * 0.5),
		door_c + Vector2(dw, dw * 0.5) + Vector2(0, -12 * s), door_c + Vector2(-dw, -dw * 0.5) + Vector2(0, -12 * s)]), Color("2a1a10"))
	var lit := 0.75 + 0.25 * sin(t * 2.0)
	for k in [0.3, 0.7]:
		var wc := so.lerp(e, k) + h * 0.55
		ci.draw_colored_polygon(PackedVector2Array([wc + Vector2(-3, 1.5) * s, wc + Vector2(3, -1.5) * s,
			wc + Vector2(3, -6.5) * s, wc + Vector2(-3, -3.5) * s]), Color(1.0, 0.8, 0.4, lit))
	# крыша: конёк вдоль длинной стороны
	var nw := n + h
	var ne := e + h
	var se := so + h
	var sw := w + h
	var up := Vector2(0, -rh)
	var along_x := n.distance_to(e) >= n.distance_to(w)
	var r1: Vector2
	var r2: Vector2
	if along_x:
		var mid_w := nw.lerp(sw, 0.5)
		var mid_e := ne.lerp(se, 0.5)
		r1 = mid_w.lerp(mid_e, 0.12) + up
		r2 = mid_w.lerp(mid_e, 0.88) + up
		ci.draw_colored_polygon(PackedVector2Array([sw, se, r2, r1]), roof)
		ci.draw_colored_polygon(PackedVector2Array([se, ne, r2]), roof.darkened(0.3))
		ci.draw_colored_polygon(PackedVector2Array([nw, sw, r1]), roof.darkened(0.15))
	else:
		var mid_n := nw.lerp(ne, 0.5)
		var mid_s := sw.lerp(se, 0.5)
		r1 = mid_n.lerp(mid_s, 0.12) + up
		r2 = mid_n.lerp(mid_s, 0.88) + up
		ci.draw_colored_polygon(PackedVector2Array([se, ne, r1, r2]), roof.darkened(0.3))
		ci.draw_colored_polygon(PackedVector2Array([sw, se, r2]), roof)
		ci.draw_colored_polygon(PackedVector2Array([nw, sw, r2, r1]), roof.darkened(0.15))
	ci.draw_line(r1, r2, roof.lightened(0.3), s * 1.5)
	ci.draw_polyline(PackedVector2Array([w, so, e]), OUTLINE, s)
	ci.draw_polyline(PackedVector2Array([w, w + h, sw, r1 if along_x else r2, r2 if along_x else r1, ne, e + h, e]), OUTLINE, s)
	ci.draw_line(so, so + h, OUTLINE, s)
	var apex := r1.lerp(r2, 0.5)
	if b.get("chimney", false):
		var ch := r2 + Vector2(-2, 2) * s
		ci.draw_rect(Rect2(ch + Vector2(-2, -10) * s, Vector2(5, 10) * s), Color("4a4448"))
		var sm := fmod(t * 8.0, 16.0)
		ci.draw_circle(ch + Vector2(1, -12 - sm) * s, (2.0 + sm * 0.2) * s, Color(0.7, 0.7, 0.7, 0.4 * (1.0 - sm / 16.0)))
	if b.get("cross", false):
		ci.draw_rect(Rect2(apex + Vector2(-0.5, -12) * s, Vector2(2, 12) * s), Color("d8c890"))
		ci.draw_rect(Rect2(apex + Vector2(-3, -9) * s, Vector2(7, 2) * s), Color("d8c890"))
	if b.get("bell", false):
		var bc := (so + h * 0.75).lerp(e + h * 0.75, 0.5)
		ci.draw_rect(Rect2(bc + Vector2(-5, -9) * s, Vector2(10, 9) * s), Color("1a1418"))
		ci.draw_rect(Rect2(bc + Vector2(-3, -7) * s, Vector2(6, 6) * s), Color("c8a040"))
	if b.get("sign", false):
		var sc := so.lerp(e, 0.15) + h * 0.8
		ci.draw_rect(Rect2(sc + Vector2(-4, 0) * s, Vector2(8, 6) * s), Color("c8a040"))
		ci.draw_rect(Rect2(sc + Vector2(-3, 1) * s, Vector2(6, 4) * s), Color("6a2a1a"))
	var top := minf(apex.y, minf(r1.y, r2.y)) - 14.0 * s
	var xs := [n.x, e.x, so.x, w.x]
	return Rect2(Vector2(xs.min(), top), Vector2(float(xs.max()) - float(xs.min()), so.y - top))


# --- Стены по стилю локации ---------------------------------------------------------------

## Стена-заглушка. corners — ромб клетки (N, E, S, W).
static func draw_wall(ci: CanvasItem, style: String, c: PackedVector2Array, s: float, t: float, variant: int) -> void:
	var center := c[0].lerp(c[2], 0.5)
	match style:
		"tree":
			_tree(ci, center + Vector2(0, 2) * s, s, t, variant, Color("2a4e2a") if variant % 3 else Color("335a2c"))
		"rock":
			draw_prop(ci, "rock", center, s * 1.2, t, variant)
		"fence":
			draw_prop(ci, "fence", center, s, t, variant)
		"palisade":
			for i in 3:
				var p := c[3].lerp(c[2], 0.2 + i * 0.3).lerp(c[0].lerp(c[1], 0.2 + i * 0.3), 0.5)
				var hgt := 22.0 + float((variant + i) % 3) * 3.0
				_box(ci, p.round(), -2, -hgt, 4, hgt, Color("6a4a2a"), s)
				_px(ci, p.round(), -1, -hgt - 2, Color("8a6a3a"), s, 2, 2)
		_:   # stone: низкая каменная ограда
			var h := Vector2(0, -12 * s)
			var left := PackedVector2Array([c[3], c[2], c[2] + h, c[3] + h])
			var right := PackedVector2Array([c[2], c[1], c[1] + h, c[2] + h])
			var top := PackedVector2Array([c[0] + h, c[1] + h, c[2] + h, c[3] + h])
			var stone := Color("6e6c68") if variant % 2 else Color("767470")
			ci.draw_colored_polygon(left, stone.darkened(0.3))
			ci.draw_colored_polygon(right, stone.darkened(0.12))
			ci.draw_colored_polygon(top, stone)
			ci.draw_line(c[3] + h * 0.5, c[2] + h * 0.5, stone.darkened(0.5), s)
			ci.draw_line(c[2] + h * 0.5, c[1] + h * 0.5, stone.darkened(0.35), s)
			if variant % 4 == 0:
				ci.draw_rect(Rect2((c[0] + h).lerp(c[2] + h, 0.5) + Vector2(-3, -1) * s, Vector2(6, 2) * s), Color("4a6a30"))
			top.append(top[0])
			ci.draw_polyline(top, OUTLINE, s)

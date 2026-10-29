class_name SceneArt
extends RefCounted
## Картинки-заглушки для заставок и титульного экрана: пиксельные пейзажи 256×144,
## нарисованные кодом один раз и увеличенные без сглаживания. Как только в data/sprites.json
## появится картинка images/<id> (её рисует поток картинок), берётся она.
## Поверх картинки рисуется немного движения: туман, вороны, искры, огонёк свечи.

const W := 256
const H := 144

const BAYER := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

static var _cache: Dictionary = {}


static func texture(id: String) -> Texture2D:
	var fr := SpriteLibrary.frame("images", id)
	if not fr.is_empty():
		var at := AtlasTexture.new()
		at.atlas = fr["texture"]
		at.region = fr["region"]
		return at
	if _cache.has(id):
		return _cache[id]
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	match id:
		"title":
			_title(img)
		"intro_2":
			_funeral(img)
		"intro_3":
			_bell(img)
		"intro_4":
			_empty_grave(img)
		"farewell":
			_farewell(img)
		"epilogue":
			_epilogue(img)
		"bell_tower_view":
			_tower_view(img)
		_:
			_marsh(img)
	var tex := ImageTexture.create_from_image(img)
	_cache[id] = tex
	return tex


## Нарисовать картинку в rect (с сохранением пропорций, лишнее обрезается) и движение поверх.
static func draw(ci: CanvasItem, id: String, rect: Rect2, t: float) -> void:
	var tex := texture(id)
	var ts := tex.get_size()
	var k := maxf(rect.size.x / ts.x, rect.size.y / ts.y)
	var sz := ts * k
	var dest := Rect2(rect.position + (rect.size - sz) * 0.5, sz)
	ci.draw_texture_rect(tex, dest, false)
	var px := k   # размер пикселя картинки на экране
	match id:
		"title", "intro_4":
			_fog(ci, dest, px, t)
			if id == "title":
				_crows(ci, dest, px, t, 3)
		"intro_1", "intro_2", "intro_3", "bell_tower_view", "":
			_crows(ci, dest, px, t, 6 if id == "intro_3" else 3)
		"farewell":
			_embers(ci, dest, px, t, Vector2(128, 92))
		"epilogue":
			var c := dest.position + Vector2(81, 88) * px
			var a := 0.12 + 0.05 * sin(t * 9.0) + 0.03 * sin(t * 23.0)
			ci.draw_circle(c, 22.0 * px, Color(1.0, 0.7, 0.3, a))
			ci.draw_circle(c, 10.0 * px, Color(1.0, 0.8, 0.4, a))
		_:
			_crows(ci, dest, px, t, 3)


# --- Движение поверх --------------------------------------------------------------------

static func _fog(ci: CanvasItem, dest: Rect2, px: float, t: float) -> void:
	for i in 5:
		var y := 96.0 + i * 9.0
		var x := fmod(t * (4.0 + i * 1.5) + i * 57.0, 320.0) - 64.0
		var w := 90.0 + i * 14.0
		ci.draw_rect(Rect2(dest.position + Vector2(x, y) * px, Vector2(w, 3.0 + i % 2) * px).intersection(dest),
			Color(0.75, 0.78, 0.9, 0.07 + 0.02 * i))


static func _crows(ci: CanvasItem, dest: Rect2, px: float, t: float, count: int) -> void:
	for i in count:
		var speed := 9.0 + i * 3.0
		var x := fmod(t * speed + i * 83.0, 300.0) - 22.0
		var y := 20.0 + float((i * 37) % 40) + sin(t * 1.3 + i) * 3.0
		var flap := int(t * 6.0 + i) % 2 == 0
		var col := Color(0.04, 0.03, 0.05)
		var p := (dest.position + Vector2(x, y) * px).round()
		var s := maxf(1.0, roundf(px))
		ci.draw_rect(Rect2(p, Vector2(s, s)), col)
		if flap:
			ci.draw_rect(Rect2(p + Vector2(-2, -1) * s, Vector2(2, 1) * s), col)
			ci.draw_rect(Rect2(p + Vector2(1, -1) * s, Vector2(2, 1) * s), col)
		else:
			ci.draw_rect(Rect2(p + Vector2(-2, 1) * s, Vector2(2, 1) * s), col)
			ci.draw_rect(Rect2(p + Vector2(1, 1) * s, Vector2(2, 1) * s), col)


static func _embers(ci: CanvasItem, dest: Rect2, px: float, t: float, src: Vector2) -> void:
	var s := maxf(1.0, roundf(px))
	for i in 18:
		var life := fmod(t * 0.6 + i * 0.137, 1.0)
		var x := src.x + sin(i * 12.9 + t * 0.7) * 14.0 + sin(life * 6.0 + i) * 4.0
		var y := src.y - life * 70.0
		var col := Color(1.0, 0.7 - life * 0.4, 0.2, 1.0 - life)
		ci.draw_rect(Rect2((dest.position + Vector2(x, y) * px).round(), Vector2(s, s)), col)


# --- Рисование в картинку ---------------------------------------------------------------

static func _bayer(x: int, y: int) -> float:
	return float(BAYER[(x % 4) + (y % 4) * 4]) / 16.0


static func _sky(img: Image, top: Color, bottom: Color, horizon: int, bands := 9) -> void:
	for y in mini(horizon + 1, H):
		var v := float(y) / float(maxi(1, horizon)) * bands
		var band := floorf(v)
		var frac := v - band
		var c0 := top.lerp(bottom, band / bands)
		var c1 := top.lerp(bottom, minf(1.0, (band + 1.0) / bands))
		for x in W:
			img.set_pixel(x, y, c1 if _bayer(x, y) < frac else c0)


static func _fill(img: Image, x: int, y: int, w: int, h: int, col: Color) -> void:
	var r := Rect2i(x, y, w, h).intersection(Rect2i(0, 0, W, H))
	if r.size.x > 0 and r.size.y > 0:
		img.fill_rect(r, col)


static func _ground(img: Image, from_y: int, col: Color) -> void:
	_fill(img, 0, from_y, W, H - from_y, col)


static func _disc(img: Image, cx: int, cy: int, r: int, col: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if x >= 0 and y >= 0 and x < W and y < H and (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r:
				img.set_pixel(x, y, col)


static func _glow(img: Image, cx: int, cy: int, r: int, col: Color, strength: float) -> void:
	for y in range(maxi(0, cy - r), mini(H, cy + r + 1)):
		for x in range(maxi(0, cx - r), mini(W, cx + r + 1)):
			var d := sqrt(float((x - cx) * (x - cx) + (y - cy) * (y - cy))) / float(r)
			if d >= 1.0:
				continue
			var k := (1.0 - d) * strength
			k = floorf(k * 4.0 + _bayer(x, y)) / 4.0
			if k > 0.0:
				img.set_pixel(x, y, img.get_pixel(x, y).lerp(col, clampf(k, 0.0, 1.0)))


static func _hills(img: Image, base: int, amp: float, freq: float, phase: float, col: Color) -> void:
	for x in W:
		var h := amp * (0.5 + 0.5 * sin(x * freq + phase)) + amp * 0.35 * sin(x * freq * 2.7 + phase * 1.9)
		var top := int(base - h)
		_fill(img, x, top, 1, H - top, col)


static func _mound(img: Image, cx: int, base: int, w: int, h: int, col: Color) -> void:
	for dx in range(-w, w + 1):
		var hh := int(h * sqrt(maxf(0.0, 1.0 - float(dx * dx) / float(w * w))))
		_fill(img, cx + dx, base - hh, 1, hh + 1, col)


static func _roof(img: Image, x: int, base: int, w: int, h: int, col: Color) -> void:
	for i in h:
		var inset := int(float(i) * float(w) / float(2 * h))
		_fill(img, x + inset, base - i, w - inset * 2, 1, col)


static func _house(img: Image, x: int, base: int, w: int, h: int, roof_h: int, col: Color, window := Color(0, 0, 0, 0)) -> void:
	_fill(img, x, base - h, w, h, col)
	_roof(img, x - 1, base - h, w + 2, roof_h, col)
	if window.a > 0.0:
		_fill(img, x + w / 2 - 1, base - h + 3, 2, 2, window)


static func _tower(img: Image, x: int, base: int, w: int, h: int, col: Color, bell := Color(0, 0, 0, 0)) -> void:
	_fill(img, x, base - h, w, h, col)
	_roof(img, x - 1, base - h, w + 2, w + 4, col)
	if bell.a > 0.0:
		_fill(img, x + w / 2 - 2, base - h + 4, 4, 5, Color(0.02, 0.02, 0.03))
		_fill(img, x + w / 2 - 1, base - h + 5, 2, 3, bell)


static func _cross(img: Image, x: int, base: int, s: int, col: Color) -> void:
	_fill(img, x, base - 5 * s, s, 5 * s, col)
	_fill(img, x - s, base - 4 * s, 3 * s, s, col)


static func _tomb(img: Image, x: int, base: int, s: int, col: Color) -> void:
	_fill(img, x, base - 3 * s, 3 * s, 3 * s, col)
	_fill(img, x + 1, base - 3 * s - 1, 3 * s - 2, 1, col)


static func _person(img: Image, x: int, base: int, h: int, col: Color) -> void:
	_fill(img, x, base - h + 3, 3, h - 3, col)
	_fill(img, x + 1, base - h + 1, 1, 1, col)
	_fill(img, x, base - h + 1, 3, 2, col)
	_fill(img, x - 1, base - h + 4, 5, 3, col)


static func _line(img: Image, x0: int, y0: int, x1: int, y1: int, col: Color) -> void:
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	var guard := 0
	while guard < 1000:
		guard += 1
		if x0 >= 0 and y0 >= 0 and x0 < W and y0 < H:
			img.set_pixel(x0, y0, col)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy


static func _dead_tree(img: Image, x: int, base: int, h: int, col: Color) -> void:
	_fill(img, x, base - h, 2, h, col)
	_line(img, x, base - h * 2 / 3, x - h / 3, base - h + 2, col)
	_line(img, x + 1, base - h / 2, x + h / 3, base - h * 5 / 6, col)
	_line(img, x - h / 6, base - h * 5 / 6, x - h / 4, base - h - 3, col)
	_line(img, x + h / 5, base - h * 3 / 4, x + h / 4 + 3, base - h * 3 / 4 - 2, col)


static func _stars(img: Image, count: int, max_y: int, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for i in count:
		var x := rng.randi_range(0, W - 1)
		var y := rng.randi_range(0, max_y)
		img.set_pixel(x, y, Color(0.8, 0.8, 0.9).lerp(img.get_pixel(x, y), rng.randf() * 0.6))


static func _reeds(img: Image, from_y: int, to_y: int, count: int, col: Color, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for i in count:
		var x := rng.randi_range(0, W - 1)
		var y := rng.randi_range(from_y, to_y)
		var h := rng.randi_range(3, 9)
		_fill(img, x, y - h, 1, h, col)
		if rng.randf() < 0.4:
			_fill(img, x, y - h - 2, 1, 2, col.lightened(0.15))


# --- Сцены -----------------------------------------------------------------------------

static func _title(img: Image) -> void:
	_sky(img, Color("070914"), Color("2b2a4a"), 104)
	_stars(img, 90, 70, 3)
	_glow(img, 196, 34, 46, Color("8a8ab8"), 0.35)
	_disc(img, 196, 34, 12, Color("e8e4d0"))
	_disc(img, 192, 31, 3, Color("c8c4b0"))
	_hills(img, 106, 9.0, 0.035, 0.6, Color("161a2c"))
	_house(img, 34, 110, 14, 8, 6, Color("0e0f1a"), Color("d8a040"))
	_tower(img, 52, 110, 12, 52, Color("0e0f1a"), Color("6a5a3a"))
	_house(img, 70, 110, 18, 9, 7, Color("0e0f1a"))
	_ground(img, 110, Color("0a0b12"))
	var c := Color("05060b")
	for g in [[16, 132, 2], [40, 124, 1], [96, 128, 1], [120, 138, 2], [150, 122, 1], [176, 134, 2], [236, 126, 1], [86, 140, 2]]:
		if int(g[0]) % 3 == 0:
			_tomb(img, int(g[0]), int(g[1]), int(g[2]) + 1, c)
		else:
			_cross(img, int(g[0]), int(g[1]), int(g[2]) + 1, c)
	_dead_tree(img, 222, 132, 48, c)


static func _marsh(img: Image) -> void:
	_sky(img, Color("241a2e"), Color("e07a3a"), 94)
	_glow(img, 170, 88, 56, Color("ff9a50"), 0.5)
	_disc(img, 170, 88, 11, Color("ffd890"))
	var far := Color("3a2430")
	_mound(img, 30, 94, 26, 9, far)
	_mound(img, 80, 94, 18, 6, far)
	_mound(img, 218, 94, 32, 12, far)
	var vil := Color("2a1a24")
	_house(img, 102, 97, 10, 6, 5, vil, Color("e0a040"))
	_house(img, 116, 97, 12, 7, 5, vil)
	_tower(img, 132, 97, 6, 24, vil)
	_house(img, 142, 97, 10, 5, 4, vil, Color("e0a040"))
	_ground(img, 97, Color("2e2428"))
	# брод: полоса воды отражает закат
	for y in range(101, 109):
		for x in W:
			var k := 0.5 + 0.5 * sin(x * 0.21 + y * 1.7)
			img.set_pixel(x, y, Color("b0603a") if _bayer(x, y) < k * 0.6 else Color("6a3a34"))
	_reeds(img, 112, 143, 140, Color("1a1418"), 11)


static func _funeral(img: Image) -> void:
	_sky(img, Color("3a2638"), Color("e8a050"), 90)
	_glow(img, 52, 82, 50, Color("ffb060"), 0.5)
	_disc(img, 52, 82, 10, Color("ffe0a0"))
	_hills(img, 100, 7.0, 0.03, 2.0, Color("2a2228"))
	_ground(img, 100, Color("2a2228"))
	var dark := Color("120e12")
	for g in [[14, 112], [30, 120], [182, 116], [200, 126], [232, 114], [70, 132], [246, 138]]:
		_cross(img, int(g[0]), int(g[1]), 1, Color("1a1418"))
	_fill(img, 118, 114, 24, 5, Color("0a0708"))      # яма
	_fill(img, 114, 112, 4, 4, Color("3a2a20"))
	_fill(img, 142, 112, 5, 4, Color("3a2a20"))
	_fill(img, 116, 107, 28, 5, Color("4a3020"))      # гроб
	_fill(img, 116, 107, 28, 1, Color("6a4a30"))
	for p in [[94, 114, 12], [102, 112, 11], [108, 110, 13], [150, 110, 12], [156, 112, 11], [163, 115, 13], [170, 113, 10], [88, 117, 11]]:
		_person(img, int(p[0]), int(p[1]), int(p[2]), dark)
	_person(img, 129, 105, 13, dark)                 # священник
	_fill(img, 130, 96, 1, 1, Color("d8d0c0"))
	_dead_tree(img, 212, 108, 40, dark)


static func _bell(img: Image) -> void:
	_sky(img, Color("1a1424"), Color("a04a3a"), 112)
	_hills(img, 120, 6.0, 0.04, 1.0, Color("2a1820"))
	var tc := Color("140e14")
	_house(img, 60, 132, 30, 18, 14, tc)
	_fill(img, 112, 34, 28, 98, tc)
	_roof(img, 110, 34, 32, 30, tc)
	_fill(img, 120, 44, 12, 14, Color("05040a"))
	_glow(img, 126, 51, 34, Color("ffb040"), 0.55)
	_fill(img, 122, 46, 8, 9, Color("e0b040"))
	_fill(img, 123, 46, 6, 1, Color("fff0a0"))
	_fill(img, 125, 55, 2, 2, Color("e0b040"))
	_house(img, 170, 132, 26, 14, 12, tc)
	_ground(img, 132, Color("120c10"))


## Вид с колокольни: внизу крыши Брода и река с бродом, дальше чёрная полоса Ольшаника и горбы курганов,
## сверху край колокола, спереди выломанные перила.
static func _tower_view(img: Image) -> void:
	_sky(img, Color("2a2438"), Color("c0704a"), 70)
	_hills(img, 62, 4.0, 0.07, 0.6, Color("3a2a34"))   # курганы
	_mound(img, 196, 62, 30, 9, Color("2e2028"))
	_hills(img, 76, 3.0, 0.11, 2.1, Color("141810"))   # Ольшаник
	_ground(img, 78, Color("4a3a24"))
	for y in range(78, H):   # поля темнее к низу
		for x in W:
			if _bayer(x, y) < float(y - 78) / 120.0:
				img.set_pixel(x, y, Color("3a2c1c"))
	for y in range(80, H):   # река с бродом
		var rx := 150 + int(round(6.0 * sin(y / 9.0))) - (y - 80) / 3
		var ford := y > 104 and y < 110
		_fill(img, rx, y, 9 + (y - 80) / 8, 1, Color("8a7a5a") if ford else Color("3a5a7a"))
	var roofs := [[20, 104, 22, 10, "6a3a24"], [52, 112, 26, 12, "5a4a2a"], [90, 100, 18, 8, "6a3a24"],
		[180, 112, 24, 11, "4a4a5a"], [214, 102, 20, 9, "6a3a24"], [36, 130, 30, 13, "5a4a2a"], [196, 132, 28, 12, "6a3a24"],
		[110, 122, 22, 10, "5a4a2a"]]
	for r in roofs:
		_house(img, int(r[0]), int(r[1]), int(r[2]), int(r[3]) - 4, int(r[3]) / 2 + 3, Color(str(r[4])), Color("e0a040"))
	_fill(img, 0, 0, W, 10, Color("0e0a0c"))        # край крыши колокольни
	_disc(img, 128, 2, 22, Color("6a5030"))          # колокол
	_disc(img, 128, 0, 19, Color("8a6a3a"))
	_fill(img, 0, 128, W, 4, Color("2a1c14"))       # перила
	for x in range(6, W, 22):
		if x > 150 and x < 200:
			continue                                 # выломаны
		_fill(img, x, 118, 3, 26, Color("2a1c14"))
	_line(img, 150, 128, 162, 140, Color("2a1c14"))  # обломки
	_line(img, 198, 128, 188, 141, Color("2a1c14"))


static func _empty_grave(img: Image) -> void:
	_sky(img, Color("080a14"), Color("23263a"), 82)
	_stars(img, 60, 60, 9)
	_glow(img, 60, 30, 36, Color("7a7aa8"), 0.3)
	_disc(img, 60, 30, 10, Color("e0dcc8"))
	_hills(img, 84, 5.0, 0.05, 0.3, Color("1a1a26"))
	_ground(img, 84, Color("14141c"))
	for g in [[20, 96], [44, 102], [190, 98], [214, 104], [240, 96]]:
		_cross(img, int(g[0]), int(g[1]), 1, Color("0a0a10"))
	_fill(img, 92, 112, 70, 18, Color("2a2420"))     # земля вокруг
	_fill(img, 100, 116, 54, 11, Color("050507"))    # яма
	_line(img, 160, 126, 182, 104, Color("4a3020"))  # крышка гроба
	_line(img, 161, 126, 183, 104, Color("4a3020"))
	_line(img, 162, 126, 184, 104, Color("3a2418"))
	for i in 7:
		var x := 170 + i * 11
		_fill(img, x, 132 - (i % 2) * 3, 2, 1, Color("08080c"))


static func _farewell(img: Image) -> void:
	_sky(img, Color("0c0a14"), Color("3a1a1a"), 102)
	_stars(img, 40, 50, 21)
	_mound(img, 128, 124, 90, 26, Color("140c0c"))
	_ground(img, 124, Color("0e0808"))
	_glow(img, 128, 92, 64, Color("ff8a30"), 0.6)
	for i in 5:
		_fill(img, 112 + i * 2, 98 - i * 2, 32 - i * 4, 2, Color("3a2414"))
	for f in [[120, 94, 4, 10], [126, 90, 5, 14], [133, 93, 4, 11], [129, 86, 2, 6]]:
		_fill(img, int(f[0]), int(f[1]) - int(f[3]), int(f[2]), int(f[3]), Color("ff8a30"))
		_fill(img, int(f[0]) + 1, int(f[1]) - int(f[3]) + 3, maxi(1, int(f[2]) - 2), int(f[3]) - 4, Color("ffd060"))
	# призрак над костром
	for y in range(52, 84):
		for x in range(120, 137):
			var dx := x - 128
			var w := 3 + (y - 52) / 5
			if absi(dx) <= w and not (y < 58 and absi(dx) > 2):
				img.set_pixel(x, y, img.get_pixel(x, y).lerp(Color("a8d8ff"), 0.55 if _bayer(x, y) < 0.7 else 0.3))
	_fill(img, 126, 55, 1, 1, Color("203040"))
	_fill(img, 129, 55, 1, 1, Color("203040"))


static func _epilogue(img: Image) -> void:
	_fill(img, 0, 0, W, H, Color("2a1a12"))
	for x in range(0, W, 18):
		_fill(img, x, 0, 1, 100, Color("1e120c"))
	_fill(img, 186, 26, 40, 46, Color("3a2414"))
	_fill(img, 190, 30, 32, 38, Color("1a2440"))
	_fill(img, 205, 30, 2, 38, Color("3a2414"))
	_fill(img, 190, 48, 32, 2, Color("3a2414"))
	_disc(img, 214, 38, 3, Color("d8d8c0"))
	_fill(img, 0, 100, W, 44, Color("4a2e1a"))
	_fill(img, 0, 100, W, 2, Color("6a4428"))
	_glow(img, 81, 88, 50, Color("ffb050"), 0.45)
	_fill(img, 79, 90, 4, 12, Color("e8e0c8"))       # свеча
	_fill(img, 80, 85, 2, 4, Color("ffd060"))
	_fill(img, 80, 84, 2, 1, Color("fff4c0"))
	_fill(img, 104, 88, 12, 14, Color("6a5a4a"))     # кружка
	_fill(img, 116, 91, 3, 7, Color("6a5a4a"))
	_fill(img, 105, 88, 10, 2, Color("e8d8b0"))
	_fill(img, 136, 104, 40, 20, Color("d8c8a0"))    # письмо
	for i in 5:
		_fill(img, 140, 108 + i * 3, 30 - (i % 2) * 8, 1, Color("6a5a4a"))
	_disc(img, 190, 116, 2, Color("1a1218"))

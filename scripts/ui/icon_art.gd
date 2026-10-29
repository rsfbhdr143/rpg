class_name IconArt
extends RefCounted
## Пиксельные значки навыков, статусов и предметов. Если в data/sprites.json есть картинка
## (skills/<id>, statuses/<id>, items/<id>), рисуется она; иначе — значок из маленького рисунка ниже.
## Рисунок — строки 10×10: "#" основной цвет, "+" светлее, "-" темнее, "w" белый, "k" контур, "." пусто.

const GLYPHS := {
	"sword": [
		"........kk",
		".......k+k",
		"......k+k.",
		".....k+k..",
		"..k.k+k...",
		"..kk+k....",
		"...k#k....",
		"..k#kk....",
		".k#k..k...",
		"k#k.......",
	],
	"shield": [
		".kkkkkkkk.",
		".k++++++k.",
		".k+####+k.",
		".k+#ww#+k.",
		".k+####+k.",
		".k++++++k.",
		"..k++++k..",
		"...k++k...",
		"....kk....",
		"..........",
	],
	"whirl": [
		"...####...",
		"..#....#..",
		".#..++..#.",
		"#..+..+..#",
		"#..+.++..#",
		"#...+....#",
		".#......#.",
		"..#....#..",
		"...####...",
		"..........",
	],
	"arrow": [
		".....kkkkk",
		"........kk",
		".......k+k",
		"......k+.k",
		".....k+...",
		"....k+....",
		".-.k+.....",
		".--+......",
		".---......",
		"..........",
	],
	"flame": [
		"....#.....",
		"...##.....",
		"...#+#....",
		"..#++#.#..",
		"..#+w+##..",
		".#+ww+#...",
		".#+ww++#..",
		".#++w++#..",
		"..#+++#...",
		"...###....",
	],
	"fireball": [
		"......#...",
		"...#.##...",
		"..##++#.#.",
		".#++ww+##.",
		".#+wwww+#.",
		".#+wwww+#.",
		".#++ww++#.",
		"..#++++#..",
		"...####...",
		"..........",
	],
	"drop": [
		"....#.....",
		"....#.....",
		"...#+#....",
		"...#+#....",
		"..#++##...",
		"..#+w+#...",
		".#+ww++#..",
		".#++w++#..",
		"..#+++#...",
		"...###....",
	],
	"rain": [
		".--------.",
		"-++++++++-",
		"-++++++++-",
		".--------.",
		"..#...#...",
		"....#...#.",
		".#...#....",
		"...#...#..",
		".#...#....",
		"..........",
	],
	"shard": [
		"....#.....",
		"...#w#....",
		"...#w#....",
		"..#+w+#...",
		"..#+w+#...",
		"..#++-#...",
		"...#+-#...",
		"...#--#...",
		"....#-....",
		"....#.....",
	],
	"cross": [
		"...kkkk...",
		"...k++k...",
		"...k++k...",
		"kkkk++kkkk",
		"k++++++++k",
		"k++++++++k",
		"kkkk++kkkk",
		"...k++k...",
		"...k++k...",
		"...kkkk...",
	],
	"bolt": [
		".....###..",
		"....##+...",
		"...##+....",
		"..######..",
		".....+#...",
		"....##....",
		"...#+.....",
		"..##......",
		".#+.......",
		".#........",
	],
	"skull": [
		"..######..",
		".#++++++#.",
		"#++++++++#",
		"#+kk++kk+#",
		"#+kk++kk+#",
		"#++++++++#",
		".#+++k++#.",
		"..#+++++#.",
		"..#k#k#k..",
		"...#.#.#..",
	],
	"oil": [
		"..........",
		"....##....",
		"...####...",
		"..##++##..",
		".##+ww+##.",
		".##++++##.",
		".########.",
		"..######..",
		"...####...",
		"..........",
	],
	"sun": [
		"....#.....",
		".#..#..#..",
		"..#+++#...",
		"..+www+...",
		"###www###.",
		"..+www+...",
		"..#+++#...",
		".#..#..#..",
		"....#.....",
		"..........",
	],
	"eye": [
		"..........",
		"...####...",
		".##----##.",
		"#--####--#",
		"#-##ww##-#",
		"#--####--#",
		".##----##.",
		"...####...",
		"..........",
		"..........",
	],
	"boot": [
		"...###....",
		"...#+#....",
		"...#+#....",
		"...#+#....",
		"...#+##...",
		"...#++###.",
		"..#+++++#.",
		"..########",
		"..........",
		"..........",
	],
	"potion": [
		"...kkkk...",
		"....kk....",
		"....kk....",
		"...k++k...",
		"..k++++k..",
		".k++ww++k.",
		".k######k.",
		".k######k.",
		"..kkkkkk..",
		"..........",
	],
	"bread": [
		"..........",
		"...####...",
		"..#++++#..",
		".#+w++w+#.",
		".#++++++#.",
		".#------#.",
		"..######..",
		"..........",
		"..........",
		"..........",
	],
	"coin": [
		"..........",
		"...####...",
		"..#++++#..",
		".#+w##++#.",
		".#+#++#+#.",
		".#+#++#+#.",
		".#++##++#.",
		"..#++++#..",
		"...####...",
		"..........",
	],
	"letter": [
		"..........",
		".kkkkkkkk.",
		".k#++++#k.",
		".k+#++#+k.",
		".k++##++k.",
		".k++++++k.",
		".k++++++k.",
		".kkkkkkkk.",
		"..........",
		"..........",
	],
	"ring": [
		"....##....",
		"...#ww#...",
		"....##....",
		"..######..",
		".##....##.",
		".#......#.",
		".#......#.",
		".##....##.",
		"..######..",
		"..........",
	],
	"hammer": [
		".kkkkkk...",
		".k++++k...",
		".k#++#k...",
		".kkkkkk...",
		"...k-k....",
		"...k-k....",
		"...k-k....",
		"...k-k....",
		"...k-k....",
		"...kkk....",
	],
	"lantern": [
		"....kk....",
		"...k..k...",
		"..kkkkkk..",
		"..k+ww+k..",
		"..k+ww+k..",
		"..k++++k..",
		"..kkkkkk..",
		"..........",
		"..........",
		"..........",
	],
	"bead": [
		"..........",
		"..........",
		"...####...",
		"..#--w-#..",
		"..#----#..",
		"..#----#..",
		"...####...",
		"..........",
		"..........",
		"..........",
	],
	"map": [
		"..........",
		"kkkkkkkkkk",
		"k++#++++-k",
		"k+#++w++-k",
		"k++#++#+-k",
		"k+++##++-k",
		"k++++++#-k",
		"kkkkkkkkkk",
		"..........",
		"..........",
	],
	"down": [
		"....##....",
		"....##....",
		"....##....",
		".########.",
		"..######..",
		"...####...",
		"....##....",
		"..........",
		"kkkkkkkkkk",
		"..........",
	],
	"hourglass": [
		".kkkkkkkk.",
		".k++++++k.",
		"..k++++k..",
		"...k++k...",
		"....kk....",
		"...k..k...",
		"..k....k..",
		".k++++++k.",
		".kkkkkkkk.",
		"..........",
	],
	"snow": [
		"....#.....",
		"..#.#.#...",
		"...+++....",
		".#+#w#+#..",
		"...+++....",
		"..#.#.#...",
		"....#.....",
		"..........",
		"..........",
		"..........",
	],
	"plus": [
		"..........",
		"....##....",
		"....##....",
		"..######..",
		"..######..",
		"....##....",
		"....##....",
		"..........",
		"..........",
		"..........",
	],
	"question": [
		"...####...",
		"..#....#..",
		"......#...",
		".....#....",
		"....#.....",
		"....#.....",
		"..........",
		"....#.....",
		"..........",
		"..........",
	],
}

const SKILLS := {
	"attack": ["sword", "d8d0c0"], "battering_ram": ["shield", "c8b090"], "whirlwind": ["whirl", "d8d0c0"],
	"arrow_shot": ["arrow", "c8a060"], "flare": ["flame", "ff8a3a"], "fireball": ["fireball", "ff7030"],
	"rain": ["rain", "5ab0ff"], "ice_shard": ["shard", "8adcff"], "minor_heal": ["cross", "82e870"],
	"shocking_touch": ["bolt", "c8b8ff"], "lightning_bolt": ["bolt", "e8e0ff"], "poison_dart": ["skull", "8ad848"],
	"oil_slick": ["oil", "8a6a2a"], "bless": ["sun", "f0d070"], "curse": ["eye", "a070d0"],
	"crippling_blow": ["hourglass", "d8a070"], "rush": ["boot", "e8c060"], "battle_cry": ["sun", "e8a050"],
	"defensive_stance": ["shield", "a8b8d0"], "rage": ["flame", "e04030"], "ground_slam": ["hammer", "c8a070"],
	"pinning_shot": ["arrow", "a8a090"], "fire_arrow": ["arrow", "ff8a3a"], "hunters_mark": ["eye", "e0c060"],
	"arrow_rain": ["rain", "c8a060"], "tactical_retreat": ["boot", "8ac8a0"], "dirty_trick": ["sword", "c84040"],
}

const STATUSES := {
	"wet": ["drop", "5ab0ff"], "burning": ["flame", "ff8a3a"], "poisoned": ["skull", "8ad848"],
	"chilled": ["snow", "8adcff"], "frozen": ["snow", "e8f8ff"], "shocked": ["bolt", "c8b8ff"],
	"stunned": ["bolt", "f0e060"], "knocked_down": ["down", "d8a060"], "slowed": ["hourglass", "a8a090"],
	"blessed": ["sun", "f0d070"], "cursed": ["eye", "a070d0"], "regenerating": ["plus", "82e870"],
	"bleeding": ["drop", "c03030"], "marked": ["eye", "e0c060"], "rallied": ["sun", "e8a050"],
	"fortified": ["shield", "a8b8d0"], "enraged": ["flame", "e04030"],
}

const ITEMS := {
	"funeral_bread": ["bread", "d8a860"], "healing_brew": ["potion", "82c86a"], "lamp_oil": ["potion", "c8a040"],
	"tar_torch": ["flame", "ff8a3a"], "juniper_bottle": ["potion", "6aa6a0"], "black_bead": ["bead", "3a3040"],
	"smith_hammer": ["hammer", "a8a8b0"], "gravedigger_lantern": ["lantern", "f0c060"], "lado_map": ["map", "d8c8a0"],
	"order_of_bravery": ["ring", "e0c060"], "own_grimoire": ["letter", "8a5ab0"], "copper_raven": ["ring", "d08a50"],
	"smoldering_seal": ["bead", "ff6a30"], "gold": ["coin", "f0c040"],
}


static var _pix_cache: Dictionary = {}

static func draw_glyph(ci: CanvasItem, glyph: String, rect: Rect2, color: Color, dim := false) -> void:
	var rows: Array = GLYPHS.get(glyph, GLYPHS["question"])
	var px := floorf(minf(rect.size.x, rect.size.y) / 10.0)
	if px < 1.0:
		px = 1.0
	var o := (rect.position + (rect.size - Vector2(10, 10) * px) * 0.5).floor()
	var mul := 0.45 if dim else 1.0
	var pal := {
		"#": color, "+": color.lightened(0.35), "-": color.darkened(0.45),
		"w": Color(1, 0.98, 0.9), "k": Color("120c0a"),
	}
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var ch := row[x]
			if ch == ".":
				continue
			var c: Color = pal.get(ch, color)
			if dim and ch != "k":
				c = Color(c.r * mul + 0.1, c.g * mul + 0.1, c.b * mul + 0.1, c.a)
			ci.draw_rect(Rect2(o + Vector2(x, y) * px, Vector2(px, px)), c)


## Картинка из data/sprites.json, если есть. Возвращает true, если нарисовала.
## Рисованный значок (painted) уменьшается заранее с хорошим сглаживанием до размера ячейки: на экране он чёткий,
## без пикселизации и без мыла.
static func _sprite(ci: CanvasItem, category: String, id: String, rect: Rect2, dim: bool) -> bool:
	var fr := SpriteLibrary.frame(category, id)
	if fr.is_empty():
		return false
	var mod := Color(0.5, 0.5, 0.5, 0.8) if dim else Color.WHITE
	var tex: Texture2D = fr["texture"]
	if bool(fr.get("painted", false)):
		var sm := _smooth(tex, fr["region"], Vector2i(rect.size.round()))
		if sm != null:
			ci.draw_texture_rect(sm, rect, false, mod)
			return true
	ci.draw_texture_rect_region(tex, rect, fr["region"], mod)
	return true


## Кусок src картинки, уменьшенный (Lanczos) ровно до size пикселей; кэшируется.
static func _smooth(tex: Texture2D, src: Rect2, size: Vector2i) -> Texture2D:
	if size.x < 1 or size.y < 1:
		return null
	var key := "s|%d|%s|%s" % [tex.get_instance_id(), src, size]
	if _pix_cache.has(key):
		return _pix_cache[key]
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	img = img.get_region(Rect2i(src))
	img.convert(Image.FORMAT_RGBA8)
	img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
	var out := ImageTexture.create_from_image(img)
	_pix_cache[key] = out
	return out


static func skill_icon(ci: CanvasItem, skill_id: String, rect: Rect2, dim := false) -> void:
	if _sprite(ci, "skills", skill_id, rect, dim):
		return
	var e: Array = SKILLS.get(skill_id, [])
	if e.is_empty():
		var def := GameData.skill(skill_id)
		var el := str((def.get("damage", {}) as Dictionary).get("element", def.get("surface", {}).get("element", "")))
		e = [{"fire": "flame", "water": "drop", "air": "bolt", "earth": "shield", "poison": "skull"}.get(el, "sword"),
			UiTheme.element_color(el).to_html(false)]
	draw_glyph(ci, str(e[0]), rect, Color(str(e[1])), dim)


static func status_icon(ci: CanvasItem, status_id: String, rect: Rect2) -> void:
	if _sprite(ci, "statuses", status_id, rect, false):
		return
	var e: Array = STATUSES.get(status_id, ["question", "c8c8c8"])
	draw_glyph(ci, str(e[0]), rect, Color(str(e[1])))


static func item_icon(ci: CanvasItem, item_id: String, rect: Rect2, dim := false) -> void:
	if _sprite(ci, "items", item_id, rect, dim):
		return
	var e: Array = ITEMS.get(item_id, [])
	if e.is_empty():
		var def := GameData.item(item_id)
		match str(def.get("type", "")):
			"weapon":
				e = ["sword", "c8c8d0"]
			"trinket":
				e = ["ring", "d8b060"]
			"quest":
				e = ["letter", "d8c8a0"]
			_:
				e = ["potion", "c86a6a"]
	draw_glyph(ci, str(e[0]), rect, Color(str(e[1])), dim)


## Портрет: картинка portraits/<id>, иначе кадр фигурки units/<id> (верхняя часть), иначе рисованная заглушка.
static func portrait(ci: CanvasItem, id: String, rect: Rect2, t := 0.0, dead := false) -> void:
	var mod := Color(0.45, 0.45, 0.45) if dead else Color.WHITE
	var fr := SpriteLibrary.frame("portraits", id)
	var src := Rect2()
	if not fr.is_empty():
		src = fr["region"]
	else:
		fr = SpriteLibrary.frame("units", id)
		if not fr.is_empty():
			var region: Rect2 = fr["region"]
			var side := minf(region.size.x, region.size.y * 0.6)
			src = Rect2(region.position.x + (region.size.x - side) * 0.5, region.position.y, side, side)
	if not fr.is_empty():
		ci.draw_rect(rect, Color("221a14"))
		if bool(fr.get("painted", false)):   # рисованный портрет: чёткий, без крупных пикселей
			var sm := _smooth(fr["texture"], src, Vector2i(rect.size.round()))
			if sm != null:
				ci.draw_texture_rect(sm, rect, false, mod)
				return
		var px := clampi(roundi(minf(rect.size.x, rect.size.y) / 3.0), 20, 48)
		var tex := _pixelated(fr["texture"], src, px)
		if tex != null:
			ci.draw_texture_rect(tex, rect, false, mod)
		else:
			ci.draw_texture_rect_region(fr["texture"], rect, src, mod)
		return
	PixelArt.draw_portrait(ci, id, rect, t)
	if dead:
		ci.draw_rect(rect, Color(0.1, 0.05, 0.05, 0.55))


## Рисованный портрет крупными пикселями, как мир на экране: уменьшаем до px×px и урезаем палитру.
static func _pixelated(tex: Texture2D, src: Rect2, px: int) -> Texture2D:
	var key := "%d|%s|%d" % [tex.get_instance_id(), src, px]
	if _pix_cache.has(key):
		return _pix_cache[key]
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	img = img.get_region(Rect2i(src))
	img.convert(Image.FORMAT_RGBA8)
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	var levels := 10.0
	for y in px:
		for x in px:
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(roundf(c.r * levels) / levels, roundf(c.g * levels) / levels,
				roundf(c.b * levels) / levels, 1.0 if c.a > 0.5 else 0.0))
	var out := ImageTexture.create_from_image(img)
	_pix_cache[key] = out
	return out


## Цвет статуса для полоски над головой (тот же, что у значка).
static func status_color(status_id: String) -> Color:
	var e: Array = STATUSES.get(status_id, ["question", "c8c8c8"])
	return Color(str(e[1]))


## Портрет в своём прямоугольнике: всё, что выходит за край, обрезается (clip_contents).
class PortraitView extends Control:
	var id := ""
	var dead := false

	func _ready() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	func _process(_delta: float) -> void:
		if is_visible_in_tree():
			queue_redraw()

	func _draw() -> void:
		if id != "":
			IconArt.portrait(self, id, Rect2(Vector2.ZERO, size), float(Time.get_ticks_msec()) / 1000.0, dead)

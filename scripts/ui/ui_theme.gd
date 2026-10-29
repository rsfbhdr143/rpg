class_name UiTheme
extends RefCounted
## Тема интерфейса: шрифты, цвета, рамки окон и кнопок.
## Рамки рисуются кодом (тёмный орех, латунь, пергамент), поэтому для интерфейса файлы картинок не обязательны;
## нарисованные images/ui_frame, ui_slot, ui_parchment подхватываются сами. Поменять вид — правь цвета ниже.

const FONT_BODY := "res://assets/fonts/AlegreyaSans-Regular.ttf"
const FONT_BOLD := "res://assets/fonts/AlegreyaSans-Bold.ttf"
const FONT_TITLE := "res://assets/fonts/AlegreyaSC-Bold.ttf"
## Заголовочный шрифт ниже прежнего пиксельного при том же размере: размеры заголовков умножаются на это число.
const TITLE_SCALE := 1.35
const PX := 2   # во сколько раз увеличены пиксели рамок (как пиксели мира)

const BG := Color("15110e")
const PANEL := Color("1d1712")
const INK := Color("0b0807")
const GOLD := Color("c8a060")
const GOLD_DIM := Color("8a6a3a")
const TEXT := Color("ecdfc2")
const TEXT_DIM := Color("a89a80")
const TEXT_FAINT := Color("6e6454")
const INK_TEXT := Color("3b2a1a")      # текст на пергаменте
const INK_DIM := Color("6b5236")
const RED := Color("d8573f")
const GREEN := Color("82c86a")
const BLUE := Color("6aa6e8")
const PURPLE := Color("a888e8")
const HP := Color("c4392b")
const HP_BACK := Color("3a1410")
const AP := Color("9ad248")
const XP := Color("7a8ef0")
const ELEMENT_COLORS := {
	"physical": Color("d8d0c0"), "fire": Color("ff8a3a"), "water": Color("5ab0ff"), "earth": Color("b08a50"),
	"air": Color("c8b8ff"), "poison": Color("8ad848"), "heal": Color("82e870"), "holy": Color("fff0a8"), "": Color("d8d0c0"),
}

static var _fonts: Dictionary = {}
static var _theme: Theme = null
## Рамки кэшируются: стиль, созданный прямо в _draw, освобождается раньше, чем кадр нарисован,
## и вместо рамки получается белый прямоугольник.
static var _boxes: Dictionary = {}


static func font(kind: String = "body") -> Font:
	if _fonts.has(kind):
		return _fonts[kind]
	var path: String = {"body": FONT_BODY, "bold": FONT_BOLD, "title": FONT_TITLE}.get(kind, FONT_BODY)
	var f: Font = null
	if ResourceLoader.exists(path):
		f = load(path) as Font
	if f == null and FileAccess.file_exists(path):
		var ff := FontFile.new()
		ff.load_dynamic_font(path)
		f = ff
	if f == null:
		f = ThemeDB.fallback_font
	if f is FontFile:
		var ffile := f as FontFile
		# обычный векторный шрифт: сглаживание и лёгкий хинтинг, чтобы мелкий текст был чётким
		ffile.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		ffile.hinting = TextServer.HINTING_LIGHT
		ffile.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
		ffile.generate_mipmaps = false
	_fonts[kind] = f
	return f


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font("body")
	t.default_font_size = 18
	var panel := frame(PANEL, GOLD_DIM, INK, Color("2c231a"), 1.0)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)
	t.set_stylebox("panel", "PopupPanel", panel)
	t.set_stylebox("panel", "TooltipPanel", frame(Color("120e0b"), GOLD_DIM, INK, Color("221a14"), 0.97, 3))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font("font", "TooltipLabel", font("body"))
	t.set_font_size("font_size", "TooltipLabel", 16)

	for cls in ["Label", "RichTextLabel"]:
		t.set_color("font_color" if cls == "Label" else "default_color", cls, TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.6))
	t.set_constant("shadow_offset_x", "Label", 2)
	t.set_constant("shadow_offset_y", "Label", 2)
	t.set_font("normal_font", "RichTextLabel", font("body"))
	t.set_font("bold_font", "RichTextLabel", font("bold"))
	t.set_font_size("normal_font_size", "RichTextLabel", 18)
	t.set_font_size("bold_font_size", "RichTextLabel", 18)

	t.set_stylebox("normal", "Button", button_box(Color("3b2d21"), Color("7d5e36"), Color("5c4731")))
	t.set_stylebox("hover", "Button", button_box(Color("4d3a28"), GOLD, Color("74593c")))
	t.set_stylebox("pressed", "Button", button_box(Color("2a2018"), GOLD, Color("2a2018"), true))
	t.set_stylebox("disabled", "Button", button_box(Color("221b15"), Color("43382b"), Color("2a221a")))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color("fff2cc"))
	t.set_color("font_pressed_color", "Button", GOLD)
	t.set_color("font_disabled_color", "Button", TEXT_FAINT)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_font("font", "Button", font("body"))
	t.set_font_size("font_size", "Button", 18)

	var edit := frame(Color("0f0c0a"), Color("5a4630"), INK, Color("1a1410"), 1.0, 3)
	t.set_stylebox("normal", "LineEdit", edit)
	t.set_stylebox("focus", "LineEdit", frame(Color("0f0c0a"), GOLD, INK, Color("1a1410"), 1.0, 3))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("caret_color", "LineEdit", GOLD)
	t.set_color("selection_color", "LineEdit", Color(0.78, 0.63, 0.38, 0.4))

	var slider_bg := StyleBoxFlat.new()
	slider_bg.bg_color = Color("0f0c0a")
	slider_bg.border_color = Color("5a4630")
	slider_bg.set_border_width_all(PX)
	slider_bg.content_margin_top = 4
	slider_bg.content_margin_bottom = 4
	var slider_fill := StyleBoxFlat.new()
	slider_fill.bg_color = GOLD_DIM
	t.set_stylebox("slider", "HSlider", slider_bg)
	t.set_stylebox("grabber_area", "HSlider", slider_fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", slider_fill)
	t.set_icon("grabber", "HSlider", _grabber(false))
	t.set_icon("grabber_highlight", "HSlider", _grabber(true))

	t.set_icon("checked", "CheckBox", _check(true))
	t.set_icon("unchecked", "CheckBox", _check(false))
	t.set_stylebox("normal", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("hover", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("pressed", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("focus", "CheckBox", StyleBoxEmpty.new())
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_hover_color", "CheckBox", Color("fff2cc"))

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("0f0c0a")
	sb.content_margin_left = 3
	sb.content_margin_right = 3
	var grab := StyleBoxFlat.new()
	grab.bg_color = GOLD_DIM
	var grab_h := StyleBoxFlat.new()
	grab_h.bg_color = GOLD
	t.set_stylebox("scroll", "VScrollBar", sb)
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab_h)
	t.set_stylebox("grabber_pressed", "VScrollBar", grab_h)

	var sep := StyleBoxLine.new()
	sep.color = GOLD_DIM
	sep.thickness = PX
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 10)

	var tab_sel := button_box(Color("4d3a28"), GOLD, Color("74593c"))
	var tab_un := button_box(Color("2a2018"), Color("5a4630"), Color("3b2d21"))
	t.set_stylebox("tab_selected", "TabBar", tab_sel)
	t.set_stylebox("tab_unselected", "TabBar", tab_un)
	t.set_stylebox("tab_hovered", "TabBar", tab_sel)
	t.set_color("font_selected_color", "TabBar", Color("fff2cc"))
	t.set_color("font_unselected_color", "TabBar", TEXT_DIM)
	_theme = t
	return t


# --- Рамки ----------------------------------------------------------------------
# Окна, кнопки и ячейки рисуются кодом в небольшие картинки 9 ломтей: тёмный орех, латунная кайма, мягкая тень.
# Края гладкие, середина повторяется без шва (узор дерева периодичен), поэтому окно любого размера выглядит одинаково.
# Если поток картинок нарисовал images/ui_slot или images/ui_parchment, берутся они; у images/ui_frame — только кайма.

## Расстояние от точки до края скруглённого прямоугольника w×h изнутри (отрицательное — снаружи).
static func _inset(x: int, y: int, w: int, h: int, r: float) -> float:
	var px := float(x) + 0.5
	var py := float(y) + 0.5
	var dx := minf(px, float(w) - px)
	var dy := minf(py, float(h) - py)
	if dx < r and dy < r:
		return r - Vector2(r - dx, r - dy).length()
	return minf(dx, dy)


## Волокна ореха: 0..1, период 24 по x и 12 по y (середина 9-ломтевой картинки повторяется без шва).
static func _grain(x: int, y: int) -> float:
	var fx := float(x) / 24.0 * TAU
	var fy := float(y) / 12.0 * TAU
	var g := 0.5 + 0.5 * sin(fy + 1.4 * sin(fx) + 0.5 * sin(2.0 * fx + 1.0))
	var line := 1.0 - clampf(absf(sin(fy * 0.5 + 0.9 * sin(fx + 0.4))) * 6.0, 0.0, 1.0)   # тонкие тёмные прожилки
	return clampf(g * 0.8 - line * 0.5 + 0.1, 0.0, 1.0)


## Окно: тёмное дерево, латунная кайма с накладками на углах, тень внутрь. alpha — прозрачность дерева.
static func frame(fill: Color, border: Color, outline: Color, inner: Color, alpha := 1.0, pad := 5) -> StyleBoxTexture:
	var key := "frame%s%s%s%s%s%d" % [fill, border, outline, inner, alpha, pad]
	if _boxes.has(key):
		return _boxes[key]
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var brass_hi := border.lightened(0.38)
	var brass_lo := border.darkened(0.3)
	for y in n:
		for x in n:
			var d := _inset(x, y, n, n, 6.0)
			if d <= 0.0:
				continue
			var c: Color
			if d < 1.2:
				c = outline
			elif d < 3.6:
				c = brass_hi.lerp(brass_lo, float(y) / float(n - 1))
				if d < 1.9:
					c = c.lightened(0.18)
			elif d < 4.6:
				c = inner.darkened(0.25)
			else:
				var g := _grain(x, y)
				c = fill.darkened(0.06).lerp(fill.lightened(0.12), g)
				c = c.darkened(0.4 * clampf((8.5 - d) / 4.0, 0.0, 1.0))
				c.a = alpha
			if d < 1.0:
				c.a *= d
			img.set_pixel(x, y, c)
	_corner_plates(img, n, border)
	_art_border(img, "ui_frame", 11)
	var sb := _smooth_box(img, 12, pad)
	_boxes[key] = sb
	return sb


## Рисованная рамка (images/<id>, тот же размер, что у рамки кодом) поверх рамки кодом — только кайма шириной ring:
## внутри у рисунка светлый пергамент, а светлый текст окон читается на тёмном дереве, поэтому середина остаётся своей.
static func _art_border(img: Image, id: String, ring: int) -> void:
	var fr := SpriteLibrary.frame("images", id)
	if fr.is_empty():
		return
	var src := (fr["texture"] as Texture2D).get_image()
	if src == null:
		return
	if src.is_compressed():
		src.decompress()
	var art := src.get_region(Rect2i(fr["region"]))
	if art.get_size() != img.get_size():
		art.resize(img.get_width(), img.get_height(), Image.INTERPOLATE_NEAREST)
	art.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var d := mini(mini(x, y), mini(w - 1 - x, h - 1 - y))
			if d < ring:
				img.set_pixel(x, y, art.get_pixel(x, y))
			elif d < ring + 3:
				img.set_pixel(x, y, img.get_pixel(x, y).darkened(0.12 * float(ring + 3 - d)))   # тень под кромкой


## Латунные накладки на углах окна: уголок с заклёпкой.
static func _corner_plates(img: Image, n: int, border: Color) -> void:
	var hi := border.lightened(0.45)
	var lo := border.darkened(0.15)
	for corner in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		for a in 10:
			for t in 4:
				for p in [Vector2i(a, t), Vector2i(t, a)]:
					var x: int = 1 + p.x if corner.x == 0 else n - 2 - p.x
					var y: int = 1 + p.y if corner.y == 0 else n - 2 - p.y
					var edge: bool = a == 9 or t == 3
					img.set_pixel(x, y, (lo.darkened(0.45) if edge else hi.lerp(lo, float(t) / 3.0)))
		var cx: int = 4 if corner.x == 0 else n - 5
		var cy: int = 4 if corner.y == 0 else n - 5
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var rr := Vector2(dx, dy).length()
				if rr <= 1.7:
					img.set_pixel(cx + dx, cy + dy, Color("fff4c8") if rr < 0.8 and dx <= 0 and dy <= 0 else lo.darkened(0.2).lerp(hi, 0.5))


## Кнопка: дощечка с латунной окантовкой; нажатая — светлая полоса внизу, тень сверху.
static func button_box(fill: Color, border: Color, highlight: Color, pressed := false) -> StyleBoxTexture:
	var key := "button%s%s%s%s" % [fill, border, highlight, pressed]
	if _boxes.has(key):
		return _boxes[key]
	var n := 24
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := _inset(x, y, n, n, 4.0)
			if d <= 0.0:
				continue
			var c: Color
			var k := float(y) / float(n - 1)
			if pressed:
				k = 1.0 - k
			if d < 1.1:
				c = INK
			elif d < 2.3:
				c = border.lightened(0.2).lerp(border.darkened(0.25), k)
			else:
				c = highlight.lerp(fill, clampf(k * 1.6, 0.0, 1.0)).lerp(fill.darkened(0.3), clampf((k - 0.6) * 2.0, 0.0, 1.0))
			if d < 1.0:
				c.a *= d
			img.set_pixel(x, y, c)
	var sb := _smooth_box(img, 7, 4)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.content_margin_left = 10 * PX
	sb.content_margin_right = 10 * PX
	_boxes[key] = sb
	return sb


## Ячейка под значок: утопленная тёмная лунка в тонкой латунной оправе.
static func slot_box(border: Color = Color("5a4630"), fill: Color = Color("0f0c0a")) -> StyleBoxTexture:
	var key := "slot%s%s" % [border, fill]
	if _boxes.has(key):
		return _boxes[key]
	var art := _art_box("ui_slot", 1)
	if art != null and border == Color("5a4630"):
		_boxes[key] = art
		return art
	var n := 24
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := _inset(x, y, n, n, 3.0)
			if d <= 0.0:
				continue
			var c: Color
			if d < 1.1:
				c = INK
			elif d < 2.4:
				c = border.lightened(0.25).lerp(border.darkened(0.2), float(y) / float(n - 1))
			else:
				var k := float(y) / float(n - 1)
				c = fill.darkened(0.3).lerp(fill.lightened(0.08), k)
				c = c.darkened(0.45 * clampf((5.5 - d) / 3.0, 0.0, 1.0))
			if d < 1.0:
				c.a *= d
			img.set_pixel(x, y, c)
	var sb := _smooth_box(img, 7, 1)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	_boxes[key] = sb
	return sb


## Пергамент: страница в окне героя, торговли, журнала. Текст на нём — INK_TEXT.
static func parchment(pad := 8) -> StyleBoxTexture:
	var key := "parchment%d" % pad
	if _boxes.has(key):
		return _boxes[key]
	var art := _art_box("ui_parchment", pad)
	if art != null:
		_boxes[key] = art
		return art
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var light := Color("e9dbb8")
	var dark := Color("cdb88c")
	for y in n:
		for x in n:
			var d := _inset(x, y, n, n, 4.0)
			if d <= 0.0:
				continue
			var fx := float(x) / 24.0 * TAU
			var fy := float(y) / 24.0 * TAU
			var blot := 0.5 + 0.25 * sin(fx + 2.0 * sin(fy)) + 0.25 * sin(2.0 * fy + sin(2.0 * fx) + 0.7)
			var c := light.lerp(dark, blot * 0.55)
			c = c.lerp(Color("8a6a42"), 0.75 * clampf((6.0 - d) / 6.0, 0.0, 1.0))   # подпалённый край
			if d < 1.2:
				c = Color("4a3622")
			if d < 1.0:
				c.a *= d
			img.set_pixel(x, y, c)
	var sb := _smooth_box(img, 12, pad)
	_boxes[key] = sb
	return sb


## Картинка интерфейса из потока картинок (images/<id>) как 9 ломтей; поля — "ui_margin" в каталоге (или 24).
static func _art_box(id: String, pad: int) -> StyleBoxTexture:
	var fr := SpriteLibrary.frame("images", id)
	if fr.is_empty():
		return null
	var region: Rect2 = fr["region"]
	var tex: Texture2D = fr["texture"]
	var m := floorf(minf(24.0, region.size.x * 0.3))
	if id == "ui_parchment":
		m = 0.0   # бесшовный лист без края: просто повторяется на всю панель
	var sb := StyleBoxTexture.new()
	sb.texture = tex
	sb.region_rect = region
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.texture_margin_left = m
	sb.texture_margin_right = m
	sb.texture_margin_top = m
	sb.texture_margin_bottom = m
	sb.set_content_margin_all(pad * PX + maxf(4.0, m * 0.5))
	return sb


## 9 ломтей из картинки в родном размере: углы и края 1:1, середина повторяется.
static func _smooth_box(img: Image, margin: int, pad: int) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	sb.texture_margin_left = margin
	sb.texture_margin_right = margin
	sb.texture_margin_top = margin
	sb.texture_margin_bottom = margin
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.content_margin_left = pad * PX
	sb.content_margin_right = pad * PX
	sb.content_margin_top = pad * PX
	sb.content_margin_bottom = pad * PX
	return sb


static func _box(img: Image, margin: int, pad: int) -> StyleBoxTexture:
	img.resize(img.get_width() * PX, img.get_height() * PX, Image.INTERPOLATE_NEAREST)
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	sb.texture_margin_left = margin * PX
	sb.texture_margin_right = margin * PX
	sb.texture_margin_top = margin * PX
	sb.texture_margin_bottom = margin * PX
	sb.content_margin_left = pad * PX
	sb.content_margin_right = pad * PX
	sb.content_margin_top = pad * PX
	sb.content_margin_bottom = pad * PX
	return sb


static func _grabber(hl: bool) -> Texture2D:
	var img := Image.create(6, 10, false, Image.FORMAT_RGBA8)
	for y in 10:
		for x in 6:
			var edge := x == 0 or y == 0 or x == 5 or y == 9
			img.set_pixel(x, y, INK if edge else (GOLD.lightened(0.2) if hl else GOLD))
	img.resize(12, 20, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


static func _check(on: bool) -> Texture2D:
	var img := Image.create(9, 9, false, Image.FORMAT_RGBA8)
	for y in 9:
		for x in 9:
			var edge := x == 0 or y == 0 or x == 8 or y == 8
			var c := GOLD_DIM if edge else Color("0f0c0a")
			if on and x >= 2 and x <= 6 and y >= 2 and y <= 6:
				c = GOLD
			img.set_pixel(x, y, c)
	img.resize(18, 18, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


# --- Быстрые конструкторы -------------------------------------------------------------

static func label(text: String, size := 18, color := TEXT, kind := "body") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(kind))
	l.add_theme_font_size_override("font_size", roundi(size * TITLE_SCALE) if kind == "title" else size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, on_press: Callable = Callable(), size := 18) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.focus_mode = Control.FOCUS_NONE
	if on_press.is_valid():
		b.pressed.connect(on_press)
	b.pressed.connect(func() -> void: GameAudio.ui("ui_click"))
	b.mouse_entered.connect(func() -> void: _hover_sound(b))
	return b


static func _hover_sound(b: Button) -> void:
	if not b.disabled:
		GameAudio.ui("ui_hover")


static func panel(min_size := Vector2.ZERO) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = min_size
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	return p


## Привязать элемент к точке родителя (preset: угол, край или центр) со смещением pos и размером size.
## В Godot 4 position у привязанного элемента считается от левого верхнего угла родителя, поэтому
## задаём offset_* напрямую; растёт элемент от точки привязки (по центру — в обе стороны).
static func place(c: Control, preset: Control.LayoutPreset, pos: Vector2, size := Vector2.ZERO) -> void:
	c.set_anchors_preset(preset, true)
	c.offset_left = pos.x
	c.offset_top = pos.y
	c.offset_right = pos.x + size.x
	c.offset_bottom = pos.y + size.y
	var ax := c.anchor_left
	var ay := c.anchor_top
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH if is_equal_approx(ax, 0.5) \
		else (Control.GROW_DIRECTION_BEGIN if is_equal_approx(ax, 1.0) else Control.GROW_DIRECTION_END)
	c.grow_vertical = Control.GROW_DIRECTION_BOTH if is_equal_approx(ay, 0.5) \
		else (Control.GROW_DIRECTION_BEGIN if is_equal_approx(ay, 1.0) else Control.GROW_DIRECTION_END)


## Тёмная обводка букв: надпись читается поверх карты без подложки.
static func outline(l: Label, size := 6) -> void:
	l.add_theme_constant_override("outline_size", size)
	l.add_theme_color_override("font_outline_color", Color(0.03, 0.02, 0.02, 0.92))


## Тёмная подложка под надписью поверх карты. Ширина — по тексту, если надпись поставлена с нулевой шириной.
static func backdrop(l: Label) -> void:
	if not _boxes.has("backdrop"):
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.035, 0.03, 0.8)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 14.0
		sb.content_margin_right = 14.0
		sb.content_margin_top = 1.0
		sb.content_margin_bottom = 3.0
		_boxes["backdrop"] = sb
	l.add_theme_stylebox_override("normal", _boxes["backdrop"])


## Окно по центру родителя размером size (если содержимое больше — растёт в обе стороны).
static func center(c: Control, size: Vector2) -> void:
	place(c, Control.PRESET_CENTER, -size * 0.5, size)


## Растянуть на весь родитель.
static func fill_parent(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


static func vbox(sep := 8) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func hbox(sep := 8) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func element_color(element: String) -> Color:
	return ELEMENT_COLORS.get(element, TEXT)

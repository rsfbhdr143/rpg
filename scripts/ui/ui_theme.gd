class_name UiTheme
extends RefCounted
## Пиксельная тема интерфейса: шрифты, цвета, рамки окон и кнопок.
## Рамки рисуются кодом в маленькую картинку и увеличиваются без сглаживания,
## поэтому для интерфейса не нужны файлы картинок. Поменять вид — правь цвета ниже.

const FONT_BODY := "res://assets/fonts/PixelifySans-Regular.ttf"
const FONT_BOLD := "res://assets/fonts/PixelifySans-Bold.ttf"
const FONT_TITLE := "res://assets/fonts/PressStart2P-Regular.ttf"
const PX := 2   # во сколько раз увеличены пиксели рамок (как пиксели мира)

const BG := Color("15110e")
const PANEL := Color("1d1712")
const INK := Color("0b0807")
const GOLD := Color("c8a060")
const GOLD_DIM := Color("8a6a3a")
const TEXT := Color("ecdfc2")
const TEXT_DIM := Color("a89a80")
const TEXT_FAINT := Color("6e6454")
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
	"air": Color("c8b8ff"), "poison": Color("8ad848"), "heal": Color("82e870"), "": Color("d8d0c0"),
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
		# Press Start 2P нарисован по сетке 8 px: без сглаживания он чёткий на размерах, кратных 8.
		# Pixelify Sans не по сетке, со сглаживанием он читается лучше.
		ffile.antialiasing = TextServer.FONT_ANTIALIASING_NONE if kind == "title" else TextServer.FONT_ANTIALIASING_GRAY
		ffile.hinting = TextServer.HINTING_NONE
		ffile.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		ffile.generate_mipmaps = false
	_fonts[kind] = f
	return f


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font("body")
	t.default_font_size = 18
	var panel := frame(PANEL, GOLD_DIM, INK, Color("2c231a"), 0.95)
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

## Рамка окна: тёмный контур, золотистая кайма, тёмная внутренняя полоса, заливка. Уголки срезаны.
static func frame(fill: Color, border: Color, outline: Color, inner: Color, alpha := 1.0, pad := 5) -> StyleBoxTexture:
	var key := "frame%s%s%s%s%s%d" % [fill, border, outline, inner, alpha, pad]
	if _boxes.has(key):
		return _boxes[key]
	var n := 12
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var f := Color(fill.r, fill.g, fill.b, alpha)
	for y in n:
		for x in n:
			var d := mini(mini(x, y), mini(n - 1 - x, n - 1 - y))
			var corner := (x == 0 or x == n - 1) and (y == 0 or y == n - 1)
			var c: Color
			if corner:
				c = Color(0, 0, 0, 0)
			elif d == 0:
				c = outline
			elif d == 1:
				c = border
			elif d == 2:
				c = inner
			else:
				c = f
			img.set_pixel(x, y, c)
	# заклёпки в углах
	for p in [Vector2i(1, 1), Vector2i(n - 2, 1), Vector2i(1, n - 2), Vector2i(n - 2, n - 2)]:
		img.set_pixel(p.x, p.y, border.lightened(0.35))
	_boxes[key] = _box(img, 3, pad)
	return _boxes[key]


static func button_box(fill: Color, border: Color, highlight: Color, pressed := false) -> StyleBoxTexture:
	var key := "button%s%s%s%s" % [fill, border, highlight, pressed]
	if _boxes.has(key):
		return _boxes[key]
	var n := 10
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var edge := x == 0 or y == 0 or x == n - 1 or y == n - 1
			var corner := (x == 0 or x == n - 1) and (y == 0 or y == n - 1)
			var c := fill
			if corner:
				c = Color(0, 0, 0, 0)
			elif edge:
				c = border
			elif (y == 1 and not pressed) or (y == n - 2 and pressed):
				c = highlight
			elif (y == n - 2 and not pressed) or (y == 1 and pressed):
				c = fill.darkened(0.35)
			img.set_pixel(x, y, c)
	var sb := _box(img, 2, 4)
	sb.content_margin_left = 10 * PX
	sb.content_margin_right = 10 * PX
	_boxes[key] = sb
	return sb


## Пустая ячейка (под значок навыка, портрет).
static func slot_box(border: Color = Color("5a4630"), fill: Color = Color("0f0c0a")) -> StyleBoxTexture:
	var key := "slot%s%s" % [border, fill]
	if _boxes.has(key):
		return _boxes[key]
	var n := 8
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var edge := x == 0 or y == 0 or x == n - 1 or y == n - 1
			img.set_pixel(x, y, border if edge else (fill.lightened(0.04) if y == n - 2 else fill))
	_boxes[key] = _box(img, 1, 1)
	return _boxes[key]


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
	l.add_theme_font_size_override("font_size", size)
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

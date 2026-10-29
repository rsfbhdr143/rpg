class_name DialogueBox
extends Control
## Окно разговора и заставки. Реплику берёт из сессии (Story.view), текст печатается по буквам,
## ответы — кнопками и клавишами 1–9. Стиль "cinematic" с картинкой — во весь экран с чёрными
## полосами; картинка держится, пока говорит рассказчик, а реплики персонажей идут поверх мира.
## Отвечает только тот игрок, кто начал разговор; остальные видят текст и имя отвечающего.
## Стиль "board" — доска объявлений: нарисованная доска с листками, реплики рассказчика идут в обычном окне под ней.

var screen: Node
var view: Dictionary = {}
var can_answer := true
var answerer := ""
var cinematic := false

var _key := ""
var _shown := 0.0
var _total := 0
var _image := ""
var _blip := 0.0
var _choice_buttons: Array = []
var _listed: Array = []      # индексы ответов под кнопками (листки доски срывают кликом по картинке, кнопок у них нет)
var _tearable := false       # на доске есть листок, который можно сорвать

var _cine: CineLayer
var _board: BoardLayer
var _box: PanelContainer
var _portrait: PortraitRect
var _name: Label
var _text: RichTextLabel
var _choices: VBoxContainer
var _hint: Label
var _cine_name: Label
var _cine_text: RichTextLabel
var _cine_choices: VBoxContainer
var _cine_hint: Label


func _ready() -> void:
	UiTheme.fill_parent(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.theme()
	visible = false
	_cine = CineLayer.new()
	_cine.box = self
	UiTheme.fill_parent(_cine)
	_cine.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_cine)
	var cv := UiTheme.vbox(6)
	UiTheme.place(cv, Control.PRESET_CENTER_BOTTOM, Vector2(-460, -176), Vector2(920, 168))
	cv.grow_vertical = Control.GROW_DIRECTION_BEGIN
	cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cine.add_child(cv)
	_board = BoardLayer.new()
	_board.box = self
	UiTheme.fill_parent(_board)
	_board.mouse_filter = Control.MOUSE_FILTER_STOP
	_board.visible = false
	add_child(_board)
	_cine_name = UiTheme.label("", 18, UiTheme.GOLD, "bold")
	_cine_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_cine_name)
	_cine_text = _make_text(22)
	_cine_text.custom_minimum_size = Vector2(920, 70)
	cv.add_child(_cine_text)
	_cine_choices = UiTheme.vbox(4)
	cv.add_child(_cine_choices)
	_cine_hint = UiTheme.label("", 14, UiTheme.TEXT_FAINT)
	_cine_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_cine_hint)

	_box = UiTheme.panel(Vector2(1060, 196))
	UiTheme.place(_box, Control.PRESET_CENTER_BOTTOM, Vector2(-530, -206), Vector2(1060, 196))
	_box.gui_input.connect(_on_box_input)
	add_child(_box)
	var h := UiTheme.hbox(14)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(h)
	_portrait = PortraitRect.new()
	_portrait.box = self
	_portrait.custom_minimum_size = Vector2(132, 132)
	_portrait.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(_portrait)
	var v := UiTheme.vbox(6)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(v)
	_name = UiTheme.label("", 20, UiTheme.GOLD, "bold")
	v.add_child(_name)
	_text = _make_text(19)
	_text.custom_minimum_size = Vector2(880, 60)
	v.add_child(_text)
	_choices = UiTheme.vbox(3)
	v.add_child(_choices)
	_hint = UiTheme.label("", 14, UiTheme.TEXT_FAINT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(_hint)


func _make_text(size: int) -> RichTextLabel:
	var t := RichTextLabel.new()
	t.bbcode_enabled = true
	t.fit_content = true
	t.scroll_active = false
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.add_theme_font_size_override("normal_font_size", size)
	t.add_theme_font_size_override("italics_font_size", size)
	t.add_theme_font_override("italics_font", UiTheme.font("body"))
	t.add_theme_color_override("default_color", UiTheme.TEXT)
	return t


## Показать реплику (зовётся каждый кадр, пока идёт разговор).
func present(v: Dictionary, answer_ok: bool, who: String) -> void:
	view = v
	can_answer = answer_ok
	answerer = who
	var key := "%s/%s" % [v.get("id", ""), v.get("node", "")]
	if key != _key:
		_key = key
		_on_new_line()
	visible = true


func close() -> void:
	visible = false
	_board.visible = false
	_key = ""
	_image = ""
	view = {}


func _on_new_line() -> void:
	var speaker := str(view.get("speaker", "narrator"))
	var img := str(view.get("image", ""))
	if img != "":
		_image = img
	elif speaker != "narrator":
		_image = ""
	cinematic = str(view.get("style", "box")) == "cinematic" and _image != ""
	_cine.visible = cinematic
	_box.visible = not cinematic
	var board := not cinematic and str(view.get("style", "")) == "board" and not (view.get("board", {}) as Dictionary).is_empty()
	if board and (not _board.visible or int(view.get("page", -1)) >= 0):
		GameAudio.sfx("page", -6.0)
	_board.visible = board
	_board.queue_redraw()
	var name := str(view.get("name", ""))
	var text := _format(str(view.get("text", "")), speaker)
	var label := _cine_text if cinematic else _text
	(_cine_name if cinematic else _name).text = name
	label.text = "[center]%s[/center]" % text if cinematic else text
	_shown = 0.0
	var strip := RegEx.new()
	strip.compile("\\[[^\\]]*\\]")
	_total = strip.sub(text, "", true).length()
	label.visible_characters = 0
	_portrait.visible = str(view.get("portrait", "")) != ""
	_portrait.queue_redraw()
	_build_choices()
	if speaker == "narrator" and cinematic and img != "":
		GameAudio.sfx("page", -6.0)


## Ремарки в скобках — курсивом и тусклее, речь рассказчика — тоже чуть тусклее.
func _format(text: String, speaker: String) -> String:
	text = text.replace("[", "(").replace("]", ")")
	var re := RegEx.new()
	re.compile("\\(([^)]*)\\)")
	text = re.sub(text, "[color=#a89a80][i]($1)[/i][/color]", true)
	if speaker == "narrator":
		text = "[color=#d8ccb0]%s[/color]" % text
	return text


func _build_choices() -> void:
	for b in _choice_buttons:
		(b as Node).queue_free()
	_choice_buttons.clear()
	var parent := _cine_choices if cinematic else _choices
	var list: Array = view.get("choices", [])
	_listed.clear()
	_tearable = false
	var texts: Array = []
	for i in list.size():
		var c: Dictionary = list[i]
		if _board.visible and int(c.get("page", -1)) >= 0:
			_tearable = true
			continue
		_listed.append(int(c.get("index", i)))
		texts.append(str(c.get("text", "")))
	for i in _listed.size():
		var idx := int(_listed[i])
		var b := UiTheme.button("%d. %s" % [i + 1, texts[i]], func() -> void: _choose(idx), 18)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = not can_answer
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size = Vector2(860, 0)
		b.visible = false
		parent.add_child(b)
		_choice_buttons.append(b)


func _process(delta: float) -> void:
	if not visible or view.is_empty():
		return
	var label := _cine_text if cinematic else _text
	if _shown < _total:
		var speed := float(GameSettings.get_value("text_speed"))
		_shown = minf(float(_total), _shown + delta * maxf(10.0, speed))
		label.visible_characters = int(_shown)
		_blip += delta
		if _blip > 0.07 and str(view.get("speaker", "")) != "narrator":
			_blip = 0.0
			GameAudio.ui("dialogue_blip")
	var done := _shown >= _total
	for b in _choice_buttons:
		(b as Button).visible = done
		(b as Button).disabled = not can_answer
	var has_choices := not _choice_buttons.is_empty()
	var hint := ""
	if not can_answer:
		hint = "Отвечает %s" % answerer
	elif not done:
		hint = "ЛКМ или Пробел — показать всё"
	elif _tearable:
		hint = "ЛКМ по листку — сорвать"
	elif has_choices:
		hint = "Выберите ответ: 1–%d" % _choice_buttons.size()
	else:
		hint = "ЛКМ или Пробел — дальше · Esc — пролистать"
	(_cine_hint if cinematic else _hint).text = hint
	if cinematic:
		_cine.queue_redraw()


func _on_box_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		advance()
		_box.accept_event()


## Пробел, Enter, клик: допечатать или перейти дальше.
func advance() -> void:
	if not visible:
		return
	if _shown < _total:
		_shown = float(_total)
		(_cine_text if cinematic else _text).visible_characters = -1
		return
	if _choice_buttons.is_empty() and not _tearable and can_answer:
		screen.call("dialogue_next")


func choose_number(n: int) -> void:
	if not visible or _shown < _total or not can_answer:
		return
	if n >= 0 and n < _listed.size():
		_choose(int(_listed[n]))


func _choose(index: int) -> void:
	if can_answer:
		GameAudio.ui("ui_confirm")
		screen.call("dialogue_choice", index)


func skip() -> void:
	if visible and can_answer:
		screen.call("dialogue_skip")


## Заставка во весь экран: картинка между чёрными полосами.
class CineLayer extends Control:
	var box: DialogueBox

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			box.advance()
			accept_event()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.02, 0.015, 0.02))
		var top := 54.0
		var bottom := 186.0
		var area := Rect2(0, top, size.x, size.y - top - bottom)
		SceneArt.draw(self, box._image, area, float(Time.get_ticks_msec()) / 1000.0)
		draw_rect(Rect2(0, 0, size.x, top), Color(0.02, 0.015, 0.02))
		draw_rect(Rect2(0, size.y - bottom, size.x, bottom), Color(0.02, 0.015, 0.02))
		draw_rect(Rect2(0, top, size.x, 2), Color("3a2c1e"))
		draw_rect(Rect2(0, size.y - bottom - 2, size.x, 2), Color("3a2c1e"))


## Доска объявлений: картинка images/<board.image> (нет картинки — простая доска), на местах board.pages —
## листки board.notes: текст, подпись, приписка другой рукой или размокшая бумажка. sign_align "left" — подпись
## слева (справа печать). Листок с делом срывают кликом: у ответа реплики есть "page" с номером листка, клик по листку
## выбирает этот ответ. Сорванный (флаг taken_flag) закрывается деревом доски (полоса board.wood_strip поверх
## board.notes[i].paper), под гвоздём остаётся клочок.
class BoardLayer extends Control:
	const INK := Color("2b1d14")
	var box: DialogueBox
	var _rects: Array = []   # места листков на экране (для клика)
	var _hover := -1

	func _gui_input(event: InputEvent) -> void:
		var mm := event as InputEventMouseMotion
		if mm != null:
			var h := _page_at(mm.position)
			if _page_choice(h) < 0:
				h = -1
			if h != _hover:
				_hover = h
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if h >= 0 else Control.CURSOR_ARROW
				queue_redraw()
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var choice := _page_choice(_page_at(mb.position))
			if choice >= 0 and box.can_answer and box._shown >= box._total:
				box._choose(choice)
			else:
				box.advance()
			accept_event()

	func _page_at(p: Vector2) -> int:
		for i in _rects.size():
			if (_rects[i] as Rect2).grow(8.0).has_point(p):
				return i
		return -1

	## Ответ реплики, привязанный к листку i (сорвать его), или -1.
	func _page_choice(i: int) -> int:
		if i < 0:
			return -1
		for c in box.view.get("choices", []):
			if int((c as Dictionary).get("page", -1)) == i:
				return int((c as Dictionary).get("index", -1))
		return -1

	func _draw() -> void:
		var b: Dictionary = box.view.get("board", {})
		var sz: Array = b.get("size", [400, 280])
		var src := Vector2(float(sz[0]), float(sz[1]))
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.015, 0.02, 0.62))
		var top_h := size.y - 214.0   # ниже — окно реплики
		var k := maxf(1.0, floorf(minf((size.x - 40.0) / src.x, (top_h - 10.0) / src.y) * 4.0) / 4.0)
		var area := Rect2(((Vector2(size.x, top_h) - src * k) * 0.5).floor(), src * k)
		var pages: Array = b.get("pages", [])
		var notes: Array = b.get("notes", [])
		var flags: Dictionary = Net.session.flags if Net.session != null else {}
		var fr := SpriteLibrary.frame("images", str(b.get("image", "")))
		if fr.is_empty():
			draw_rect(area, Color("5a3c24"))
			draw_rect(area, Color("2a1a10"), false, 3.0)
			for i in pages.size():
				var nt: Dictionary = notes[i] if i < notes.size() else {}
				if not flags.has(str(nt.get("taken_flag", "-"))):
					draw_rect(_at(pages[i], area, k).grow(7.0 * k), Color("e8dcc0"))
		else:
			draw_texture_rect_region(fr["texture"], area, fr["region"])
		if b.has("title_rect"):
			var tr := _at(b["title_rect"], area, k)
			var fs := int(tr.size.y * 0.8)
			var base := Vector2(tr.position.x, tr.position.y + (tr.size.y + fs * 0.7) * 0.5).round()
			var title := str(b.get("title", ""))
			draw_string(UiTheme.font("bold"), base + Vector2(1, 1), title, HORIZONTAL_ALIGNMENT_CENTER, tr.size.x, fs, Color("1a0f08"))
			draw_string(UiTheme.font("bold"), base, title, HORIZONTAL_ALIGNMENT_CENTER, tr.size.x, fs, Color("f0dcb0"))
		var cur := int(box.view.get("page", -1))
		_rects.clear()
		for i in pages.size():
			var r := _at(pages[i], area, k)
			_rects.append(r)
			var note: Dictionary = notes[i] if i < notes.size() else {}
			if flags.has(str(note.get("taken_flag", "-"))):
				_torn(fr, b, note, area, k)
				continue
			if bool(note.get("soaked", false)):
				_soaked(r, k)
			else:
				_note(r, note, k, INK if cur < 0 or cur == i else Color(INK, 0.38))
			if i == _hover:
				draw_rect(r.grow(9.0 * k), Color(UiTheme.GOLD, 0.95), false, 3.0)
				draw_string(UiTheme.font("bold"), Vector2(r.position.x, r.end.y + 9.0 * k + 18.0), "Сорвать",
					HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 16, UiTheme.GOLD)
		if cur >= 0 and cur < pages.size():
			draw_rect(_at(pages[cur], area, k).grow(9.0 * k), Color(UiTheme.GOLD, 0.9), false, 2.0)

	## Листок сорван: место под ним — дерево доски, под гвоздём клочок бумаги.
	func _torn(fr: Dictionary, b: Dictionary, note: Dictionary, area: Rect2, k: float) -> void:
		var pa: Array = note.get("paper", [])
		if pa.size() < 4:
			return
		var paper := _at(pa, area, k)
		var strip: Array = b.get("wood_strip", [])
		if not fr.is_empty() and strip.size() >= 2:
			var reg: Rect2 = fr["region"]
			var sy := float(strip[0])
			var sh := float(strip[1])
			var y := 0.0
			while y < float(pa[3]):
				var h := minf(sh, float(pa[3]) - y)
				var src := Rect2(reg.position + Vector2(float(pa[0]), sy), Vector2(float(pa[2]), h))
				draw_texture_rect_region(fr["texture"], Rect2(paper.position + Vector2(0, y * k), Vector2(paper.size.x, h * k)), src)
				y += sh
		else:
			draw_rect(paper, Color("5a3c24"))
		var pin := paper.position + Vector2(paper.size.x * 0.48, 5.0 * k)
		var scrap := PackedVector2Array([pin + Vector2(-9, -4) * k, pin + Vector2(8, -5) * k, pin + Vector2(6, 3) * k,
			pin + Vector2(1, 9) * k, pin + Vector2(-3, 4) * k, pin + Vector2(-8, 7) * k])
		draw_colored_polygon(scrap, Color("e2d4b4"))
		draw_polyline(scrap + PackedVector2Array([scrap[0]]), Color("8a7a5a"), 1.0)
		draw_circle(pin, 2.5 * k, Color("a02a20"))
		draw_circle(pin + Vector2(-0.6, -0.6) * k, 1.0 * k, Color("e86a5a"))

	func _at(v: Variant, area: Rect2, k: float) -> Rect2:
		var a: Array = v
		return Rect2(area.position + Vector2(float(a[0]), float(a[1])) * k, Vector2(float(a[2]), float(a[3])) * k)

	## Объявление: текст подбирается по размеру листка, подпись справа внизу, приписка — наискось другой рукой.
	func _note(r: Rect2, note: Dictionary, k: float, ink: Color) -> void:
		var font := UiTheme.font("body")
		var bold := UiTheme.font("bold")
		var text := str(note.get("text", ""))
		var sign := str(note.get("sign", ""))
		var ps := str(note.get("postscript", ""))
		var inner := r.grow(-2.0 * k)
		var fs := int(12.0 * k)
		while fs > 9:
			var foot := (fs + 4) if sign != "" or ps != "" else 0
			if font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, inner.size.x, fs).y + foot <= inner.size.y:
				break
			fs -= 1
		draw_multiline_string(font, inner.position + Vector2(0, font.get_ascent(fs)), text, HORIZONTAL_ALIGNMENT_LEFT, inner.size.x, fs, -1, ink)
		var foot_y := inner.end.y - font.get_descent(fs)
		if sign != "":
			var align := HORIZONTAL_ALIGNMENT_LEFT if str(note.get("sign_align", "")) == "left" else HORIZONTAL_ALIGNMENT_RIGHT
			draw_string(bold, Vector2(inner.position.x, foot_y), "— " + sign, align, inner.size.x, fs, ink)
		if ps != "":
			draw_set_transform(Vector2(inner.position.x + 4.0 * k, foot_y), -0.12)
			draw_string(bold, Vector2.ZERO, ps, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 3, Color(Color("8a2c18"), ink.a))
			draw_set_transform(Vector2.ZERO)

	## Размокшая бумажка: разводы и расплывшиеся строки, прочесть нельзя.
	func _soaked(r: Rect2, k: float) -> void:
		var c := r.get_center()
		draw_circle(c + Vector2(-r.size.x * 0.12, r.size.y * 0.06), r.size.y * 0.36, Color(0.45, 0.33, 0.2, 0.16))
		draw_circle(c + Vector2(r.size.x * 0.2, -r.size.y * 0.1), r.size.y * 0.26, Color(0.4, 0.3, 0.2, 0.13))
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var y := r.position.y + 8.0 * k
		while y < r.end.y - 6.0 * k:
			var x := r.position.x + 3.0 * k
			var end := r.end.x - rng.randf_range(4.0, 34.0) * k
			while x < end:
				var w := rng.randf_range(6.0, 22.0) * k
				var a := Vector2(x, y + rng.randf_range(-1.0, 1.0))
				var e := Vector2(minf(x + w, end), y + rng.randf_range(-1.5, 1.5))
				draw_line(a, e, Color(0.32, 0.25, 0.22, 0.12), maxf(4.0, 4.5 * k))   # расплылось
				draw_line(a, e, Color(0.28, 0.22, 0.22, 0.2), maxf(2.0, 1.8 * k))
				x += w + rng.randf_range(3.0, 7.0) * k
			y += 10.0 * k


class PortraitRect extends Control:
	var box: DialogueBox
	var _view: IconArt.PortraitView

	func _ready() -> void:
		_view = IconArt.PortraitView.new()
		UiTheme.place(_view, Control.PRESET_FULL_RECT, Vector2(6, 6))
		_view.offset_right = -6
		_view.offset_bottom = -6
		add_child(_view)

	func _draw() -> void:
		draw_style_box(UiTheme.slot_box(UiTheme.GOLD_DIM), Rect2(Vector2.ZERO, size))
		_view.id = str(box.view.get("portrait", ""))

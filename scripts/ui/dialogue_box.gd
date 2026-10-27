class_name DialogueBox
extends Control
## Окно разговора и заставки. Реплику берёт из сессии (Story.view), текст печатается по буквам,
## ответы — кнопками и клавишами 1–9. Стиль "cinematic" с картинкой — во весь экран с чёрными
## полосами; картинка держится, пока говорит рассказчик, а реплики персонажей идут поверх мира.
## Отвечает только тот игрок, кто начал разговор; остальные видят текст и имя отвечающего.

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

var _cine: CineLayer
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
	for i in list.size():
		var c: Dictionary = list[i]
		var idx := int(c.get("index", i))
		var b := UiTheme.button("%d. %s" % [i + 1, str(c.get("text", ""))], func() -> void: _choose(idx), 18)
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
	if _choice_buttons.is_empty() and can_answer:
		screen.call("dialogue_next")


func choose_number(n: int) -> void:
	if not visible or _shown < _total or not can_answer:
		return
	var list: Array = view.get("choices", [])
	if n >= 0 and n < list.size():
		_choose(int((list[n] as Dictionary).get("index", n)))


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

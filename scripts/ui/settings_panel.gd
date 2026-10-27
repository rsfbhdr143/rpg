class_name SettingsPanel
extends PanelContainer
## Настройки: громкость (музыка, звуки, фон, интерфейс), полный экран, пиксельность,
## меньше цветов, тряска, скорость текста. Всё сохраняется сразу.

signal closed

var _rows: VBoxContainer


func _ready() -> void:
	theme = UiTheme.theme()
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(560, 0)
	position = Vector2(-280, -250)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UiTheme.vbox(10)
	add_child(v)
	v.add_child(UiTheme.label("Настройки", 22, UiTheme.GOLD, "bold"))
	_rows = UiTheme.vbox(8)
	v.add_child(_rows)
	_slider("Музыка", "music", 0.0, 1.0, 0.05)
	_slider("Звуки", "sfx", 0.0, 1.0, 0.05)
	_slider("Фоновые звуки", "ambient", 0.0, 1.0, 0.05)
	_slider("Звуки интерфейса", "ui", 0.0, 1.0, 0.05)
	_slider("Скорость текста", "text_speed", 20.0, 200.0, 10.0)
	_check("Полный экран (F11)", "fullscreen")
	_check("Меньше цветов, как в старых играх", "posterize")
	_check("Тряска экрана", "shake")
	var px := UiTheme.hbox(8)
	_rows.add_child(px)
	var l := UiTheme.label("Крупность пикселей", 18)
	l.custom_minimum_size = Vector2(220, 0)
	px.add_child(l)
	for k in [2, 3, 4]:
		var b := UiTheme.button("×%d" % k, _set_scale.bind(k), 16)
		b.toggle_mode = true
		b.button_pressed = int(GameSettings.get_value("pixel_scale")) == k
		b.set_meta("scale", k)
		px.add_child(b)
	v.add_child(UiTheme.button("Готово", func() -> void: closed.emit(), 18))


func _slider(text: String, key: String, lo: float, hi: float, step: float) -> void:
	var h := UiTheme.hbox(8)
	_rows.add_child(h)
	var l := UiTheme.label(text, 18)
	l.custom_minimum_size = Vector2(220, 0)
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(GameSettings.get_value(key))
	s.custom_minimum_size = Vector2(280, 24)
	s.focus_mode = Control.FOCUS_NONE
	s.value_changed.connect(func(val: float) -> void: GameSettings.set_value(key, val))
	h.add_child(s)


func _check(text: String, key: String) -> void:
	var c := CheckBox.new()
	c.text = text
	c.focus_mode = Control.FOCUS_NONE
	c.button_pressed = bool(GameSettings.get_value(key))
	c.add_theme_font_size_override("font_size", 18)
	c.toggled.connect(func(on: bool) -> void: GameSettings.set_value(key, on))
	_rows.add_child(c)


func _set_scale(k: int) -> void:
	GameSettings.set_value("pixel_scale", k)
	for row in _rows.get_children():
		for b in row.get_children():
			if b is Button and b.has_meta("scale"):
				(b as Button).button_pressed = int(b.get_meta("scale")) == k

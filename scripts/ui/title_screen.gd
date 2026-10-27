class_name TitleScreen
extends Control
## Титульный экран: новая игра (одиночка выбирает двух героев), продолжить с сохранения,
## игра по сети (хост, подключение, лобби с выбором героя), настройки, выход.
## Запуск выделенного сервера без графики:
##   godot --headless --path . -- --server --port 8910
## Сразу одиночная игра, минуя меню: godot --path . -- --solo

const GAME_SCENE := "res://scenes/game.tscn"
const SOLO_PICKS := 2

## Что сказать игроку при возврате в меню (обрыв связи, выход из игры).
static var message := ""

var _bg: TitleArt
var _main: VBoxContainer
var _new_panel: PanelContainer
var _net_panel: PanelContainer
var _lobby_panel: PanelContainer
var _settings: SettingsPanel
var _status: Label
var _picks: Array = []
var _cards: Dictionary = {}
var _go_btn: Button
var _name_edit: LineEdit
var _port_edit: LineEdit
var _url_edit: LineEdit
var _net_status: Label
var _lobby_list: VBoxContainer
var _lobby_heroes: HBoxContainer
var _lobby_hint: Label
var _start_btn: Button


func _ready() -> void:
	if _is_dedicated_launch():
		_start_dedicated()
		return
	GameData.ensure_loaded()
	SpriteLibrary.ensure_loaded()
	GameSettings.ensure_loaded()
	GameSettings.apply()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiTheme.theme()
	_picks = (GameData.rule("party_templates", ["knight", "wizard"]) as Array).slice(0, SOLO_PICKS)
	_build()
	Net.lobby_changed.connect(_refresh_lobby)
	Net.game_started.connect(_on_game_started)
	Net.disconnected.connect(_on_disconnected)
	Net.notice.connect(_on_notice)
	if message != "" and message != "Вы вышли из игры.":
		_status.text = message
	message = ""
	if GameAudio.current_music() != str(GameData.rule("menu_music", "theme_lado")):
		GameAudio.music(str(GameData.rule("menu_music", "theme_lado")))
	GameAudio.ambient("")
	if OS.get_cmdline_user_args().has("--solo"):
		_start_solo.call_deferred()


func _is_dedicated_launch() -> bool:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	return args.has("--server") or (DisplayServer.get_name() == "headless" and not args.has("--client"))


func _start_dedicated() -> void:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var port := Net.DEFAULT_PORT
	var i := args.find("--port")
	if i >= 0 and i + 1 < args.size():
		port = int(args[i + 1])
	var err := Net.host(port, true)
	if err != "":
		printerr(err)
		get_tree().quit(1)


# --- Сборка экрана ----------------------------------------------------------------------

func _build() -> void:
	_bg = TitleArt.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_bg)

	var head := UiTheme.vbox(10)
	head.set_anchors_preset(Control.PRESET_CENTER_TOP)
	head.position = Vector2(-500, 70)
	head.custom_minimum_size = Vector2(1000, 0)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(head)
	var title := UiTheme.label("ПЕПЕЛЬНЫЕ СТРАЖИ", 40, UiTheme.GOLD, "title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 4)
	head.add_child(title)
	var sub := UiTheme.label("Пролог: Последняя воля", 24, UiTheme.TEXT_DIM, "bold")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	sub.add_theme_constant_override("shadow_offset_x", 2)
	sub.add_theme_constant_override("shadow_offset_y", 2)
	head.add_child(sub)

	_main = UiTheme.vbox(10)
	_main.set_anchors_preset(Control.PRESET_CENTER)
	_main.position = Vector2(-170, -40)
	_main.custom_minimum_size = Vector2(340, 0)
	add_child(_main)
	_main.add_child(_menu_button("Новая игра", _open_new))
	if GameSession.has_save():
		_main.add_child(_menu_button("Продолжить", _continue))
	_main.add_child(_menu_button("Игра по сети", _open_net))
	_main.add_child(_menu_button("Настройки", _open_settings))
	if not OS.has_feature("web"):
		_main.add_child(_menu_button("Выход", _quit))
	_status = UiTheme.label("", 17, Color("f0c080"))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.custom_minimum_size = Vector2(340, 0)
	_main.add_child(_status)

	var foot := UiTheme.label("Прототип · пошаговая партийная RPG · до 4 игроков по сети", 14, UiTheme.TEXT_FAINT)
	foot.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	foot.position = Vector2(16, -30)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(foot)

	_build_new()
	_build_net()
	_build_lobby()
	_settings = SettingsPanel.new()
	_settings.visible = false
	_settings.closed.connect(_back)
	add_child(_settings)


func _menu_button(text: String, cb: Callable) -> Button:
	var b := UiTheme.button(text, cb, 22)
	b.custom_minimum_size = Vector2(340, 48)
	return b


func _build_new() -> void:
	_new_panel = UiTheme.panel(Vector2(1040, 0))
	_new_panel.set_anchors_preset(Control.PRESET_CENTER)
	_new_panel.position = Vector2(-520, -150)
	_new_panel.visible = false
	add_child(_new_panel)
	var v := UiTheme.vbox(10)
	_new_panel.add_child(v)
	v.add_child(UiTheme.label("Кого вести в путь?", 22, UiTheme.GOLD, "bold"))
	var hint := UiTheme.label("В одиночной игре вы ведёте двоих героев, как в Divinity: Original Sin. Выберите двух.", 16, UiTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	var row := UiTheme.hbox(12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	for t in GameData.rule("party_templates", ["knight", "wizard"]):
		var card := HeroCard.new()
		card.template = str(t)
		card.custom_minimum_size = Vector2(240, 300)
		card.pressed.connect(_toggle_pick.bind(str(t)))
		row.add_child(card)
		_cards[str(t)] = card
	var buttons := UiTheme.hbox(10)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(buttons)
	buttons.add_child(UiTheme.button("Назад", _back, 18))
	_go_btn = UiTheme.button("В путь", _start_solo, 20)
	_go_btn.custom_minimum_size = Vector2(180, 0)
	buttons.add_child(_go_btn)
	_update_picks()


func _build_net() -> void:
	_net_panel = UiTheme.panel(Vector2(620, 0))
	_net_panel.set_anchors_preset(Control.PRESET_CENTER)
	_net_panel.position = Vector2(-310, -130)
	_net_panel.visible = false
	add_child(_net_panel)
	var v := UiTheme.vbox(10)
	_net_panel.add_child(v)
	v.add_child(UiTheme.label("Игра по сети", 22, UiTheme.GOLD, "bold"))
	var hint := UiTheme.label("До четырёх игроков, у каждого свой герой. Один создаёт игру, остальные подключаются по адресу.", 16, UiTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(580, 0)
	v.add_child(hint)
	var name_row := UiTheme.hbox(8)
	v.add_child(name_row)
	var nl := UiTheme.label("Ваше имя", 18)
	nl.custom_minimum_size = Vector2(150, 0)
	name_row.add_child(nl)
	_name_edit = _edit(str(GameSettings.get_value("player_name")), 420)
	name_row.add_child(_name_edit)
	# Браузер не может принимать подключения, поэтому в веб-версии создать игру нельзя.
	if not OS.has_feature("web"):
		var host_row := UiTheme.hbox(8)
		v.add_child(host_row)
		var pl := UiTheme.label("Порт", 18)
		pl.custom_minimum_size = Vector2(150, 0)
		host_row.add_child(pl)
		_port_edit = _edit(str(Net.DEFAULT_PORT), 110)
		host_row.add_child(_port_edit)
		var hb := UiTheme.button("Создать игру", _host, 18)
		hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host_row.add_child(hb)
	var join_row := UiTheme.hbox(8)
	v.add_child(join_row)
	var jl := UiTheme.label("Адрес", 18)
	jl.custom_minimum_size = Vector2(150, 0)
	join_row.add_child(jl)
	_url_edit = _edit(str(GameSettings.get_value("server_url")), 270)
	join_row.add_child(_url_edit)
	var jb := UiTheme.button("Подключиться", _join, 18)
	jb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_row.add_child(jb)
	_net_status = UiTheme.label("", 16, Color("f0c080"))
	_net_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_status.custom_minimum_size = Vector2(580, 0)
	v.add_child(_net_status)
	var buttons := UiTheme.hbox(10)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(buttons)
	buttons.add_child(UiTheme.button("Назад", _back, 18))


func _build_lobby() -> void:
	_lobby_panel = UiTheme.panel(Vector2(1040, 0))
	_lobby_panel.set_anchors_preset(Control.PRESET_CENTER)
	_lobby_panel.position = Vector2(-520, -170)
	_lobby_panel.visible = false
	add_child(_lobby_panel)
	var v := UiTheme.vbox(10)
	_lobby_panel.add_child(v)
	v.add_child(UiTheme.label("Лобби", 22, UiTheme.GOLD, "bold"))
	_lobby_hint = UiTheme.label("", 16, UiTheme.TEXT_DIM)
	_lobby_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lobby_hint.custom_minimum_size = Vector2(1000, 0)
	v.add_child(_lobby_hint)
	_lobby_list = UiTheme.vbox(4)
	v.add_child(_lobby_list)
	v.add_child(UiTheme.label("Ваш герой", 19, UiTheme.GOLD, "bold"))
	_lobby_heroes = UiTheme.hbox(12)
	_lobby_heroes.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(_lobby_heroes)
	for t in GameData.rule("party_templates", ["knight", "wizard"]):
		var card := HeroCard.new()
		card.template = str(t)
		card.compact = true
		card.custom_minimum_size = Vector2(240, 200)
		card.pressed.connect(_lobby_pick.bind(str(t)))
		_lobby_heroes.add_child(card)
	var buttons := UiTheme.hbox(10)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(buttons)
	buttons.add_child(UiTheme.button("Выйти из лобби", _leave_lobby, 18))
	_start_btn = UiTheme.button("Начать игру", _request_start, 20)
	_start_btn.custom_minimum_size = Vector2(200, 0)
	buttons.add_child(_start_btn)


func _edit(text: String, width: float) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size = Vector2(width, 36)
	e.add_theme_font_override("font", UiTheme.font("body"))
	e.add_theme_font_size_override("font_size", 18)
	return e


# --- Переходы между окнами ------------------------------------------------------------------

func _show_only(panel: Control) -> void:
	_main.visible = panel == _main
	_new_panel.visible = panel == _new_panel
	_net_panel.visible = panel == _net_panel
	_lobby_panel.visible = panel == _lobby_panel
	_settings.visible = panel == _settings


func _open_new() -> void:
	_show_only(_new_panel)


func _open_net() -> void:
	_net_status.text = ""
	_show_only(_net_panel)


func _open_settings() -> void:
	_show_only(_settings)


func _back() -> void:
	_show_only(_main)


func _quit() -> void:
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_ESCAPE and not _main.visible and not _lobby_panel.visible:
		_back()
	elif key.keycode == KEY_F11:
		GameSettings.set_value("fullscreen", not bool(GameSettings.get_value("fullscreen")))


# --- Одиночная игра -------------------------------------------------------------------------

func _toggle_pick(t: String) -> void:
	if _picks.has(t):
		_picks.erase(t)
	else:
		_picks.append(t)
		while _picks.size() > SOLO_PICKS:
			_picks.pop_front()
	_update_picks()


func _update_picks() -> void:
	for t in _cards:
		(_cards[t] as HeroCard).selected = _picks.has(t)
		(_cards[t] as HeroCard).queue_redraw()
	if _go_btn != null:
		_go_btn.disabled = _picks.size() != SOLO_PICKS


func _start_solo() -> void:
	_apply_name()
	Net.hero_choice = _picks.duplicate()
	Net.start_offline()


func _continue() -> void:
	_apply_name()
	Net.hero_choice = []
	Net.start_offline(true)


func _apply_name() -> void:
	var n := _name_edit.text.strip_edges() if _name_edit != null else ""
	if n == "":
		n = str(GameSettings.get_value("player_name"))
	if n == "":
		n = "Игрок"
	Net.my_name = n.substr(0, 20)
	GameSettings.set_value("player_name", Net.my_name)


# --- Сеть ------------------------------------------------------------------------------------

func _host() -> void:
	_apply_name()
	Net.hero_choice = [_first_free_hero()]
	var err := Net.host(int(_port_edit.text))
	if err != "":
		_net_status.text = err
		return
	Net.choose_hero(str(Net.hero_choice[0]))
	_refresh_lobby()


func _join() -> void:
	_apply_name()
	var url := _url_edit.text.strip_edges()
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "ws://" + url
	if url.count(":") < 2:
		url += ":%d" % Net.DEFAULT_PORT
	GameSettings.set_value("server_url", url)
	Net.hero_choice = []
	var err := Net.join(url)
	_net_status.text = err if err != "" else "Подключаемся к %s…" % url


func _lobby_pick(t: String) -> void:
	if _taken_by_other(t):
		return
	Net.choose_hero(t)
	_refresh_lobby()


func _request_start() -> void:
	Net.request_start()


func _leave_lobby() -> void:
	Net.leave()


func _first_free_hero() -> String:
	var templates: Array = GameData.rule("party_templates", ["knight"])
	for t in templates:
		if not _taken_by_other(str(t)):
			return str(t)
	return str(templates[0])


func _taken_by_other(t: String) -> bool:
	for pid in Net.lobby:
		if int(pid) == Net.my_id():
			continue
		if (Net.lobby[pid].get("heroes", []) as Array).has(t):
			return true
	return false


func _refresh_lobby() -> void:
	if not Net.in_lobby():
		if _lobby_panel.visible:
			_show_only(_net_panel)
		return
	if Net.lobby.is_empty():
		return   # клиент ждёт ответа сервера
	_show_only(_lobby_panel)
	for c in _lobby_list.get_children():
		c.queue_free()
	var ids := Net.lobby.keys()
	ids.sort()
	var names: Dictionary = {}
	for t in GameData.rule("party_templates", []):
		names[str(t)] = str(GameData.character(str(t)).get("name", t))
	for pid in ids:
		var info: Dictionary = Net.lobby[pid]
		var heroes: Array = info.get("heroes", [])
		var hero := str(names.get(str(heroes[0]), heroes[0])) if not heroes.is_empty() else "выбирает героя"
		var line := "• %s — %s" % [str(info.get("name", "Игрок")), hero]
		if int(pid) == Net.leader_id():
			line += "  (ведущий)"
		if int(pid) == Net.my_id():
			line += "  — вы"
		_lobby_list.add_child(UiTheme.label(line, 18, UiTheme.TEXT if int(pid) == Net.my_id() else UiTheme.TEXT_DIM))
	var mine: Array = Net.hero_choice
	for c in _lobby_heroes.get_children():
		var card := c as HeroCard
		card.selected = mine.has(card.template)
		card.taken = _taken_by_other(card.template)
		card.queue_redraw()
	var hint := "Игроков: %d из %d. " % [Net.lobby.size(), GameSession.max_players()]
	if Net.mode == Net.Mode.HOST:
		var port := _port_edit.text if _port_edit != null else str(Net.DEFAULT_PORT)
		var ips := _local_ips()
		hint += "Друзья подключаются по адресу ws://%s:%s (в одной сети) или по внешнему IP, если открыт порт." % [
			ips[0] if not ips.is_empty() else "<ваш IP>", port]
	if Net.is_leader():
		hint += " Когда все выберут героев, нажмите «Начать игру». Если игрок один, второго героя дадут автоматически."
	else:
		hint += " Игру начнёт ведущий."
	_lobby_hint.text = hint
	_start_btn.visible = Net.is_leader()


func _local_ips() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		var s := str(a)
		if s.count(".") == 3 and not s.begins_with("127.") and not s.begins_with("169.254."):
			out.append(s)
	out.sort_custom(func(x, y): return str(x).begins_with("192.168.") and not str(y).begins_with("192.168."))
	return out


func _on_game_started() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_disconnected(reason: String) -> void:
	if _net_panel.visible or _lobby_panel.visible:
		_show_only(_net_panel)
		_net_status.text = reason
	elif reason != "Вы вышли из игры.":
		_status.text = reason


func _on_notice(text: String) -> void:
	if _net_status != null:
		_net_status.text = text


# --- Картинки -------------------------------------------------------------------------------

## Фон: пиксельный пейзаж с туманом и воронами.
class TitleArt extends Control:
	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("070914"))
		SceneArt.draw(self, "title", Rect2(Vector2.ZERO, size), float(Time.get_ticks_msec()) / 1000.0)
		# затемнение снизу, чтобы читались кнопки
		for i in 12:
			var y := size.y * (0.55 + 0.0375 * i)
			draw_rect(Rect2(0, y, size.x, size.y * 0.0375 + 1.0), Color(0, 0, 0, 0.04 * i))


## Карточка героя: портрет, имя, роль. Клик — выбрать.
class HeroCard extends Control:
	signal pressed

	var template := ""
	var selected := false
	var taken := false
	var compact := false
	var _hover := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		mouse_entered.connect(_on_enter)
		mouse_exited.connect(_on_exit)

	func _on_enter() -> void:
		_hover = true
		if not taken:
			GameAudio.ui("ui_hover")
		queue_redraw()

	func _on_exit() -> void:
		_hover = false
		queue_redraw()

	func _process(_delta: float) -> void:
		if selected or _hover:
			queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			if taken:
				GameAudio.ui("ui_error")
				return
			GameAudio.ui("ui_confirm")
			pressed.emit()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var border := UiTheme.GOLD if selected else (UiTheme.GOLD_DIM if _hover and not taken else Color("4a3a28"))
		draw_style_box(UiTheme.slot_box(border, Color("120e0b") if not selected else Color("1e1710")), r)
		var t := float(Time.get_ticks_msec()) / 1000.0
		var side := 96.0 if compact else 132.0
		var pr := Rect2((size.x - side) * 0.5, 14, side, side)
		IconArt.portrait(self, template, pr, t, taken)
		var f := UiTheme.font("bold")
		var def := GameData.character(template)
		var name := str(def.get("name", template))
		var y := pr.end.y + 28
		draw_string(f, Vector2(0, y), name, HORIZONTAL_ALIGNMENT_CENTER, size.x, 20,
			UiTheme.GOLD if selected else (UiTheme.TEXT_FAINT if taken else UiTheme.TEXT))
		if taken:
			draw_string(UiTheme.font("body"), Vector2(0, y + 24), "занят другим игроком", HORIZONTAL_ALIGNMENT_CENTER, size.x, 15, UiTheme.TEXT_FAINT)
			return
		var info := str((GameData.rule("hero_info", {}) as Dictionary).get(template, ""))
		if info != "" and not compact:
			draw_multiline_string(UiTheme.font("body"), Vector2(14, y + 24), info, HORIZONTAL_ALIGNMENT_CENTER,
				size.x - 28, 15, 5, UiTheme.TEXT_DIM)
		if selected:
			var a := 0.5 + 0.5 * sin(t * 4.0)
			draw_rect(r.grow(-3), Color(UiTheme.GOLD, 0.25 + 0.2 * a), false, 2.0)

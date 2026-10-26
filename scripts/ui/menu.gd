extends Control
## Главное меню и лобби (временный интерфейс, собирается из кода).
## Запуск выделенного сервера без графики:
##   godot --headless --path . -- --server --port 8910

const BATTLE_SCENE := "res://scenes/battle.tscn"

var _name_edit: LineEdit
var _port_edit: LineEdit
var _url_edit: LineEdit
var _status: Label
var _players: Label
var _start_btn: Button
var _leave_btn: Button
var _menu_box: VBoxContainer


func _ready() -> void:
	if _is_dedicated_launch():
		_start_dedicated()
		return
	_build_ui()
	Net.lobby_changed.connect(_refresh)
	Net.game_started.connect(_on_game_started)
	Net.disconnected.connect(_on_disconnected)
	_refresh()


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


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = "Пошаговая RPG — прототип"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_name_edit = _labeled_edit(box, "Имя:", "Игрок")

	_menu_box = VBoxContainer.new()
	_menu_box.add_theme_constant_override("separation", 8)
	box.add_child(_menu_box)

	var solo := Button.new()
	solo.text = "Одиночная игра"
	solo.pressed.connect(_on_solo)
	_menu_box.add_child(solo)

	# Браузер не может принимать подключения, поэтому в веб-версии хоста нет.
	if not OS.has_feature("web"):
		var host_row := HBoxContainer.new()
		_menu_box.add_child(host_row)
		_port_edit = LineEdit.new()
		_port_edit.text = str(Net.DEFAULT_PORT)
		_port_edit.custom_minimum_size = Vector2(90, 0)
		host_row.add_child(_port_edit)
		var host_btn := Button.new()
		host_btn.text = "Создать игру (хост)"
		host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host_btn.pressed.connect(_on_host)
		host_row.add_child(host_btn)

	var join_row := HBoxContainer.new()
	_menu_box.add_child(join_row)
	_url_edit = LineEdit.new()
	_url_edit.text = "ws://127.0.0.1:%d" % Net.DEFAULT_PORT
	_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_row.add_child(_url_edit)
	var join_btn := Button.new()
	join_btn.text = "Подключиться"
	join_btn.pressed.connect(_on_join)
	join_row.add_child(join_btn)

	_players = Label.new()
	box.add_child(_players)

	_start_btn = Button.new()
	_start_btn.text = "Начать бой"
	_start_btn.pressed.connect(func() -> void: Net.request_start())
	box.add_child(_start_btn)

	_leave_btn = Button.new()
	_leave_btn.text = "Выйти из лобби"
	_leave_btn.pressed.connect(func() -> void: Net.leave())
	box.add_child(_leave_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status.modulate = Color(1, 0.85, 0.5)
	box.add_child(_status)


func _labeled_edit(parent: Control, caption: String, value: String) -> LineEdit:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = caption
	row.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(e)
	return e


func _apply_name() -> void:
	var n := _name_edit.text.strip_edges()
	Net.my_name = n if n != "" else "Игрок"


func _on_solo() -> void:
	_apply_name()
	Net.start_offline()


func _on_host() -> void:
	_apply_name()
	var err := Net.host(int(_port_edit.text))
	_status.text = err if err != "" else "Сервер запущен. Друзья подключаются по адресу ws://<ваш IP>:%s" % _port_edit.text
	_refresh()


func _on_join() -> void:
	_apply_name()
	var err := Net.join(_url_edit.text.strip_edges())
	_status.text = err if err != "" else "Подключение..."
	_refresh()


func _refresh() -> void:
	if _players == null:
		return
	var in_lobby := Net.in_lobby()
	_menu_box.visible = not in_lobby
	_name_edit.editable = not in_lobby
	_leave_btn.visible = in_lobby
	_start_btn.visible = in_lobby and Net.is_leader() and not Net.lobby.is_empty()
	if not in_lobby:
		_players.text = ""
		return
	var lines: Array = ["Игроки (%d/%d):" % [Net.lobby.size(), GameSession.max_players()]]
	var ids := Net.lobby.keys()
	ids.sort()
	for pid in ids:
		var mark: String = " (лидер)" if int(pid) == Net.leader_id() else ""
		var me: String = " — вы" if int(pid) == Net.my_id() else ""
		lines.append("  • %s%s%s" % [Net.lobby[pid]["name"], mark, me])
	if not Net.is_leader():
		lines.append("Ждём, пока лидер начнёт бой.")
	_players.text = "\n".join(lines)


func _on_game_started() -> void:
	get_tree().change_scene_to_file(BATTLE_SCENE)


func _on_disconnected(reason: String) -> void:
	_status.text = reason
	_refresh()

class_name Journal
extends PanelContainer
## Журнал заданий: слева список (сначала текущие, ниже выполненные), справа страница на пергаменте —
## что уже было и что делать дальше. Сумка отряда теперь в окне героя (I или C).

var screen: Node
var tab := "quests"
var _key := ""
var _sel_quest := ""
var _list: VBoxContainer
var _detail: VBoxContainer


func _ready() -> void:
	theme = UiTheme.theme()
	custom_minimum_size = Vector2(980, 580)
	UiTheme.center(self, custom_minimum_size)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var root := UiTheme.vbox(8)
	add_child(root)
	var top := UiTheme.hbox(8)
	root.add_child(top)
	var title := UiTheme.label("Журнал заданий", 24, UiTheme.GOLD, "title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	top.add_child(UiTheme.label("J — закрыть", 14, UiTheme.TEXT_FAINT))
	top.add_child(UiTheme.button("Закрыть", func() -> void: screen.call("open_panel", ""), 16))
	var body := UiTheme.hbox(12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(320, 480)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(sc)
	_list = UiTheme.vbox(6)
	_list.custom_minimum_size = Vector2(306, 0)
	sc.add_child(_list)
	var page := PanelContainer.new()
	page.add_theme_stylebox_override("panel", UiTheme.parchment(14))
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(page)
	var dsc := ScrollContainer.new()
	dsc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(dsc)
	_detail = UiTheme.vbox(10)
	_detail.custom_minimum_size = Vector2(580, 0)
	dsc.add_child(_detail)


func open(_which: String = "quests") -> void:
	tab = "quests"
	_key = ""
	visible = true


func _process(_delta: float) -> void:
	if not visible:
		return
	var s: GameSession = Net.session
	if s == null:
		return
	var key := str(s.quests) + str(s.quest_order) + _sel_quest
	if key == _key:
		return
	_key = key
	for c in _list.get_children():
		c.queue_free()
	for c in _detail.get_children():
		c.queue_free()
	_quests(s)


func _quests(s: GameSession) -> void:
	if s.quest_order.is_empty():
		_list.add_child(UiTheme.label("Заданий пока нет", 16, UiTheme.TEXT_FAINT))
		_detail.add_child(_ink("Здесь будут записаны поручения и всё, что о них известно.", 17, UiTheme.INK_DIM))
		return
	var order: Array = s.quest_order.duplicate()
	order.reverse()
	var active: Array = []
	var done: Array = []
	for q in order:
		var qid := str(q)
		if Story.is_done_stage(qid, str(s.quests.get(qid, ""))):
			done.append(qid)
		else:
			active.append(qid)
	if _sel_quest == "" or not s.quests.has(_sel_quest):
		_sel_quest = str(active[0]) if not active.is_empty() else str(done[0])
	_section("Текущие", active, false)
	_section("Выполненные", done, true)
	var qd := GameData.quest(_sel_quest)
	var cur := str(s.quests.get(_sel_quest, ""))
	_detail.add_child(_ink(str(qd.get("name", _sel_quest)), 26, Color("4a2a10"), "title"))
	if qd.has("description"):
		_detail.add_child(_ink(str(qd["description"]), 16, UiTheme.INK_DIM))
	_detail.add_child(HSeparator.new())
	for st in Story.stages(_sel_quest):
		var sd: Dictionary = st
		var sid := str(sd.get("id", ""))
		var is_cur := sid == cur
		var text := str(sd.get("journal", ""))
		if text != "":
			_detail.add_child(_ink(("» " if is_cur else "✓ ") + text, 17, UiTheme.INK_TEXT if is_cur else Color(0.42, 0.33, 0.22, 0.8)))
		if is_cur:
			if str(sd.get("objective", "")) != "" and not Story.is_done_stage(_sel_quest, sid):
				var goal := _ink("Цель: " + str(sd["objective"]), 18, Color("8a3a10"), "bold")
				_detail.add_child(goal)
			break


func _section(title: String, ids: Array, finished: bool) -> void:
	if ids.is_empty():
		return
	_list.add_child(UiTheme.label(title, 16, UiTheme.TEXT_FAINT, "bold"))
	for q in ids:
		var qid := str(q)
		var name := str(GameData.quest(qid).get("name", qid)) + ("  ✓" if finished else "")
		var b := UiTheme.button(name, _pick_quest.bind(qid), 17)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = qid == _sel_quest
		if finished:
			b.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		_list.add_child(b)


func _pick_quest(qid: String) -> void:
	_sel_quest = qid
	_key = ""


## Текст чернилами по пергаменту, с переносом строк.
func _ink(text: String, size: int, color: Color, kind := "body") -> Label:
	var l := UiTheme.label(text, size, color, kind)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(560, 0)
	return l

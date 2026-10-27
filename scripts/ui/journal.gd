class_name Journal
extends PanelContainer
## Журнал: задания (что уже было и что делать дальше) и общая сумка отряда (использовать, надеть).

var screen: Node
var tab := "quests"
var _key := ""
var _sel_quest := ""
var _sel_item := ""
var _list: VBoxContainer
var _detail: VBoxContainer
var _tab_buttons: Dictionary = {}
var _title: Label


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
	_title = UiTheme.label("Журнал", 22, UiTheme.GOLD, "bold")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)
	for t in [["quests", "Задания (J)"], ["bag", "Сумка (I)"]]:
		var b := UiTheme.button(str(t[1]), func() -> void: open(str(t[0])), 16)
		_tab_buttons[str(t[0])] = b
		top.add_child(b)
	top.add_child(UiTheme.button("Закрыть", func() -> void: screen.call("open_panel", ""), 16))
	root.add_child(HSeparator.new())
	var body := UiTheme.hbox(16)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(330, 470)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(sc)
	_list = UiTheme.vbox(4)
	_list.custom_minimum_size = Vector2(316, 0)
	sc.add_child(_list)
	var dsc := ScrollContainer.new()
	dsc.custom_minimum_size = Vector2(600, 470)
	dsc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dsc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(dsc)
	_detail = UiTheme.vbox(8)
	_detail.custom_minimum_size = Vector2(590, 0)
	dsc.add_child(_detail)


func open(which: String) -> void:
	tab = which
	_key = ""
	visible = true


func _process(_delta: float) -> void:
	if not visible:
		return
	var s: GameSession = Net.session
	if s == null:
		return
	var key := tab + str(s.quests) + str(s.items) + str(s.gold) + _sel_quest + _sel_item + s.mode
	for h in s.heroes:
		key += str((h as Character).equipment)
	if key == _key:
		return
	_key = key
	_title.text = "Журнал заданий" if tab == "quests" else "Сумка отряда"
	for t in _tab_buttons:
		(_tab_buttons[t] as Button).disabled = t == tab
	for c in _list.get_children():
		c.queue_free()
	for c in _detail.get_children():
		c.queue_free()
	if tab == "quests":
		_quests(s)
	else:
		_bag(s)


func _quests(s: GameSession) -> void:
	if s.quest_order.is_empty():
		_list.add_child(UiTheme.label("Заданий пока нет", 16, UiTheme.TEXT_FAINT))
		return
	var order: Array = s.quest_order.duplicate()
	order.reverse()
	if _sel_quest == "" or not s.quests.has(_sel_quest):
		_sel_quest = str(order[0])
	for q in order:
		var qid := str(q)
		var stage := str(s.quests.get(qid, ""))
		var done := Story.is_done_stage(qid, stage)
		var name := str(GameData.quest(qid).get("name", qid)) + ("  ✓" if done else "")
		var b := UiTheme.button(name, _pick_quest.bind(qid), 17)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = qid == _sel_quest
		_list.add_child(b)
	var qd := GameData.quest(_sel_quest)
	var cur := str(s.quests.get(_sel_quest, ""))
	_detail.add_child(UiTheme.label(str(qd.get("name", _sel_quest)), 22, Color("f0dcae"), "bold"))
	if qd.has("description"):
		_detail.add_child(_wrap(str(qd["description"]), 16, UiTheme.TEXT_DIM))
	var stages := Story.stages(_sel_quest)
	for st in stages:
		var sd: Dictionary = st
		var sid := str(sd.get("id", ""))
		var is_cur := sid == cur
		var text := str(sd.get("journal", ""))
		if text != "":
			_detail.add_child(_wrap(("» " if is_cur else "✓ ") + text, 17, UiTheme.TEXT if is_cur else UiTheme.TEXT_FAINT))
		if is_cur:
			if str(sd.get("objective", "")) != "" and not Story.is_done_stage(_sel_quest, sid):
				_detail.add_child(_wrap("Цель: " + str(sd["objective"]), 17, UiTheme.GOLD))
			break


func _bag(s: GameSession) -> void:
	_list.add_child(UiTheme.label("Золото: %d" % s.gold, 17, Color("f0c860")))
	if s.items.is_empty():
		_list.add_child(UiTheme.label("Сумка пуста", 16, UiTheme.TEXT_FAINT))
	var keys: Array = s.items.keys()
	keys.sort()
	if _sel_item == "" or not s.items.has(_sel_item):
		_sel_item = str(keys[0]) if not keys.is_empty() else ""
	for it in keys:
		var id := str(it)
		var row := UiTheme.hbox(6)
		var icon := ItemIcon.new()
		icon.item = id
		icon.custom_minimum_size = Vector2(32, 32)
		row.add_child(icon)
		var b := UiTheme.button("%s ×%d" % [GameData.item(id).get("name", id), int(s.items[it])], _pick_item.bind(id), 16)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = id == _sel_item
		row.add_child(b)
		_list.add_child(row)
	if _sel_item == "":
		return
	var def := GameData.item(_sel_item)
	var head := UiTheme.hbox(10)
	var big := ItemIcon.new()
	big.item = _sel_item
	big.custom_minimum_size = Vector2(56, 56)
	head.add_child(big)
	head.add_child(UiTheme.label(str(def.get("name", _sel_item)), 22, Color("f0dcae"), "bold"))
	_detail.add_child(head)
	if def.has("description"):
		_detail.add_child(_wrap(str(def["description"]), 17, UiTheme.TEXT_DIM))
	var stats: Dictionary = def.get("stats", {})
	for k in stats:
		_detail.add_child(UiTheme.label("%s %+d" % [str(k), int(stats[k])], 16, UiTheme.GREEN))
	var use: Dictionary = def.get("use", def.get("effect", {}))
	var hero_uid := str(screen.get("selected_uid"))
	var hero := s.unit_by_uid(hero_uid)
	if not use.is_empty():
		if use.has("skill"):
			_detail.add_child(_wrap("Пригодится в бою: выберите на панели внизу и укажите клетку.", 16, UiTheme.TEXT_FAINT))
		else:
			var who := hero.display_name if hero != null else "герой"
			var b := UiTheme.button("Использовать (%s)" % who, _send.bind({"type": "use_item", "unit": hero_uid, "item": _sel_item}), 17)
			b.disabled = hero == null or s.mode == "dialogue" or s.owner_of(hero) != Net.my_id()
			_detail.add_child(b)
	if GameSession.is_equippable(_sel_item):
		var row := UiTheme.hbox(6)
		row.add_child(UiTheme.label("Надеть:", 17, UiTheme.TEXT))
		for h in s.heroes_of(Net.my_id()):
			var hh: Character = h
			var b := UiTheme.button(hh.display_name, _send.bind({"type": "equip", "unit": hh.uid, "item": _sel_item}), 16)
			b.disabled = s.mode == "combat"
			row.add_child(b)
		_detail.add_child(row)


func _pick_quest(qid: String) -> void:
	_sel_quest = qid
	_key = ""


func _pick_item(id: String) -> void:
	_sel_item = id
	_key = ""


func _send(cmd: Dictionary) -> void:
	screen.call("send", cmd)
	_key = ""


func _wrap(text: String, size: int, color: Color) -> Label:
	var l := UiTheme.label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(580, 0)
	return l


class ItemIcon extends Control:
	var item := ""

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_style_box(UiTheme.slot_box(), r)
		IconArt.item_icon(self, item, r.grow(-4))

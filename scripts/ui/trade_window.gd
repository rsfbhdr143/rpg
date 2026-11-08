extends PanelContainer
## Торговля: слева товар торговца с ценой, справа сумка отряда с ценой продажи. Щелчок — купить или продать
## одну штуку (команды trade_buy / trade_sell). Цены — GameSession.price(), товар — GameSession.trader_stock().

const ItemGrid := preload("res://scripts/ui/item_grid.gd")
const Describe := preload("res://scripts/ui/describe.gd")

var screen: Node
var npc := ""
var unit := ""
var _title: Label
var _sub: Label
var _gold: Label
var _goods: ItemGrid
var _bag: ItemGrid
var _key := ""


func _ready() -> void:
	theme = UiTheme.theme()
	custom_minimum_size = Vector2(820, 560)
	UiTheme.center(self, custom_minimum_size)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var root := UiTheme.vbox(8)
	add_child(root)
	var top := UiTheme.hbox(10)
	root.add_child(top)
	var tv := UiTheme.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(tv)
	_title = UiTheme.label("Торговля", 24, UiTheme.GOLD, "title")
	tv.add_child(_title)
	_sub = UiTheme.label("", 15, UiTheme.TEXT_DIM)
	tv.add_child(_sub)
	_gold = UiTheme.label("", 20, Color("f0c860"), "bold")
	top.add_child(_gold)
	top.add_child(UiTheme.button("Готово", close, 18))
	var body := UiTheme.hbox(12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	_goods = _column(body, "Товар", "ЛКМ — купить")
	_goods.on_click = _buy
	_goods.on_double = _buy
	_goods.tip_fn = func(id: String) -> String:
		return Describe.item_text(id, "[color=#f0c860]Купить за %d з.[/color]" % GameSession.price(npc, id, false))
	_bag = _column(body, "Сумка отряда", "ЛКМ — продать")
	_bag.on_click = _sell
	_bag.on_double = _sell
	_bag.tip_fn = func(id: String) -> String:
		if not GameSession.can_sell(id):
			return Describe.item_text(id, "[color=#a89a80]Не продаётся[/color]")
		return Describe.item_text(id, "[color=#f0c860]Продать за %d з.[/color]" % GameSession.price(npc, id, true))
	var hint := UiTheme.label("Надетое сначала снимите в окне героя (C). Квестовые вещи не продаются.", 14, UiTheme.TEXT_FAINT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(hint)


func _column(parent: Control, title: String, hint: String) -> ItemGrid:
	var page := PanelContainer.new()
	page.add_theme_stylebox_override("panel", UiTheme.parchment(8))
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(page)
	var v := UiTheme.vbox(6)
	page.add_child(v)
	var head := UiTheme.hbox(6)
	v.add_child(head)
	var t := UiTheme.label(title, 20, UiTheme.INK_TEXT, "bold")
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var h := UiTheme.label(hint, 14, UiTheme.INK_DIM)
	h.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	head.add_child(h)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 380)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	var g := ItemGrid.new()
	g.cols = 7
	g.cell = 48.0
	g.min_rows = 7
	sc.add_child(g)
	return g


func open(npc_id: String, hero_uid: String) -> void:
	npc = npc_id
	unit = hero_uid
	_goods.screen = screen
	_bag.screen = screen
	_key = ""
	visible = true
	GameAudio.ui("ui_open")


func close() -> void:
	visible = false
	if screen != null:
		screen.set("ui_tip", "")


func _buy(id: String) -> void:
	screen.call("send", {"type": "trade_buy", "unit": unit, "npc": npc, "item": id})


func _sell(id: String) -> void:
	screen.call("send", {"type": "trade_sell", "unit": unit, "npc": npc, "item": id})


func _process(_delta: float) -> void:
	if not visible:
		return
	var s: GameSession = Net.session
	if s == null or s.mode != "explore" or not s.npcs.any(func(n): return (n as Character).template_id == npc):
		close()
		return
	var stock := s.trader_stock(npc)
	var key := str(stock) + str(s.items) + str(s.gold)
	if key == _key:
		return
	_key = key
	var nd := GameData.npc(npc)
	_title.text = "Торговля: %s" % str(nd.get("name", npc))
	_sub.text = str(nd.get("title", ""))
	_gold.text = "%d з." % s.gold
	var goods: Array = []
	var ids: Array = stock.keys()
	ids.sort_custom(func(a, b): return int(GameData.item(str(a)).get("value", 0)) < int(GameData.item(str(b)).get("value", 0)))
	for id in ids:
		var n := int(stock[id])
		var cost := GameSession.price(npc, str(id), false)
		goods.append({"id": str(id), "count": n if n > 0 else 1, "price": cost, "dim": cost > s.gold})
	_goods.set_entries(goods)
	var mine: Array = []
	var bag_ids: Array = s.items.keys()
	bag_ids.sort()
	for id in bag_ids:
		var ok := GameSession.can_sell(str(id))
		mine.append({"id": str(id), "count": int(s.items[id]), "price": GameSession.price(npc, str(id), true) if ok else -1, "dim": not ok})
	_bag.set_entries(mine)

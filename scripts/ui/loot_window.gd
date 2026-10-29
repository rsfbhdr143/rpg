extends PanelContainer
## Окно добычи: что лежит на теле. Щелчок по предмету — взять его, «Взять всё» — забрать всё (команды loot_take).
## Закрывается само, когда мешок опустел или партия ушла.

const ItemGrid := preload("res://scripts/ui/item_grid.gd")
const Describe := preload("res://scripts/ui/describe.gd")

var screen: Node
var corpse := ""
var unit := ""
var _title: Label
var _grid: ItemGrid
var _key := ""


func _ready() -> void:
	theme = UiTheme.theme()
	custom_minimum_size = Vector2(380, 0)
	UiTheme.place(self, Control.PRESET_CENTER, Vector2(-190, -180), Vector2(380, 0))
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var root := UiTheme.vbox(10)
	add_child(root)
	_title = UiTheme.label("Добыча", 22, UiTheme.GOLD, "title")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_title)
	var page := PanelContainer.new()
	page.add_theme_stylebox_override("panel", UiTheme.parchment(6))
	root.add_child(page)
	_grid = ItemGrid.new()
	_grid.cols = 6
	_grid.min_rows = 2
	_grid.on_click = _take
	_grid.on_double = _take
	_grid.tip_fn = func(id: String) -> String:
		return "[b][color=#f0c860]Золото[/color][/b]" if id == "gold" else Describe.item_text(id) + "\n[color=#c8a060]ЛКМ — взять[/color]"
	page.add_child(_grid)
	var row := UiTheme.hbox(10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(row)
	row.add_child(UiTheme.button("Взять всё", func() -> void: _take("all"), 18))
	row.add_child(UiTheme.button("Закрыть", close, 18))


func open(corpse_uid: String, hero_uid: String) -> void:
	corpse = corpse_uid
	unit = hero_uid
	_grid.screen = screen
	_key = ""
	visible = true
	GameAudio.ui("ui_open")


func close() -> void:
	visible = false
	if screen != null:
		screen.set("ui_tip", "")


func _take(what: String) -> void:
	screen.call("send", {"type": "loot_take", "unit": unit, "corpse": corpse, "item": what})


func _process(_delta: float) -> void:
	if not visible:
		return
	var s: GameSession = Net.session
	if s == null or s.mode != "explore" or not s.loot.has(corpse):
		close()
		return
	var bag: Dictionary = s.loot[corpse]
	var key := str(bag)
	if key == _key:
		return
	_key = key
	_title.text = "Тело: %s" % str(bag.get("name", ""))
	var list: Array = []
	if int(bag.get("gold", 0)) > 0:
		list.append({"id": "gold", "count": int(bag["gold"])})
	var its: Dictionary = bag.get("items", {})
	for id in its:
		list.append({"id": str(id), "count": int(its[id])})
	_grid.set_entries(list)

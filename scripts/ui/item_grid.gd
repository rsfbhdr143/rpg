extends Control
## Сетка предметов: сумка в окне героя, товар торговца, добыча с тела. Ячейки со значками и числом,
## под значком может стоять цена. Наведение — подсказка у курсора (screen.ui_tip), щелчок — on_click(id),
## двойной щелчок или ПКМ — on_double(id). drag_fn(id) отдаёт данные для перетаскивания (или null).

var screen: Node
var entries: Array = []        # [{"id", "count", "price" (-1 — без цены), "dim"}]
var cols := 6
var cell := 50.0
var gap := 4.0
var min_rows := 4
var selected := ""
var on_click: Callable
var on_double: Callable
var tip_fn: Callable           # id -> String (BBCode)
var drag_fn: Callable          # id -> Variant
var empty_text := ""
var _hover := -1
var _tip := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_entries(list: Array) -> void:
	entries = list
	var rows := maxi(min_rows, ceili(float(entries.size()) / float(cols)))
	custom_minimum_size = Vector2(cols * (cell + gap) - gap, rows * (cell + gap) - gap)
	if _hover >= entries.size():
		_hover = -1
	queue_redraw()


func _cell_rect(i: int) -> Rect2:
	@warning_ignore("integer_division")
	var row := i / cols
	return Rect2((i % cols) * (cell + gap), row * (cell + gap), cell, cell)


func _index_at(p: Vector2) -> int:
	for i in entries.size():
		if _cell_rect(i).has_point(p):
			return i
	return -1


func _set_tip(text: String) -> void:
	if screen == null:
		return
	if text == "" and str(screen.get("ui_tip")) != _tip:
		return   # подсказку уже поставил кто-то другой
	_tip = text
	screen.set("ui_tip", text)


func _gui_input(event: InputEvent) -> void:
	var mm := event as InputEventMouseMotion
	if mm != null:
		var i := _index_at(mm.position)
		if i != _hover:
			_hover = i
			queue_redraw()
		var id := str(entries[i]["id"]) if i >= 0 else ""
		_set_tip(tip_fn.call(id) if i >= 0 and tip_fn.is_valid() else "")
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var i := _index_at(mb.position)
	if i < 0:
		return
	var id := str(entries[i]["id"])
	if mb.button_index == MOUSE_BUTTON_LEFT:
		selected = id
		if mb.double_click and on_double.is_valid():
			on_double.call(id)
		elif on_click.is_valid():
			on_click.call(id)
		queue_redraw()
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT and on_double.is_valid():
		on_double.call(id)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = -1
		_set_tip("")
		queue_redraw()


func _get_drag_data(at_position: Vector2) -> Variant:
	var i := _index_at(at_position)
	if i < 0 or not drag_fn.is_valid():
		return null
	var id := str(entries[i]["id"])
	var data: Variant = drag_fn.call(id)
	if data != null:
		var pv := DragPreview.new()
		pv.item = id
		set_drag_preview(pv)
	return data


func _draw() -> void:
	var font := UiTheme.font("bold")
	var body := UiTheme.font("body")
	var rows := maxi(min_rows, ceili(float(entries.size()) / float(cols)))
	for i in rows * cols:
		var r := _cell_rect(i)
		if i >= entries.size():
			draw_style_box(UiTheme.slot_box(Color("6b5236"), Color("2a2018")), r)
			continue
		var e: Dictionary = entries[i]
		var id := str(e["id"])
		var border := Color("8a6a3a")
		if i == _hover:
			border = UiTheme.GOLD
		if id == selected:
			border = Color("fff0a0")
		draw_style_box(UiTheme.slot_box(border, Color("1a1410")), r)
		var dim := bool(e.get("dim", false))
		if id == "gold":
			IconArt.item_icon(self, "gold", r.grow(-7), dim)
		else:
			IconArt.item_icon(self, id, r.grow(-7), dim)
		var n := int(e.get("count", 1))
		if n > 1 or id == "gold":
			_text(font, Vector2(r.end.x - 4, r.end.y - 4), str(n), HORIZONTAL_ALIGNMENT_RIGHT, 14, UiTheme.TEXT)
		var price := int(e.get("price", -1))
		if price >= 0:
			_text(body, Vector2(r.position.x + 4, r.position.y + 14), "%d" % price, HORIZONTAL_ALIGNMENT_LEFT, 13,
				Color("f0c860") if not dim else UiTheme.TEXT_FAINT)
	if entries.is_empty() and empty_text != "":
		draw_string(body, Vector2(0, cell * 0.5 + 6), empty_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 16, UiTheme.INK_DIM)


## Надпись с тёмной обводкой: читается и на светлом значке.
func _text(f: Font, p: Vector2, t: String, align: HorizontalAlignment, sz: int, col: Color) -> void:
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var x := p.x - w if align == HORIZONTAL_ALIGNMENT_RIGHT else p.x
	draw_string_outline(f, Vector2(x, p.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, 4, Color(0, 0, 0, 0.85))
	draw_string(f, Vector2(x, p.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)


class DragPreview extends Control:
	var item := ""

	func _draw() -> void:
		var r := Rect2(Vector2(-24, -24), Vector2(48, 48))
		draw_style_box(UiTheme.slot_box(UiTheme.GOLD), r)
		IconArt.item_icon(self, item, r.grow(-6))

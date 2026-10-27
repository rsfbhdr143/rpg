class_name CharSheet
extends PanelContainer
## Лист героя: атрибуты, способности, навыки, таланты и снаряжение. Кнопки «+» тратят очки
## (команды raise_attribute, raise_ability, learn_skill, learn_talent), «Надеть» / «Снять» — вещи.
## Чужих героев можно смотреть, но не менять. В бою прокачка закрыта, как в D:OS.

var screen: Node
var uid := ""
var _key := ""
var _tabs: HBoxContainer
var _body: HBoxContainer
var _head: HBoxContainer


func _ready() -> void:
	theme = UiTheme.theme()
	custom_minimum_size = Vector2(1080, 650)
	UiTheme.center(self, custom_minimum_size)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var root := UiTheme.vbox(8)
	add_child(root)
	var top := UiTheme.hbox(8)
	root.add_child(top)
	var title := UiTheme.label("Герой", 22, UiTheme.GOLD, "bold")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_tabs = UiTheme.hbox(4)
	top.add_child(_tabs)
	top.add_child(UiTheme.button("Закрыть (C)", func() -> void: screen.call("open_panel", ""), 16))
	_head = UiTheme.hbox(14)
	root.add_child(_head)
	root.add_child(HSeparator.new())
	_body = UiTheme.hbox(18)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body)


func open(hero_uid: String) -> void:
	uid = hero_uid
	_key = ""
	visible = true


func _process(_delta: float) -> void:
	if not visible:
		return
	var s: GameSession = Net.session
	if s == null:
		return
	var h := s.unit_by_uid(uid)
	if h == null or not s.heroes.has(h):
		if s.heroes.is_empty():
			return
		uid = (s.heroes[0] as Character).uid
		h = s.heroes[0]
	var key := JSON.stringify(h.to_dict()) + str(s.items) + s.mode + str(s.heroes.size())
	if key != _key:
		_key = key
		_rebuild(s, h)


func _clear(c: Node) -> void:
	for ch in c.get_children():
		ch.queue_free()


func _rebuild(s: GameSession, h: Character) -> void:
	_clear(_tabs)
	for hh in s.heroes:
		var hero: Character = hh
		var b := UiTheme.button(hero.display_name, func() -> void: open(hero.uid), 16)
		b.disabled = hero.uid == uid
		_tabs.add_child(b)
	var editable := s.owner_of(h) == Net.my_id() and s.mode != "combat"

	# шапка: портрет, имя, уровень, опыт, свободные очки
	_clear(_head)
	var pr := PortraitBox.new()
	pr.template = h.template_id
	pr.custom_minimum_size = Vector2(84, 84)
	_head.add_child(pr)
	var hv := UiTheme.vbox(2)
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_head.add_child(hv)
	var info := str((GameData.rule("hero_info", {}) as Dictionary).get(h.template_id, ""))
	hv.add_child(UiTheme.label("%s — уровень %d" % [h.display_name, h.level], 22, UiTheme.TEXT, "bold"))
	if info != "":
		hv.add_child(UiTheme.label(info, 15, UiTheme.TEXT_DIM))
	hv.add_child(UiTheme.label("Опыт: %d из %d до следующего уровня" % [h.xp, Progression.xp_to_next(h.level)], 16, UiTheme.XP))
	var pts := "Свободные очки: атрибуты %d · способности %d · таланты %d" % [
		h.unspent_attribute_points, h.unspent_ability_points, h.unspent_talent_points]
	var any := h.unspent_attribute_points + h.unspent_ability_points + h.unspent_talent_points > 0
	hv.add_child(UiTheme.label(pts, 17, UiTheme.GOLD if any else UiTheme.TEXT_DIM))
	if not editable:
		var why := "Во время боя прокачка закрыта." if s.mode == "combat" else "Этим героем управляет другой игрок."
		hv.add_child(UiTheme.label(why, 15, UiTheme.TEXT_FAINT))

	_clear(_body)
	_body.add_child(_col_attributes(h, editable))
	_body.add_child(_col_abilities(h, editable))
	_body.add_child(_col_talents(s, h, editable))


func _column(title: String, width: float) -> Array:
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(width, 470)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := UiTheme.vbox(4)
	v.custom_minimum_size = Vector2(width - 14, 0)
	sc.add_child(v)
	v.add_child(UiTheme.label(title, 19, UiTheme.GOLD, "bold"))
	return [sc, v]


func _row(parent: Control, text: String, color: Color, button_text: String, enabled: bool, cmd: Dictionary, tip := "") -> void:
	var r := UiTheme.hbox(6)
	parent.add_child(r)
	var l := UiTheme.label(text, 17, color)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS if tip != "" else Control.MOUSE_FILTER_IGNORE
	r.add_child(l)
	if button_text != "":
		var b := UiTheme.button(button_text, func() -> void: screen.call("send", cmd), 16)
		b.disabled = not enabled
		b.custom_minimum_size = Vector2(36 if button_text == "+" else 0, 0)
		b.tooltip_text = tip
		r.add_child(b)


func _col_attributes(h: Character, editable: bool) -> Control:
	var c := _column("Атрибуты", 330)
	var v: VBoxContainer = c[1]
	var names: Dictionary = GameData.rule("attribute_names", {})
	for a in GameData.attribute_list():
		var can := editable and Progression.can_raise_attribute(h, str(a))
		_row(v, "%s  %d" % [names.get(a, a), int(h.attributes.get(a, 0))], UiTheme.TEXT, "+", can,
			{"type": "raise_attribute", "unit": h.uid, "attribute": a})
	v.add_child(HSeparator.new())
	var lines := [
		"Здоровье: %d / %d" % [roundi(h.hp), roundi(h.max_hp())],
		"Очки действия: %d, +%d за ход" % [h.get_int("max_ap"), h.get_int("ap_recovery")],
		"Инициатива: %d" % h.get_int("initiative"),
		"Броня: %d" % DamageCalc.effective_armor(h),
		"Точность: %d · Уклонение: %d" % [h.get_int("accuracy"), h.get_int("dodge")],
		"Крит: %d%%" % h.get_int("crit_chance"),
	]
	var w := h.effective_weapon()
	if not w.is_empty():
		lines.append("Оружие: %s, %d–%d" % [str(w.get("name", "")), int(w.get("min", 0)), int(w.get("max", 0))])
	for line in lines:
		v.add_child(UiTheme.label(str(line), 16, UiTheme.TEXT_DIM))
	var res := PackedStringArray()
	var res_names := {"fire": "огонь", "water": "вода", "earth": "земля", "air": "воздух", "poison": "яд", "tenacity": "стойкость"}
	for r in GameData.rule("resistances", []):
		var val := roundi(h.get_resistance(str(r)))
		if val != 0:
			res.append("%s %d%%" % [res_names.get(r, r), val])
	v.add_child(UiTheme.label("Сопротивления: " + (", ".join(res) if not res.is_empty() else "нет"), 16, UiTheme.TEXT_DIM))
	return c[0]


func _col_abilities(h: Character, editable: bool) -> Control:
	var c := _column("Способности", 340)
	var v: VBoxContainer = c[1]
	for ab in GameData.abilities:
		var def := GameData.ability(str(ab))
		var rank := h.ability_rank(str(ab))
		if rank == 0 and not editable:
			continue
		var cost := Progression.ability_cost(rank + 1)
		var col := UiTheme.TEXT if rank > 0 else UiTheme.TEXT_DIM
		_row(v, "%s  %d" % [def.get("name", ab), rank], col, "+", editable and Progression.can_raise_ability(h, str(ab)),
			{"type": "raise_ability", "unit": h.uid, "ability": ab},
			"%s\nСледующий ранг стоит %d очк." % [str(def.get("description", "")), cost])
	v.add_child(HSeparator.new())
	v.add_child(UiTheme.label("Навыки", 19, UiTheme.GOLD, "bold"))
	for sk in h.skills:
		var def := GameData.skill(str(sk))
		_row(v, "• %s — %d ОД" % [def.get("name", sk), int(def.get("ap", 0))], UiTheme.GREEN, "", false, {}, _skill_tip(str(sk)))
	for sk in GameData.skills:
		if h.skills.has(sk):
			continue
		var reason := Progression.skill_block_reason(h, str(sk))
		var def := GameData.skill(str(sk))
		if reason == "":
			_row(v, "%s — %d ОД" % [def.get("name", sk), int(def.get("ap", 0))], UiTheme.TEXT, "Выучить", editable,
				{"type": "learn_skill", "unit": h.uid, "skill": sk}, _skill_tip(str(sk)))
	return c[0]


func _col_talents(s: GameSession, h: Character, editable: bool) -> Control:
	var c := _column("Таланты", 340)
	var v: VBoxContainer = c[1]
	for t in h.talents:
		var def := GameData.talent(str(t))
		_row(v, "• %s" % def.get("name", t), UiTheme.GREEN, "", false, {}, str(def.get("description", "")))
	for t in GameData.talents:
		if h.talents.has(t):
			continue
		var def := GameData.talent(str(t))
		var reason := Progression.talent_block_reason(h, str(t))
		var ok := reason == ""
		if not ok and reason != "нет очков талантов":
			continue
		_row(v, str(def.get("name", t)), UiTheme.TEXT if ok else UiTheme.TEXT_FAINT, "Взять", editable and ok,
			{"type": "learn_talent", "unit": h.uid, "talent": t}, str(def.get("description", "")))
	v.add_child(HSeparator.new())
	v.add_child(UiTheme.label("Снаряжение", 19, UiTheme.GOLD, "bold"))
	if h.equipment.is_empty():
		v.add_child(UiTheme.label("Ничего не надето", 16, UiTheme.TEXT_FAINT))
	for it in h.equipment:
		var def := GameData.item(str(it))
		_row(v, "• %s" % def.get("name", it), UiTheme.TEXT, "Снять", editable,
			{"type": "unequip", "unit": h.uid, "item": it}, _item_tip(str(it)))
	for it in s.items:
		if not GameSession.is_equippable(str(it)):
			continue
		var def := GameData.item(str(it))
		_row(v, "%s (в сумке)" % def.get("name", it), UiTheme.TEXT_DIM, "Надеть", editable,
			{"type": "equip", "unit": h.uid, "item": it}, _item_tip(str(it)))
	return c[0]


static func _skill_tip(sk: String) -> String:
	var def := GameData.skill(sk)
	var parts := PackedStringArray()
	parts.append(str(def.get("name", sk)))
	parts.append("ОД %d · дальность %d · перезарядка %d" % [int(def.get("ap", 0)), int(def.get("range", 1)), int(def.get("cooldown", 0))])
	if def.has("description"):
		parts.append(str(def["description"]))
	return "\n".join(parts)


static func _item_tip(it: String) -> String:
	var def := GameData.item(it)
	var parts := PackedStringArray([str(def.get("name", it))])
	if def.has("description"):
		parts.append(str(def["description"]))
	var stats: Dictionary = def.get("stats", {})
	for k in stats:
		parts.append("%s %+d" % [str(k), int(stats[k])])
	return "\n".join(parts)


class PortraitBox extends Control:
	var template := ""

	func _ready() -> void:
		var v := IconArt.PortraitView.new()
		v.id = template
		UiTheme.place(v, Control.PRESET_FULL_RECT, Vector2(5, 5))
		v.offset_right = -5
		v.offset_bottom = -5
		add_child(v)

	func _draw() -> void:
		draw_style_box(UiTheme.slot_box(UiTheme.GOLD_DIM), Rect2(Vector2.ZERO, size))

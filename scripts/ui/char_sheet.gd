class_name CharSheet
extends PanelContainer
## Окно героя, как в D:OS: слева портреты отряда, дальше снаряжение на силуэте (10 ячеек), общая сумка отряда
## и страница героя: атрибуты (что даёт каждый), способности, навыки (их можно перетащить на панель умений) и таланты.
## Вещь надевается двойным щелчком, ПКМ или перетаскиванием на силуэт, снимается щелчком по ячейке.
## Чужих героев можно смотреть, но не менять. В бою прокачка и переодевание закрыты, как в D:OS.

const Describe := preload("res://scripts/ui/describe.gd")
const ItemGrid := preload("res://scripts/ui/item_grid.gd")
const PAGES := [["stats", "Атрибуты"], ["abilities", "Способности"], ["skills", "Навыки"], ["talents", "Таланты"]]
const FILTERS := [["all", "Всё"], ["gear", "Снаряжение"], ["use", "Расходники"], ["loot", "Прочее"]]

var screen: Node
var uid := ""
var page := "stats"
var bag_filter := "all"
var _key := ""
var _tabs: VBoxContainer
var _doll: Doll
var _bag: ItemGrid
var _gold: Label
var _sel_name: Label
var _sel_buttons: HBoxContainer
var _filter_buttons: Dictionary = {}
var _page_buttons: Dictionary = {}
var _content: VBoxContainer
var _points: Label


func _ready() -> void:
	theme = UiTheme.theme()
	custom_minimum_size = Vector2(1200, 600)   # панель умений внизу остаётся видна: на неё перетаскивают навыки
	UiTheme.place(self, Control.PRESET_CENTER, Vector2(-600, -340), custom_minimum_size)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var root := UiTheme.vbox(6)
	add_child(root)
	var top := UiTheme.hbox(8)
	root.add_child(top)
	var title := UiTheme.label("Герой", 24, UiTheme.GOLD, "title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var keys := UiTheme.label("C — закрыть · двойной щелчок по вещи — надеть или использовать", 14, UiTheme.TEXT_FAINT)
	top.add_child(keys)
	top.add_child(UiTheme.button("Закрыть", func() -> void: screen.call("open_panel", ""), 16))
	var body := UiTheme.hbox(10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	_tabs = UiTheme.vbox(8)
	_tabs.custom_minimum_size = Vector2(64, 0)
	body.add_child(_tabs)

	var doll_page := _parchment(body, 320)
	_doll = Doll.new()
	_doll.sheet = self
	_doll.custom_minimum_size = Vector2(304, 530)
	doll_page.add_child(_doll)

	var bag_page := _parchment(body, 344)
	var bv := UiTheme.vbox(6)
	bag_page.add_child(bv)
	var bh := UiTheme.hbox(6)
	bv.add_child(bh)
	var bt := _ink("Сумка отряда", 20, "bold")
	bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(bt)
	_gold = _ink("", 18, "bold", Color("8a5a10"))
	bh.add_child(_gold)
	var fr := UiTheme.hbox(4)
	bv.add_child(fr)
	for f in FILTERS:
		var b := UiTheme.button(str(f[1]), _set_filter.bind(str(f[0])), 14)
		_filter_buttons[str(f[0])] = b
		fr.add_child(b)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 370)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bv.add_child(sc)
	_bag = ItemGrid.new()
	_bag.cols = 6
	_bag.cell = 48.0
	_bag.min_rows = 7
	_bag.empty_text = ""
	_bag.on_click = func(_id: String) -> void: _key = ""
	_bag.on_double = _quick_use
	_bag.tip_fn = _bag_tip
	_bag.drag_fn = _bag_drag
	sc.add_child(_bag)
	_sel_name = _ink("", 16, "bold")
	_sel_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sel_name.custom_minimum_size = Vector2(320, 0)
	bv.add_child(_sel_name)
	_sel_buttons = UiTheme.hbox(6)
	bv.add_child(_sel_buttons)

	var info_page := _parchment(body, 0)
	info_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var iv := UiTheme.vbox(6)
	info_page.add_child(iv)
	var pr := UiTheme.hbox(4)
	iv.add_child(pr)
	for p in PAGES:
		var b := UiTheme.button(str(p[1]), _set_page.bind(str(p[0])), 15)
		_page_buttons[str(p[0])] = b
		pr.add_child(b)
	_points = _ink("", 15, "bold", Color("8a5a10"))
	_points.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_points.custom_minimum_size = Vector2(380, 0)
	iv.add_child(_points)
	var isc := ScrollContainer.new()
	isc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	isc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	iv.add_child(isc)
	_content = UiTheme.vbox(4)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	isc.add_child(_content)


func _parchment(parent: Control, width: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UiTheme.parchment(8))
	p.custom_minimum_size = Vector2(width, 0)
	parent.add_child(p)
	return p


## Надпись чернилами по пергаменту (без тени).
static func _ink(text: String, size := 16, kind := "body", color := UiTheme.INK_TEXT) -> Label:
	var l := UiTheme.label(text, size, color, kind)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	return l


func open(hero_uid: String) -> void:
	uid = hero_uid
	_key = ""
	visible = true
	_bag.screen = screen


func hero() -> Character:
	var s: GameSession = Net.session
	return s.unit_by_uid(uid) if s != null else null


func editable() -> bool:
	var s: GameSession = Net.session
	var h := hero()
	return s != null and h != null and s.owner_of(h) == Net.my_id() and s.mode != "combat"


func _set_filter(f: String) -> void:
	bag_filter = f
	_key = ""


func _set_page(p: String) -> void:
	page = p
	_key = ""


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
	_doll.queue_redraw()
	var key := JSON.stringify(h.to_dict()) + str(s.items) + str(s.gold) + s.mode + str(s.heroes.size()) + page + bag_filter + _bag.selected
	if key != _key:
		_key = key
		_rebuild(s, h)


func _clear(c: Node) -> void:
	for ch in c.get_children():
		ch.queue_free()


func _rebuild(s: GameSession, h: Character) -> void:
	_clear(_tabs)
	for hh in s.heroes:
		var hero_c: Character = hh
		var t := HeroTab.new()
		t.sheet = self
		t.hero_uid = hero_c.uid
		t.custom_minimum_size = Vector2(64, 64)
		_tabs.add_child(t)
		_hover_tip(t, "[b]%s[/b]\n[color=#a89a80]%s, уровень %d[/color]" % [hero_c.display_name, hero_c.class_title().to_lower(), hero_c.level])
	for f in _filter_buttons:
		(_filter_buttons[f] as Button).disabled = f == bag_filter
	for p in _page_buttons:
		(_page_buttons[p] as Button).disabled = p == page
	_gold.text = "%d з." % s.gold
	_rebuild_bag(s, h)
	var pts := PackedStringArray()
	if h.unspent_attribute_points > 0:
		pts.append("атрибуты %d" % h.unspent_attribute_points)
	if h.unspent_ability_points > 0:
		pts.append("способности %d" % h.unspent_ability_points)
	if h.unspent_talent_points > 0:
		pts.append("таланты %d" % h.unspent_talent_points)
	_points.text = ("Свободные очки: " + ", ".join(pts)) if not pts.is_empty() else ""
	if not editable():
		_points.text = "Во время боя прокачка и переодевание закрыты." if s.mode == "combat" else "Этим героем управляет другой игрок."
	_clear(_content)
	match page:
		"stats":
			_page_stats(h)
		"abilities":
			_page_abilities(h)
		"skills":
			_page_skills(h)
		"talents":
			_page_talents(h)


# --- Сумка ---------------------------------------------------------------------------------

static func _kind(id: String) -> String:
	var d := GameData.item(id)
	if GameSession.is_equippable(id):
		return "gear"
	if d.has("use"):
		return "use"
	return "loot"


func _rebuild_bag(s: GameSession, h: Character) -> void:
	var ids: Array = s.items.keys()
	ids.sort_custom(func(a, b): return [_kind(str(a)), str(GameData.item(str(a)).get("name", a))] < [_kind(str(b)), str(GameData.item(str(b)).get("name", b))])
	var list: Array = []
	for id in ids:
		if bag_filter != "all" and _kind(str(id)) != bag_filter:
			continue
		list.append({"id": str(id), "count": int(s.items[id])})
	_bag.set_entries(list)
	if not s.items.has(_bag.selected):
		_bag.selected = ""
	_clear(_sel_buttons)
	var sel := _bag.selected
	if sel == "":
		_sel_name.text = "Наведите на вещь — подробности, двойной щелчок — надеть или использовать."
		_sel_name.add_theme_color_override("font_color", UiTheme.INK_DIM)
		return
	_sel_name.add_theme_color_override("font_color", UiTheme.INK_TEXT)
	_sel_name.text = str(GameData.item(sel).get("name", sel))
	var ed := editable()
	if GameSession.is_equippable(sel):
		var b := UiTheme.button("Надеть: %s" % h.display_name, func() -> void: _send({"type": "equip", "unit": h.uid, "item": sel}), 15)
		b.disabled = not ed
		_sel_buttons.add_child(b)
	var use: Dictionary = GameData.item(sel).get("use", {})
	if not use.is_empty() and not use.has("skill"):
		var b := UiTheme.button("Использовать", func() -> void: _send({"type": "use_item", "unit": h.uid, "item": sel}), 15)
		b.disabled = s.owner_of(h) != Net.my_id() or s.mode == "dialogue"
		_sel_buttons.add_child(b)


func _bag_tip(id: String) -> String:
	var t := Describe.item_text(id)
	var h := hero()
	if h == null:
		return t
	if GameSession.is_equippable(id):
		t += "\n[color=#c8a060]Двойной щелчок — надеть: %s[/color]" % h.display_name
		var on: Array = h.in_slot(Character.slot_of(id))
		if not on.is_empty() and on.size() >= Character.slot_capacity(Character.slot_of(id)):
			t += "\n[color=#6e6454]Сейчас надето: %s[/color]" % str(GameData.item(str(on[0])).get("name", on[0]))
	elif (GameData.item(id).get("use", {}) as Dictionary).has("skill"):
		t += "\n[color=#6e6454]Перетащите на панель умений внизу[/color]"
	elif GameData.item(id).has("use"):
		t += "\n[color=#c8a060]Двойной щелчок — использовать: %s[/color]" % h.display_name
	return t


func _bag_drag(id: String) -> Variant:
	var h := hero()
	if h == null:
		return null
	var data := {"bag_item": id, "uid": h.uid}
	if GameData.item(id).has("use"):
		data["hotbar_id"] = "item:" + id   # расходник можно положить на панель умений
		data["from"] = -1
	return data


func _quick_use(id: String) -> void:
	var h := hero()
	if h == null:
		return
	if GameSession.is_equippable(id):
		if editable():
			_send({"type": "equip", "unit": h.uid, "item": id})
	elif GameData.item(id).has("use") and not (GameData.item(id).get("use", {}) as Dictionary).has("skill"):
		_send({"type": "use_item", "unit": h.uid, "item": id})


func _send(cmd: Dictionary) -> void:
	screen.call("send", cmd)
	_key = ""


## Подсказка у курсора, пока мышь над элементом.
func _hover_tip(c: Control, text: String) -> void:
	if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		c.mouse_filter = Control.MOUSE_FILTER_PASS
	c.mouse_entered.connect(func() -> void: screen.set("ui_tip", text))
	c.mouse_exited.connect(func() -> void:
		if str(screen.get("ui_tip")) == text:
			screen.set("ui_tip", ""))


# --- Страницы ------------------------------------------------------------------------------

func _heading(text: String) -> void:
	var l := _ink(text, 19, "bold", Color("5a3a18"))
	_content.add_child(l)


func _note(text: String, size := 14, color := UiTheme.INK_DIM) -> Label:
	var l := _ink(text, size, "body", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(380, 0)
	_content.add_child(l)
	return l


func _plus(enabled: bool, cmd: Dictionary) -> Button:
	var b := UiTheme.button("+", func() -> void: _send(cmd), 16)
	b.custom_minimum_size = Vector2(34, 30)
	b.disabled = not enabled
	return b


func _page_stats(h: Character) -> void:
	var ed := editable()
	var names: Dictionary = GameData.rule("attribute_names", {})
	var info: Dictionary = GameData.rule("attribute_info", {})
	_heading("Атрибуты")
	for a in GameData.attribute_list():
		var row := UiTheme.hbox(8)
		_content.add_child(row)
		var n := _ink(str(names.get(a, a)), 17, "bold")
		n.custom_minimum_size = Vector2(130, 0)
		row.add_child(n)
		var v := _ink(str(int(h.attributes.get(a, 0))), 18, "bold", Color("2a1a0a"))
		v.custom_minimum_size = Vector2(28, 0)
		row.add_child(v)
		var eff := _ink("за очко: " + Describe.attribute_effects(str(a)), 13, "body", UiTheme.INK_DIM)
		eff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		eff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		eff.custom_minimum_size = Vector2(150, 0)
		row.add_child(eff)
		row.add_child(_plus(ed and Progression.can_raise_attribute(h, str(a)), {"type": "raise_attribute", "unit": h.uid, "attribute": a}))
		var tip := "[b]%s[/b]\n%s\n[color=#a89a80]За каждое очко: %s[/color]" % [names.get(a, a), info.get(a, ""), Describe.attribute_effects(str(a))]
		_hover_tip(row, tip)
		if info.has(a):
			_note(str(info[a]), 13)
	_content.add_child(HSeparator.new())
	_heading("В бою")
	var w := h.effective_weapon()
	var p := DamageCalc.preview(h, GameData.skill("attack"))
	var rows := [
		["max_hp", "Здоровье", "%d / %d" % [roundi(h.hp), roundi(h.max_hp())]],
		["max_ap", "Очки действия", "%d, +%d за ход" % [h.get_int("max_ap"), h.get_int("ap_recovery")]],
		["armor", "Броня", "%d (режет %d%% урона врага своего уровня)" % [roundi(DamageCalc.effective_armor(h)), roundi(DamageCalc.armor_reduction_pct(h, h.level))]],
		["physical_damage_pct", "Удар оружием", "%s %d–%d" % [str(w.get("name", "")), int(p.get("min", 0)), int(p.get("max", 0))]],
		["accuracy", "Точность", "%d%%" % h.get_int("accuracy")],
		["dodge", "Уклонение", "%d%%" % h.get_int("dodge")],
		["crit_chance", "Крит", "%d%%, урон ×%s" % [h.get_int("crit_chance"), ("%.1f" % h.get_stat("crit_multiplier")).replace(".", ",")]],
		["initiative", "Инициатива", "%d" % h.get_int("initiative")],
		["move_per_ap", "Шаг", "%s кл. за 1 ОД" % ("%.1f" % h.get_stat("move_per_ap")).replace(".", ",")],
		["magic_damage_pct", "Сила заклинаний", "%+d%%" % h.get_int("magic_damage_pct")],
	]
	for r in rows:
		var row := UiTheme.hbox(8)
		_content.add_child(row)
		var n := _ink(str(r[1]), 15, "bold")
		n.custom_minimum_size = Vector2(150, 0)
		row.add_child(n)
		var v := _ink(str(r[2]), 15)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.custom_minimum_size = Vector2(150, 0)
		row.add_child(v)
		_hover_tip(row, "[b]%s[/b]\n%s" % [r[1], Describe.STAT_INFO.get(str(r[0]), "")])
	_content.add_child(HSeparator.new())
	_heading("Сопротивления")
	var res_row := HFlowContainer.new()
	res_row.add_theme_constant_override("h_separation", 14)
	_content.add_child(res_row)
	var res_names := {"fire": "огонь", "water": "вода", "earth": "земля", "air": "воздух", "poison": "яд", "tenacity": "стойкость"}
	for r in GameData.rule("resistances", []):
		var val := roundi(h.get_resistance(str(r)))
		var col := UiTheme.element_color(str(r)).darkened(0.45) if str(r) != "tenacity" else Color("4a3a2a")
		var l := _ink("%s %d%%" % [res_names.get(r, r), val], 15, "bold", col if val >= 0 else Color("a02a1a"))
		res_row.add_child(l)
		_hover_tip(l, "[b]Сопротивление: %s[/b]\nНа столько процентов слабее бьёт эта стихия. Минус — бьёт сильнее.%s" % [
			res_names.get(r, r), "\nСтойкость защищает от оглушения, сбивания с ног и страха." if str(r) == "tenacity" else ""])


func _page_abilities(h: Character) -> void:
	var ed := editable()
	_heading("Способности")
	_note("Ранг способности открывает навыки и даёт прибавки. Очки дают за уровень.", 13)
	for ab in GameData.abilities:
		var def := GameData.ability(str(ab))
		var rank := h.ability_rank(str(ab))
		if rank == 0 and (not ed or h.unspent_ability_points <= 0):
			continue
		var row := UiTheme.hbox(8)
		_content.add_child(row)
		var n := _ink(str(def.get("name", ab)), 17, "bold", UiTheme.INK_TEXT if rank > 0 else UiTheme.INK_DIM)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(n)
		row.add_child(_ink("ранг %d" % rank, 15))
		row.add_child(_plus(ed and Progression.can_raise_ability(h, str(ab)), {"type": "raise_ability", "unit": h.uid, "ability": ab}))
		_hover_tip(row, Describe.ability_text(str(ab), rank) + "\n[color=#6e6454]Следующий ранг стоит %d очк.[/color]" % Progression.ability_cost(rank + 1))
		var pr: Dictionary = def.get("per_rank", {})
		if not pr.is_empty():
			_note("за ранг: " + Describe.modifiers(pr, false), 13)


func _page_skills(h: Character) -> void:
	var ed := editable()
	_heading("Изученные навыки")
	_note("Перетащите навык на панель умений внизу экрана.", 13)
	for sk in h.skills:
		_skill_row(h, str(sk), true, "")
	var open: Array = []
	var locked: Array = []
	for sk in GameData.skills:
		if h.skills.has(sk) or bool(GameData.skill(str(sk)).get("item_only", false)):
			continue
		var reason := Progression.skill_block_reason(h, str(sk))
		if reason == "":
			open.append(str(sk))
		elif h.ability_rank(str(GameData.skill(str(sk)).get("ability", ""))) > 0:
			locked.append([str(sk), reason])
	if not open.is_empty():
		_content.add_child(HSeparator.new())
		_heading("Можно выучить")
		for sk in open:
			_skill_row(h, sk, false, "", ed)
	if not locked.is_empty():
		_content.add_child(HSeparator.new())
		_heading("Позже")
		for l in locked:
			_skill_row(h, str(l[0]), false, str(l[1]))


func _skill_row(h: Character, sk: String, learned: bool, reason: String, can_learn := false) -> void:
	var def := GameData.skill(sk)
	var row := UiTheme.hbox(8)
	_content.add_child(row)
	var icon := SkillIcon.new()
	icon.skill_id = sk
	icon.uid = h.uid
	icon.draggable = learned
	icon.dim = not learned
	icon.custom_minimum_size = Vector2(40, 40)
	row.add_child(icon)
	var v := UiTheme.vbox(0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)
	v.add_child(_ink(str(def.get("name", sk)), 16, "bold", UiTheme.INK_TEXT if learned or reason == "" else UiTheme.INK_DIM))
	var sub := "%d ОД" % int(def.get("ap", 0))
	if int(def.get("cooldown", 0)) > 0:
		sub += " · перезарядка %d" % int(def["cooldown"])
	if reason != "":
		sub += " · " + reason
	v.add_child(_ink(sub, 13, "body", UiTheme.INK_DIM))
	if not learned and reason == "":
		var b := UiTheme.button("Выучить", func() -> void: _send({"type": "learn_skill", "unit": h.uid, "skill": sk}), 15)
		b.disabled = not can_learn
		row.add_child(b)
	var tip := str(screen.call("skill_tip", sk, h))
	_hover_tip(row, tip + ("\n[color=#6e6454]Перетащите на панель умений[/color]" if learned else ""))
	_hover_tip(icon, tip + ("\n[color=#6e6454]Перетащите на панель умений[/color]" if learned else ""))


func _page_talents(h: Character) -> void:
	var ed := editable()
	_heading("Таланты")
	if h.talents.is_empty():
		_note("Пока ни одного.", 14)
	for t in h.talents:
		var def := GameData.talent(str(t))
		var l := _ink("• " + str(def.get("name", t)), 16, "bold")
		_content.add_child(l)
		_note(str(def.get("description", "")), 13)
	_content.add_child(HSeparator.new())
	_heading("Можно взять")
	var any := false
	for t in GameData.talents:
		if h.talents.has(t):
			continue
		var def := GameData.talent(str(t))
		var reason := Progression.talent_block_reason(h, str(t))
		if reason != "" and reason != "нет очков талантов":
			continue
		any = true
		var row := UiTheme.hbox(8)
		_content.add_child(row)
		var n := _ink(str(def.get("name", t)), 16, "bold", UiTheme.INK_TEXT if reason == "" else UiTheme.INK_DIM)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(n)
		var b := UiTheme.button("Взять", func() -> void: _send({"type": "learn_talent", "unit": h.uid, "talent": t}), 15)
		b.disabled = not (ed and reason == "")
		row.add_child(b)
		_note(str(def.get("description", "")), 13)
	if not any:
		_note("Новых талантов пока нет.", 14)


# =========================================================================================

## Портрет героя слева: щелчок — открыть его лист.
class HeroTab extends Control:
	var sheet: CharSheet
	var hero_uid := ""
	var _view: IconArt.PortraitView

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		_view = IconArt.PortraitView.new()
		_view.position = Vector2(6, 6)
		_view.size = Vector2(52, 52)
		_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_view)

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			sheet.open(hero_uid)
			GameAudio.ui("ui_click")
			accept_event()

	func _process(_delta: float) -> void:
		var s: GameSession = Net.session
		var h: Character = s.unit_by_uid(hero_uid) if s != null else null
		if h != null:
			_view.id = h.template_id
			_view.dead = not h.is_alive()
		queue_redraw()

	func _draw() -> void:
		var sel := sheet.uid == hero_uid
		draw_style_box(UiTheme.slot_box(Color("fff0a0") if sel else UiTheme.GOLD_DIM), Rect2(Vector2.ZERO, size))
		var s: GameSession = Net.session
		var h: Character = s.unit_by_uid(hero_uid) if s != null else null
		if h != null and h.unspent_attribute_points + h.unspent_ability_points + h.unspent_talent_points > 0:
			draw_circle(Vector2(size.x - 8, 8), 6.0, Color("120c0a"))
			draw_circle(Vector2(size.x - 8, 8), 4.5, Color("f0c860"))


## Значок навыка в листе: изученный можно перетащить на панель умений.
class SkillIcon extends Control:
	var skill_id := ""
	var uid := ""
	var draggable := false
	var dim := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		if draggable:
			mouse_default_cursor_shape = Control.CURSOR_DRAG

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_style_box(UiTheme.slot_box(UiTheme.GOLD_DIM), r)
		IconArt.skill_icon(self, skill_id, r.grow(-4), dim)

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if not draggable:
			return null
		set_drag_preview(Hud.drag_icon(skill_id))
		return {"hotbar_id": skill_id, "from": -1, "uid": uid}


## Снаряжение на силуэте, как в D:OS1: слева голова, тело, руки, ноги; справа амулет, пояс, два кольца;
## снизу оружие, ступни и вторая рука. Щелчок по вещи — снять, вещь из сумки бросают на силуэт — надеть.
class Doll extends Control:
	var sheet: CharSheet
	var _hover := -1
	var _slots: Array = []   # [Rect2, ячейка, индекс в ячейке]

	const S := 54.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		var lx := 6.0
		var rx := 304.0 - 6.0 - S
		_slots = [
			[Rect2(lx, 86, S, S), "head", 0], [Rect2(lx, 150, S, S), "chest", 0],
			[Rect2(lx, 214, S, S), "hands", 0], [Rect2(lx, 278, S, S), "legs", 0],
			[Rect2(rx, 86, S, S), "amulet", 0], [Rect2(rx, 150, S, S), "belt", 0],
			[Rect2(rx, 214, S, S), "ring", 0], [Rect2(rx, 278, S, S), "ring", 1],
			[Rect2(40, 352, S, S), "weapon", 0], [Rect2(125, 352, S, S), "feet", 0], [Rect2(210, 352, S, S), "offhand", 0],
		]

	func _item(h: Character, slot: String, idx: int) -> String:
		var on: Array = h.in_slot(slot)
		return str(on[idx]) if idx < on.size() else ""

	func _index_at(p: Vector2) -> int:
		for i in _slots.size():
			if (_slots[i][0] as Rect2).has_point(p):
				return i
		return -1

	func _gui_input(event: InputEvent) -> void:
		var h := sheet.hero()
		if h == null:
			return
		var mm := event as InputEventMouseMotion
		if mm != null:
			var i := _index_at(mm.position)
			if i != _hover:
				_hover = i
				sheet.screen.set("ui_tip", _tip(h, i) if i >= 0 else "")
			return
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT):
			var i := _index_at(mb.position)
			if i >= 0:
				var it := _item(h, str(_slots[i][1]), int(_slots[i][2]))
				if it != "" and sheet.editable():
					sheet._send({"type": "unequip", "unit": h.uid, "item": it})
					sheet.screen.set("ui_tip", "")
				accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT:
			_hover = -1
			if sheet != null and sheet.screen != null:
				sheet.screen.set("ui_tip", "")

	func _tip(h: Character, i: int) -> String:
		var slot := str(_slots[i][1])
		var it := _item(h, slot, int(_slots[i][2]))
		if it == "":
			var w := h.effective_weapon()
			if slot == "weapon" and not w.is_empty():
				return "[b]%s[/b] (своё)\nУрон %d–%d\n[color=#a89a80]Перетащите сюда оружие из сумки[/color]" % [w.get("name", ""), int(w.get("min", 0)), int(w.get("max", 0))]
			if slot == "offhand" and h.two_handed():
				return "[b]Вторая рука[/b]\n[color=#a89a80]Занята: оружие двуручное[/color]"
			return "[b]%s[/b] — пусто\n[color=#a89a80]Перетащите сюда вещь из сумки или дважды щёлкните по ней[/color]" % Character.SLOT_NAMES.get(slot, slot)
		var t := Describe.item_text(it)
		if sheet.editable():
			t += "\n[color=#c8a060]ЛКМ — снять в сумку[/color]"
		return t

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.has("bag_item") and GameSession.is_equippable(str(data["bag_item"])) \
			and sheet.editable()

	func _drop_data(_at: Vector2, data: Variant) -> void:
		var h := sheet.hero()
		if h != null:
			sheet._send({"type": "equip", "unit": h.uid, "item": str(data["bag_item"])})

	func _draw() -> void:
		var h := sheet.hero()
		if h == null:
			return
		var title := UiTheme.font("title")
		var body := UiTheme.font("body")
		var bold := UiTheme.font("bold")
		draw_string(title, Vector2(0, 26), h.display_name, HORIZONTAL_ALIGNMENT_CENTER, size.x, 28, UiTheme.INK_TEXT)
		draw_string(body, Vector2(0, 48), "%s, уровень %d" % [h.class_title(), h.level], HORIZONTAL_ALIGNMENT_CENTER, size.x, 16, UiTheme.INK_DIM)
		var xr := Rect2(52, 58, size.x - 104, 7)
		draw_rect(xr.grow(1), Color("4a3622"))
		draw_rect(xr, Color("cdb88c"))
		var need := maxi(1, Progression.xp_to_next(h.level))
		draw_rect(Rect2(xr.position, Vector2(roundf(xr.size.x * clampf(float(h.xp) / need, 0, 1)), xr.size.y)), Color("5a6ad0"))
		draw_string(body, Vector2(0, 80), "опыт %d / %d" % [h.xp, need], HORIZONTAL_ALIGNMENT_CENTER, size.x, 12, UiTheme.INK_DIM)
		_silhouette()
		for i in _slots.size():
			var r: Rect2 = _slots[i][0]
			var slot := str(_slots[i][1])
			var it := _item(h, slot, int(_slots[i][2]))
			var border := Color("8a6a3a")
			if i == _hover:
				border = UiTheme.GOLD
			draw_style_box(UiTheme.slot_box(border, Color("1a1410")), r)
			if it != "":
				IconArt.item_icon(self, it, r.grow(-6))
			elif slot == "weapon" and not h.effective_weapon().is_empty():
				IconArt.draw_glyph(self, "sword", r.grow(-10), Color("8a7a6a"), true)
			else:
				var blocked := slot == "offhand" and h.two_handed()
				_hint(slot, r, Color(0.8, 0.7, 0.55, 0.22 if not blocked else 0.1))
				draw_string(body, Vector2(r.position.x, r.end.y - 4), Character.SLOT_NAMES.get(slot, slot),
					HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 10, Color(0.85, 0.75, 0.6, 0.55))
		# итог внизу
		var y := 432.0
		var lines := [
			"Здоровье %d / %d   ·   Броня %d" % [roundi(h.hp), roundi(h.max_hp()), roundi(DamageCalc.effective_armor(h))],
			"Точность %d%%   ·   Уклонение %d%%   ·   Крит %d%%" % [h.get_int("accuracy"), h.get_int("dodge"), h.get_int("crit_chance")],
		]
		var w := h.effective_weapon()
		if not w.is_empty():
			var p := DamageCalc.preview(h, GameData.skill("attack"))
			lines.insert(1, "%s: урон %d–%d" % [str(w.get("name", "")), int(p.get("min", 0)), int(p.get("max", 0))])
		for ln in lines:
			draw_string(bold if ln == lines[0] else body, Vector2(0, y), str(ln), HORIZONTAL_ALIGNMENT_CENTER, size.x, 15, UiTheme.INK_TEXT)
			y += 22.0

	## Силуэт человека: картинка images/ui_paperdoll или контур кодом.
	func _silhouette() -> void:
		var fr := SpriteLibrary.frame("images", "ui_paperdoll")
		var area := Rect2(70, 86, 164, 262)
		if not fr.is_empty():
			var region: Rect2 = fr["region"]
			var k := minf(area.size.x / region.size.x, area.size.y / region.size.y)
			var sz := region.size * k
			draw_texture_rect_region(fr["texture"], Rect2(area.get_center() - sz * 0.5, sz), region, Color(1, 1, 1, 0.9))
			return
		var c := Color(0.29, 0.2, 0.12, 0.22)
		var cx := 152.0
		draw_circle(Vector2(cx, 112), 17.0, c)
		draw_colored_polygon(PackedVector2Array([Vector2(cx - 8, 126), Vector2(cx + 8, 126), Vector2(cx + 9, 134), Vector2(cx - 9, 134)]), c)
		draw_colored_polygon(PackedVector2Array([Vector2(cx - 34, 138), Vector2(cx + 34, 138), Vector2(cx + 26, 196),
			Vector2(cx + 22, 236), Vector2(cx - 22, 236), Vector2(cx - 26, 196)]), c)
		for sx in [-1.0, 1.0]:
			draw_colored_polygon(PackedVector2Array([Vector2(cx + sx * 34, 138), Vector2(cx + sx * 46, 150),
				Vector2(cx + sx * 50, 222), Vector2(cx + sx * 40, 226), Vector2(cx + sx * 36, 160)]), c)
			draw_colored_polygon(PackedVector2Array([Vector2(cx + sx * 4, 236), Vector2(cx + sx * 22, 236),
				Vector2(cx + sx * 20, 338), Vector2(cx + sx * 6, 338)]), c)

	## Подсказка пустой ячейки: простой рисунок того, что туда надевают.
	func _hint(slot: String, r: Rect2, c: Color) -> void:
		var o := r.get_center() + Vector2(0, -5)
		match slot:
			"head":
				draw_arc(o + Vector2(0, 4), 12.0, PI, TAU, 16, c, 4.0)
				draw_line(o + Vector2(-15, 5), o + Vector2(15, 5), c, 3.0)
			"amulet":
				draw_arc(o + Vector2(0, -6), 11.0, 0.2, PI - 0.2, 12, c, 2.0)
				draw_circle(o + Vector2(0, 8), 5.0, c)
			"chest":
				draw_colored_polygon(PackedVector2Array([o + Vector2(-14, -10), o + Vector2(14, -10), o + Vector2(10, 14), o + Vector2(-10, 14)]), c)
			"hands":
				draw_colored_polygon(PackedVector2Array([o + Vector2(-8, 12), o + Vector2(8, 12), o + Vector2(10, -6), o + Vector2(-10, -6)]), c)
				for k in 4:
					draw_line(o + Vector2(-8 + k * 5, -6), o + Vector2(-8 + k * 5, -13), c, 3.0)
			"belt":
				draw_rect(Rect2(o + Vector2(-16, -3), Vector2(32, 7)), c)
				draw_rect(Rect2(o + Vector2(-5, -6), Vector2(10, 13)), c, false, 2.0)
			"legs":
				draw_colored_polygon(PackedVector2Array([o + Vector2(-12, -12), o + Vector2(12, -12), o + Vector2(11, 14), o + Vector2(3, 14), o + Vector2(0, -2), o + Vector2(-3, 14), o + Vector2(-11, 14)]), c)
			"feet":
				draw_colored_polygon(PackedVector2Array([o + Vector2(-6, -12), o + Vector2(4, -12), o + Vector2(4, 6), o + Vector2(14, 8), o + Vector2(14, 13), o + Vector2(-6, 13)]), c)
			"ring":
				draw_arc(o, 9.0, 0.0, TAU, 20, c, 3.0)
				draw_circle(o + Vector2(0, -10), 3.0, c)
			"weapon":
				draw_line(o + Vector2(-10, 12), o + Vector2(10, -12), c, 3.0)
				draw_line(o + Vector2(-12, 4), o + Vector2(-2, 14), c, 3.0)
			"offhand":
				draw_colored_polygon(PackedVector2Array([o + Vector2(-12, -12), o + Vector2(12, -12), o + Vector2(12, 2), o + Vector2(0, 14), o + Vector2(-12, 2)]), c)

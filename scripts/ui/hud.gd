class_name Hud
extends Control
## Интерфейс поверх мира: портреты героев, очередь ходов, панель навыков, задания, журнал боя,
## всплывающие сообщения, баннеры, карточка локации, советы и подсказка под курсором.
## Только показывает состояние и передаёт нажатия в GameScreen (screen), сам ничего не решает.

const FRAME_SIZE := Vector2(244, 66)
const TOAST_W := 290.0   # шире сообщения переносятся, чтобы не залезать на середину экрана
const SLOT := 46.0

var screen: Node                    # GameScreen
var party_box: VBoxContainer
var party_frames: Dictionary = {}   # uid -> PartyFrame
var turn_bar: TurnBar
var action_bar: ActionBar
var end_turn_btn: Button
var location_label: Label
var quest_box: VBoxContainer
var quest_panel: PanelContainer
var gold_label: Label
var log_label: RichTextLabel
var log_panel: PanelContainer
var toast_box: VBoxContainer
var banner: Label
var sub_banner: Label
var card_title: Label
var card_text: Label
var tooltip: PanelContainer
var tooltip_label: RichTextLabel
var help_panel: PanelContainer
var waiting_label: Label

var _quest_key := ""
var _log_size := -1
var _tips: Array = []
var _tip := ""          # совет, который сейчас показан последней строкой журнала боя
var _tip_t := 0.0
var _banner_tween: Tween
var _card_tween: Tween
var _toasts_recent: Dictionary = {}   # текст -> время, чтобы не повторять одно и то же


func _ready() -> void:
	UiTheme.fill_parent(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.theme()
	_build_party()
	_build_top()
	_build_quests()
	_build_bottom()
	_build_log()
	_build_messages()
	_build_tooltip()
	_build_help()


# --- Постройка -----------------------------------------------------------------------

func _build_party() -> void:
	party_box = VBoxContainer.new()
	party_box.position = Vector2(10, 10)
	party_box.add_theme_constant_override("separation", 6)
	party_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(party_box)


func _build_top() -> void:
	location_label = UiTheme.label("", 18, UiTheme.GOLD, "bold")
	location_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.place(location_label, Control.PRESET_CENTER_TOP, Vector2(0, 10), Vector2(0, 24))
	UiTheme.outline(location_label)
	UiTheme.backdrop(location_label)
	add_child(location_label)
	turn_bar = TurnBar.new()
	turn_bar.hud = self
	UiTheme.place(turn_bar, Control.PRESET_CENTER_TOP, Vector2(-300, 8), Vector2(600, 70))
	turn_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(turn_bar)
	waiting_label = UiTheme.label("Ждём состояние игры от сервера…", 22, UiTheme.TEXT_DIM)
	waiting_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.place(waiting_label, Control.PRESET_CENTER, Vector2(-300, -16), Vector2(600, 32))
	waiting_label.visible = false
	add_child(waiting_label)


func _build_quests() -> void:
	quest_panel = UiTheme.panel(Vector2(300, 0))
	UiTheme.place(quest_panel, Control.PRESET_TOP_RIGHT, Vector2(-310, 10), Vector2(300, 0))
	quest_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(quest_panel)
	var v := UiTheme.vbox(4)
	quest_panel.add_child(v)
	var top := UiTheme.hbox(6)
	v.add_child(top)
	var head := UiTheme.label("Задания", 18, UiTheme.GOLD, "bold")
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(head)
	gold_label = UiTheme.label("", 16, Color("f0c860"))
	top.add_child(gold_label)
	quest_box = UiTheme.vbox(6)
	v.add_child(quest_box)
	var buttons := UiTheme.hbox(4)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(buttons)
	for b in [["Журнал (J)", "journal"], ["Герой (C)", "sheet"], ["Меню", "menu"]]:
		var btn := UiTheme.button(str(b[0]), func() -> void: screen.call("open_panel", str(b[1])), 14)
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		buttons.add_child(btn)


func _build_bottom() -> void:
	action_bar = ActionBar.new()
	action_bar.hud = self
	UiTheme.place(action_bar, Control.PRESET_CENTER_BOTTOM, Vector2(-330, -86), Vector2(660, 78))
	add_child(action_bar)
	end_turn_btn = UiTheme.button("Конец хода", func() -> void: screen.call("end_turn"), 18)
	UiTheme.place(end_turn_btn, Control.PRESET_CENTER_BOTTOM, Vector2(340, -70), Vector2(140, 44))
	end_turn_btn.grow_horizontal = Control.GROW_DIRECTION_END
	end_turn_btn.tooltip_text = "Пробел"
	add_child(end_turn_btn)


func _build_log() -> void:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.035, 0.03, 0.55)
	sb.set_content_margin_all(6)
	p.add_theme_stylebox_override("panel", sb)
	UiTheme.place(p, Control.PRESET_BOTTOM_LEFT, Vector2(10, -150), Vector2(380, 140))
	log_panel = p
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(p)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.custom_minimum_size = Vector2(368, 128)
	log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_label.add_theme_font_size_override("normal_font_size", 15)
	log_label.add_theme_color_override("default_color", UiTheme.TEXT_DIM)
	p.add_child(log_label)


func _build_messages() -> void:
	toast_box = UiTheme.vbox(4)
	# сообщения — слева под портретами отряда, чтобы не закрывать середину карты
	UiTheme.place(toast_box, Control.PRESET_TOP_LEFT, Vector2(12, 160), Vector2(310, 10))
	toast_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast_box)
	banner = UiTheme.label("", 32, UiTheme.GOLD, "title")
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.place(banner, Control.PRESET_CENTER, Vector2(-400, -150), Vector2(800, 48))
	banner.add_theme_constant_override("shadow_offset_x", 4)
	banner.add_theme_constant_override("shadow_offset_y", 4)
	banner.modulate.a = 0.0
	UiTheme.outline(banner)
	add_child(banner)
	sub_banner = UiTheme.label("", 20, UiTheme.TEXT, "bold")
	sub_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.place(sub_banner, Control.PRESET_CENTER_TOP, Vector2(0, 90), Vector2(0, 30))
	sub_banner.modulate.a = 0.0
	UiTheme.outline(sub_banner)
	UiTheme.backdrop(sub_banner)
	add_child(sub_banner)
	card_title = UiTheme.label("", 24, Color("f0dcae"), "title")
	card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.place(card_title, Control.PRESET_CENTER_TOP, Vector2(-500, 150), Vector2(1000, 40))
	card_title.add_theme_constant_override("shadow_offset_x", 3)
	card_title.add_theme_constant_override("shadow_offset_y", 3)
	card_title.modulate.a = 0.0
	UiTheme.outline(card_title)
	add_child(card_title)
	card_text = UiTheme.label("", 20, UiTheme.TEXT)
	card_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UiTheme.place(card_text, Control.PRESET_CENTER_TOP, Vector2(-318, 200), Vector2(636, 60))
	card_text.grow_vertical = Control.GROW_DIRECTION_END
	card_text.modulate.a = 0.0
	UiTheme.outline(card_text)
	add_child(card_text)


func _build_tooltip() -> void:
	tooltip = PanelContainer.new()
	tooltip.add_theme_stylebox_override("panel", UiTheme.frame(Color("120e0b"), UiTheme.GOLD_DIM, UiTheme.INK, Color("221a14"), 0.96, 4))
	tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip.visible = false
	tooltip.z_index = 20
	add_child(tooltip)
	tooltip_label = RichTextLabel.new()
	tooltip_label.bbcode_enabled = true
	tooltip_label.fit_content = true
	tooltip_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip_label.add_theme_font_size_override("normal_font_size", 16)
	tooltip_label.add_theme_font_size_override("bold_font_size", 17)
	tooltip.add_child(tooltip_label)


func _build_help() -> void:
	help_panel = UiTheme.panel(Vector2(560, 0))
	UiTheme.center(help_panel, Vector2(560, 300))
	help_panel.visible = false
	add_child(help_panel)
	var v := UiTheme.vbox(6)
	help_panel.add_child(v)
	v.add_child(UiTheme.label("Управление", 20, UiTheme.GOLD, "bold"))
	var text := UiTheme.label("""ЛКМ по земле — идти, по герою — выбрать, по жителю или предмету — поговорить, осмотреть
ЛКМ по врагу в бою — атаковать оружием
1–9 — навык в бою, ПКМ или Esc — отменить навык, Пробел — конец хода
Tab — следующий герой, колесо — приблизить, ПКМ с перетаскиванием или WASD — сдвинуть камеру, Z — вернуть
C — герой и прокачка, J — журнал заданий, I — сумка
K — сохранить, L — загрузить, Esc — меню, H — эта справка
В разговоре: ЛКМ или Пробел — дальше, 1–9 — ответ, Esc — пролистать""", 16, UiTheme.TEXT)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size = Vector2(540, 0)
	v.add_child(text)


# --- Каждый кадр ---------------------------------------------------------------------

func refresh(s: GameSession) -> void:
	waiting_label.visible = s == null or s.grid == null
	if s == null or s.grid == null:
		return
	_refresh_party(s)
	var in_combat := s.mode == "combat" and s.combat != null
	turn_bar.visible = in_combat
	location_label.visible = not in_combat
	location_label.text = str(s.location_data().get("name", s.location_id))
	turn_bar.queue_redraw()
	action_bar.queue_redraw()
	var my_turn := bool(screen.call("is_my_turn"))
	end_turn_btn.visible = in_combat
	end_turn_btn.disabled = not my_turn
	_refresh_quests(s)
	_refresh_log()
	gold_label.text = "%d з." % s.gold
	var dlg := s.mode == "dialogue"
	action_bar.visible = not dlg
	quest_panel.visible = not dlg
	end_turn_btn.visible = end_turn_btn.visible and not dlg
	log_panel.visible = not dlg
	toast_box.offset_top = party_box.position.y + party_box.size.y + 14.0
	toast_box.offset_bottom = toast_box.offset_top + 10.0
	# советы показываются последней строкой журнала боя (отдельное окно закрывало карту)
	if not dlg and (not _tips.is_empty() or _tip != ""):
		_tip_t -= get_process_delta_time()
		if _tip_t <= 0.0:
			_tip = str(_tips.pop_front()) if not _tips.is_empty() else ""
			_tip_t = 12.0
			_log_size = -1


func _refresh_party(s: GameSession) -> void:
	var seen := {}
	for h in s.heroes:
		var hero: Character = h
		seen[hero.uid] = true
		if not party_frames.has(hero.uid):
			var f := PartyFrame.new()
			f.hud = self
			f.uid = hero.uid
			f.custom_minimum_size = FRAME_SIZE
			party_box.add_child(f)
			party_frames[hero.uid] = f
	for uid in party_frames.keys():
		if not seen.has(uid):
			(party_frames[uid] as Control).queue_free()
			party_frames.erase(uid)
	for f in party_frames.values():
		(f as Control).queue_redraw()


func _refresh_quests(s: GameSession) -> void:
	var key := str(s.quests) + str(s.quest_order)
	if key == _quest_key:
		return
	_quest_key = key
	for c in quest_box.get_children():
		c.queue_free()
	var shown := 0
	for i in range(s.quest_order.size() - 1, -1, -1):
		var qid := str(s.quest_order[i])
		var stage := str(s.quests.get(qid, ""))
		if Story.is_done_stage(qid, stage) or Story.is_failed_stage(qid, stage):
			continue
		var qd := GameData.quest(qid)
		var sd := Story.stage_def(qid, stage)
		var name := UiTheme.label(str(qd.get("name", qid)), 17, Color("f0dcae"), "bold")
		quest_box.add_child(name)
		var t := UiTheme.label(str(sd.get("objective", sd.get("journal", ""))), 15, UiTheme.TEXT_DIM)
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.custom_minimum_size = Vector2(284, 0)
		quest_box.add_child(t)
		shown += 1
		if shown >= 3:
			break
	if shown == 0:
		quest_box.add_child(UiTheme.label("Нет активных заданий", 15, UiTheme.TEXT_FAINT))


func _refresh_log() -> void:
	if GameLog.lines.size() == _log_size:
		return
	_log_size = GameLog.lines.size()
	var lines: Array = GameLog.lines.slice(maxi(0, GameLog.lines.size() - 30))
	var out := PackedStringArray()
	for i in lines.size():
		var line := str(lines[i]).replace("[", "(").replace("]", ")")
		out.append(line if i >= lines.size() - 3 else "[color=#8a7e6a]%s[/color]" % line)
	if _tip != "":
		out.append("[color=#e8c870]Совет: %s[/color]" % _tip.replace("[", "(").replace("]", ")"))
	log_label.text = "\n".join(out)


# --- Сообщения ------------------------------------------------------------------------

func toast(text: String, color: Color = UiTheme.TEXT, dur := 3.2) -> void:
	var now := Time.get_ticks_msec()
	if int(_toasts_recent.get(text, -100000)) > now - 1500:
		return
	_toasts_recent[text] = now
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UiTheme.frame(Color("15110e"), UiTheme.GOLD_DIM, UiTheme.INK, Color("221a14"), 0.9, 3))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.self_modulate.a = 0.9
	var l := UiTheme.label(text, 16, color)
	if UiTheme.font("body").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x > TOAST_W:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(TOAST_W, 0)
	p.add_child(l)
	toast_box.add_child(p)
	if toast_box.get_child_count() > 3:
		toast_box.get_child(0).queue_free()
	var tw := p.create_tween()
	p.modulate.a = 0.0
	tw.tween_property(p, "modulate:a", 1.0, 0.15)
	tw.tween_interval(dur)
	tw.tween_property(p, "modulate:a", 0.0, 0.5)
	tw.tween_callback(p.queue_free)


func show_banner(text: String, sub := "", color: Color = UiTheme.GOLD, hold := 1.0) -> void:
	banner.text = text
	banner.add_theme_color_override("font_color", color)
	sub_banner.text = sub
	if _banner_tween != null:
		_banner_tween.kill()
	_banner_tween = create_tween()
	banner.modulate.a = 0.0
	sub_banner.modulate.a = 0.0
	banner.scale = Vector2.ONE
	_banner_tween.set_parallel(true)
	_banner_tween.tween_property(banner, "modulate:a", 1.0, 0.15)
	_banner_tween.tween_property(sub_banner, "modulate:a", 1.0 if sub != "" else 0.0, 0.2)
	_banner_tween.chain().tween_interval(hold)
	_banner_tween.chain().tween_property(banner, "modulate:a", 0.0, 0.4)
	_banner_tween.parallel().tween_property(sub_banner, "modulate:a", 0.0, 0.4)


func show_sub_banner(text: String, hold := 0.9) -> void:
	show_banner("", text, UiTheme.GOLD, hold)


## Ход перешёл к другому: «Ваш ход» гаснет сразу, не дожидаясь конца показа.
func hide_sub_banner() -> void:
	if banner.text != "" or sub_banner.modulate.a <= 0.0:
		return
	if _banner_tween != null:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(sub_banner, "modulate:a", 0.0, 0.15)


func show_card(title: String, text: String) -> void:
	card_title.text = title
	card_text.text = text
	if _card_tween != null:
		_card_tween.kill()
	_card_tween = create_tween()
	card_title.modulate.a = 0.0
	card_text.modulate.a = 0.0
	_card_tween.tween_property(card_title, "modulate:a", 1.0, 0.6)
	_card_tween.parallel().tween_property(card_text, "modulate:a", 1.0, 0.9)
	_card_tween.tween_interval(3.0 if text != "" else 2.0)
	_card_tween.tween_property(card_title, "modulate:a", 0.0, 0.8)
	_card_tween.parallel().tween_property(card_text, "modulate:a", 0.0, 0.8)


func add_tip(text: String) -> void:
	if not _tips.has(text) and _tip != text:
		_tips.append(text)
		if _tip == "":
			_tip_t = 0.0


func toggle_help() -> void:
	help_panel.visible = not help_panel.visible


## Подсказка у курсора; пустой текст прячет её.
func set_tooltip(text: String, at: Vector2) -> void:
	if text == "":
		tooltip.visible = false
		return
	if tooltip_label.text != text:
		tooltip_label.text = text
		tooltip.reset_size()
	tooltip.visible = true
	var sz := tooltip.get_combined_minimum_size()
	var vp := get_viewport_rect().size
	var p := at + Vector2(18, 18)
	if p.x + sz.x > vp.x - 4:
		p.x = at.x - sz.x - 12
	if p.y + sz.y > vp.y - 4:
		p.y = at.y - sz.y - 12
	tooltip.position = p.round()


# =========================================================================================

## Портрет героя с полосками здоровья, опыта, ОД и статусами. ЛКМ — выбрать, двойной — лист героя.
class PartyFrame extends Control:
	var hud: Hud
	var uid := ""
	var _portrait: IconArt.PortraitView

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		_portrait = IconArt.PortraitView.new()
		_portrait.position = Vector2(11, 11)
		_portrait.size = Vector2(44, 44)
		add_child(_portrait)

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			hud.screen.call("select_hero", uid, mb.double_click)
			accept_event()

	func _make_tooltip_text() -> String:
		return ""

	func _draw() -> void:
		var s: GameSession = Net.session
		if s == null:
			return
		var h := s.unit_by_uid(uid)
		if h == null:
			return
		var mine := s.owner_of(h) == Net.my_id()
		var current := s.combat != null and s.combat.current == h
		var selected := str(hud.screen.get("selected_uid")) == uid
		var t := float(Time.get_ticks_msec()) / 1000.0
		var border := UiTheme.GOLD if selected else UiTheme.GOLD_DIM
		if current:
			border = Color("f0c860").lerp(Color("fff4c0"), 0.5 + 0.5 * sin(t * 6.0))
		draw_style_box(UiTheme.frame(Color("1d1712"), border, UiTheme.INK, Color("2c231a"), 0.92, 4), Rect2(Vector2.ZERO, size))
		var pr := Rect2(8, 8, 50, 50)
		draw_style_box(UiTheme.slot_box(), pr)
		_portrait.id = h.template_id
		_portrait.dead = not h.is_alive()
		var font := UiTheme.font("bold")
		var body := UiTheme.font("body")
		draw_string(font, Vector2(66, 24), h.display_name, HORIZONTAL_ALIGNMENT_LEFT, 120, 18, UiTheme.TEXT if mine else UiTheme.TEXT_DIM)
		draw_string(body, Vector2(size.x - 52, 24), "ур. %d" % h.level, HORIZONTAL_ALIGNMENT_RIGHT, 44, 15, UiTheme.GOLD)
		var bar := Rect2(66, 30, size.x - 76, 11)
		_bar(bar, h.hp / maxf(1.0, h.max_hp()), UiTheme.HP, UiTheme.HP_BACK)
		draw_string(body, Vector2(bar.position.x + 4, bar.end.y - 1), "%d/%d" % [roundi(h.hp), roundi(h.max_hp())],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("fff0e0"))
		var xp_next := maxi(1, Progression.xp_to_next(h.level))
		_bar(Rect2(66, 44, size.x - 76, 4), float(h.xp) / float(xp_next), UiTheme.XP, Color("1a1a30"))
		var x := 66.0
		if s.mode == "combat" and s.combat != null:
			var max_ap := h.get_int("max_ap")
			for i in max_ap:
				var filled := i < h.ap
				var c := UiTheme.AP if filled else Color("2a3020")
				_pip(Vector2(x + 4, 56), c)
				x += 10.0
			x += 6.0
		for sid in h.statuses:
			IconArt.status_icon(self, str(sid), Rect2(x, 50, 12, 12))
			x += 14.0
		var pts := h.unspent_attribute_points + h.unspent_ability_points + h.unspent_talent_points
		if pts > 0 and mine:
			var badge := Rect2(pr.end.x - 14, pr.position.y - 4, 18, 18)
			var pulse := 0.5 + 0.5 * sin(t * 4.0)
			draw_rect(badge, Color("120c0a"))
			draw_rect(badge.grow(-2), Color("c8a040").lerp(Color("fff0a0"), pulse))
			draw_string(UiTheme.font("title"), badge.position + Vector2(5, 13), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color("120c0a"))
		if not mine and s.players.size() > 1:
			draw_string(body, Vector2(66, size.y - 4), s.player_name(s.owner_of(h)), HORIZONTAL_ALIGNMENT_LEFT, 160, 12, UiTheme.TEXT_FAINT)

	func _bar(r: Rect2, k: float, fill: Color, back: Color) -> void:
		draw_rect(r.grow(1.0), Color("0b0807"))
		draw_rect(r, back)
		var w := roundf(r.size.x * clampf(k, 0.0, 1.0))
		draw_rect(Rect2(r.position, Vector2(w, r.size.y)), fill)
		draw_rect(Rect2(r.position, Vector2(w, maxf(1.0, roundf(r.size.y * 0.3)))), fill.lightened(0.25))

	func _pip(c: Vector2, col: Color) -> void:
		var pts := PackedVector2Array([c + Vector2(0, -4), c + Vector2(4, 0), c + Vector2(0, 4), c + Vector2(-4, 0)])
		draw_colored_polygon(pts, Color("0b0807"))
		var inner := PackedVector2Array([c + Vector2(0, -3), c + Vector2(3, 0), c + Vector2(0, 3), c + Vector2(-3, 0)])
		draw_colored_polygon(inner, col)


## Очередь ходов в бою: портреты по порядку, текущий крупнее.
class TurnBar extends Control:
	var hud: Hud
	var _views: Array = []

	func _ready() -> void:
		for i in 10:
			var v := IconArt.PortraitView.new()
			v.visible = false
			add_child(v)
			_views.append(v)

	func _process(_delta: float) -> void:
		var s: GameSession = Net.session
		var order := _order(s)
		var n := mini(order.size(), _views.size())
		var w := 44.0 + maxf(0.0, n - 1) * 40.0
		var x := (size.x - w) * 0.5
		for i in _views.size():
			var v: IconArt.PortraitView = _views[i]
			v.visible = i < n
			if i >= n:
				continue
			var sz := 44.0 if i == 0 else 34.0
			v.position = Vector2(x, 4.0 if i == 0 else 9.0) + Vector2(2, 2)
			v.size = Vector2(sz - 4, sz - 4)
			v.id = (order[i] as Character).template_id
			x += sz + 6.0
		queue_redraw()

	func _order(s: GameSession) -> Array:
		var order: Array = []
		if s == null or s.combat == null:
			return order
		var cm := s.combat
		for i in range(maxi(0, cm.turn_index), cm.turn_order.size()):
			var u: Character = cm.turn_order[i]
			if u.is_alive():
				order.append(u)
		return order

	func _draw() -> void:
		var s: GameSession = Net.session
		if s == null or s.combat == null:
			return
		var cm := s.combat
		var order: Array = []
		for i in range(maxi(0, cm.turn_index), cm.turn_order.size()):
			var u: Character = cm.turn_order[i]
			if u.is_alive():
				order.append(u)
		var t := float(Time.get_ticks_msec()) / 1000.0
		var n := mini(order.size(), 10)
		var w := 44.0 + (n - 1) * 40.0
		var x := (size.x - w) * 0.5
		var body := UiTheme.font("body")
		draw_string(body, Vector2(0, size.y - 2), "Раунд %d" % cm.round_number, HORIZONTAL_ALIGNMENT_CENTER, size.x, 14, UiTheme.TEXT_DIM)
		for i in n:
			var u: Character = order[i]
			var big := i == 0
			var sz := 44.0 if big else 34.0
			var r := Rect2(x, 4.0 if big else 9.0, sz, sz)
			var hero := s.heroes.has(u)
			var col := Color("5a8ad8") if hero else Color("c84a3a")
			if big:
				col = col.lerp(Color("fff0c0"), 0.4 + 0.3 * sin(t * 5.0))
			draw_rect(r.grow(2.0), Color("0b0807"))
			draw_rect(r.grow(1.0), col)
			draw_rect(r, Color("1a1410"))
			var hb := Rect2(r.position.x, r.end.y + 2, sz, 3)
			draw_rect(hb, Color("3a1410"))
			draw_rect(Rect2(hb.position, Vector2(roundf(sz * clampf(u.hp / maxf(1.0, u.max_hp()), 0, 1)), 3)), Color("6ac04a") if hero else Color("d0402c"))
			x += sz + 6.0


## Панель действий: навыки (1–9) и расходники. В бою — ОД и стоимость; вне боя навыки только для справки.
class ActionBar extends Control:
	var hud: Hud
	var slots: Array = []     # [{"rect", "kind": "skill"|"item"|"move", "id"}]
	var hover_index := -1

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		var mm := event as InputEventMouseMotion
		if mm != null:
			hover_index = _slot_at(mm.position)
			hud.screen.call("set_bar_hover", slots[hover_index] if hover_index >= 0 else {})
			return
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var i := _slot_at(mb.position)
			if i >= 0:
				hud.screen.call("activate_slot", slots[i])
			accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT:
			hover_index = -1
			if hud != null:
				hud.screen.call("set_bar_hover", {})

	func _slot_at(p: Vector2) -> int:
		for i in slots.size():
			if Rect2(slots[i]["rect"]).has_point(p):
				return i
		return -1

	func _draw() -> void:
		slots.clear()
		var s: GameSession = Net.session
		if s == null:
			return
		var u: Character = hud.screen.call("bar_unit")
		if u == null:
			return
		var my_turn := bool(hud.screen.call("is_my_turn"))
		var in_combat := s.mode == "combat"
		var sel_skill := str(hud.screen.get("selected_skill"))
		var sel_item := str(hud.screen.get("selected_item"))
		var preview_ap := int(hud.screen.call("preview_ap_cost"))
		var t := float(Time.get_ticks_msec()) / 1000.0
		var items: Array = []
		for it in s.items:
			var def := GameData.item(str(it))
			if def.has("use") or def.has("effect"):
				items.append(str(it))
		var n_sk := mini(u.skills.size(), 9)
		var total := n_sk + items.size()
		var w := total * (Hud.SLOT + 4) + (12 if not items.is_empty() else 0)
		var x0 := roundf((size.x - w) * 0.5)
		var y0 := 24.0
		# фон
		draw_style_box(UiTheme.frame(Color("15110e"), UiTheme.GOLD_DIM, UiTheme.INK, Color("221a14"), 0.85, 4),
			Rect2(x0 - 10, y0 - 8, w + 16, Hud.SLOT + 16))
		# ОД
		if in_combat:
			var max_ap := u.get_int("max_ap")
			var ax := roundf(size.x * 0.5 - max_ap * 7.0)
			for i in max_ap:
				var col := Color("2a3020")
				if i < u.ap:
					col = UiTheme.AP
					if my_turn and preview_ap > 0 and i >= u.ap - preview_ap:
						col = Color("f0d050").lerp(Color("fff8c0"), 0.5 + 0.5 * sin(t * 8.0))
				_pip(Vector2(ax + i * 14.0 + 7.0, 10.0), col)
			if my_turn and preview_ap > u.ap:
				draw_string(UiTheme.font("body"), Vector2(ax + max_ap * 14.0 + 10.0, 15.0), "не хватает ОД",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, UiTheme.RED)
		var x := x0
		var body := UiTheme.font("body")
		var title := UiTheme.font("title")
		for i in n_sk:
			var sk := str(u.skills[i])
			var def := GameData.skill(sk)
			var r := Rect2(x, y0, Hud.SLOT, Hud.SLOT)
			var cd := int(u.cooldowns.get(sk, 0))
			var cost := int(def.get("ap", 0))
			var usable := in_combat and my_turn and cd <= 0 and cost <= u.ap
			var active := sel_skill == sk
			_slot(r, active, i == hover_index)
			IconArt.skill_icon(self, sk, r.grow(-6), not usable and in_combat)
			if not in_combat:
				draw_rect(r.grow(-3), Color(0, 0, 0, 0.35))
			draw_string(title, r.position + Vector2(4, 12), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, UiTheme.TEXT_DIM)
			draw_string(body, Vector2(r.end.x - 4, r.end.y - 3), str(cost), HORIZONTAL_ALIGNMENT_RIGHT, -1, 14,
				UiTheme.AP if cost <= u.ap else UiTheme.RED)
			if cd > 0:
				draw_rect(r.grow(-3), Color(0, 0, 0, 0.55))
				draw_string(title, r.get_center() + Vector2(-4, 6), str(cd), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, UiTheme.TEXT)
			slots.append({"rect": r, "kind": "skill", "id": sk, "index": i})
			x += Hud.SLOT + 4
		if not items.is_empty():
			x += 12
			draw_rect(Rect2(x - 9, y0 + 4, 2, Hud.SLOT - 8), UiTheme.GOLD_DIM)
			for it in items:
				var r := Rect2(x, y0, Hud.SLOT, Hud.SLOT)
				_slot(r, sel_item == it, slots.size() == hover_index)
				IconArt.item_icon(self, str(it), r.grow(-7))
				draw_string(body, Vector2(r.end.x - 4, r.end.y - 3), str(int(s.items[it])), HORIZONTAL_ALIGNMENT_RIGHT, -1, 14, UiTheme.TEXT)
				slots.append({"rect": r, "kind": "item", "id": str(it)})
				x += Hud.SLOT + 4
		if in_combat and not my_turn and s.combat != null and s.combat.current != null:
			var cur := s.combat.current
			var who := cur.display_name
			var txt := "Ходит %s" % who if s.heroes.has(cur) else "Ход врага: %s" % who
			draw_string(UiTheme.font("bold"), Vector2(0, y0 - 12), txt, HORIZONTAL_ALIGNMENT_CENTER, size.x, 16, UiTheme.TEXT_DIM)

	func _slot(r: Rect2, active: bool, hovered: bool) -> void:
		var border := Color("5a4630")
		if hovered:
			border = UiTheme.GOLD
		if active:
			border = Color("fff0a0")
		draw_style_box(UiTheme.slot_box(border), r)

	func _pip(c: Vector2, col: Color) -> void:
		var pts := PackedVector2Array([c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0)])
		draw_colored_polygon(pts, Color("0b0807"))
		var inner := PackedVector2Array([c + Vector2(0, -3), c + Vector2(3, 0), c + Vector2(0, 3), c + Vector2(-3, 0)])
		draw_colored_polygon(inner, col)

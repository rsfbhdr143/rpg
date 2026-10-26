extends Node2D
## Временная отладочная визуализация: исследование, бой, экран персонажа.
## Вся логика — в scripts/core, combat, world, net; состояние приходит из Net.session
## (на сервере — живое, у клиента — снимок). Действия уходят командами Net.send_command().
##
## Управление:
##   Исследование: ЛКМ по клетке — идти выбранным героем, ЛКМ по своему герою — выбрать,
##                 Tab — следующий свой герой. Клетки-выходы подсвечены жёлтым.
##   Бой (ваш ход): ЛКМ — идти / применить навык, 1..9 — навык, 0 — перемещение, Пробел — конец хода.
##   Везде: C — экран персонажа, K — сохранить, L — загрузить (лидер), R — после поражения,
##          Esc — закрыть экран персонажа / отменить навык, F10 — выйти в меню.

const ORIGIN := Vector2(16, 16)
const MAP_AREA := Vector2(860, 688)
const MENU_SCENE := "res://scenes/menu.tscn"
const SHEET_RECT := Rect2(30, 30, 900, 660)

var session: GameSession
var grid: SurfaceGrid
var combat: CombatManager
var cell_size := 48
var selected_uid := ""
var selected_skill := ""
var hovered := Vector2i(-1, -1)
var sheet_open := false
var _font: Font
var _notice := ""
var _last_current := ""
var _buttons: Array = []   # [{"rect": Rect2, "cmd": Dictionary}] — кнопки экрана персонажа


func _ready() -> void:
	GameData.ensure_loaded()
	_font = ThemeDB.fallback_font
	Net.notice.connect(_on_notice)
	Net.disconnected.connect(_on_disconnected)
	_sync()


## Берём актуальное состояние (клиент получает новые объекты с каждым снимком).
func _sync() -> void:
	session = Net.session
	if session == null or session.grid == null:
		grid = null
		return
	grid = session.grid
	combat = session.combat
	cell_size = clampi(mini(int(MAP_AREA.x) / grid.width, int(MAP_AREA.y) / grid.height), 16, 48)
	var cur_uid: String = combat.current.uid if combat != null and combat.current != null else ""
	if cur_uid != _last_current:
		_last_current = cur_uid
		selected_skill = ""
	var mine := session.heroes_of(Net.my_id())
	var sel := session.unit_by_uid(selected_uid)
	if (sel == null or not mine.has(sel)) and not mine.is_empty():
		selected_uid = mine[0].uid


func _process(_delta: float) -> void:
	_sync()
	queue_redraw()


func _on_notice(text: String) -> void:
	_notice = text


func _on_disconnected(_reason: String) -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


func _send(cmd: Dictionary) -> void:
	_notice = ""
	Net.send_command(cmd)


func _is_my_combat_turn() -> bool:
	return session.mode == "combat" and combat != null and combat.active and combat.current != null \
		and session.owner_of(combat.current) == Net.my_id()


## Чей лист персонажа показываем: в бою — текущего, иначе — выбранного героя.
func _sheet_unit() -> Character:
	if session.mode == "combat" and combat != null and combat.current != null and session.heroes.has(combat.current):
		return combat.current
	return session.unit_by_uid(selected_uid)


# --- Ввод ---------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if grid == null:
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		hovered = _cell_at(motion.position)
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_on_click(mb.position)
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	_on_key(key.keycode)


func _on_key(k: Key) -> void:
	match k:
		KEY_F10:
			Net.leave()
		KEY_C:
			sheet_open = not sheet_open
		KEY_ESCAPE:
			if sheet_open:
				sheet_open = false
			else:
				selected_skill = ""
		KEY_K:
			_send({"type": "save"})
		KEY_L:
			_send({"type": "load"})
		KEY_R:
			if session.mode == "defeat":
				_send({"type": "restart"})
		KEY_TAB:
			var mine := session.heroes_of(Net.my_id())
			if not mine.is_empty():
				var idx := mine.find(session.unit_by_uid(selected_uid))
				selected_uid = mine[(idx + 1) % mine.size()].uid
		_:
			if _is_my_combat_turn():
				_on_combat_key(k)


func _on_combat_key(k: Key) -> void:
	var u := combat.current
	if k == KEY_SPACE:
		selected_skill = ""
		_send({"type": "end_turn"})
	elif k == KEY_0:
		selected_skill = ""
	elif k >= KEY_1 and k <= KEY_9:
		var idx: int = k - KEY_1
		if idx < u.skills.size():
			selected_skill = u.skills[idx]
			var def := GameData.skill(selected_skill)
			if str(def.get("target", "")) == "self":   # навыки на себя применяются сразу
				_send({"type": "skill", "skill": selected_skill, "cell": [u.cell.x, u.cell.y]})
				selected_skill = ""


func _on_click(pos: Vector2) -> void:
	if sheet_open:
		for b in _buttons:
			if Rect2(b["rect"]).has_point(pos):
				_send(b["cmd"])
				return
		if SHEET_RECT.has_point(pos):
			return
	var c := _cell_at(pos)
	if not grid.in_bounds(c):
		return
	if session.mode == "explore":
		var u := session.unit_at(c)
		if u != null and session.owner_of(u) == Net.my_id() and session.heroes.has(u):
			selected_uid = u.uid
		elif selected_uid != "":
			_send({"type": "move", "unit": selected_uid, "cell": [c.x, c.y]})
	elif _is_my_combat_turn():
		if selected_skill == "":
			_send({"type": "move", "unit": combat.current.uid, "cell": [c.x, c.y]})
		else:
			_send({"type": "skill", "skill": selected_skill, "cell": [c.x, c.y]})
			selected_skill = ""


func _cell_at(p: Vector2) -> Vector2i:
	var local := (p - ORIGIN) / cell_size
	return Vector2i(floori(local.x), floori(local.y))


func _cell_rect(c: Vector2i) -> Rect2:
	return Rect2(ORIGIN + Vector2(c) * cell_size, Vector2(cell_size, cell_size))


# --- Отрисовка ----------------------------------------------------------------

func _text(pos: Vector2, s: String, col := Color.WHITE, size := 14) -> void:
	draw_string(_font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), Color(0.08, 0.08, 0.1))
	if grid == null:
		_text(Vector2(40, 40), "Ожидание состояния от сервера...")
		return
	_buttons.clear()
	_draw_grid()
	_draw_units()
	_draw_panel()
	if sheet_open:
		_draw_sheet()


func _draw_grid() -> void:
	var cur: Character = combat.current if combat != null else null
	var skill_def: Dictionary = GameData.skill(selected_skill) if selected_skill != "" else {}
	for y in grid.height:
		for x in grid.width:
			var c := Vector2i(x, y)
			var r := _cell_rect(c)
			var col := Color(0.22, 0.24, 0.2)
			if grid.blocked.has(c):
				col = Color(0.1, 0.1, 0.1)
			else:
				var g := grid.get_ground(c)
				if g != "none":
					col = Color.html(str(GameData.surface(g).get("color", "#ff00ff")))
			draw_rect(r, col)
			var cl := grid.get_cloud(c)
			if cl != "none":
				var cc := Color.html(str(GameData.surface(cl).get("color", "#ffffff")))
				cc.a = 0.45
				draw_rect(r.grow(-cell_size * 0.12), cc)
			if not session.exit_at(c).is_empty():
				draw_rect(r.grow(-2), Color(1.0, 0.85, 0.2, 0.5), false, 3.0)
			if cur != null and not skill_def.is_empty() and _is_my_combat_turn():
				if SurfaceGrid.distance(cur.cell, c) <= SkillSystem.skill_range(cur, skill_def):
					draw_rect(r, Color(1, 1, 0.3, 0.12))
			draw_rect(r, Color(0, 0, 0, 0.35), false, 1.0)
	if grid.in_bounds(hovered):
		draw_rect(_cell_rect(hovered), Color(1, 1, 1, 0.8), false, 2.0)


func _draw_units() -> void:
	var cur: Character = combat.current if combat != null else null
	for u in session.all_units():
		var ch: Character = u
		if not ch.is_alive():
			continue
		var r := _cell_rect(ch.cell)
		var center := r.get_center()
		var is_hero := session.heroes.has(ch)
		# радиус, с которого враги замечают партию
		if session.mode == "explore" and not is_hero:
			var tr := session.trigger_radius(ch.encounter_id)
			if tr > 0:
				draw_arc(center, (tr + 0.5) * cell_size, 0.0, TAU, 48, Color(1, 0.3, 0.3, 0.25), 1.0)
		if ch == cur:
			draw_circle(center, cell_size * 0.46, Color(1, 1, 0.4))
		elif is_hero and ch.uid == selected_uid and session.mode != "combat":
			draw_circle(center, cell_size * 0.46, Color(1, 1, 1))
		var col: Color = Color(0.3, 0.6, 1.0) if is_hero else Color(0.9, 0.3, 0.3)
		draw_circle(center, cell_size * 0.38, col)
		draw_string(_font, center + Vector2(-cell_size * 0.13, cell_size * 0.13), ch.display_name.substr(0, 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(cell_size * 0.38))
		var hp_ratio := ch.hp / ch.max_hp()
		draw_rect(Rect2(r.position + Vector2(3, cell_size - 6), Vector2((cell_size - 6) * hp_ratio, 3)), Color(0.2, 0.9, 0.3))
		if not ch.statuses.is_empty():
			draw_circle(r.position + Vector2(cell_size - 6, 6), 3, Color(1, 0.6, 0.1))


func _draw_panel() -> void:
	var x := ORIGIN.x + grid.width * cell_size + 20
	var y := 30.0
	var loc_name := str(session.location_data().get("name", session.location_id))
	_text(Vector2(x, y), "%s — %s" % [loc_name, _mode_name()], Color.YELLOW, 16)
	y += 24
	if session.mode == "combat" and combat != null and combat.current != null:
		y = _draw_combat_panel(x, y)
	else:
		y = _draw_explore_panel(x, y)
	if _notice != "":
		_text(Vector2(x, y), "Нельзя: " + _notice, Color(1, 0.5, 0.4))
		y += 18
	y += 8
	if grid.in_bounds(hovered):
		var info := "Клетка %s: %s / %s" % [str(hovered), _surface_name(grid.get_ground(hovered)), _surface_name(grid.get_cloud(hovered))]
		var ex := session.exit_at(hovered)
		if not ex.is_empty():
			info += " | выход: " + str(ex.get("name", ex.get("to", "")))
		var hu := session.unit_at(hovered)
		if hu != null:
			info += " | %s ОЗ %d/%d [%s]" % [hu.display_name, hu.hp, hu.max_hp(), _statuses_text(hu)]
		_text(Vector2(x, y), info, Color(0.8, 0.9, 1.0), 13)
		y += 22
	var log_lines: Array = GameLog.lines.slice(maxi(0, GameLog.lines.size() - 20))
	for line in log_lines:
		_text(Vector2(x, y), str(line), Color(0.85, 0.85, 0.85), 13)
		y += 17


func _mode_name() -> String:
	match session.mode:
		"combat":
			return "бой, раунд %d" % (combat.round_number if combat != null else 0)
		"defeat":
			return "поражение (R — ко входу)"
	return "исследование"


func _draw_explore_panel(x: float, y: float) -> float:
	_text(Vector2(x, y), "Ваши герои (Tab — переключить):")
	y += 18
	for h in session.heroes_of(Net.my_id()):
		var ch: Character = h
		var mark: String = "> " if ch.uid == selected_uid else "   "
		var pts := ch.unspent_attribute_points + ch.unspent_ability_points + ch.unspent_talent_points
		var extra: String = "  (+%d очков, C)" % pts if pts > 0 else ""
		_text(Vector2(x, y), "%s%s ур.%d  ОЗ %d/%d%s" % [mark, ch.display_name, ch.level, ch.hp, ch.max_hp(), extra])
		y += 18
	var others: Array = session.heroes.filter(func(h): return session.owner_of(h) != Net.my_id())
	for h in others:
		_text(Vector2(x, y), "   %s — %s" % [h.display_name, session.player_name(session.owner_of(h))], Color(0.7, 0.7, 0.7))
		y += 18
	y += 4
	_text(Vector2(x, y), "ЛКМ — идти, жёлтые клетки — выходы, C — персонаж", Color(0.7, 0.7, 0.7), 13)
	y += 16
	_text(Vector2(x, y), "K — сохранить, L — загрузить, F10 — меню", Color(0.7, 0.7, 0.7), 13)
	return y + 20


func _draw_combat_panel(x: float, y: float) -> float:
	var u := combat.current
	_text(Vector2(x, y), "Ход: %s [%s]" % [u.describe(), session.player_name(session.owner_of(u))], Color.YELLOW)
	y += 20
	_text(Vector2(x, y), "ОЗ %d/%d   ОД %d/%d (+%d)   Броня %d" % [
		u.hp, u.max_hp(), u.ap, u.get_int("max_ap"), u.get_int("ap_recovery"), DamageCalc.effective_armor(u)])
	y += 20
	_text(Vector2(x, y), "Статусы: " + _statuses_text(u))
	y += 22
	if not _is_my_combat_turn():
		_text(Vector2(x, y), "Ходит другой игрок или ИИ...", Color(0.7, 0.7, 0.7))
		return y + 22
	_text(Vector2(x, y), "[0] Перемещение" + ("  <" if selected_skill == "" else ""))
	y += 18
	for i in u.skills.size():
		var sk: String = u.skills[i]
		var def := GameData.skill(sk)
		var cd := ""
		if u.cooldowns.has(sk):
			cd = "  (перезарядка %d)" % int(u.cooldowns[sk])
		var mark: String = "  <" if sk == selected_skill else ""
		var col: Color = Color.WHITE if int(def.get("ap", 0)) <= u.ap and cd == "" else Color(0.55, 0.55, 0.55)
		_text(Vector2(x, y), "[%d] %s — %d ОД%s%s" % [i + 1, def.get("name", sk), int(def.get("ap", 0)), cd, mark], col)
		y += 18
	_text(Vector2(x, y), "Пробел — конец хода", Color(0.7, 0.7, 0.7))
	return y + 22


# --- Экран персонажа ----------------------------------------------------------

func _draw_sheet() -> void:
	var h := _sheet_unit()
	draw_rect(SHEET_RECT, Color(0.05, 0.05, 0.07, 0.96))
	draw_rect(SHEET_RECT, Color(0.6, 0.6, 0.7), false, 2.0)
	if h == null:
		_text(SHEET_RECT.position + Vector2(20, 30), "Нет выбранного героя.")
		return
	var editable := session.owner_of(h) == Net.my_id() and session.mode != "combat"
	var x1 := SHEET_RECT.position.x + 20
	var x2 := SHEET_RECT.position.x + 460
	var y := SHEET_RECT.position.y + 30
	_text(Vector2(x1, y), "%s — уровень %d, опыт %d/%d" % [h.display_name, h.level, h.xp, Progression.xp_to_next(h.level)], Color.YELLOW, 16)
	_text(Vector2(x2 + 200, y), "C / Esc — закрыть", Color(0.6, 0.6, 0.6), 12)
	y += 22
	_text(Vector2(x1, y), "Свободные очки: атрибуты %d, способности %d, таланты %d" % [
		h.unspent_attribute_points, h.unspent_ability_points, h.unspent_talent_points])
	if not editable:
		_text(Vector2(x2 + 60, y), "(только просмотр)", Color(0.6, 0.6, 0.6), 12)
	y += 26
	var top := y

	# Левая колонка: атрибуты, производные, таланты
	y = _sheet_header(x1, y, "Атрибуты")
	var names: Dictionary = GameData.rule("attribute_names", {})
	for a in GameData.attribute_list():
		var can := editable and Progression.can_raise_attribute(h, a)
		y = _sheet_row(x1, y, "%s %d" % [names.get(a, a), int(h.attributes[a])], can,
			{"type": "raise_attribute", "unit": h.uid, "attribute": a})
	y += 6
	_text(Vector2(x1, y), "ОЗ %d/%d   ОД макс %d, +%d за ход   Инициатива %d" % [
		h.hp, h.max_hp(), h.get_int("max_ap"), h.get_int("ap_recovery"), h.get_int("initiative")], Color(0.8, 0.8, 0.8), 13)
	y += 16
	_text(Vector2(x1, y), "Броня %d   Точность %d   Уклонение %d   Крит %d%%" % [
		DamageCalc.effective_armor(h), h.get_int("accuracy"), h.get_int("dodge"), h.get_int("crit_chance")], Color(0.8, 0.8, 0.8), 13)
	y += 16
	var res: Array = []
	for r in GameData.rule("resistances", []):
		res.append("%s %d" % [r, h.get_resistance(r)])
	_text(Vector2(x1, y), "Сопротивления: " + ", ".join(res), Color(0.8, 0.8, 0.8), 13)
	y += 24

	y = _sheet_header(x1, y, "Таланты")
	for t in h.talents:
		_text(Vector2(x1 + 30, y), str(GameData.talent(t).get("name", t)), Color(0.7, 1.0, 0.7), 13)
		y += 16
	for t in GameData.talents:
		if h.talents.has(t):
			continue
		var reason := Progression.talent_block_reason(h, t)
		var label := "%s — %s" % [GameData.talent(t).get("name", t), GameData.talent(t).get("description", "")]
		if reason != "" and reason != "нет очков талантов":
			label += " (%s)" % reason
		y = _sheet_row(x1, y, label, editable and reason == "", {"type": "learn_talent", "unit": h.uid, "talent": t})

	# Правая колонка: способности и навыки
	y = top
	y = _sheet_header(x2, y, "Способности (ранг, цена следующего)")
	for ab in GameData.abilities:
		var rank := h.ability_rank(ab)
		var label := "%s %d  (%d)" % [GameData.ability(ab).get("name", ab), rank, Progression.ability_cost(rank + 1)]
		y = _sheet_row(x2, y, label, editable and Progression.can_raise_ability(h, ab),
			{"type": "raise_ability", "unit": h.uid, "ability": ab})
	y += 8
	y = _sheet_header(x2, y, "Навыки")
	var known: Array = []
	for sk in h.skills:
		known.append(str(GameData.skill(sk).get("name", sk)))
	_text(Vector2(x2 + 30, y), ", ".join(known), Color(0.7, 1.0, 0.7), 12)
	y += 18
	for sk in GameData.skills:
		if h.skills.has(sk) or Progression.skill_block_reason(h, sk) != "":
			continue
		y = _sheet_row(x2, y, "Выучить: " + str(GameData.skill(sk).get("name", sk)), editable,
			{"type": "learn_skill", "unit": h.uid, "skill": sk})


func _sheet_header(x: float, y: float, title: String) -> float:
	_text(Vector2(x, y), title, Color(0.9, 0.8, 0.5), 14)
	return y + 18


## Строка с кнопкой «+». Возвращает новую координату y.
func _sheet_row(x: float, y: float, label: String, enabled: bool, cmd: Dictionary) -> float:
	var btn := Rect2(x, y - 12, 22, 16)
	if enabled:
		draw_rect(btn, Color(0.25, 0.5, 0.25))
		_text(Vector2(x + 6, y), "+", Color.WHITE, 13)
		_buttons.append({"rect": Rect2(x, y - 12, 420, 16), "cmd": cmd})
	else:
		draw_rect(btn, Color(0.2, 0.2, 0.2))
	_text(Vector2(x + 30, y), label, Color.WHITE if enabled else Color(0.65, 0.65, 0.65), 13)
	return y + 17


func _statuses_text(u: Character) -> String:
	var parts: Array = []
	for id in u.statuses:
		parts.append("%s(%d)" % [GameData.status(id).get("name", id), int(u.statuses[id]["turns"])])
	return "—" if parts.is_empty() else ", ".join(parts)


func _surface_name(id: String) -> String:
	if id == "none":
		return "—"
	return str(GameData.surface(id).get("name", id))

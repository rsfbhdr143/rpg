extends Node2D
## Временная отладочная визуализация боя. Вся логика — в scripts/core, combat, world;
## состояние приходит из Net.session (на сервере — живое, у клиента — снимок).
## Действия отправляются командами через Net.send_command().
## Управление (когда ходит ваш персонаж):
##   ЛКМ по клетке — идти / применить выбранный навык
##   1..9 — выбрать навык, 0 или Esc — режим перемещения
##   Пробел — закончить ход, R — новый бой после победы/поражения, F10 — выйти в меню

const CELL := 48
const ORIGIN := Vector2(16, 16)
const MENU_SCENE := "res://scenes/menu.tscn"

var grid: SurfaceGrid
var combat: CombatManager
var heroes: Array = []
var selected_skill := ""
var hovered := Vector2i(-1, -1)
var _font: Font
var _notice := ""
var _last_current := ""


func _ready() -> void:
	GameData.ensure_loaded()
	_font = ThemeDB.fallback_font
	Net.notice.connect(_on_notice)
	Net.disconnected.connect(_on_disconnected)
	_sync()


## Берём актуальное состояние из сессии (клиент получает новый объект боя с каждым снимком).
func _sync() -> void:
	if Net.session == null or Net.session.combat == null:
		return
	combat = Net.session.combat
	grid = combat.grid
	heroes = Net.session.heroes
	var cur_uid: String = combat.current.uid if combat.current != null else ""
	if cur_uid != _last_current:
		_last_current = cur_uid
		selected_skill = ""
		_notice = ""


func _process(_delta: float) -> void:
	_sync()
	queue_redraw()


func _on_notice(text: String) -> void:
	_notice = text


func _on_disconnected(_reason: String) -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


func _is_player_turn() -> bool:
	return combat != null and combat.active and combat.current != null \
		and Net.session.owner_of(combat.current) == Net.my_id()


func _send(cmd: Dictionary) -> void:
	_notice = ""
	Net.send_command(cmd)


func _unhandled_input(event: InputEvent) -> void:
	if combat == null:
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		hovered = _cell_at(motion.position)
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_on_click(_cell_at(mb.position))
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var k := key.keycode
	if k == KEY_F10:
		Net.leave()
		return
	if k == KEY_R and not combat.active:
		_send({"type": "restart"})
		return
	if not _is_player_turn():
		return
	if k == KEY_SPACE:
		selected_skill = ""
		_send({"type": "end_turn"})
	elif k == KEY_0 or k == KEY_ESCAPE:
		selected_skill = ""
	elif k >= KEY_1 and k <= KEY_9:
		var idx: int = k - KEY_1
		var u := combat.current
		if idx < u.skills.size():
			selected_skill = u.skills[idx]
			var def := GameData.skill(selected_skill)
			if str(def.get("target", "")) == "self":   # навыки на себя применяются сразу
				_send({"type": "skill", "skill": selected_skill, "cell": [u.cell.x, u.cell.y]})
				selected_skill = ""


func _on_click(c: Vector2i) -> void:
	if not _is_player_turn() or not grid.in_bounds(c):
		return
	if selected_skill == "":
		_send({"type": "move", "cell": [c.x, c.y]})
	else:
		_send({"type": "skill", "skill": selected_skill, "cell": [c.x, c.y]})
		selected_skill = ""


func _cell_at(p: Vector2) -> Vector2i:
	var local := (p - ORIGIN) / CELL
	return Vector2i(floori(local.x), floori(local.y))


func _cell_rect(c: Vector2i) -> Rect2:
	return Rect2(ORIGIN + Vector2(c) * CELL, Vector2(CELL, CELL))


# --- Отрисовка ----------------------------------------------------------------

func _draw() -> void:
	if combat == null:
		_text(Vector2(40, 40), "Ожидание состояния от сервера...")
		return
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), Color(0.08, 0.08, 0.1))
	_draw_grid()
	_draw_units()
	_draw_panel()


func _draw_grid() -> void:
	var cur := combat.current
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
				draw_rect(r.grow(-6), cc)
			# подсветка дальности выбранного навыка
			if cur != null and not skill_def.is_empty() and _is_player_turn():
				if SurfaceGrid.distance(cur.cell, c) <= SkillSystem.skill_range(cur, skill_def):
					draw_rect(r, Color(1, 1, 0.3, 0.12))
			draw_rect(r, Color(0, 0, 0, 0.35), false, 1.0)
	if grid.in_bounds(hovered):
		draw_rect(_cell_rect(hovered), Color(1, 1, 1, 0.8), false, 2.0)


func _draw_units() -> void:
	for u in combat.units:
		var ch: Character = u
		if not ch.is_alive():
			continue
		var r := _cell_rect(ch.cell)
		var center := r.get_center()
		var col: Color = Color(0.3, 0.6, 1.0) if ch.faction == "player" else Color(0.9, 0.3, 0.3)
		if ch == combat.current:
			draw_circle(center, CELL * 0.45, Color(1, 1, 0.4))
		draw_circle(center, CELL * 0.38, col)
		draw_string(_font, center + Vector2(-6, 6), ch.display_name.substr(0, 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
		var hp_ratio := ch.hp / ch.max_hp()
		draw_rect(Rect2(r.position + Vector2(4, CELL - 7), Vector2((CELL - 8) * hp_ratio, 4)), Color(0.2, 0.9, 0.3))
		if not ch.statuses.is_empty():
			draw_circle(r.position + Vector2(CELL - 7, 7), 4, Color(1, 0.6, 0.1))


func _text(pos: Vector2, s: String, col := Color.WHITE, size := 14) -> void:
	draw_string(_font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_panel() -> void:
	var x := int(ORIGIN.x) + grid.width * CELL + 24
	var y := 30.0
	if not combat.active:
		_text(Vector2(x, y), "Бой окончен. Победа: %s. R — новый бой." % combat.winner_faction, Color.YELLOW, 16)
		y += 24
		for h in heroes:
			var ch: Character = h
			_text(Vector2(x, y), "%s ур.%d  опыт %d/%d  очки: атр %d, спос %d, тал %d" % [
				ch.display_name, ch.level, ch.xp, Progression.xp_to_next(ch.level),
				ch.unspent_attribute_points, ch.unspent_ability_points, ch.unspent_talent_points])
			y += 20
	else:
		var u := combat.current
		if u != null:
			_text(Vector2(x, y), "Раунд %d — ход: %s [%s]" % [
				combat.round_number, u.describe(), Net.session.player_name(Net.session.owner_of(u))], Color.YELLOW, 16)
			y += 22
			_text(Vector2(x, y), "ОЗ %d/%d   ОД %d/%d (+%d)   Броня %d" % [
				u.hp, u.max_hp(), u.ap, u.get_int("max_ap"), u.get_int("ap_recovery"), DamageCalc.effective_armor(u)])
			y += 20
			_text(Vector2(x, y), "Статусы: " + _statuses_text(u))
			y += 24
			if _is_player_turn():
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
				y += 18
			else:
				_text(Vector2(x, y), "Ходит другой игрок или ИИ...", Color(0.7, 0.7, 0.7))
				y += 18
	if _notice != "":
		_text(Vector2(x, y), "Нельзя: " + _notice, Color(1, 0.5, 0.4))
		y += 18
	y += 10
	if grid.in_bounds(hovered):
		var info := "Клетка %s: %s / %s" % [str(hovered), _surface_name(grid.get_ground(hovered)), _surface_name(grid.get_cloud(hovered))]
		var hu := combat.unit_at(hovered)
		if hu != null:
			info += " | %s ОЗ %d/%d [%s]" % [hu.display_name, hu.hp, hu.max_hp(), _statuses_text(hu)]
		_text(Vector2(x, y), info, Color(0.8, 0.9, 1.0), 13)
		y += 22
	# журнал
	var log_lines: Array = GameLog.lines.slice(maxi(0, GameLog.lines.size() - 22))
	for line in log_lines:
		_text(Vector2(x, y), str(line), Color(0.85, 0.85, 0.85), 13)
		y += 17


func _statuses_text(u: Character) -> String:
	var parts: Array = []
	for id in u.statuses:
		parts.append("%s(%d)" % [GameData.status(id).get("name", id), int(u.statuses[id]["turns"])])
	return "—" if parts.is_empty() else ", ".join(parts)


func _surface_name(id: String) -> String:
	if id == "none":
		return "—"
	return str(GameData.surface(id).get("name", id))

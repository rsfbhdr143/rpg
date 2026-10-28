extends Control
## Экран игры. Мир (WorldView) рисуется в маленьком SubViewport и увеличивается без сглаживания,
## интерфейс (Hud, DialogueBox, окна) — поверх в полном разрешении.
## Состояние берётся из Net.session (у хоста — живая сессия, у клиента — зеркало со снимка),
## события GameEvents проигрываются по очереди: ходьба, удары, цифры, звуки, сообщения.
## Пока очередь не пуста, ИИ на этом компьютере ждёт (Net.presentation_busy).
## Действия игрока уходят командами Net.send_command(); справка по клавишам — H.

const TITLE_SCENE := "res://scenes/title.tscn"

var session: GameSession
var world: WorldView
var hud: Hud
var dialogue_box: DialogueBox
var sheet: CharSheet
var journal: Journal
var settings: SettingsPanel
var pause_panel: PanelContainer
var defeat_panel: PanelContainer
var end_panel: Control
var container: SubViewportContainer
var viewport: SubViewport
var post_mat: ShaderMaterial

var selected_uid := ""
var selected_skill := ""
var selected_item := ""
var bar_hover: Dictionary = {}

var _bg: ColorRect
var _queue: Array = []
var _last_seq := 0
var _wait := 0.0
var _pending: Array = []
var _mouse_on_world := false
var _drag := false
var _drag_last := Vector2.ZERO
var _fade := 0.0
var _fade_target := 0.0
var _last_skill := ""
var _music_back_at := -1.0
var _reach: Dictionary = {}
var _reach_key := ""
var _preview_ap := 0
var _end_shown := false
var _pixel_scale := 2
var _time := 0.0
var _last_current := ""
var _xp_toast := {}


func _ready() -> void:
	UiTheme.fill_parent(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.theme()
	GameData.ensure_loaded()
	SpriteLibrary.ensure_loaded()
	GameSettings.ensure_loaded()
	_pixel_scale = int(GameSettings.get_value("pixel_scale"))
	container = SubViewportContainer.new()
	UiTheme.fill_parent(container)
	container.stretch = true
	container.stretch_shrink = _pixel_scale
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	post_mat = ShaderMaterial.new()
	post_mat.shader = load("res://shaders/post.gdshader")
	container.material = post_mat
	add_child(container)
	viewport = SubViewport.new()
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	viewport.snap_2d_transforms_to_pixel = true
	viewport.snap_2d_vertices_to_pixel = true
	viewport.handle_input_locally = false
	viewport.audio_listener_enable_2d = false
	container.add_child(viewport)
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -10
	viewport.add_child(bg_layer)
	_bg = ColorRect.new()
	UiTheme.fill_parent(_bg)
	_bg.color = Color("0b0a0c")
	bg_layer.add_child(_bg)
	world = WorldView.new()
	viewport.add_child(world)

	hud = Hud.new()
	hud.screen = self
	add_child(hud)
	dialogue_box = DialogueBox.new()
	dialogue_box.screen = self
	add_child(dialogue_box)
	sheet = CharSheet.new()
	sheet.screen = self
	add_child(sheet)
	journal = Journal.new()
	journal.screen = self
	add_child(journal)
	_build_pause()
	_build_defeat()
	_build_end()
	settings = SettingsPanel.new()
	settings.visible = false
	settings.closed.connect(func() -> void: settings.visible = false)
	add_child(settings)

	Net.notice.connect(_on_notice)
	Net.disconnected.connect(_on_disconnected)
	session = Net.session
	if session != null and session.grid != null:
		world.build(session)
		_location_audio()


# --- Кадр ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_time += delta
	session = Net.session
	if session == null or session.grid == null:
		hud.refresh(null)
		return
	var ps := int(GameSettings.get_value("pixel_scale"))
	if ps != _pixel_scale:
		_pixel_scale = ps
		container.stretch_shrink = ps
	_pull_events()
	_run_queue(delta)
	var idle := _queue.is_empty() and _wait <= 0.0
	world.idle = idle
	Net.presentation_busy = not idle or world.busy_fx()
	if world.session != session or (idle and world.loc_id != session.location_id):
		_rebuild_world()
	if world.loc_id == session.location_id:
		world.sync_units()
		if idle:
			world.update_cells()
	_update_selection()
	_update_hover()
	_update_highlights()
	_update_focus(delta)
	_update_post(delta)
	_update_dialogue(idle)
	_update_overlays(idle)
	hud.refresh(session)
	_update_tooltip()
	if idle and not world.busy_fx() and not _pending.is_empty():
		send(_pending.pop_front())
	if _music_back_at > 0.0 and _time > _music_back_at:
		_music_back_at = -1.0
		if session.mode != "combat":
			_location_audio()


func _pull_events() -> void:
	var evs := GameEvents.since(_last_seq)
	if evs.is_empty():
		return
	_last_seq = int(evs[-1]["seq"])
	for e in evs:
		if str(e["type"]) == "death":
			var n := world.unit_node(str(e.get("unit", "")))
			if n != null:
				n.death_pending = true
		_queue.append(e)


func _run_queue(delta: float) -> void:
	var speed := 1.0
	if _queue.size() > 24 or Input.is_key_pressed(KEY_SHIFT):
		speed = 3.0
	if _wait > 0.0:
		_wait -= delta * speed
	var guard := 0
	while _wait <= 0.0 and not _queue.is_empty() and guard < 60:
		guard += 1
		var e: Dictionary = _queue.pop_front()
		_wait += _present(e)


func _rebuild_world() -> void:
	world.build(session)
	world.pan = Vector2.ZERO
	_update_focus(0.0)
	world.snap_camera()
	_location_audio()


func _location_audio() -> void:
	if session == null:
		return
	var data := session.location_data()
	_bg.color = world.bg_color
	if session.mode != "combat":
		GameAudio.music(str(data.get("music", "")))
	GameAudio.ambient(str(data.get("ambient", "")))


# --- События -> анимации, звуки, сообщения --------------------------------------------------

## Показать событие. Возвращает, сколько секунд ждать до следующего.
func _present(e: Dictionary) -> float:
	var uid := str(e.get("unit", ""))
	match str(e["type"]):
		"location":
			var id := str(e.get("id", ""))
			if world.loc_id != id or world.session != session:
				if world.loc_id == "":
					_rebuild_world()
					return 0.0
				_fade_target = 1.0
				_queue.push_front({"type": "_rebuild"})
				return 0.35
			if not bool(e.get("first", false)):
				_fade = 1.0
				_fade_target = 0.0
			_location_audio()
			return 0.0
		"_rebuild":
			if world.loc_id != session.location_id or world.session != session:
				_rebuild_world()
			_fade_target = 0.0
			return 0.3
		"transition":
			GameAudio.sfx("transition")
			return 0.0
		"narrate":
			var title := str(e.get("title", ""))
			var text := str(e.get("text", ""))
			if bool(e.get("short", false)) or title == "":
				hud.toast(text, UiTheme.TEXT, 4.0)
			elif session.mode != "dialogue":
				hud.show_card(title, text)
			return 0.0
		"move":
			var paths: Dictionary = e.get("paths", {})
			var longest := 0.0
			var k := 0.85 if session.mode == "combat" else 1.0
			for u in paths:
				longest = maxf(longest, world.walk(str(u), paths[u], k))
			return longest if session.mode == "combat" else minf(longest, 0.6)
		"cast":
			return _present_cast(e)
		"hit":
			var crit := bool(e.get("crit", false))
			var element := str(e.get("element", ""))
			world.hit_fx(uid, int(e.get("amount", 0)), element, crit)
			if str(e.get("src", "")) != "" and _last_skill != "":
				GameAudio.skill_impact(_last_skill, crit)
			else:
				GameAudio.sfx({"fire": "fire_impact", "poison": "poison_impact", "water": "water_impact",
					"air": "lightning_impact", "earth": "bone_crunch"}.get(element, "hurt"))
			world.update_cells()
			return 0.12
		"miss":
			world.miss_fx(uid)
			GameAudio.skill_miss(_last_skill if _last_skill != "" else "attack")
			return 0.12
		"heal":
			world.heal_fx(uid, int(e.get("amount", 0)))
			return 0.06
		"explosion":
			world.explosion_fx(Vector2i(int(e["cell"][0]), int(e["cell"][1])))
			GameAudio.sfx("explosion")
			world.update_cells()
			return 0.3
		"death":
			world.death_fx(uid)
			var u := session.unit_by_uid(uid)
			if u != null and session.heroes.has(u):
				GameAudio.sfx("death")
			elif u != null and u.template_id in ["skeleton", "risen", "lado_body"]:
				GameAudio.sfx("bone_crunch")
			else:
				GameAudio.sfx("enemy_death")
			return 0.35
		"status":
			world.status_fx(uid, str(e.get("status", "")), bool(e.get("negative", false)))
			GameAudio.status(str(e.get("status", "")))
			return 0.05
		"reaction":
			var text := str(e.get("text", ""))
			if e.has("cell"):
				world.text_at_cell(Vector2i(int(e["cell"][0]), int(e["cell"][1])), text, Color("f0e0a0"))
			elif uid != "":
				world.float_text(world.unit_pos(uid) + Vector2(0, -44), text, Color("f0e0a0"), 8)
			world.update_cells()
			return 0.15
		"turn":
			var u := session.unit_by_uid(uid)
			if u == null:
				return 0.0
			_last_current = uid
			if session.owner_of(u) == Net.my_id() and session.heroes.has(u):
				hud.show_sub_banner("Ваш ход: %s" % u.display_name)
				GameAudio.sfx("turn_start")
				selected_uid = uid
				return 0.3
			hud.hide_sub_banner()
			return 0.35
		"combat_start":
			hud.show_banner("БОЙ!", "", Color("ff8a5a"), 0.7)
			GameAudio.sfx("enemy_alert")
			GameAudio.music(str(e.get("music", "combat")))
			_music_back_at = -1.0
			_cancel_targeting()
			world.pan = Vector2.ZERO
			return 1.0
		"combat_end":
			if str(e.get("winner", "")) == "player":
				hud.show_banner("ПОБЕДА!", "", UiTheme.GOLD, 1.1)
				GameAudio.stinger("victory")
				_music_back_at = _time + 3.5
			else:
				hud.show_banner("ПОРАЖЕНИЕ", "", UiTheme.RED, 1.5)
				GameAudio.stinger("defeat")
			_cancel_targeting()
			return 1.2
		"xp":
			var amount := int(e.get("amount", 0))
			# опыт получает вся партия разом: одна надпись над первым героем и одно сообщение
			if int(_xp_toast.get(amount, -9999)) < Time.get_ticks_msec() - 800:
				_xp_toast[amount] = Time.get_ticks_msec()
				hud.toast("Опыт +%d" % amount, Color("a8b4ff"), 2.0)
				if uid != "" and world.unit_node(uid) != null:
					world.float_text(world.unit_pos(uid) + Vector2(0, -50), "+%d опыта" % amount, Color("a8b4ff"), 8)
			return 0.0
		"level_up":
			var u := session.unit_by_uid(uid)
			world.level_up_fx(uid, int(e.get("level", 0)))
			GameAudio.stinger("level_up")
			if u != null:
				hud.toast("%s: уровень %d · очки в листе героя (C)" % [u.display_name, int(e.get("level", u.level))], UiTheme.GOLD, 4.5)
			return 0.4
		"quest":
			var qn := str(GameData.quest(str(e.get("quest", ""))).get("name", e.get("quest", "")))
			if bool(e.get("done", false)):
				hud.toast("Задание выполнено: «%s»" % qn, UiTheme.GREEN, 4.0)
				GameAudio.stinger("quest_done")
			elif bool(e.get("failed", false)):
				hud.toast("Задание провалено: «%s»" % qn, UiTheme.RED, 4.0)
			elif bool(e.get("new", false)):
				hud.toast("Новое задание: «%s»" % qn, Color("f0dcae"), 4.0)
				GameAudio.stinger("quest")
			else:
				hud.toast("Журнал обновлён: «%s»" % qn, UiTheme.TEXT_DIM, 3.0)
				GameAudio.sfx("page")
			return 0.1
		"item":
			var count := int(e.get("count", 1))
			var name := str(GameData.item(str(e.get("item", ""))).get("name", e.get("item", "")))
			if uid != "":
				var u := session.unit_by_uid(uid)
				hud.toast("%s получает: %s" % [u.display_name if u != null else "Герой", name], Color("f0dcae"))
				GameAudio.sfx("pickup")
			elif count > 0:
				hud.toast("Получено: %s%s" % [name, " ×%d" % count if count > 1 else ""], Color("f0dcae"))
				GameAudio.sfx("pickup")
			else:
				hud.toast("Отдано: %s" % name, UiTheme.TEXT_DIM)
			return 0.05
		"gold":
			var amount := int(e.get("amount", 0))
			hud.toast("%+d золота" % amount, Color("f0c860"))
			GameAudio.sfx("coin")
			return 0.05
		"check":
			var attr := Story.attribute_name(str(e.get("attr", "")))
			var ok := bool(e.get("success", false))
			hud.toast("Проверка: %s — %s" % [attr, "успех" if ok else "не вышло"], UiTheme.GREEN if ok else UiTheme.RED)
			GameAudio.ui("ui_confirm" if ok else "ui_error")
			return 0.1
		"tip":
			hud.add_tip(str(e.get("text", "")))
			return 0.0
		"saved":
			hud.toast("Игра сохранена", UiTheme.GREEN)
			return 0.0
		"heal_party":
			hud.toast("Отряд отдохнул и залечил раны", UiTheme.GREEN)
			GameAudio.sfx("heal")
			return 0.0
		"music":
			_music_back_at = -1.0
			GameAudio.music(str(e.get("id", "")))
			return 0.0
		"ambient":
			GameAudio.ambient(str(e.get("id", "")))
			return 0.0
		"sfx":
			GameAudio.sfx(str(e.get("id", "")))
			return 0.0
		"stinger":
			GameAudio.stinger(str(e.get("id", "")))
			return 0.0
		"shake":
			world.shake(2.0 * float(e.get("power", 1.0)), 0.5)
			return 0.0
	return 0.0


func _present_cast(e: Dictionary) -> float:
	var uid := str(e.get("unit", ""))
	var skill := str(e.get("skill", ""))
	_last_skill = skill
	var def := GameData.skill(skill)
	var cell := Vector2i(int(e["cell"][0]), int(e["cell"][1]))
	var target := WorldView.cell_center(cell)
	var from := world.unit_pos(uid)
	GameAudio.skill(skill)
	var tt := str(def.get("target", "enemy"))
	var element := str((def.get("damage", {}) as Dictionary).get("element", (def.get("surface", {}) as Dictionary).get("element", "")))
	if def.has("heal"):
		element = "heal"
	var col := UiTheme.element_color(element)
	if tt == "self":
		world.cast_glow(uid, col)
		return 0.3
	var rng := int(def.get("range", 1))
	if rng <= 1 and tt == "enemy":
		world.lunge(uid, target)
		return 0.16
	world.cast_glow(uid, col)
	var n := world.unit_node(uid)
	if n != null:
		n.face_to(target)
	if tt == "ally":
		var tn := session.unit_at(cell)
		if tn != null:
			world.cast_glow(tn.uid, col)
		return 0.3
	var kind := "bolt"
	if (def.get("damage", {}) as Dictionary).get("source", "") == "weapon":
		kind = "arrow"
	return world.shoot(from + Vector2(0, -16), target + Vector2(0, -10), col, kind) + 0.05


# --- Выбор, наведение, подсветка ----------------------------------------------------------

func is_my_turn() -> bool:
	return session != null and session.mode == "combat" and session.combat != null and session.combat.active \
		and session.combat.current != null and session.owner_of(session.combat.current) == Net.my_id() \
		and session.heroes.has(session.combat.current)


func bar_unit() -> Character:
	if session == null:
		return null
	if is_my_turn():
		return session.combat.current
	return session.unit_by_uid(selected_uid)


func preview_ap_cost() -> int:
	return _preview_ap


func _update_selection() -> void:
	var mine := session.heroes_of(Net.my_id())
	var sel := session.unit_by_uid(selected_uid)
	if sel == null or not mine.has(sel) or (not sel.is_alive() and session.mode == "explore"):
		var alive: Array = mine.filter(func(h): return h.is_alive())
		var pick: Array = alive if not alive.is_empty() else mine
		selected_uid = (pick[0] as Character).uid if not pick.is_empty() else ""
	var cur := ""
	if session.mode == "combat" and session.combat != null and session.combat.current != null:
		cur = session.combat.current.uid
	world.current_uid = cur
	world.selected_uid = selected_uid if session.mode == "explore" else ""
	var can_aim := is_my_turn() or (session.mode == "explore" and selected_item == "")
	if not can_aim and (selected_skill != "" or selected_item != ""):
		_cancel_targeting()


func _modal_open() -> bool:
	return sheet.visible or journal.visible or pause_panel.visible or settings.visible or end_panel.visible \
		or hud.help_panel.visible


func _update_hover() -> void:
	if not _mouse_on_world or _modal_open() or dialogue_box.visible:
		world.hover_uid = ""
		world.hover_object = ""
		world.hover_cell = Vector2i(-99, -99)
		world.hover_point = Vector2(-9999, -9999)
		return
	var vp := (get_global_mouse_position() - container.global_position) / float(_pixel_scale)
	world.pick_prefer = _pick_prefer()
	var pk := world.pick(world.viewport_to_world(vp))
	world.hover_uid = str(pk.get("uid", ""))
	world.hover_object = str(pk.get("object", ""))
	world.hover_cell = pk.get("cell", Vector2i(-99, -99))


## Кого выбирать при перекрытии фигур: с союзным навыком — своих, иначе врагов и жителей.
func _pick_prefer() -> String:
	var sk := selected_skill
	if sk == "" and selected_item != "":
		sk = str((GameData.item(selected_item).get("use", {}) as Dictionary).get("skill", ""))
	return "ally" if str(GameData.skill(sk).get("target", "")) == "ally" else "foe"


func _update_highlights() -> void:
	world.hl_move = {}
	world.hl_range = {}
	world.hl_aoe = {}
	world.hl_path = []
	world.target_uids = {}
	_preview_ap = 0
	world.grid_lines = session.mode == "combat"
	if session.mode == "explore" and selected_skill != "":
		_explore_aim_highlights()
		return
	if not is_my_turn() or not world.idle or world.busy_fx():
		return
	var cm := session.combat
	var cur := cm.current
	var hover := world.hover_cell
	var hover_unit: Character = session.unit_at(hover) if world.hover_uid == "" else session.unit_by_uid(world.hover_uid)
	if hover_unit != null and world.hover_uid != "":
		hover = hover_unit.cell
	var skill_id := selected_skill
	var def: Dictionary = {}
	if selected_item != "":
		def = GameData.skill(str((GameData.item(selected_item).get("use", {}) as Dictionary).get("skill", "")))
		_preview_ap = int(GameData.item(selected_item).get("ap", def.get("ap", 2)))
	elif skill_id != "":
		def = GameData.skill(skill_id)
		_preview_ap = int(def.get("ap", 0))
	if not def.is_empty():
		var rng := SkillSystem.skill_range(cur, def)
		for c in cm.grid.cells_in_radius(cur.cell, rng):
			world.hl_range[c] = true
		if SkillSystem.target_block_reason(cm, cur, def, hover) == "":
			var r := int(def.get("aoe_radius", 0))
			for c in cm.grid.cells_in_radius(hover, r):
				world.hl_aoe[c] = true
				var t := cm.unit_at(c)
				if t != null:
					world.target_uids[t.uid] = true
		return
	# перемещение и атака по клику
	var key := "%s|%s|%d|%d" % [cur.uid, cur.cell, cur.ap, cm.round_number]
	if key != _reach_key:
		_reach_key = key
		_reach = _reachable(cur)
	world.hl_move = _reach
	if hover_unit != null and hover_unit.is_alive() and hover_unit.faction != cur.faction and session.enemies.has(hover_unit):
		var atk := _attack_skill(cur)
		if atk != "":
			world.target_uids[hover_unit.uid] = true
			var adef := GameData.skill(atk)
			_preview_ap = int(adef.get("ap", 0))
			if SkillSystem.target_block_reason(cm, cur, adef, hover_unit.cell) != "":
				var path := _approach_path(cur, hover_unit.cell)
				if not path.is_empty():
					world.hl_path = path
					_preview_ap += cm.move_cost(cur, path.size())
	elif _reach.has(hover):
		var path := cm.grid.find_path(cur.cell, hover, cm.occupied_cells(cur))
		world.hl_path = path
		_preview_ap = cm.move_cost(cur, path.size())


func _reachable(u: Character) -> Dictionary:
	var cm := session.combat
	var steps := cm.max_move_steps(u)
	var occ := cm.occupied_cells(u)
	var dist := {u.cell: 0}
	var queue: Array = [u.cell]
	var out := {}
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		var d := int(dist[c])
		if d >= steps:
			continue
		for dir in SurfaceGrid.DIRS:
			var n: Vector2i = c + dir
			if dist.has(n) or not cm.grid.is_walkable(n) or occ.has(n):
				continue
			dist[n] = d + 1
			out[n] = true
			queue.append(n)
	return out


func _attack_skill(u: Character) -> String:
	if u.skills.has("attack"):
		return "attack"
	for sk in u.skills:
		var def := GameData.skill(str(sk))
		if str(def.get("target", "")) == "enemy" and def.has("damage"):
			return str(sk)
	return ""


## Путь до клетки рядом с целью, откуда можно ударить (самый короткий из доступных).
func _approach_path(u: Character, target: Vector2i) -> Array:
	var cm := session.combat
	var best: Array = []
	for dir in SurfaceGrid.DIRS:
		var n: Vector2i = target + dir
		if n == u.cell:
			return []
		if not _reach.has(n):
			continue
		var p := cm.grid.find_path(u.cell, n, cm.occupied_cells(u))
		if not p.is_empty() and (best.is_empty() or p.size() < best.size()):
			best = p
	return best


func _update_focus(delta: float) -> void:
	var f := Vector2.ZERO
	var have := false
	if session.mode == "combat" and session.combat != null and session.combat.current != null:
		f = world.unit_pos(session.combat.current.uid)
		have = true
	elif session.mode == "dialogue" and not session.dialogue.is_empty():
		var npc_id := str(session.dialogue.get("npc", ""))
		for n in session.npcs:
			if (n as Character).template_id == npc_id:
				f = world.unit_pos((n as Character).uid)
				have = true
		if not have:
			f = world.unit_pos(str(session.dialogue.get("hero", "")))
			have = f != Vector2.ZERO
	if not have and selected_uid != "":
		f = world.unit_pos(selected_uid)
		have = true
	if have:
		world.focus = f + Vector2(0, -12)
	# камера стрелками и WASD
	var mv := Vector2.ZERO
	if not _modal_open():
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			mv.x -= 1
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			mv.x += 1
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
			mv.y -= 1
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
			mv.y += 1
	if mv != Vector2.ZERO:
		world.pan += mv.normalized() * 220.0 * delta / float(world.zoom)


func _update_post(delta: float) -> void:
	_fade = move_toward(_fade, _fade_target, delta * 3.5)
	post_mat.set_shader_parameter("fade", _fade)
	post_mat.set_shader_parameter("posterize", bool(GameSettings.get_value("posterize")))
	var style: Dictionary = session.location_data().get("style", {})
	post_mat.set_shader_parameter("tint", Color(str(style.get("tint", "ffffff"))))


func _update_dialogue(idle: bool) -> void:
	if session.mode == "dialogue" and not session.dialogue.is_empty():
		if idle and not world.busy_fx() and _fade < 0.05:
			var v := Story.view(session)
			if not v.is_empty():
				var pid := int(v.get("pid", 0))
				dialogue_box.present(v, pid == Net.my_id(), session.player_name(pid))
	elif dialogue_box.visible:
		dialogue_box.close()


func _update_overlays(idle: bool) -> void:
	defeat_panel.visible = session.mode == "defeat" and idle
	if session.flags.has("demo_end") and not _end_shown and session.mode == "explore" and idle:
		_end_shown = true
		_show_end()


# --- Подсказка у курсора ----------------------------------------------------------------------

func _update_tooltip() -> void:
	var text := ""
	if not bar_hover.is_empty():
		text = _slot_tip(bar_hover)
	elif _mouse_on_world and not _modal_open() and not dialogue_box.visible:
		text = _world_tip()
	hud.set_tooltip(text, get_global_mouse_position())


func _slot_tip(slot: Dictionary) -> String:
	var id := str(slot.get("id", ""))
	if str(slot.get("kind", "")) == "skill":
		var def := GameData.skill(id)
		var u := bar_unit()
		var lines := PackedStringArray()
		lines.append("[b]%s[/b]  [color=#9ad248]%d ОД[/color]" % [def.get("name", id), int(def.get("ap", 0))])
		var info := "Дальность %d" % (SkillSystem.skill_range(u, def) if u != null else int(def.get("range", 1)))
		if int(def.get("aoe_radius", 0)) > 0:
			info += " · область %d" % int(def["aoe_radius"])
		if int(def.get("cooldown", 0)) > 0:
			info += " · перезарядка %d" % int(def["cooldown"])
		lines.append(info)
		var dmg: Dictionary = def.get("damage", {})
		if not dmg.is_empty():
			var el := str(dmg.get("element", "physical" if str(dmg.get("source", "")) == "weapon" else ""))
			lines.append("Урон: %s" % _element_name(el))
		if def.has("heal"):
			lines.append("Лечит союзника")
		for st in def.get("statuses", []):
			var sd: Dictionary = st
			lines.append("%s, шанс %d%%" % [GameData.status(str(sd.get("id", ""))).get("name", sd.get("id", "")), int(sd.get("chance", 100))])
		if def.has("description"):
			lines.append("[color=#a89a80]%s[/color]" % str(def["description"]))
		if def.has("vs_undead"):
			lines.append("[color=#fff0a8]По нежити: святой урон[/color]")
		if session.mode == "explore":
			lines.append("[color=#6e6454]Вне боя — без ОД; удар по врагу начнёт бой[/color]")
		return "\n".join(lines)
	var idef := GameData.item(id)
	var out := "[b]%s[/b]" % idef.get("name", id)
	if idef.has("description"):
		out += "\n[color=#a89a80]%s[/color]" % str(idef["description"])
	var use: Dictionary = idef.get("use", {})
	if use.has("skill"):
		out += "\nВ бою: выберите и укажите клетку · %d ОД" % int(idef.get("ap", GameData.skill(str(use["skill"])).get("ap", 2)))
	elif use.has("heal"):
		out += "\nЛечит %d" % int(use["heal"])
	return out


func _world_tip() -> String:
	if world.hover_uid != "":
		var u := session.unit_by_uid(world.hover_uid)
		if u == null:
			return ""
		var lines := PackedStringArray()
		if session.is_npc(u):
			var nd := GameData.npc(u.template_id)
			lines.append("[b]%s[/b]" % u.display_name)
			if nd.has("title"):
				lines.append("[color=#a89a80]%s[/color]" % str(nd["title"]))
			if session.mode == "explore" and session.npc_dialogue(u.template_id) != "":
				lines.append("[color=#c8a060]ЛКМ — поговорить[/color]")
			return "\n".join(lines)
		var hero := session.heroes.has(u)
		var cls := " · " + u.class_title().to_lower() if hero else ""
		lines.append("[b][color=%s]%s[/color][/b]%s  ур. %d" % ["#ecdfc2" if hero else "#e8806a", u.display_name, cls, u.level])
		if not u.is_alive():
			lines.append("Пал")
			return "\n".join(lines)
		lines.append("Здоровье %d/%d · броня %d" % [roundi(u.hp), roundi(u.max_hp()), roundi(DamageCalc.effective_armor(u))])
		var sts := PackedStringArray()
		for sid in u.statuses:
			sts.append("%s (%d)" % [GameData.status(str(sid)).get("name", sid), int(u.statuses[sid].get("turns", 0))])
		if not sts.is_empty():
			lines.append("[color=#c8b8ff]%s[/color]" % ", ".join(sts))
		if is_my_turn() and not hero:
			var cur := session.combat.current
			var sk := selected_skill if selected_skill != "" else _attack_skill(cur)
			var def := GameData.skill(sk)
			if not def.is_empty():
				var reason := SkillSystem.target_block_reason(session.combat, cur, def, u.cell)
				if reason == "" or selected_skill == "":
					if bool(def.get("can_miss", false)):
						lines.append("Шанс попасть: %d%%" % roundi(DamageCalc.hit_chance(cur, u)))
					lines.append("[color=#c8a060]ЛКМ — %s (%d ОД)[/color]" % [def.get("name", sk), _preview_ap])
				else:
					lines.append("[color=#d8573f]Нельзя: %s[/color]" % reason)
		elif hero and session.mode == "explore" and session.owner_of(u) == Net.my_id() and u.uid != selected_uid:
			lines.append("[color=#c8a060]ЛКМ — выбрать[/color]")
		return "\n".join(lines)
	if world.hover_object != "":
		for o in session.location_data().get("objects", []):
			if str(o.get("id", "")) == world.hover_object:
				var t := "[b]%s[/b]" % str(o.get("name", world.hover_object))
				var vis: bool = session.visible_objects().any(func(v): return str(v.get("id", "")) == world.hover_object)
				if vis and session.mode == "explore":
					t += "\n[color=#c8a060]ЛКМ — осмотреть[/color]"
				return t
		return ""
	var c := world.hover_cell
	if session.grid.in_bounds(c):
		var ex := session.exit_at(c)
		if not ex.is_empty():
			return "[b]%s[/b]\n[color=#a89a80]Выход[/color]" % str(ex.get("name", ex.get("to", "")))
		if is_my_turn() and selected_skill == "" and selected_item == "" and not world.hl_path.is_empty():
			var t := "Идти: %d ОД" % _preview_ap
			var g := session.grid.get_ground(c)
			if g != "none":
				t += "\n[color=#a89a80]%s[/color]" % str(GameData.surface(g).get("name", g))
			return t
		var gs := session.grid.get_ground(c)
		if gs != "none" and session.mode == "combat":
			return str(GameData.surface(gs).get("name", gs))
	return ""


static func _element_name(el: String) -> String:
	return str({"physical": "физический", "fire": "огонь", "water": "вода", "earth": "земля", "air": "воздух",
		"poison": "яд", "holy": "святой свет", "": "физический"}.get(el, el))


# --- Ввод ---------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_on_world = false   # если интерфейс не заберёт движение, _unhandled_input вернёт true


func _unhandled_input(event: InputEvent) -> void:
	var mm := event as InputEventMouseMotion
	if mm != null:
		_mouse_on_world = true
		if _drag:
			world.pan -= (mm.position - _drag_last) / float(_pixel_scale * world.zoom)
			_drag_last = mm.position
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		_on_mouse(mb)
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		_on_key(key)


func _on_mouse(mb: InputEventMouseButton) -> void:
	if session == null or session.grid == null:
		return
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			if not mb.pressed:
				return
			if dialogue_box.visible:
				dialogue_box.advance()
				return
			if _modal_open():
				return
			_on_world_click()
		MOUSE_BUTTON_RIGHT:
			if mb.pressed and (selected_skill != "" or selected_item != ""):
				_cancel_targeting()
				return
			_drag = mb.pressed
			_drag_last = mb.position
		MOUSE_BUTTON_MIDDLE:
			_drag = mb.pressed
			_drag_last = mb.position
		MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				world.zoom = 2
		MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				world.zoom = 1


func _on_world_click() -> void:
	var c := world.hover_cell
	var hu: Character = null
	if world.hover_uid != "":
		hu = session.unit_by_uid(world.hover_uid)
	if session.mode == "explore":
		if selected_skill != "":
			_cast_explore((hu.cell if hu != null else c))
			return
		if hu != null and session.heroes.has(hu) and session.owner_of(hu) == Net.my_id():
			select_hero(hu.uid, false)
			return
		if selected_uid == "":
			return
		if hu != null and session.is_npc(hu):
			_queue_or_send({"type": "talk", "unit": selected_uid, "target": hu.uid})
			return
		if world.hover_object != "":
			var vis: bool = session.visible_objects().any(func(v): return str(v.get("id", "")) == world.hover_object)
			if vis:
				_queue_or_send({"type": "talk", "unit": selected_uid, "object": world.hover_object})
				return
		if hu != null:
			c = hu.cell
		var target := _walk_target(c)
		if target.x > -90:
			world.pan = Vector2.ZERO
			_queue_or_send({"type": "move", "unit": selected_uid, "cell": [target.x, target.y]})
		return
	if not is_my_turn() or not world.idle or world.busy_fx():
		return
	var cur := session.combat.current
	if selected_item != "":
		var cell := hu.cell if hu != null else c
		send({"type": "use_item", "unit": cur.uid, "item": selected_item, "cell": [cell.x, cell.y]})
		_cancel_targeting()
		return
	if selected_skill != "":
		var cell := hu.cell if hu != null else c
		var reason := session.combat.skill_block_reason(cur, selected_skill, cell)
		if reason != "":
			_on_notice(reason)
			return
		send({"type": "skill", "skill": selected_skill, "cell": [cell.x, cell.y]})
		_cancel_targeting()
		return
	if hu != null and hu.is_alive() and hu.faction != cur.faction and session.enemies.has(hu):
		var atk := _attack_skill(cur)
		if atk == "":
			return
		var reason := session.combat.skill_block_reason(cur, atk, hu.cell)
		if reason == "":
			send({"type": "skill", "skill": atk, "cell": [hu.cell.x, hu.cell.y]})
		elif reason == "слишком далеко":
			var path := _approach_path(cur, hu.cell)
			if path.is_empty():
				_on_notice("не подойти")
				return
			var dest: Vector2i = path[-1]
			send({"type": "move", "unit": cur.uid, "cell": [dest.x, dest.y]})
			_pending.append({"type": "skill", "skill": atk, "cell": [hu.cell.x, hu.cell.y]})
		else:
			_on_notice(reason)
		return
	if session.grid.in_bounds(c):
		send({"type": "move", "unit": cur.uid, "cell": [c.x, c.y]})


## Куда идти, если кликнули по занятой клетке: на ближайшую свободную рядом.
func _walk_target(c: Vector2i) -> Vector2i:
	var g := session.grid
	if not g.in_bounds(c):
		return Vector2i(-99, -99)
	var occ := {}
	for u in session.all_units():
		if (u as Character).is_alive() and (u as Character).uid != selected_uid:
			occ[(u as Character).cell] = true
	if g.is_walkable(c) and not occ.has(c):
		return c
	var me := session.unit_by_uid(selected_uid)
	var best := Vector2i(-99, -99)
	var best_d := 999
	for r in [1, 2]:
		for n in g.cells_in_radius(c, r):
			var cell: Vector2i = n
			if occ.has(cell) or not g.is_walkable(cell):
				continue
			var d := SurfaceGrid.distance(cell, me.cell) if me != null else 0
			if d < best_d:
				best_d = d
				best = cell
		if best.x > -90:
			break
	return best


func _queue_or_send(cmd: Dictionary) -> void:
	if world.idle and not world.busy_fx():
		send(cmd)
	else:
		_pending = [cmd]


func _on_key(key: InputEventKey) -> void:
	var k := key.keycode
	if k == KEY_F11:
		GameSettings.set_value("fullscreen", not bool(GameSettings.get_value("fullscreen")))
		return
	if k == KEY_ESCAPE:
		_on_escape()
		return
	if settings.visible or end_panel.visible:
		return
	if dialogue_box.visible:
		if k == KEY_SPACE or k == KEY_ENTER or k == KEY_KP_ENTER:
			dialogue_box.advance()
		elif k >= KEY_1 and k <= KEY_9:
			dialogue_box.choose_number(k - KEY_1)
		return
	match k:
		KEY_H, KEY_F1:
			hud.toggle_help()
		KEY_C:
			open_panel("sheet")
		KEY_J:
			open_panel("journal")
		KEY_I:
			open_panel("bag")
		KEY_K, KEY_F5:
			send({"type": "save"})
		KEY_L, KEY_F9:
			send({"type": "load"})
		KEY_R:
			if session != null and session.mode == "defeat":
				send({"type": "restart"})
		KEY_Z, KEY_HOME:
			world.pan = Vector2.ZERO
		KEY_TAB:
			_next_hero()
		KEY_SPACE:
			end_turn()
		KEY_0:
			_cancel_targeting()
		_:
			if k >= KEY_1 and k <= KEY_9 and (is_my_turn() or (session != null and session.mode == "explore")):
				var u := bar_unit()
				var idx: int = k - KEY_1
				if u != null and idx < u.skills.size():
					select_skill(str(u.skills[idx]))


func _on_escape() -> void:
	if settings.visible:
		settings.visible = false
	elif hud.help_panel.visible:
		hud.help_panel.visible = false
	elif sheet.visible or journal.visible:
		open_panel("")
	elif pause_panel.visible:
		pause_panel.visible = false
	elif selected_skill != "" or selected_item != "":
		_cancel_targeting()
	elif dialogue_box.visible:
		dialogue_box.skip()
	elif not end_panel.visible:
		pause_panel.visible = true
		GameAudio.ui("ui_open")


func _next_hero() -> void:
	if session == null:
		return
	if session.mode == "combat":
		world.pan = Vector2.ZERO
		return
	var mine: Array = session.heroes_of(Net.my_id()).filter(func(h): return h.is_alive())
	if mine.is_empty():
		return
	var idx := mine.find(session.unit_by_uid(selected_uid))
	select_hero((mine[(idx + 1) % mine.size()] as Character).uid, false)


# --- Действия (их зовут HUD и окна) ---------------------------------------------------------------

func send(cmd: Dictionary) -> void:
	Net.send_command(cmd)


func select_hero(uid: String, open_sheet: bool) -> void:
	if session == null:
		return
	var u := session.unit_by_uid(uid)
	if u == null:
		return
	if session.owner_of(u) == Net.my_id() and session.mode != "combat":
		selected_uid = uid
		world.pan = Vector2.ZERO
		GameAudio.ui("ui_click")
	if open_sheet:
		sheet.open(uid)
		journal.visible = false


func select_skill(skill_id: String) -> void:
	if session != null and session.mode == "explore":
		_select_explore_skill(skill_id)
		return
	if not is_my_turn():
		return
	var u := session.combat.current
	var def := GameData.skill(skill_id)
	var reason := session.combat.skill_block_reason(u, skill_id, u.cell) if str(def.get("target", "")) == "self" else ""
	if int(def.get("ap", 0)) > u.ap:
		_on_notice("не хватает ОД")
		return
	if u.cooldowns.has(skill_id):
		_on_notice("перезарядка %d" % int(u.cooldowns[skill_id]))
		return
	if str(def.get("target", "")) == "self":
		if reason != "":
			_on_notice(reason)
			return
		send({"type": "skill", "skill": skill_id, "cell": [u.cell.x, u.cell.y]})
		_cancel_targeting()
		return
	selected_item = ""
	selected_skill = "" if selected_skill == skill_id else skill_id
	GameAudio.ui("ui_click")


# --- Навыки вне боя -----------------------------------------------------------------------

func _select_explore_skill(skill_id: String) -> void:
	var u := bar_unit()
	if u == null or not u.is_alive():
		return
	if u.cooldowns.has(skill_id):
		_on_notice("перезарядка %d" % int(u.cooldowns[skill_id]))
		return
	selected_item = ""
	if str(GameData.skill(skill_id).get("target", "")) == "self":
		_cancel_targeting()
		_queue_or_send({"type": "skill", "unit": u.uid, "skill": skill_id, "cell": [u.cell.x, u.cell.y]})
		return
	selected_skill = "" if selected_skill == skill_id else skill_id
	GameAudio.ui("ui_click")


func _cast_explore(cell: Vector2i) -> void:
	var u := bar_unit()
	if u == null:
		return
	var reason := SkillSystem.target_block_reason(session.explore_field(), u, GameData.skill(selected_skill), cell)
	if reason != "":
		_on_notice(reason)
		return
	_queue_or_send({"type": "skill", "unit": u.uid, "skill": selected_skill, "cell": [cell.x, cell.y]})
	_cancel_targeting()


## Подсветка прицела вне боя: дальность навыка и область под курсором.
func _explore_aim_highlights() -> void:
	var u := bar_unit()
	if u == null:
		return
	var def := GameData.skill(selected_skill)
	var field := session.explore_field()
	for c in session.grid.cells_in_radius(u.cell, SkillSystem.skill_range(u, def)):
		world.hl_range[c] = true
	var hover := world.hover_cell
	var hu := session.unit_by_uid(world.hover_uid)
	if hu != null:
		hover = hu.cell
	if SkillSystem.target_block_reason(field, u, def, hover) == "":
		for c in session.grid.cells_in_radius(hover, int(def.get("aoe_radius", 0))):
			world.hl_aoe[c] = true
			var t := field.unit_at(c)
			if t != null:
				world.target_uids[t.uid] = true


func activate_slot(slot: Dictionary) -> void:
	var id := str(slot.get("id", ""))
	if str(slot.get("kind", "")) == "skill":
		if session.mode != "combat" and session.mode != "explore":
			return
		select_skill(id)
		return
	var def := GameData.item(id)
	var use: Dictionary = def.get("use", {})
	if use.has("skill"):
		if not is_my_turn():
			_on_notice("это пригодится в бою, в свой ход")
			return
		selected_skill = ""
		selected_item = "" if selected_item == id else id
		return
	var u := bar_unit()
	if u == null:
		return
	send({"type": "use_item", "unit": u.uid, "item": id})


func set_bar_hover(slot: Dictionary) -> void:
	bar_hover = slot


func end_turn() -> void:
	if is_my_turn():
		_cancel_targeting()
		send({"type": "end_turn"})


func dialogue_next() -> void:
	send({"type": "dialogue_next"})


func dialogue_choice(index: int) -> void:
	send({"type": "dialogue_choice", "index": index})


func dialogue_skip() -> void:
	send({"type": "dialogue_skip"})


func open_panel(which: String) -> void:
	var was_sheet := sheet.visible
	var was_journal := journal.visible
	sheet.visible = false
	journal.visible = false
	pause_panel.visible = false
	match which:
		"sheet":
			if not was_sheet:
				sheet.open(selected_uid)
		"journal":
			if not (was_journal and journal.tab == "quests"):
				journal.open("quests")
		"bag":
			if not (was_journal and journal.tab == "bag"):
				journal.open("bag")
		"menu":
			pause_panel.visible = true
	if which != "":
		GameAudio.ui("ui_open")


func _cancel_targeting() -> void:
	selected_skill = ""
	selected_item = ""


func _on_notice(text: String) -> void:
	if hud != null:
		hud.toast(text.substr(0, 1).to_upper() + text.substr(1), UiTheme.RED, 2.2)
	GameAudio.ui("ui_error")


func _on_disconnected(reason: String) -> void:
	Net.presentation_busy = false
	TitleScreen.message = reason
	get_tree().change_scene_to_file(TITLE_SCENE)


func _to_title() -> void:
	Net.leave()


# --- Меню паузы, поражение, конец пролога ------------------------------------------------------------

func _build_pause() -> void:
	pause_panel = UiTheme.panel(Vector2(360, 0))
	UiTheme.center(pause_panel, Vector2(360, 420))
	pause_panel.visible = false
	add_child(pause_panel)
	var v := UiTheme.vbox(8)
	pause_panel.add_child(v)
	var t := UiTheme.label("Пауза", 22, UiTheme.GOLD, "bold")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	v.add_child(UiTheme.button("Продолжить", _close_pause, 20))
	v.add_child(UiTheme.button("Сохранить (K)", _pause_send.bind({"type": "save"}), 20))
	v.add_child(UiTheme.button("Загрузить (L)", _pause_send.bind({"type": "load"}), 20))
	v.add_child(UiTheme.button("Настройки", _open_settings, 20))
	v.add_child(UiTheme.button("Управление (H)", _pause_help, 20))
	v.add_child(UiTheme.button("В главное меню", _to_title, 20))
	if not OS.has_feature("web"):
		v.add_child(UiTheme.button("Выйти из игры", _quit, 20))


func _close_pause() -> void:
	pause_panel.visible = false


func _pause_send(cmd: Dictionary) -> void:
	send(cmd)
	pause_panel.visible = false


func _open_settings() -> void:
	settings.visible = true


func _pause_help() -> void:
	pause_panel.visible = false
	hud.toggle_help()


func _quit() -> void:
	get_tree().quit()


func _build_defeat() -> void:
	defeat_panel = UiTheme.panel(Vector2(520, 0))
	UiTheme.center(defeat_panel, Vector2(520, 220))
	defeat_panel.visible = false
	add_child(defeat_panel)
	var v := UiTheme.vbox(10)
	defeat_panel.add_child(v)
	var t := UiTheme.label("Отряд пал", 24, UiTheme.RED, "title")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var l := UiTheme.label("Но это ещё не конец. Герои очнутся у входа в локацию, враги тоже переведут дух.", 18, UiTheme.TEXT)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(500, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	var h := UiTheme.hbox(8)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(h)
	h.add_child(UiTheme.button("Очнуться (R)", func() -> void: send({"type": "restart"}), 18))
	h.add_child(UiTheme.button("Загрузить", func() -> void: send({"type": "load"}), 18))
	h.add_child(UiTheme.button("В меню", _to_title, 18))


func _build_end() -> void:
	end_panel = ColorRect.new()
	(end_panel as ColorRect).color = Color(0.02, 0.015, 0.02, 0.92)
	UiTheme.fill_parent(end_panel)
	end_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	end_panel.visible = false
	add_child(end_panel)


func _show_end() -> void:
	for c in end_panel.get_children():
		c.queue_free()
	var v := UiTheme.vbox(14)
	v.custom_minimum_size = Vector2(840, 0)
	UiTheme.center(v, Vector2(840, 460))
	end_panel.add_child(v)
	var t := UiTheme.label("Конец пролога", 32, UiTheme.GOLD, "title")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := UiTheme.label("Пепельные стражи · «Последняя воля»", 20, UiTheme.TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	var done := 0
	for q in session.quests:
		if Story.is_done_stage(str(q), str(session.quests[q])):
			done += 1
	var lvl := 0
	for h in session.heroes:
		lvl = maxi(lvl, (h as Character).level)
	var text := UiTheme.label(("Ладо ушёл на Тихий Берег, а у вас в кармане тлеет его уголь и чужая тайна.\n" +
		"Выполнено заданий: %d из %d · уровень отряда: %d · золото: %d\n\n" +
		"Это прототип: две с половиной локации, один босс и много заглушек. Если хочется узнать, что было дальше, " +
		"значит, идея работает.") % [done, session.quests.size(), lvl, session.gold], 19, UiTheme.TEXT)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.custom_minimum_size = Vector2(840, 0)
	v.add_child(text)
	var h := UiTheme.hbox(10)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(h)
	h.add_child(UiTheme.button("Бродить дальше", func() -> void: end_panel.visible = false, 20))
	h.add_child(UiTheme.button("В главное меню", _to_title, 20))
	end_panel.visible = true
	GameAudio.music("epilogue")

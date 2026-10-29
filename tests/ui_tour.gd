extends SceneTree
## Прогон всей игры через настоящий интерфейс: титульный экран → выбор героев → вступление → погост →
## разговор → лист героя и журнал → бой → деревня → лес → курган → настройки и пауза.
## С графикой сохраняет снимки экрана в папку:
##   godot --path . --resolution 1280x720 -s res://tests/ui_tour.gd -- --shots C:/путь/к/папке
## Без графики просто проверяет, что все экраны собираются и кадры идут (ошибки скриптов видны в выводе):
##   godot --headless --path . -s res://tests/ui_tour.gd

var shots_dir := ""
var shots := 0
var net: Node
var screen: Node
var _tried := {}   # уже выбранные ответы ("диалог/узел/индекс")


func _initialize() -> void:
	# сторож: если внутри прогона случится ошибка скрипта, корутина встанет — не висеть вечно
	create_timer(600.0).timeout.connect(_on_watchdog)
	_run()


func _on_watchdog() -> void:
	printerr("UI TOUR: FAIL — прогон завис (ошибка выше?)")
	quit(2)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i >= 0 and i + 1 < args.size() and DisplayServer.get_name() != "headless":
		shots_dir = args[i + 1]
		DirAccess.make_dir_recursive_absolute(shots_dir)
	net = root.get_node_or_null("Net")
	if net == null:
		printerr("UI TOUR: нет автозагрузки Net")
		quit(1)
		return
	# не по имени класса: title_screen.gd использует автозагрузку Net, а её имени ещё нет,
	# когда Godot компилирует скрипт из -s, — прогон тогда не собирается
	load("res://scripts/ui/title_screen.gd").set("allow_dedicated", false)
	# своя раскладка панели умений: прогон не должен затирать раскладку игрока (user://hotbars.json)
	var hotbar: GDScript = load("res://scripts/ui/hotbar.gd")
	hotbar.set("path", "user://test_hotbars.json")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_hotbars.json"))

	# титульный экран и выбор героев
	var title: Node = load("res://scenes/title.tscn").instantiate()
	root.add_child(title)
	current_scene = title
	await _wait(1.5)
	await _shot("01_title")
	title.call("_open_new")
	await _wait(0.5)
	await _shot("02_heroes")
	title.call("_add_pick", "ranger")   # к рыцарю и волшебнице по умолчанию: остаются волшебница и следопыт
	title.call("_start_solo")
	await _wait(0.5)
	screen = current_scene
	if screen == null or net.get("session") == null:
		printerr("UI TOUR: игра не началась")
		quit(1)
		return
	print("UI TOUR: игра началась, герои: ", _hero_names())

	# вступление: несколько реплик со снимками, остальное пролистать
	await _wait(2.5)
	await _shot("03_intro")
	for k in 5:
		_dialogue_step()
		await _wait(2.0)
		await _shot("04_intro_%d" % k)
	await _finish_dialogue()
	var s: GameSession = net.get("session")
	if s.mode == "combat":
		await _combat("05_cemetery")
	await _finish_dialogue()
	await _wait(2.0)
	await _shot("06_cemetery")

	# лист героя (снаряжение, сумка, страницы), журнал; в сумку — пара вещей, чтобы было что показать
	var bag: Dictionary = s.items
	for it in ["iron_helm", "silver_ring", "wolf_fang", "honey_cake"]:
		bag[it] = int(bag.get(it, 0)) + 1
	screen.call("open_panel", "sheet")
	await _wait(0.6)
	await _shot("07_sheet")
	var sheet: Node = screen.get("sheet")
	for pg in ["abilities", "skills", "talents"]:
		sheet.call("_set_page", pg)
		await _wait(0.4)
		await _shot("07_sheet_" + pg)
	sheet.call("_set_page", "stats")
	screen.call("open_panel", "journal")
	await _wait(0.6)
	await _shot("08_journal")
	screen.call("open_panel", "bag")
	await _wait(0.6)
	await _shot("08_bag")
	screen.call("open_panel", "")

	# деревня: туда идём по-настоящему, через выход с погоста; потом разговор с жителем
	await _walk_exit("village", "09_to_village", "10_village")
	s = net.get("session")
	if s.location_id != "village":
		await _goto("village", "from_cemetery", "10_village")
	s = net.get("session")
	if not s.npcs.is_empty():
		var npc: Character = s.npcs[0]
		for n in s.npcs:
			if (n as Character).template_id == "marta":
				npc = n
		net.call("send_command", {"type": "talk", "unit": str(screen.get("selected_uid")), "target": npc.uid})
		await _wait(4.0)
		await _shot("11_village_walk")
		await _wait(6.0)
		await _shot("11_talk")
		_dialogue_step()
		await _wait(2.0)
		await _shot("12_talk")
		await _finish_dialogue()
		await _wait(1.0)
		await _shot("13_tavern_inside")
		# путевой камень на площади: список камней
		net.call("send_command", {"type": "talk", "unit": str(screen.get("selected_uid")), "object": "waystone_village"})
		await _wait(7.0)
		await _shot("14_waystone")
		(screen.get("travel_panel") as Control).visible = false
		await _wait(0.5)
		await _shot("15_village_square")
		# камера отдалена до упора: пол без сетки квадратов, видна река
		var world_node: Node2D = screen.get("world")
		var ps := int(screen.get("_pixel_scale"))
		var wz := int(world_node.get("zoom"))
		for i in 4:
			screen.call("_zoom_step", -1)
		await _wait(0.8)
		await _shot("15_village_far")
		screen.set("_pixel_scale", ps)
		world_node.set("zoom", wz)
		(screen.get("container") as SubViewportContainer).stretch_shrink = ps
		# торговля: кузнец раскладывает товар
		s.gold += 120
		s.open_trade("gunter", int(net.call("my_id")), str(screen.get("selected_uid")))
		await _wait(1.5)
		await _shot("15_trade")
		screen.call("open_panel", "")

	# лес: через брод и выход на краю деревни, потом бой; курган
	await _walk_exit("forest", "16_village_ford", "20_forest")
	s = net.get("session")
	if s.location_id != "forest":
		await _goto("forest", "from_village", "20_forest")
	s = net.get("session")
	for e in s.location_data().get("encounters", []):
		if s.mode == "explore" and not s.encounter_defeated(str(e.get("id", ""))) and not bool(e.get("script", false)):
			s.start_encounter(str(e.get("id", "")))
			break
	if s.mode == "combat":
		await _combat("21_forest")
	await _finish_dialogue()
	# добыча: обыскать первое тело с мешком
	s = net.get("session")
	if s.mode == "explore" and not s.loot.is_empty():
		net.call("send_command", {"type": "loot", "unit": str(screen.get("selected_uid")), "corpse": str(s.loot.keys()[0])})
		await _wait(5.0)
		await _shot("22_loot")
		screen.call("open_panel", "")
	await _goto("goblin_camp", "from_forest", "30_goblin_camp")
	s = net.get("session")
	s.reveal_traps()
	await _wait(0.6)
	await _shot("31_camp_traps")

	# настройки и пауза
	(screen.get("settings") as Control).visible = true
	await _wait(0.4)
	await _shot("40_settings")
	(screen.get("settings") as Control).visible = false
	screen.call("open_panel", "menu")
	await _wait(0.4)
	await _shot("41_pause")
	screen.call("open_panel", "")
	await _wait(0.3)
	s = net.get("session")
	print("UI TOUR: OK, режим %s, локация %s, снимков %d" % [s.mode, s.location_id, shots])
	quit(0)


func _goto(loc: String, spawn: String, shot: String) -> void:
	var s: GameSession = net.get("session")
	if s.mode == "combat":
		await _combat("x_" + s.location_id)
	await _finish_dialogue()
	s.mode = "explore"
	s.goto_location(loc, spawn)
	await _wait(3.0)
	await _shot(shot)
	await _finish_dialogue()
	await _wait(1.0)


## Переход как в игре: партия идёт к выходу на карте; снимок по дороге и после того, как экран показал новую локацию.
func _walk_exit(to_loc: String, mid: String, after: String) -> void:
	await _finish_dialogue()
	var s: GameSession = net.get("session")
	var cell := Vector2i(-1, -1)
	for ex in s.location_data().get("exits", []):
		if str(ex.get("to", "")) == to_loc and not (ex.get("cells", []) as Array).is_empty():
			cell = Vector2i(int(ex["cells"][0][0]), int(ex["cells"][0][1]))
	if cell.x < 0:
		printerr("UI TOUR: нет выхода в ", to_loc)
		return
	net.call("send_command", {"type": "move", "unit": str(screen.get("selected_uid")), "cell": [cell.x, cell.y]})
	await _wait(6.0)
	await _shot(mid)
	var world: Node = screen.get("world")
	var guard := 0
	while str(world.get("loc_id")) != to_loc and guard < 80:
		guard += 1
		await _wait(0.5)
	await _wait(2.0)
	await _shot(after)
	s = net.get("session")
	if s.location_id != to_loc:
		print("UI TOUR: партия не перешла в ", to_loc, " пешком (", s.location_id, "), переносим")
	else:
		print("UI TOUR: переход пешком в ", to_loc, " OK")
	await _finish_dialogue()


func _hero_names() -> String:
	var s: GameSession = net.get("session")
	var out := PackedStringArray()
	for h in s.heroes:
		out.append((h as Character).display_name)
	return ", ".join(out)


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _shot(name: String) -> void:
	if shots_dir == "":
		return
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img != null:
		img.save_png(shots_dir.path_join(name + ".png"))
		shots += 1


func _dialogue_step() -> void:
	var s: GameSession = net.get("session")
	if s.mode != "dialogue":
		return
	var v := Story.view(s)
	var ch: Array = v.get("choices", [])
	if ch.is_empty():
		net.call("send_command", {"type": "dialogue_next"})
		return
	# первый ещё не выбранный ответ, иначе последний — так из «хаба» разговора можно выйти
	var where := "%s/%s/" % [v.get("id", ""), v.get("node", "")]
	var pick: Dictionary = ch[-1]
	for c in ch:
		if not _tried.has(where + str(c.get("index", 0))):
			pick = c
			break
	_tried[where + str(pick.get("index", 0))] = true
	net.call("send_command", {"type": "dialogue_choice", "index": int(pick.get("index", 0))})


func _finish_dialogue() -> void:
	var guard := 0
	while guard < 300:
		var s: GameSession = net.get("session")
		if s.mode != "dialogue":
			return
		guard += 1
		_dialogue_step()
		await process_frame
	printerr("UI TOUR: разговор не кончается")


## Бой: показать прицел, дальше герои ходят сами (ИИ), враги — как обычно на сервере.
func _combat(tag: String) -> void:
	await _wait(2.5)
	await _shot("%s_combat_start" % tag)
	var shown_target := false
	var turns := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 90000:
		var s: GameSession = net.get("session")
		if s.mode != "combat":
			break
		if bool(screen.call("is_my_turn")) and not bool(net.get("presentation_busy")):
			var cur: Character = s.combat.current
			if not shown_target:
				for sk in cur.skills:
					var def := GameData.skill(str(sk))
					if str(def.get("target", "")) != "self" and int(def.get("range", 1)) > 1:
						screen.call("select_skill", str(sk))
						break
				await _wait(0.6)
				await _shot("%s_combat_target" % tag)
				screen.set("selected_skill", "")
				shown_target = true
			s.run_ai_turn(true)
			net.call("_broadcast_state")
			turns += 1
			if turns == 3:
				await _wait(0.8)
				await _shot("%s_combat_mid" % tag)
		await _wait(0.2)
	await _wait(2.5)
	await _shot("%s_combat_end" % tag)
	var s2: GameSession = net.get("session")
	print("UI TOUR: бой %s закончился: %s, ходов героев %d" % [tag, s2.mode, turns])
	if s2.mode == "defeat":
		net.call("send_command", {"type": "restart"})
		await _wait(1.5)

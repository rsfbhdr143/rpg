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


func _initialize() -> void:
	_run()


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
	TitleScreen.allow_dedicated = false

	# титульный экран и выбор героев
	var title: Node = load("res://scenes/title.tscn").instantiate()
	root.add_child(title)
	current_scene = title
	await _wait(1.5)
	await _shot("01_title")
	title.call("_open_new")
	await _wait(0.5)
	await _shot("02_heroes")
	title.call("_toggle_pick", "ranger")
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
	for k in 4:
		_dialogue_step()
		await _wait(1.8)
		await _shot("04_intro_%d" % k)
	await _finish_dialogue()
	await _wait(2.0)
	await _shot("05_cemetery")

	# разговор с первым жителем, если он есть
	var s: GameSession = net.get("session")
	if not s.npcs.is_empty():
		var npc: Character = s.npcs[0]
		var hero := str(screen.get("selected_uid"))
		net.call("send_command", {"type": "talk", "unit": hero, "target": npc.uid})
		await _wait(2.5)
		await _shot("06_talk")
		await _finish_dialogue()
		await _wait(1.0)

	# лист героя, журнал, сумка
	screen.call("open_panel", "sheet")
	await _wait(0.6)
	await _shot("07_sheet")
	screen.call("open_panel", "journal")
	await _wait(0.6)
	await _shot("08_journal")
	screen.call("open_panel", "")

	# бой на погосте
	s = net.get("session")
	var encs: Array = s.location_data().get("encounters", [])
	for e in encs:
		if s.mode == "explore" and not s.encounter_defeated(str(e.get("id", ""))):
			s.start_encounter(str(e.get("id", "")))
			break
	if s.mode == "combat":
		await _combat("09")
	await _finish_dialogue()

	# остальные локации
	for loc in [["village", "from_cemetery"], ["forest", "from_village"], ["goblin_camp", "from_forest"]]:
		s = net.get("session")
		if s.mode == "combat":
			await _combat("x")
		s.mode = "explore"
		s.goto_location(str(loc[0]), str(loc[1]))
		await _wait(3.0)
		await _shot("20_%s" % loc[0])
		await _finish_dialogue()
		await _wait(1.0)
		if s.location_id == "forest":
			for e in s.location_data().get("encounters", []):
				if s.mode == "explore" and not s.encounter_defeated(str(e.get("id", ""))):
					s.start_encounter(str(e.get("id", "")))
					break
			if s.mode == "combat":
				await _combat("21_forest")
			await _finish_dialogue()

	# настройки и пауза
	(screen.get("settings") as Control).visible = true
	await _wait(0.4)
	await _shot("30_settings")
	(screen.get("settings") as Control).visible = false
	screen.call("open_panel", "menu")
	await _wait(0.4)
	await _shot("31_pause")
	screen.call("open_panel", "")
	await _wait(0.3)
	print("UI TOUR: OK, режим %s, локация %s, снимков %d" % [s.mode, s.location_id, shots])
	quit(0)


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
	else:
		net.call("send_command", {"type": "dialogue_choice", "index": int((ch[0] as Dictionary).get("index", 0))})


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

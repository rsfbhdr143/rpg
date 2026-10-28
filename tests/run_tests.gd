extends SceneTree
## Тесты ядра без графики. Запуск из папки проекта:
##   godot --headless -s res://tests/run_tests.gd
## (перед первым запуском открой проект в редакторе, чтобы Godot зарегистрировал классы)

var _failed := 0
var _passed := 0


func _init() -> void:
	GameData.reload_data()
	GameLog.echo_to_console = false
	for t in [
		"test_data_loaded", "test_derived_stats", "test_status_reactions",
		"test_surface_reactions", "test_armor_and_resist", "test_progression",
		"test_auto_battle", "test_serialization", "test_session_commands",
		"test_story_data", "test_dialogue_engine", "test_npcs_and_items", "test_respawn_and_scripted",
		"test_exploration", "test_events", "test_sprites", "test_balance", "test_party_and_explore_skills",
		"test_traps_and_surfaces",
	]:
		GameData.rng.seed = 12345
		GameLog.clear()
		GameEvents.clear()
		call(t)
	print("\nИтого: %d ок, %d ошибок" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func check(cond: bool, what: String) -> void:
	if cond:
		_passed += 1
		print("  ok   ", what)
	else:
		_failed += 1
		print("  FAIL ", what)


func dummy() -> Character:
	return Character.from_template("training_dummy")


func test_data_loaded() -> void:
	print("data")
	check(not GameData.skills.is_empty(), "навыки загружены")
	check(not GameData.statuses.is_empty(), "статусы загружены")
	check(not GameData.surfaces.is_empty(), "поверхности загружены")
	# все ссылки в данных указывают на существующие записи
	for sk in GameData.skills:
		for s in GameData.skill(sk).get("statuses", []):
			check(GameData.statuses.has(s["id"]), "%s -> статус %s существует" % [sk, s["id"]])
	for ch in GameData.characters:
		for sk in GameData.character(ch).get("skills", []):
			check(GameData.skills.has(sk), "%s -> навык %s существует" % [ch, sk])
	for loc in GameData.locations:
		var ld := GameData.location(loc)
		for ex in ld.get("exits", []):
			var to := str(ex.get("to", ""))
			check(GameData.locations.has(to) and GameData.location(to).get("spawns", {}).has(str(ex.get("spawn", ""))),
				"%s -> выход в %s:%s существует" % [loc, to, ex.get("spawn", "")])
		for enc in ld.get("encounters", []):
			for e in enc.get("enemies", []):
				check(GameData.characters.has(str(e["template"])), "%s -> враг %s существует" % [loc, e["template"]])


func test_derived_stats() -> void:
	print("derived stats")
	var c := dummy()
	var hp_before := c.max_hp()
	c.attributes["constitution"] = 8
	check(c.max_hp() > hp_before, "телосложение повышает макс. ОЗ")
	var ap_before := c.get_stat("max_ap")
	c.talents.append("lone_wolf")
	check(is_equal_approx(c.get_stat("max_ap"), ap_before + 2), "талант добавляет модификатор")
	c.statuses["wet"] = {"turns": 2, "level": 1}
	check(c.get_resistance("air") < 0, "мокрый: сопротивление воздуху снижено")


func test_status_reactions() -> void:
	print("status reactions")
	var c := dummy()
	StatusSystem.apply(c, "wet")
	check(c.has_status("wet"), "мокрый наложен")
	StatusSystem.apply(c, "burning")
	check(not c.has_status("burning"), "мокрого нельзя поджечь")
	StatusSystem.apply(c, "chilled")
	check(c.has_status("frozen") and not c.has_status("wet"), "мокрый + озноб = заморозка")
	check(not c.can_act(), "замороженный пропускает ход")
	StatusSystem.apply(c, "burning")
	check(not c.has_status("frozen") and c.has_status("wet"), "огонь растапливает лёд -> мокрый")
	StatusSystem.apply(c, "shocked")
	check(c.has_status("stunned"), "мокрый + электричество = оглушение")

	var z := dummy()
	z.talents.append("walk_it_off")
	StatusSystem.apply(z, "poisoned")
	check(int(z.statuses["poisoned"]["turns"]) == int(GameData.status("poisoned")["duration"]) - 1, "талант сокращает негативный статус")

	var t := dummy()
	StatusSystem.apply(t, "poisoned")
	var hp := t.hp
	StatusSystem.on_turn_start(t)
	check(t.hp < hp, "яд наносит урон в начале хода")
	t.talents.append("zombie")
	t.hp = 10
	StatusSystem.on_turn_start(t)
	check(t.hp > 10, "зомби лечится ядом")


func test_surface_reactions() -> void:
	print("surface reactions")
	var g := SurfaceGrid.new(8, 8)
	g.apply_element(Vector2i(2, 2), 1, "water", true)
	check(g.get_ground(Vector2i(1, 1)) == "water", "дождь создаёт воду")
	g.apply_element(Vector2i(3, 3), 0, "air", false)
	check(g.get_ground(Vector2i(1, 1)) == "electrified_water", "электричество растекается по луже")
	g.tick_round()
	g.tick_round()
	check(g.get_ground(Vector2i(1, 1)) == "water", "ток в воде истекает обратно в воду")
	g.apply_element(Vector2i(2, 2), 0, "fire", false)
	check(g.get_ground(Vector2i(2, 2)) == "none" and g.get_cloud(Vector2i(2, 2)) == "steam", "огонь + вода = пар")
	g.apply_element(Vector2i(2, 2), 0, "air", false)
	check(g.get_cloud(Vector2i(2, 2)) == "electrified_steam", "пар + электричество")

	g.set_surface(Vector2i(6, 6), "poison")
	var ex := g.apply_element(Vector2i(6, 6), 0, "fire", false)
	check(ex.size() == 1 and g.get_ground(Vector2i(6, 6)) == "fire", "яд + огонь = взрыв и огонь")

	g.set_surface(Vector2i(0, 7), "oil")
	g.set_surface(Vector2i(1, 7), "oil")
	g.apply_element(Vector2i(0, 7), 0, "fire", false)
	check(g.get_ground(Vector2i(1, 7)) == "fire", "масло вспыхивает целиком")


func test_armor_and_resist() -> void:
	print("armor & resist")
	var a := dummy()
	var b := dummy()
	var raw := 100.0
	check(is_equal_approx(DamageCalc.mitigate(b, raw, "physical", 1), raw), "без брони урон не режется")
	b.base_stats["armor"] = 30
	check(DamageCalc.mitigate(b, raw, "physical", 1) < raw, "броня режет физический урон")
	check(DamageCalc.mitigate(b, raw, "physical", 10) > DamageCalc.mitigate(b, raw, "physical", 1), "броня хуже против высокоуровневых")
	b.base_stats["fire_res"] = 50
	check(is_equal_approx(DamageCalc.mitigate(b, raw, "fire", 1), 50.0), "50% сопротивления огню")
	b.base_stats["fire_res"] = -50
	check(is_equal_approx(DamageCalc.mitigate(b, raw, "fire", 1), 150.0), "отрицательное сопротивление усиливает урон")
	check(DamageCalc.hit_chance(a, b) >= 5.0 and DamageCalc.hit_chance(a, b) <= 95.0, "шанс попадания в пределах")


func test_progression() -> void:
	print("progression")
	var c := dummy()
	var need := Progression.xp_to_next(1)
	var lv := Progression.add_xp(c, need)
	check(lv == 1 and c.level == 2, "повышение уровня")
	check(c.unspent_attribute_points == 1 and c.unspent_ability_points == 1, "очки за уровень")
	check(Progression.raise_attribute(c, "strength") and int(c.attributes["strength"]) == 6, "вложить очко в атрибут")
	check(Progression.raise_ability(c, "pyrokinetic") and c.ability_rank("pyrokinetic") == 1, "вложить очко в способность")
	check(not Progression.raise_ability(c, "pyrokinetic"), "без очков нельзя")
	check(Progression.learn_skill(c, "flare"), "выучить навык с нужным рангом школы")
	check(not Progression.learn_skill(c, "fireball"), "нельзя выучить навык без ранга")
	c.unspent_talent_points = 1
	c.level = 3
	check(Progression.learn_talent(c, "bigger_and_better") and c.unspent_attribute_points == 1, "талант с бонусом при изучении")


func test_auto_battle() -> void:
	print("auto battle")
	var g := SurfaceGrid.new(12, 8)
	var k := Character.from_template("knight")
	var w := Character.from_template("wizard")
	var e1 := Character.from_template("goblin_warrior")
	var e2 := Character.from_template("goblin_shaman")
	k.cell = Vector2i(1, 3)
	w.cell = Vector2i(0, 5)
	e1.cell = Vector2i(10, 3)
	e2.cell = Vector2i(11, 5)
	var combat := CombatManager.new(g)
	combat.start([k, w, e1, e2])
	var guard := 0
	while combat.active and guard < 500:
		guard += 1
		SimpleAI.take_turn(combat, combat.current)
	check(not combat.active, "бой завершился (%d ходов, %d раундов)" % [guard, combat.round_number])
	check(combat.winner_faction != "", "есть победитель: %s" % combat.winner_faction)
	var winner_xp := false
	for u in combat.living_units():
		if u.xp > 0 or u.level > int(GameData.character(u.template_id).get("level", 1)):
			winner_xp = true
	check(winner_xp or combat.winner_faction == "enemy", "победители получили опыт")


func test_serialization() -> void:
	print("serialization")
	var g := SurfaceGrid.new(10, 6)
	g.blocked[Vector2i(5, 1)] = true
	g.set_surface(Vector2i(2, 2), "water")
	g.set_surface(Vector2i(3, 3), "steam")
	var k := Character.from_template("knight")
	var e := Character.from_template("goblin_warrior")
	k.cell = Vector2i(1, 1)
	e.cell = Vector2i(8, 4)
	StatusSystem.apply(k, "wet")
	var combat := CombatManager.new(g)
	combat.start([k, e])
	var copy := CombatManager.from_dict(combat.to_dict())
	check(copy.units.size() == 2, "персонажи восстановлены")
	check(copy.current != null and copy.current.uid == combat.current.uid, "текущий ход восстановлен")
	check(copy.grid.get_ground(Vector2i(2, 2)) == "water" and copy.grid.get_cloud(Vector2i(3, 3)) == "steam", "поверхности восстановлены")
	check(copy.grid.blocked.has(Vector2i(5, 1)), "стены восстановлены")
	var ck: Character = copy.units[0]
	check(ck.has_status("wet") and ck.cell == k.cell and is_equal_approx(ck.hp, k.hp), "статусы, клетка и ОЗ восстановлены")
	check(is_equal_approx(ck.get_stat("max_hp"), k.get_stat("max_hp")), "производные характеристики совпадают")
	check(var_to_str(copy.to_dict()) == var_to_str(combat.to_dict()), "повторная сериализация даёт тот же снимок")


func test_session_commands() -> void:
	print("session (multiplayer without network)")
	var s := GameSession.new()
	check(s.add_player(1, "Аня") and s.add_player(2, "Борис"), "два игрока")
	check(s.add_player(3, "Вера") and s.add_player(4, "Гоша"), "до четырёх игроков")
	check(not s.add_player(5, "Лишний"), "пятый не помещается")
	s.remove_player(3)
	s.remove_player(4)
	s.new_game({1: ["ranger"], 2: ["cleric"]})
	check(s.heroes.size() == 2, "по герою на игрока")
	check(s.heroes[0].template_id == "ranger" and s.heroes[1].template_id == "cleric", "герои по выбору игроков")
	check(s.owner_of(s.heroes[0]) == 1 and s.owner_of(s.heroes[1]) == 2, "герои раздаются игрокам")
	check(s.location_id == str(GameData.rule("start_location", "")), "игра начинается в стартовой локации")
	check(s.mode == "dialogue" and str(s.dialogue.get("id", "")) == "funeral", "новая игра начинается с похорон")
	check(int(s.dialogue["pid"]) == 1, "отвечает лидер")
	check(s.submit(2, {"type": "dialogue_next"}) != "", "не лидер не листает разговор")
	var h0: Character = s.heroes[0]
	check(s.submit(1, {"type": "move", "unit": h0.uid, "cell": [h0.cell.x + 1, h0.cell.y]}) != "", "во время разговора ходить нельзя")
	_drive(s, true)
	check(s.mode == "explore" and s.location_id == "village", "после похорон и боя партия в деревне")
	var target := _free_neighbor(s, h0.cell)
	check(s.submit(2, {"type": "move", "unit": h0.uid, "cell": [target.x, target.y]}) != "", "чужим героем ходить нельзя")
	check(s.submit(1, {"type": "move", "unit": h0.uid, "cell": [target.x, target.y]}) == "" and h0.cell == target, "свой герой идёт")
	check(s.submit(1, {"type": "end_turn"}) != "", "вне боя нет ходов")

	h0.unspent_attribute_points = 1
	check(s.submit(1, {"type": "raise_attribute", "unit": h0.uid, "attribute": "strength"}) == "", "очко атрибута через команду")
	check(s.submit(2, {"type": "raise_ability", "unit": h0.uid, "ability": "bow"}) != "", "чужого героя прокачивать нельзя")

	var mirror := GameSession.new()
	mirror.load_snapshot(s.snapshot())
	check(mirror.heroes.size() == 2 and mirror.owner_of(mirror.heroes[1]) == 2, "клиентское зеркало из снимка")
	check(mirror.grid != null and mirror.location_id == s.location_id, "зеркало знает локацию")
	check(mirror.quests.get("last_will", "") == s.quests.get("last_will", "x") and mirror.flags.size() == s.flags.size(), "зеркало знает задания и флаги")
	check(mirror.npcs.size() == s.npcs.size() and mirror.npcs.size() > 0, "зеркало видит NPC")
	s.remove_player(2)
	check(s.owner_of(s.heroes[1]) == 1, "герой ушедшего игрока переходит другому")

	var solo := GameSession.new()
	solo.add_player(1, "Соло")
	solo.create_party()
	check(solo.heroes.size() == 2, "одиночка ведёт двух героев, как в D:OS1")
	solo.create_party({1: ["cleric", "ranger"]})
	check(solo.heroes[0].template_id == "cleric" and solo.heroes[1].template_id == "ranger", "одиночка выбирает двух героев")


func _free_neighbor(s: GameSession, c: Vector2i) -> Vector2i:
	for d in SurfaceGrid.DIRS:
		var n: Vector2i = c + d
		if s.grid.is_walkable(n) and s.unit_at(n) == null and s.exit_at(n).is_empty():
			return n
	return c


## Ведёт героя к клетке; если путь прервался (бой), возвращает false.
func _walk(s: GameSession, h: Character, to: Vector2i) -> String:
	return s.submit(s.owner_of(h), {"type": "move", "unit": h.uid, "cell": [to.x, to.y]})


## Проматывает разговоры (первый ещё не выбранный ответ, иначе последний — из «хаба» разговора так можно выйти)
## и бои (ИИ за всех). strong — герои неуязвимы, чтобы не проиграть.
func _drive(s: GameSession, strong := false, max_steps := 800) -> void:
	var guard := 0
	var tried := {}
	while guard < max_steps:
		guard += 1
		if s.mode == "dialogue":
			var pid := int(s.dialogue["pid"])
			var vis := Story.visible_choices(s)
			if vis.is_empty():
				s.submit(pid, {"type": "dialogue_next"})
			else:
				var where := "%s/%s/" % [s.dialogue["id"], s.dialogue["node"]]
				var pick: Dictionary = vis[-1]
				for v in vis:
					if not tried.has(where + str(v["index"])):
						pick = v
						break
				tried[where + str(pick["index"])] = true
				s.submit(pid, {"type": "dialogue_choice", "index": int(pick["index"])})
		elif s.mode == "combat":
			if strong:
				for h in s.heroes:
					h.base_stats["max_hp"] = 900
					if h.is_alive():
						h.hp = h.max_hp()
			s.run_ai_turn(true)
		else:
			return


func test_story_data() -> void:
	print("story data")
	check(not GameData.dialogues.is_empty(), "диалоги сюжета загружены")
	check(GameData.load_warnings.is_empty(), "карты и сюжет сходятся%s" % ("" if GameData.load_warnings.is_empty() else ": " + "; ".join(GameData.load_warnings)))
	var bad: Array = []
	for did in GameData.dialogues:
		var d := GameData.dialogue(did)
		var nodes: Dictionary = d.get("nodes", {})
		if not nodes.has(str(d.get("start", ""))):
			bad.append("%s: нет стартового узла" % did)
		for nid in nodes:
			var n: Dictionary = nodes[nid]
			var nexts: Array = []
			for x in [n.get("next")]:
				nexts.append_array(_next_ids(x))
			for c in n.get("choices", []):
				nexts.append_array(_next_ids(c.get("next")))
				var chk: Dictionary = c.get("check", {})
				if not chk.is_empty():
					nexts.append(str(chk.get("fail", "")))
					if not GameData.attribute_list().has(Story.attribute_id(str(chk.get("attr", "")))):
						bad.append("%s/%s: проверка неизвестного атрибута %s" % [did, nid, chk.get("attr")])
			for nx in nexts:
				if nx != "" and not nodes.has(nx):
					bad.append("%s/%s: нет узла %s" % [did, nid, nx])
			var sp := str(n.get("speaker", "narrator"))
			if not (sp in ["narrator", "hero"] or GameData.characters.has(sp)):
				bad.append("%s/%s: неизвестный говорящий %s" % [did, nid, sp])
			var effs: Array = n.get("do", []).duplicate()
			for c in n.get("choices", []):
				effs.append_array(c.get("do", []))
			for e in effs:
				if e.has("quest") and GameData.quest(str(e["quest"])).is_empty():
					bad.append("%s/%s: нет задания %s" % [did, nid, e["quest"]])
				for k in ["give_item", "take_item"]:
					if e.has(k) and GameData.item(str(e[k])).is_empty():
						bad.append("%s/%s: нет предмета %s" % [did, nid, e[k]])
				if e.has("goto"):
					var loc := GameData.location(str(e["goto"]))
					if loc.is_empty() or not (loc.get("spawns", {}) as Dictionary).has(str(e.get("spawn", ""))):
						bad.append("%s/%s: нет точки %s:%s" % [did, nid, e["goto"], e.get("spawn", "")])
				if e.has("combat") and not _encounter_exists(str(e["combat"])):
					bad.append("%s/%s: нет встречи %s" % [did, nid, e["combat"]])
	for nid in GameData.npcs:
		var dl: Variant = GameData.npc(nid).get("dialogue", "")
		for opt in (dl if typeof(dl) == TYPE_ARRAY else [dl]):
			var id := str(opt.get("id", "")) if typeof(opt) == TYPE_DICTIONARY else str(opt)
			if id != "" and GameData.dialogue(id).is_empty():
				bad.append("NPC %s: нет диалога %s" % [nid, id])
	for lid in GameData.locations:
		var loc := GameData.location(lid)
		for o in loc.get("objects", []):
			if o.has("dialogue") and GameData.dialogue(str(o["dialogue"])).is_empty():
				bad.append("%s: у предмета %s нет диалога %s" % [lid, o.get("id"), o["dialogue"]])
		if str(loc.get("on_enter", "")) != "" and GameData.dialogue(str(loc["on_enter"])).is_empty():
			bad.append("%s: нет диалога входа %s" % [lid, loc["on_enter"]])
	check(bad.is_empty(), "ссылки сюжета целы%s" % ("" if bad.is_empty() else ": " + "; ".join(bad.slice(0, 12))))


func _next_ids(x: Variant) -> Array:
	if x == null:
		return []
	if typeof(x) == TYPE_ARRAY:
		return x.map(func(o): return str(o.get("id", "")) if typeof(o) == TYPE_DICTIONARY else str(o))
	return [str(x)]


func _encounter_exists(id: String) -> bool:
	for lid in GameData.locations:
		for enc in GameData.location(lid).get("encounters", []):
			if str(enc.get("id", "")) == id:
				return true
	return false


func test_dialogue_engine() -> void:
	print("dialogue engine")
	GameData.dialogues["_t"] = {"start": "a", "nodes": {
		"a": {"speaker": "narrator", "text": "Привет, {hero}.", "do": [{"set_flag": "t_seen"}], "next": "b"},
		"b": {"speaker": "hero", "text": "Ну?", "choices": [
			{"text": "Сила", "check": {"attr": "strength", "min": 99, "fail": "f"}, "next": "ok"},
			{"text": "Тайный", "if": {"flag": "nope"}, "next": "ok"},
			{"text": "Золото", "do": [{"gold": 5}, {"give_item": "funeral_bread", "count": 2}], "next": [{"if": {"gold_min": 5}, "id": "rich"}, {"id": "f"}]}]},
		"f": {"speaker": "narrator", "text": "Неудача.", "next": "b"},
		"rich": {"next": "end"},
		"end": {"speaker": "narrator", "text": "Конец.", "do": [{"quest": "last_will", "stage": "prepare"}, {"xp": 10}]},
		"ok": {"speaker": "narrator", "text": "Ок."}}}
	var s := _story_session()
	check(s.start_dialogue("_t", 1), "диалог начался")
	var v := Story.view(s)
	check(s.mode == "dialogue" and v["text"].contains(s.heroes[0].display_name), "подстановка {hero}")
	check(s.flags.has("t_seen"), "эффект узла сработал при входе")
	s.submit(1, {"type": "dialogue_next"})
	var vis := Story.visible_choices(s)
	check(vis.size() == 2, "скрытый ответ не показан")
	s.submit(1, {"type": "dialogue_choice", "index": 0})
	check(str(s.dialogue["node"]) == "f", "проверка атрибута не прошла -> fail")
	s.submit(1, {"type": "dialogue_next"})
	var xp: int = s.heroes[0].xp + s.heroes[0].level * 1000   # опыт даёт узел end при входе
	s.submit(1, {"type": "dialogue_choice", "index": 2})
	check(s.gold == 5 and int(s.items.get("funeral_bread", 0)) == 2, "золото и предметы")
	check(str(s.dialogue["node"]) == "end", "next списком и невидимый узел")
	s.submit(1, {"type": "dialogue_next"})
	check(s.mode == "explore" and s.dialogue.is_empty(), "разговор закончился")
	check(s.quests.get("last_will", "") == "prepare", "стадия задания")
	check(s.heroes[0].xp + s.heroes[0].level * 1000 > xp, "опыт за диалог")
	s.set_quest_stage("last_will", "funeral")
	check(s.quests["last_will"] == "prepare", "стадия задания не откатывается")
	GameData.dialogues.erase("_t")


func _story_session(start := "village", classes: Array = ["knight", "wizard"]) -> GameSession:
	var s := GameSession.new()
	s.add_player(1, "Соло")
	s.create_party({1: classes})
	s.flags["intro_done"] = true
	s.quests["last_will"] = "prepare"
	s.enter_location(start, "from_cemetery" if start == "village" else "from_village")
	s.mode = "explore"
	s.dialogue = {}
	return s


func test_npcs_and_items() -> void:
	print("NPC, talk, items, equipment")
	var s := _story_session()
	var marta: Character = null
	for n in s.npcs:
		if n.template_id == "marta":
			marta = n
	check(marta != null, "Марта в деревне после похорон")
	check(not s.npcs.any(func(n): return n.template_id == "vetla"), "Ветлы в деревне нет")
	var h: Character = s.heroes[0]
	check(s.submit(1, {"type": "talk", "unit": h.uid, "target": marta.uid}) == "", "заговорить с Мартой")
	check(s.mode == "dialogue" and str(s.dialogue["id"]) == "marta_village", "разговор с Мартой")
	check(SurfaceGrid.distance(h.cell, marta.cell) <= 1, "герой подошёл к Марте")
	_drive(s)
	check(int(s.items.get("lamp_oil", 0)) > 0 and s.gold >= 40, "Марта дала масло и золото")   # золото — во второй реплике
	check(s.mode == "explore", "разговор закончен")
	s.give_item("healing_brew", 1)
	h.hp = 5
	StatusSystem.apply(h, "poisoned")
	check(s.submit(1, {"type": "use_item", "unit": h.uid, "item": "healing_brew"}) == "" and h.hp > 5, "отвар лечит")
	check(not h.has_status("poisoned") and not s.items.has("healing_brew"), "отвар выводит яд и тратится")
	var acc := h.get_stat("accuracy")
	s.give_item("order_of_bravery", 1, "knight")
	check(h.equipment.has("order_of_bravery") and h.get_stat("accuracy") > acc, "наследство надето на рыцаря и даёт бонус")
	s.give_item("gravedigger_lantern", 1)
	check(s.submit(1, {"type": "equip", "unit": h.uid, "item": "gravedigger_lantern"}) == "" and h.equipment.has("gravedigger_lantern"), "надеть предмет из сумки")
	check(s.submit(1, {"type": "unequip", "unit": h.uid, "item": "gravedigger_lantern"}) == "" and s.items.has("gravedigger_lantern"), "снять предмет в сумку")
	check(Story.check(s, {"has_item": "order_of_bravery"}), "надетый предмет считается в has_item")
	var copy := Character.from_dict(h.to_dict())
	check(copy.equipment.has("order_of_bravery"), "снаряжение сохраняется")


func test_respawn_and_scripted() -> void:
	print("respawn, scripted encounters, on_defeat")
	var s := _story_session("forest")
	s.mode = "explore"
	check(not s.enemies.any(func(e): return e.encounter_id == "forest_scout"), "сценарная встреча не появляется сама")
	check(s.trigger_radius("forest_scout") == 0, "сценарная встреча не нападает при сближении")
	var pack: Array = s.enemies.filter(func(e): return e.encounter_id == "forest_wolf_pack")
	check(not pack.is_empty(), "стая для прокачки на месте")
	s.start_encounter("forest_wolf_pack")
	check(s.mode == "combat", "бой со стаей")
	_drive(s, true)
	check(s.encounter_defeated("forest_wolf_pack"), "стая побеждена")
	s.enter_location("village", "from_forest")
	s.mode = "explore"
	s.dialogue = {}
	s.enter_location("forest", "from_village")
	var again: Array = s.enemies.filter(func(e): return e.encounter_id == "forest_wolf_pack" and e.is_alive())
	check(not again.is_empty() and not s.encounter_defeated("forest_wolf_pack"), "стая вернулась после перехода (можно качаться)")
	s.mode = "explore"
	s.dialogue = {}
	s.start_encounter("forest_wolves")
	_drive(s, true, 4)
	while s.mode == "combat":
		s.run_ai_turn(true)
		for hh in s.heroes:
			hh.base_stats["max_hp"] = 900
	check(s.mode == "dialogue" and str(s.dialogue.get("id", "")) == "goat_rescue", "после победы — диалог on_defeat")


func test_exploration() -> void:
	print("exploration, transitions, combat on the map, save/load")
	var s := _story_session()
	var h0: Character = s.heroes[0]
	var h1: Character = s.heroes[1]

	# Деревня -> лес через выход.
	var ex: Dictionary = {}
	for e in s.location_data()["exits"]:
		if str(e["to"]) == "forest":
			ex = e
	var ec: Array = ex["cells"][0]
	check(_walk(s, h0, Vector2i(int(ec[0]), int(ec[1]))) == "", "дойти до выхода")
	check(s.location_id == "forest", "партия перешла в лес")
	var spawn: Array = s.location_data()["spawns"][str(ex["spawn"])]
	check(SurfaceGrid.distance(h0.cell, Vector2i(int(spawn[0][0]), int(spawn[0][1]))) <= 2, "герои у точки входа")
	_drive(s)   # разговор при первом входе в лес
	check(s.mode == "explore", "можно ходить")
	var forest_enemies := s.enemies.size()
	check(forest_enemies > 0, "в лесу есть враги")

	# Спутник идёт следом.
	var dest := Vector2i(6, 6)
	_walk(s, h0, dest)
	check(SurfaceGrid.distance(h1.cell, h0.cell) <= 2, "спутник идёт за героем")

	# Подходим к врагам — начинается бой прямо на карте.
	var foe: Character = null
	for e in s.enemies:
		if e.encounter_id == "forest_wolf_pack":
			foe = e
	_walk(s, h0, foe.cell + Vector2i(-1, 1))
	check(s.mode == "combat" and s.combat != null and s.combat.active, "враги заметили партию, начался бой")
	check(SurfaceGrid.distance(h0.cell, foe.cell) > 1, "движение остановилось, когда враги заметили")
	var guard := 0
	while s.mode == "combat" and guard < 400:
		guard += 1
		s.run_ai_turn(true)
	check(s.mode != "combat", "бой закончился (%d ходов)" % guard)
	if s.mode == "defeat":
		check(s.submit(1, {"type": "restart"}) == "" and s.mode == "explore", "после поражения — снова у входа")
	else:
		check(s.defeated_encounters().size() >= 1, "группа врагов отмечена побеждённой")
		check(s.heroes.all(func(h): return h.is_alive()), "павшие герои поднялись после победы")

	# Сохранение и загрузка.
	var path := "user://test_save.json"
	s.flags["test_flag"] = true
	s.give_item("funeral_bread", 3)
	check(s.save_game(path) == "", "сохранение записано")
	var loc := s.location_id
	var xp := h0.xp
	var hp := h0.hp
	var gold := s.gold
	h0.xp += 999
	s.flags.erase("test_flag")
	s.enter_location("village", "from_forest")
	s.mode = "explore"
	s.dialogue = {}
	check(s.load_game(path) == "", "сохранение загружено")
	var h0l: Character = s.heroes[0]
	check(s.location_id == loc and h0l.xp == xp and is_equal_approx(h0l.hp, hp), "локация, опыт и ОЗ восстановлены")
	check(s.flags.has("test_flag") and int(s.items.get("funeral_bread", 0)) >= 3 and s.gold == gold, "флаги, предметы и золото восстановлены")
	check(s.quests.get("last_will", "") != "", "задания восстановлены")
	var uids := {}
	for u in s.all_units():
		uids[u.uid] = true
	check(not uids.has(Character.from_template("wolf").uid), "новые персонажи не повторяют uid загруженных")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_events() -> void:
	print("presentation events")
	GameEvents.clear()
	var s := _story_session("forest")
	s.mode = "explore"
	s.start_encounter("forest_wolf_pack")
	var types := {}
	for e in GameEvents.list:
		types[str(e["type"])] = true
	check(types.has("combat_start") and types.has("turn"), "события начала боя")
	var guard := 0
	while s.mode == "combat" and guard < 300:
		guard += 1
		s.run_ai_turn(true)
	for e in GameEvents.list:
		types[str(e["type"])] = true
	check(types.has("cast") and (types.has("hit") or types.has("miss")), "события ударов")
	check(types.has("combat_end"), "событие конца боя")
	var mirror := GameSession.new()
	mirror.load_snapshot(s.snapshot())
	check(not GameEvents.list.is_empty() and int(GameEvents.list[-1]["seq"]) == GameEvents.seq, "события приходят в снимке")


func test_balance() -> void:
	print("balance (ИИ за обе стороны, только для сведения)")
	for party in [["knight", "wizard"], ["ranger", "cleric"], ["knight", "wizard", "ranger", "cleric"]]:
		# третий элемент — уровень, с которым партия обычно приходит к этому бою
		for enc in [["cemetery", "cemetery_rising", 1], ["forest", "forest_wolf_pack", 2], ["goblin_camp", "camp_gate", 3]]:
			var wins := 0
			for i in 10:
				GameData.rng.seed = 1000 + i
				var s := GameSession.new()
				for p in party.size():
					s.add_player(p + 1, "И%d" % p)
				var choices := {}
				for p in party.size():
					choices[p + 1] = [party[p]]
				s.create_party(choices)
				for h in s.heroes:
					while (h as Character).level < int(enc[2]):
						Progression.add_xp(h, Progression.xp_to_next((h as Character).level) - (h as Character).xp)
				s.enter_location(enc[0], "from_village" if enc[0] != "goblin_camp" else "from_forest")
				s.mode = "explore"
				s.dialogue = {}
				s.flags["aggro:" + enc[1]] = true
				s.start_encounter(enc[1])
				var guard := 0
				while s.mode == "combat" and guard < 500:
					guard += 1
					s.run_ai_turn(true)
				if s.mode != "defeat":
					wins += 1
			print("    %s (ур. %d) против %s: побед %d из 10" % ["+".join(party), int(enc[2]), enc[1], wins])
	check(true, "баланс посчитан")


func test_sprites() -> void:
	print("sprites")
	SpriteLibrary.reload_data()
	check(typeof(SpriteLibrary.bindings.get("settings")) == TYPE_DICTIONARY, "data/sprites.json загружен")
	for cat in ["units", "tiles", "surfaces", "skills", "statuses"]:
		var table: Dictionary = SpriteLibrary.bindings.get(cat, {})
		for id in table:
			check(SpriteLibrary.has_sprite(cat, id), "%s/%s -> спрайт есть в art/catalog.json" % [cat, id])
	for aid in SpriteLibrary.assets:
		var sheet := str(SpriteLibrary.assets[aid].get("sheet", ""))
		check(ResourceLoader.exists(sheet) or FileAccess.file_exists(sheet), "лист %s существует" % sheet)
	check(SpriteLibrary.frame("units", "нет_такого").is_empty(), "без привязки — пустой кадр (рисуется заглушка)")


func test_party_and_explore_skills() -> void:
	print("same classes, hero names, skills outside combat, holy light vs undead")
	var solo := GameSession.new()
	solo.add_player(1, "Соло")
	solo.create_party({1: ["knight", "knight"]})
	check(solo.heroes.size() == 2 and solo.heroes.all(func(h): return h.template_id == "knight"), "два рыцаря в одном отряде")
	var names: Array = (GameData.rule("hero_names", {}) as Dictionary).get("knight", [])
	check(names.size() >= 2 and solo.heroes[0].display_name == str(names[0]) and solo.heroes[1].display_name == str(names[1]),
		"у героев одного класса разные имена из списка")
	var duo := GameSession.new()
	duo.add_player(1, "Аня")
	duo.add_player(2, "Борис")
	duo.create_party({1: ["cleric"], 2: ["cleric"]})
	check(duo.heroes.size() == 2 and duo.heroes.all(func(h): return h.template_id == "cleric"), "два игрока выбрали один класс")
	check(duo.heroes[0].display_name != duo.heroes[1].display_name, "и у них разные имена")

	var s := _story_session("village", ["cleric", "knight"])
	var cl: Character = s.heroes[0]
	var kn: Character = s.heroes[1]
	kn.hp = 5
	var ap := cl.ap
	var heal := {"type": "skill", "unit": cl.uid, "skill": "minor_heal", "cell": [kn.cell.x, kn.cell.y]}
	check(s.submit(1, heal) == "" and kn.hp > 5, "лечение вне боя")
	check(s.mode == "explore" and cl.ap == ap, "лечение союзника не начинает бой и не тратит ОД")
	check(cl.cooldowns.has("minor_heal") and s.submit(1, heal) != "", "навык ушёл на перезарядку")
	check(s.submit(1, {"type": "skill", "unit": cl.uid, "skill": "battering_ram", "cell": [kn.cell.x, kn.cell.y]}) != "", "чужой навык нельзя")
	var cd := int(cl.cooldowns["minor_heal"])
	check(not s.pass_time(1.0) and int(cl.cooldowns["minor_heal"]) == cd, "время копится до «хода»")
	check(s.pass_time(3.5) and int(cl.cooldowns.get("minor_heal", 0)) == cd - 1, "через несколько секунд перезарядка идёт")
	for i in cd:
		s.pass_time(float(GameData.rule("explore_turn_seconds", 4.0)))
	check(not cl.cooldowns.has("minor_heal") and s.submit(1, heal) == "", "навык снова готов")

	var bone := Character.from_template("skeleton")
	check(bone.is_undead() and not kn.is_undead(), "скелет — нежить, рыцарь — нет")
	bone.cell = _free_neighbor(s, cl.cell)
	var field := s.explore_field()
	field.units.append(bone)
	var mend := GameData.skill("minor_heal")
	check(SkillSystem.target_block_reason(field, cl, mend, bone.cell) == "", "лечение наводится на нежить")
	var hp0 := bone.hp
	SkillSystem.execute(field, cl, mend, bone.cell)
	check(bone.hp < hp0, "лечение жжёт нежить")
	var wolf := Character.from_template("wolf")
	wolf.cell = bone.cell
	bone.cell = Vector2i(-50, -50)
	field.units.append(wolf)
	check(SkillSystem.target_block_reason(field, cl, mend, wolf.cell) != "", "живого врага лечить нельзя")

	var hit := {"damage": {"source": "skill", "element": "fire", "multiplier": 1.0}}
	var zombie := Character.from_template("skeleton")
	var paladin := Character.from_template("knight")
	GameData.rng.seed = 77
	var plain := float(DamageCalc.roll_attack(paladin, zombie, hit)["amount"])
	StatusSystem.apply(paladin, "blessed")
	GameData.rng.seed = 77
	var holy := float(DamageCalc.roll_attack(paladin, zombie, hit)["amount"])
	check(paladin.has_status("blessed") and holy > plain, "благословлённый бьёт нежить сильнее")

	var f := _story_session("forest", ["wizard", "cleric"])
	var wz: Character = f.heroes[0]
	var prey: Character = null
	for e in f.enemies:
		if e.encounter_id == "forest_wolf_pack" and e.is_alive():
			prey = e
	check(prey != null, "стая в лесу")
	var spot := wz.cell
	for c in f.grid.cells_in_radius(prey.cell, 4):
		if SurfaceGrid.distance(c, prey.cell) >= 3 and f.grid.is_walkable(c) and f.unit_at(c) == null:
			spot = c
			break
	wz.cell = spot
	check(f.submit(1, {"type": "skill", "unit": wz.uid, "skill": "ice_shard", "cell": [prey.cell.x, prey.cell.y]}) == "", "удар издалека вне боя")
	check(f.mode == "combat", "удар по врагу начинает бой")


## Свободная клетка пола на расстоянии dist от from (без людей, выходов, предметов, ловушек и поверхностей),
## не ближе far к героям.
func _floor_cell(s: GameSession, from: Vector2i, dist: int, far := 0) -> Vector2i:
	for c in s.grid.cells_in_radius(from, dist):
		if SurfaceGrid.distance(c, from) != dist or not s.grid.is_walkable(c) or s.unit_at(c) != null:
			continue
		if not s.exit_at(c).is_empty() or not s.object_at(c).is_empty() or s.grid.traps.has(c) or s.grid.get_ground(c) != "none":
			continue
		if s.heroes.any(func(h): return SurfaceGrid.distance(h.cell, c) < far):
			continue
		return c
	return Vector2i(-1, -1)


func test_traps_and_surfaces() -> void:
	print("traps: spot, avoid, disarm, spring, blow up; surfaces outside combat")
	var cfg: Dictionary = GameData.rules["traps"]
	var saved := cfg.duplicate()
	check(GameData.trap("fire_rune").has("surface") and (GameData.location("forest").get("traps", []) as Array).size() >= 2,
		"виды ловушек загружены, в лесу они стоят")

	var s := _story_session("village", ["ranger", "knight"])
	var h: Character = s.heroes[0]
	var k: Character = s.heroes[1]
	var spot := _floor_cell(s, h.cell, 2)
	s.grid.traps[spot] = {"type": "spike_plate", "state": "hidden", "rolled": {}}
	cfg["max_chance"] = 100.0
	h.base_stats["trap_detect"] = 200
	check(TrapSystem.look_around(s.grid, h) == [spot] and str(s.grid.traps[spot]["state"]) == "found", "зоркий герой замечает ловушку")
	check(TrapSystem.look_around(s.grid, h).is_empty(), "второй раз не бросает")
	var beyond := _floor_cell(s, spot, 2, 3)
	if beyond.x >= 0:
		s.submit(1, {"type": "move", "unit": h.uid, "cell": [beyond.x, beyond.y]})
		check(str(s.grid.traps[spot]["state"]) == "found", "найденную ловушку герои обходят")
	var mirror := GameSession.new()
	mirror.load_snapshot(s.snapshot())
	check(str(mirror.grid.traps.get(spot, {}).get("state", "")) == "found", "клиент видит найденную ловушку")
	h.base_stats["trap_disarm"] = 200
	var xp := h.xp
	check(s.submit(1, {"type": "disarm", "unit": h.uid, "cell": [spot.x, spot.y]}) == "", "команда обезвредить")
	check(str(s.grid.traps[spot]["state"]) == "disarmed" and h.xp > xp, "ловушка обезврежена, за неё опыт")
	check(SurfaceGrid.distance(h.cell, spot) <= 1 and h.cell != spot, "герой подошёл, но не наступил")
	check(s.submit(1, {"type": "disarm", "unit": h.uid, "cell": [spot.x, spot.y]}) != "", "обезвреженную второй раз не трогают")

	cfg["min_chance"] = 0.0
	cfg["max_chance"] = 0.0
	h.base_stats.erase("trap_detect")
	k.base_stats["trap_detect"] = -500
	var plate := _floor_cell(s, h.cell, 2)
	s.grid.traps[plate] = {"type": "spike_plate", "state": "hidden", "rolled": {}}
	h.hp = 2
	s.submit(1, {"type": "move", "unit": h.uid, "cell": [plate.x, plate.y]})
	check(str(s.grid.traps[plate]["state"]) == "sprung" and h.cell == plate, "наступил на спрятанную — сработала")
	check(h.is_alive() and h.hp >= 1.0, "вне боя ловушка не добивает")
	check(s.mode == "explore", "в деревне бой не начался")

	cfg["max_chance"] = 100.0
	var rune := _floor_cell(s, h.cell, 4, 3)
	s.grid.traps[rune] = {"type": "fire_rune", "state": "found", "rolled": {}}
	var shot := {"type": "skill", "unit": h.uid, "skill": "arrow_shot", "cell": [rune.x, rune.y]}
	check(SkillSystem.target_block_reason(s.explore_field(), h, GameData.skill("arrow_shot"), rune) == "", "в найденную ловушку можно целиться")
	check(s.submit(1, shot) == "" and str(s.grid.traps[rune]["state"]) == "sprung", "выстрел подрывает ловушку издалека")
	check(s.grid.get_ground(rune) == "fire", "руна выплеснула огонь")
	for i in 6:
		s.pass_time(float(GameData.rule("explore_turn_seconds", 4.0)))
	check(s.grid.get_ground(rune) != "fire", "огонь прогорает и вне боя")

	cfg["max_chance"] = 0.0
	cfg["fail_spring_pct"] = 100.0
	var pot := _floor_cell(s, h.cell, 1)
	s.grid.traps[pot] = {"type": "poison_pot", "state": "found", "rolled": {}}
	check(TrapSystem.try_disarm(s.explore_field(), h, pot) == "sprung" and s.grid.get_ground(pot) == "poison", "неудача задевает механизм")

	var oil_at := _floor_cell(s, h.cell, 3, 2)
	s.give_item("lamp_oil", 1)
	s.give_item("tar_torch", 1)
	check(s.submit(1, {"type": "use_item", "unit": h.uid, "item": "lamp_oil", "cell": [oil_at.x, oil_at.y]}) == "" and s.grid.get_ground(oil_at) == "oil",
		"масло разливается и вне боя")
	check(s.submit(1, {"type": "use_item", "unit": h.uid, "item": "tar_torch", "cell": [oil_at.x, oil_at.y]}) == "" and s.grid.get_ground(oil_at) == "fire",
		"брошенный факел поджигает масло")
	check(not s.items.has("lamp_oil") and not s.items.has("tar_torch"), "масло и факел потрачены")

	var restored := GameSession.new()
	restored.add_player(1, "Соло")
	restored.from_save(s.to_save())
	check(str(restored.grid.traps.get(spot, {}).get("state", "")) == "disarmed" and str(restored.grid.traps.get(rune, {}).get("state", "")) == "sprung",
		"ловушки сохраняются")

	var f := _story_session("forest")
	var swamp := Vector2i(15, 9)
	check(f.grid.get_ground(swamp) == "poison" and int(f.grid.layers["ground"][swamp]["turns"]) == -1, "болото с карты не высыхает")
	check(f.grid.traps.values().all(func(tr): return str(tr["state"]) in ["hidden", "found"]), "ловушки леса взведены")
	var camp := _story_session("goblin_camp")
	camp.reveal_traps()
	check(camp.grid.traps.size() == 2 and camp.grid.traps.values().all(func(tr): return str(tr["state"]) == "found"), "Шмыг показывает ловушки лагеря")

	cfg.clear()
	cfg.merge(saved)

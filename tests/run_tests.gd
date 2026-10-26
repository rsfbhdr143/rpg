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
	]:
		GameData.rng.seed = 12345
		GameLog.clear()
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
	s.create_party()
	check(s.heroes.size() == 2, "по герою на игрока")
	check(s.owner_of(s.heroes[0]) == 1 and s.owner_of(s.heroes[1]) == 2, "герои раздаются игрокам")
	s.start_encounter()
	check(s.combat != null and s.combat.active, "бой начался")
	var guard := 0
	while s.is_ai_turn() and guard < 50:
		guard += 1
		s.run_ai_turn()
	if s.combat.active:
		var cur := s.combat.current
		var owner := s.owner_of(cur)
		var other: int = 2 if owner == 1 else 1
		check(s.submit(other, {"type": "end_turn"}) != "", "чужой игрок не может ходить")
		check(s.submit(owner, {"type": "skill", "skill": "nope", "cell": [0, 0]}) != "", "неизвестный навык отклонён")
		check(s.submit(owner, {"type": "end_turn"}) == "", "владелец заканчивает ход")
		check(s.combat.current != cur or not s.combat.active, "ход перешёл дальше")
	var mirror := GameSession.new()
	mirror.load_snapshot(s.snapshot())
	check(mirror.heroes.size() == 2 and mirror.owner_of(mirror.heroes[1]) == 2, "клиентское зеркало из снимка")
	s.remove_player(2)
	check(s.owner_of(s.heroes[1]) == 1, "герой ушедшего игрока переходит другому")

	var solo := GameSession.new()
	solo.add_player(1, "Соло")
	solo.create_party()
	check(solo.heroes.size() == 2, "одиночка ведёт двух героев, как в D:OS1")

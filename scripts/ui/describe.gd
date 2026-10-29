extends RefCounted
## Тексты подсказок: названия характеристик по-русски, что делает статус, сколько урона наносит навык.
## Всё считается из data/*.json: поменяли цифры в статусе или навыке — поменялась и подсказка.
## Подключается через preload (без class_name), чтобы его видели и headless-тесты.

const GOOD := "#9ad248"
const BAD := "#e8806a"
const NOTE := "#a89a80"
const DIM := "#6e6454"

const STAT_NAMES := {
	"max_hp": "здоровье", "max_ap": "запас ОД", "start_ap": "ОД в начале боя", "ap_recovery": "ОД за ход",
	"initiative": "инициатива", "move_per_ap": "клеток за 1 ОД", "accuracy": "точность", "dodge": "уклонение",
	"crit_chance": "шанс крита", "crit_multiplier": "сила крита", "physical_damage_pct": "физический урон",
	"magic_damage_pct": "урон магии", "armor": "броня", "armor_bonus_pct": "броня",
	"fire_res": "сопротивление огню", "water_res": "сопротивление воде", "earth_res": "сопротивление земле",
	"air_res": "сопротивление воздуху", "poison_res": "сопротивление яду", "tenacity_res": "стойкость",
	"range_bonus": "дальность", "trap_find": "поиск ловушек", "trap_disarm": "обезвреживание ловушек",
}
## Эти характеристики пишутся в процентах.
const PERCENT := ["accuracy", "dodge", "crit_chance", "physical_damage_pct", "magic_damage_pct", "armor_bonus_pct",
	"fire_res", "water_res", "earth_res", "air_res", "poison_res", "tenacity_res", "trap_find", "trap_disarm"]

const ELEMENTS := {"physical": "физический", "fire": "огонь", "water": "вода", "earth": "земля", "air": "воздух",
	"poison": "яд", "holy": "святой свет", "frost": "холод", "heal": "лечение", "": "физический"}
const ELEMENT_OF := {"physical": "физического", "fire": "огнём", "water": "водой", "earth": "землёй",
	"air": "молнией", "poison": "ядом", "holy": "святым светом", "": "физического"}
const RES_OF := {"fire": "сопротивление огню", "water": "сопротивление воде", "earth": "сопротивление земле",
	"air": "сопротивление воздуху", "poison": "сопротивление яду", "tenacity": "стойкость"}


static func stat_name(key: String) -> String:
	return str(STAT_NAMES.get(key, key))


static func element_name(el: String) -> String:
	return str(ELEMENTS.get(el, el))


## «точность +10%», «клеток за 1 ОД −0,5»; цвет по знаку (плюс — хорошо).
static func modifier(key: String, value: float, colored := true) -> String:
	var num := ("%d" % roundi(value)) if is_equal_approx(value, roundf(value)) else ("%.1f" % value).replace(".", ",")
	if value > 0:
		num = "+" + num
	else:
		num = num.replace("-", "−")
	if key in PERCENT:
		num += "%"
	var t := "%s %s" % [stat_name(key), num]
	if not colored:
		return t
	return "[color=%s]%s[/color]" % [GOOD if value > 0 else BAD, t]


static func modifiers(mods: Dictionary, colored := true) -> String:
	# Все пять стихий с одним числом пишем коротко.
	var el := ["fire_res", "water_res", "earth_res", "air_res", "poison_res"]
	var parts := PackedStringArray()
	var same := el.all(func(k): return mods.has(k) and is_equal_approx(float(mods[k]), float(mods[el[0]])))
	if same:
		var v := float(mods[el[0]])
		var t := "сопротивления стихиям %s%d%%" % ["+" if v > 0 else "−", absi(roundi(v))]
		parts.append(("[color=%s]%s[/color]" % [GOOD if v > 0 else BAD, t]) if colored else t)
	for k in mods:
		if same and str(k) in el:
			continue
		parts.append(modifier(str(k), float(mods[k]), colored))
	return ", ".join(parts)


## Урон или лечение за ход у статуса: «4 урона огнём», «лечит 6».
static func tick_text(tick: Dictionary, level: int) -> String:
	var amount := roundi(GameData.scaled(tick, level))
	var el := str(tick.get("element", ""))
	if el == "heal":
		return "лечит %d" % amount
	return "%d урона %s" % [amount, ELEMENT_OF.get(el, el)]


## Полное описание статуса для подсказки (BBCode). turns > 0 — сколько ходов осталось.
static func status_text(id: String, turns := -1, level := 1) -> String:
	var d := GameData.status(id)
	if d.is_empty():
		return id
	var neg := bool(d.get("negative", false))
	var lines := PackedStringArray()
	var head := "[b][color=%s]%s[/color][/b]" % [BAD if neg else GOOD, d.get("name", id)]
	if turns > 0:
		head += "  [color=%s]ещё %d х.[/color]" % [NOTE, turns]
	else:
		head += "  [color=%s]%d х.[/color]" % [NOTE, int(d.get("duration", 1))]
	lines.append(head)
	if d.has("description"):
		lines.append("[color=%s]%s[/color]" % [NOTE, d["description"]])
	lines.append_array(status_effects(id, level))
	return "\n".join(lines)


## Строки «что делает» статуса без названия и описания.
static func status_effects(id: String, level := 1) -> PackedStringArray:
	var d := GameData.status(id)
	var lines := PackedStringArray()
	if bool(d.get("skip_turn", false)):
		lines.append("[color=%s]Пропускает ход[/color]" % BAD)
	if d.has("tick"):
		var tick: Dictionary = d["tick"]
		lines.append("В начале хода: [color=%s]%s[/color]" % [GOOD if str(tick.get("element", "")) == "heal" else BAD,
			tick_text(tick, level)])
	var mods: Dictionary = d.get("modifiers", {})
	if not mods.is_empty():
		lines.append(modifiers(mods))
	if d.has("vs_undead_damage"):
		lines.append("[color=%s]урон по нежити +%d%%[/color]" % [GOOD, int(d["vs_undead_damage"])])
	var rm: Array = d.get("removes", [])
	rm = rm.filter(func(r): return str(r) != id)
	if not rm.is_empty():
		lines.append("Снимает: %s" % _names(rm))
	var bl: Array = d.get("blocked_by", [])
	if not bl.is_empty():
		lines.append("Не ложится на того, кто %s" % _names(bl).to_lower())
	for r in GameData.status_reactions:
		var re: Dictionary = r
		if str(re.get("has", "")) == id and str(re.get("result", "")) != "":
			lines.append("[color=%s]+ %s → %s[/color]" % [NOTE, GameData.status(str(re["incoming"])).get("name", re["incoming"]),
				GameData.status(str(re["result"])).get("name", re["result"])])
	if d.has("resist_by"):
		lines.append("[color=%s]Шанс наложить снижает %s[/color]" % [DIM, RES_OF.get(str(d["resist_by"]), d["resist_by"])])
	return lines


static func _names(ids: Array) -> String:
	var out := PackedStringArray()
	for r in ids:
		out.append(str(GameData.status(str(r)).get("name", r)))
	return ", ".join(out)


## Одна строка про статус в подсказке навыка: «Горит (2 х., 50%): 4 урона огнём».
static func status_short(sd: Dictionary, level := 1) -> String:
	var id := str(sd.get("id", ""))
	var d := GameData.status(id)
	var dur := int(sd.get("duration", d.get("duration", 1)))
	var chance := int(sd.get("chance", 100))
	var head := "[color=%s]%s[/color] %d х." % [BAD if bool(d.get("negative", false)) else GOOD, d.get("name", id), dur]
	if chance < 100:
		head += ", шанс %d%%" % chance
	if str(sd.get("on", "target")) == "self":
		head += ", на себя"
	var what := PackedStringArray()
	if bool(d.get("skip_turn", false)):
		what.append("пропуск хода")
	if d.has("tick"):
		what.append(tick_text(d["tick"], level) + " в ход")
	var mods: Dictionary = d.get("modifiers", {})
	if not mods.is_empty():
		what.append(modifiers(mods, false))
	if what.is_empty():
		return head
	return "%s: [color=%s]%s[/color]" % [head, NOTE, "; ".join(what)]


## Разброс урона навыка строкой: «12–17 огнём, крит 15% ×1,5». С целью — после её защиты.
static func damage_line(u: Character, def: Dictionary, target: Character = null) -> String:
	var p := DamageCalc.preview(u, def, target)
	if p.is_empty():
		return ""
	var el := str(p["element"])
	var t := "[color=%s]%d–%d[/color] %s" % [UiTheme.element_color(el).to_html(false), int(p["min"]), int(p["max"]),
		"физического урона" if el == "physical" else "урона " + str(ELEMENT_OF.get(el, el))]
	if float(p["crit_chance"]) > 0.0:
		t += ", крит %d%% ×%s" % [roundi(float(p["crit_chance"])), ("%.1f" % float(p["crit_multiplier"])).replace(".", ",")]
	return t


## Что значит характеристика (подсказка в листе героя).
const STAT_INFO := {
	"max_hp": "Сколько урона герой выдержит. Растёт с уровнем и Телосложением.",
	"max_ap": "Очки действия: шаг, удар, заклинание стоят ОД. Больше запас — больше дел за ход.",
	"ap_recovery": "Сколько ОД возвращается в начале каждого хода. Неистраченные копятся до запаса.",
	"initiative": "Кто раньше ходит в бою. Зависит от Восприятия и Скорости.",
	"move_per_ap": "Сколько клеток герой проходит за одно очко действия.",
	"accuracy": "Шанс попасть оружием = точность героя − уклонение цели (от 5 до 95%).",
	"dodge": "Насколько труднее по герою попасть оружием. Заклинания не уворачиваются.",
	"crit_chance": "Шанс удара в уязвимое место: урон умножается на силу крита.",
	"crit_multiplier": "Во сколько раз крит сильнее обычного удара.",
	"physical_damage_pct": "Прибавка к урону оружием и физическими приёмами.",
	"magic_damage_pct": "Прибавка к урону огнём, водой, воздухом, землёй, ядом и святым светом.",
	"armor": "Режет физический урон. Чем выше уровень врага, тем меньше от брони толку.",
	"tenacity_res": "Сопротивление оглушению, сбиванию с ног и страху.",
}


## Что даёт одно очко атрибута: «здоровье +6, стойкость +3%».
static func attribute_effects(attr: String) -> String:
	var parts := PackedStringArray()
	var derived: Dictionary = GameData.rule("derived", {})
	for stat in derived:
		var a: Dictionary = (derived[stat] as Dictionary).get("attr", {})
		if a.has(attr):
			parts.append(modifier(str(stat), float(a[attr]), false))
	return ", ".join(parts)


const SLOT_GLYPH := {"head": "helm", "amulet": "bead", "chest": "shield", "weapon": "sword", "offhand": "shield",
	"hands": "hand", "belt": "ring", "legs": "boot", "feet": "boot", "ring": "ring"}
const TYPE_NAMES := {"weapon": "оружие", "armor": "доспех", "trinket": "украшение", "consumable": "расходник",
	"loot": "добыча", "quest": "для задания"}


## Описание предмета для подсказки (BBCode): ячейка, урон, прибавки, действие, цена.
static func item_text(id: String, price_line := "") -> String:
	var d := GameData.item(id)
	if d.is_empty():
		return id
	var lines := PackedStringArray()
	lines.append("[b][color=#f0dcae]%s[/color][/b]" % d.get("name", id))
	var kind := str(TYPE_NAMES.get(str(d.get("type", "")), ""))
	var slot := Character.slot_of(id) if (d.has("slot") or d.has("stats") or d.has("weapon")) else ""
	var sub := PackedStringArray()
	if slot != "":
		sub.append(str(Character.SLOT_NAMES.get(slot, slot)))
	if kind != "":
		sub.append(kind)
	if not sub.is_empty():
		lines.append("[color=%s]%s[/color]" % [DIM, " · ".join(sub)])
	var w: Dictionary = d.get("weapon", {})
	if not w.is_empty():
		var extra := PackedStringArray()
		if bool(w.get("two_handed", false)):
			extra.append("двуручное")
		if bool(w.get("ranged", false)):
			extra.append("стреляет")
		lines.append("Урон [color=#ecdfc2]%d–%d[/color] %s%s" % [int(w.get("min", 0)), int(w.get("max", 0)),
			"физический" if str(w.get("element", "physical")) == "physical" else element_name(str(w.get("element", ""))),
			(" · " + ", ".join(extra)) if not extra.is_empty() else ""])
	var stats: Dictionary = d.get("stats", {})
	for k in stats:
		lines.append(modifier(str(k), float(stats[k])))
	var use: Dictionary = d.get("use", {})
	if use.has("heal"):
		lines.append("[color=%s]Лечит %d[/color]" % [GOOD, int(use["heal"])])
	if use.has("remove_status"):
		lines.append("[color=%s]Снимает: %s[/color]" % [GOOD, _names(use["remove_status"])])
	if use.has("skill"):
		var sk := GameData.skill(str(use["skill"]))
		lines.append("[color=%s]Как навык «%s»: выберите и укажите клетку[/color]" % [GOOD, sk.get("name", use["skill"])])
	if d.has("description"):
		lines.append("[color=%s]%s[/color]" % [NOTE, d["description"]])
	if price_line != "":
		lines.append(price_line)
	elif int(d.get("value", 0)) > 0:
		lines.append("[color=#f0c860]Цена: %d з.[/color]" % int(d["value"]))
	return "\n".join(lines)


## Способность: описание и что даёт каждый ранг.
static func ability_text(ab: String, rank: int) -> String:
	var d := GameData.ability(ab)
	var lines := PackedStringArray()
	lines.append("[b][color=#f0dcae]%s[/color][/b]  [color=%s]ранг %d[/color]" % [d.get("name", ab), NOTE, rank])
	if d.has("description"):
		lines.append("[color=%s]%s[/color]" % [NOTE, d["description"]])
	var pr: Dictionary = d.get("per_rank", {})
	if not pr.is_empty():
		lines.append("За ранг: " + modifiers(pr))
	var sk := PackedStringArray()
	for id in GameData.skills:
		var s := GameData.skill(str(id))
		if str(s.get("ability", "")) == ab and not bool(s.get("item_only", false)):
			sk.append("%s (%d)" % [s.get("name", id), int(s.get("ability_rank", 1))])
	if not sk.is_empty():
		lines.append("[color=%s]Навыки (нужный ранг): %s[/color]" % [DIM, ", ".join(sk)])
	return "\n".join(lines)

class_name Story
extends RefCounted
## Сюжет: условия, эффекты и диалоги из data/story/*.json. Работает на сервере (меняет сессию)
## и на клиенте (только читает: какие ответы показать, кто говорит).
##
## Диалог (data/story/dialogues.json):
##   "id": {"start": "узел", "style": "cinematic"?, "nodes": {"узел": {
##       "speaker": "tadeush" | "narrator" | "hero" | "knight"…, "text": "…", "text_party": "…"?, "image": "intro_1"?,
##       "next": "узел" | [{"if": {…}, "id": "узел"}, …]?, "do": [эффекты]?,
##       "choices": [{"text": "…", "next": …, "if": {…}?, "do": [...]?, "check": {"attr", "min", "fail"}?, "end": true?}]?}}}
## Условие — словарь, все ключи должны выполниться: flag, not_flag, quest + stage, quest_active, quest_done,
##   party_min, hero, has_item, has_skill, gold, level, defeated, any (список условий, хватит одного), all.
## Эффекты — список словарей: set_flag, clear_flag, quest + stage, give_item (+count), take_item, xp, gold, combat,
##   heal_party, status, goto (+spawn), music, ambient, sfx, stinger, shake, show_npc, hide_npc, end_demo, narrate.
## combat, goto и end_demo завершают разговор и выполняются, когда игрок дочитал реплику.

const TERMINAL := ["combat", "goto", "end_demo"]
const PRESENTATION := ["music", "ambient", "sfx", "stinger", "shake", "tip"]
const DONE_STAGES := ["done", "complete", "completed", "finished", "end"]


# --- Условия ------------------------------------------------------------------

static func check(s: GameSession, cond: Variant, hero: Character = null) -> bool:
	if cond == null:
		return true
	if typeof(cond) == TYPE_ARRAY:
		for c in cond:
			if not check(s, c, hero):
				return false
		return true
	if typeof(cond) != TYPE_DICTIONARY:
		return true
	var d: Dictionary = cond
	for key in d:
		if not _check_key(s, str(key), d[key], d, hero):
			return false
	return true


static func _check_key(s: GameSession, key: String, v: Variant, d: Dictionary, hero: Character) -> bool:
	match key:
		"flag", "flags":
			for f in _list(v):
				if not s.flags.has(str(f)):
					return false
			return true
		"not_flag", "not_flags":
			for f in _list(v):
				if s.flags.has(str(f)):
					return false
			return true
		"quest":
			var stage := str(s.quests.get(str(v), ""))
			if not d.has("stage"):
				return stage != ""
			return _list(d["stage"]).map(func(x): return str(x)).has(stage)
		"stage", "count":
			return true   # разбираются вместе с quest / has_item
		"quest_active":
			return s.quests.has(str(v)) and not quest_done(s, str(v))
		"quest_done":
			return quest_done(s, str(v))
		"quest_not_started":
			return not s.quests.has(str(v))
		"party_min":
			return s.heroes.size() >= int(v)
		"players_min":
			return s.players.size() >= int(v)
		"hero":
			for t in _list(v):
				if s.heroes.any(func(h): return h.template_id == str(t)):
					return true
			return false
		"speaker_hero":
			return hero != null and _list(v).map(func(x): return str(x)).has(hero.template_id)
		"has_item":
			var need := int(d.get("count", 1))
			for it in _list(v):
				if s.item_count(str(it)) < need:
					return false
			return true
		"has_skill":
			for sk in _list(v):
				if s.heroes.any(func(h): return h.is_alive() and h.skills.has(str(sk))):
					return true
			return false
		"gold", "gold_min":
			return s.gold >= int(v)
		"level":
			return s.heroes.any(func(h): return h.level >= int(v))
		"defeated":
			return s.encounter_defeated(str(v))
		"any":
			for c in _list(v):
				if check(s, c, hero):
					return true
			return false
		"all":
			return check(s, v, hero)
		"not":
			return not check(s, v, hero)
	push_warning("Story: неизвестное условие '%s'" % key)
	return true


static func _list(v: Variant) -> Array:
	return v if typeof(v) == TYPE_ARRAY else [v]


# --- Задания ------------------------------------------------------------------

static func quest_def(id: String) -> Dictionary:
	return GameData.quest(id)


static func stage_def(quest_id: String, stage_id: String) -> Dictionary:
	var stages: Variant = quest_def(quest_id).get("stages", [])
	if typeof(stages) == TYPE_DICTIONARY:
		var sd: Dictionary = stages.get(stage_id, {})
		var out := sd.duplicate()
		out["id"] = stage_id
		return out
	for st in stages:
		if str(st.get("id", "")) == stage_id:
			return st
	return {}


## Этапы задания по порядку (список словарей с id).
static func stages(quest_id: String) -> Array:
	var raw: Variant = quest_def(quest_id).get("stages", [])
	if typeof(raw) == TYPE_ARRAY:
		return raw
	var out: Array = []
	for k in raw:
		out.append(stage_def(quest_id, str(k)))
	return out


static func is_done_stage(quest_id: String, stage_id: String) -> bool:
	var sd := stage_def(quest_id, stage_id)
	return bool(sd.get("done", sd.get("complete", false))) or DONE_STAGES.has(stage_id)


static func is_failed_stage(quest_id: String, stage_id: String) -> bool:
	return bool(stage_def(quest_id, stage_id).get("failed", false)) or stage_id == "failed"


static func quest_done(s: GameSession, quest_id: String) -> bool:
	return s.quests.has(quest_id) and is_done_stage(quest_id, str(s.quests[quest_id]))


# --- Эффекты (только на сервере) --------------------------------------------------

## Выполняет эффекты. Завершающие (combat, goto, end_demo) не выполняет, а возвращает списком,
## если collect_terminal=true (диалог выполнит их, когда игрок дочитает реплику).
static func apply(s: GameSession, effects: Variant, hero: Character = null, collect_terminal := false) -> Array:
	var deferred: Array = []
	var list := _list(effects)
	# если в списке есть бой или переход, всё, кроме звука и тряски, ждёт, пока игрок дочитает реплику
	var has_terminal := collect_terminal and list.any(func(e): return typeof(e) == TYPE_DICTIONARY \
		and (e as Dictionary).keys().any(func(k): return TERMINAL.has(str(k))))
	for e in list:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var ed: Dictionary = e
		if has_terminal and not ed.keys().all(func(k): return PRESENTATION.has(str(k))):
			deferred.append(ed)
			continue
		_apply_one(s, ed, hero)
	return deferred


static func _apply_one(s: GameSession, e: Dictionary, hero: Character) -> void:
	for key in e:
		var v: Variant = e[key]
		match str(key):
			"set_flag", "flag":
				for f in _list(v):
					s.flags[str(f)] = true
			"clear_flag", "unset_flag", "remove_flag":
				for f in _list(v):
					s.flags.erase(str(f))
			"quest":
				s.set_quest_stage(str(v), str(e.get("stage", "start")))
			"give_item":
				s.give_item(str(v), int(e.get("count", 1)), str(e.get("to", "")))
			"take_item", "remove_item":
				s.give_item(str(v), -int(e.get("count", 1)))
			"xp":
				s.give_xp(int(v))
			"gold":
				s.give_gold(int(v))
			"heal_party", "heal":
				for h in s.heroes:
					h.hp = h.max_hp()
					h.death_handled = false
					h.statuses.clear()
				GameEvents.add("heal_party", {})
			"status":
				var targets: Array = s.heroes
				if str(e.get("target", "party")) == "hero" and hero != null:
					targets = [hero]
				for h in targets:
					StatusSystem.apply(h, str(v), int(e.get("duration", -1)), h.level)
			"goto":
				var spawn := str(e.get("spawn", ""))
				s.goto_location(str(v), spawn)
			"combat":
				s.start_encounter(str(v))
			"show_npc":
				for n in _list(v):
					s.flags["show:" + str(n)] = true
					s.flags.erase("hide:" + str(n))
			"hide_npc":
				for n in _list(v):
					s.flags["hide:" + str(n)] = true
					s.flags.erase("show:" + str(n))
			"end_demo":
				s.flags["demo_end"] = true
				GameEvents.add("demo_end", {})
			"music", "ambient", "sfx", "stinger":
				GameEvents.add(str(key), {"id": str(v)})
			"shake":
				GameEvents.add("shake", {"power": float(v)})
			"narrate":
				GameEvents.add("narrate", {"title": str(e.get("title", "")), "text": str(v)})
			"tip":
				GameEvents.add("tip", {"text": str(v)})
			"reveal_traps":
				s.reveal_traps()
			"trade":   # разговор кончается, и торговец раскладывает товар перед тем, кто говорил
				s.open_trade(str(v), int(s.dialogue.get("pid", s.leader_id())), str(s.dialogue.get("hero", "")))
			"count", "stage", "spawn", "target", "duration", "title", "to":
				pass   # параметры соседних эффектов
			_:
				push_warning("Story: неизвестный эффект '%s'" % key)
	s.refresh_world()


# --- Диалоги ------------------------------------------------------------------

static func dialogue_def(id: String) -> Dictionary:
	return GameData.dialogue(id)


static func node_def(s: GameSession) -> Dictionary:
	if s.dialogue.is_empty():
		return {}
	var nodes: Dictionary = dialogue_def(str(s.dialogue["id"])).get("nodes", {})
	return nodes.get(str(s.dialogue["node"]), {})


static func speaking_hero(s: GameSession) -> Character:
	if s.dialogue.is_empty():
		return null
	var h := s.unit_by_uid(str(s.dialogue.get("hero", "")))
	if h == null and not s.heroes.is_empty():
		h = s.heroes[0]
	return h


## Куда ведёт next: строка или список [{"if", "id"}] (первый подходящий). "" — конец.
static func resolve_next(s: GameSession, next: Variant, hero: Character) -> String:
	if next == null:
		return ""
	if typeof(next) == TYPE_ARRAY:
		for opt in next:
			if typeof(opt) == TYPE_DICTIONARY:
				if check(s, opt.get("if"), hero):
					return str(opt.get("id", opt.get("next", "")))
			else:
				return str(opt)
		return ""
	return str(next)


## Какие варианты ответа видит игрок: [{"index": индекс в choices, "text", "check"?}].
static func visible_choices(s: GameSession) -> Array:
	var node := node_def(s)
	var hero := speaking_hero(s)
	var out: Array = []
	var choices: Array = node.get("choices", [])
	for i in choices.size():
		var c: Dictionary = choices[i]
		if not check(s, c.get("if"), hero):
			continue
		var text := substitute(s, str(c.get("text", "…")), hero)
		var chk: Dictionary = c.get("check", {})
		if not chk.is_empty():
			text = "[%s %d] %s" % [attribute_name(str(chk.get("attr", ""))), int(chk.get("min", 0)), text]
		var v := {"index": i, "text": text}
		if c.has("page"):
			v["page"] = int(c["page"])   # ответ-листок доски объявлений (DialogueBox.BoardLayer)
		out.append(v)
	return out


## Всё, что нужно интерфейсу, чтобы показать текущую реплику.
static func view(s: GameSession) -> Dictionary:
	var node := node_def(s)
	if node.is_empty():
		return {}
	var hero := speaking_hero(s)
	var speaker := str(node.get("speaker", "narrator"))
	var speaker_unit: Character = null
	var name := ""
	var portrait := speaker
	if speaker == "hero" or (GameData.characters.has(speaker) and str(GameData.character(speaker).get("faction", "")) == "player"):
		speaker_unit = hero
		if speaker != "hero":
			for h in s.heroes:
				if h.template_id == speaker:
					speaker_unit = h
		if speaker_unit != null:
			name = speaker_unit.display_name
			portrait = speaker_unit.template_id
	elif speaker != "narrator" and speaker != "":
		var npc := GameData.npc(speaker)
		var ch := GameData.character(speaker)
		name = str(npc.get("name", ch.get("name", speaker)))
		portrait = str(npc.get("portrait", speaker))
	var text := str(node.get("text", ""))
	if node.has("text_party") and s.players.size() > 1:
		text = str(node["text_party"])
	var def := dialogue_def(str(s.dialogue["id"]))
	return {
		"id": str(s.dialogue["id"]),
		"node": str(s.dialogue["node"]),
		"speaker": speaker,
		"name": name,
		"portrait": portrait if speaker != "narrator" else "",
		"text": substitute(s, text, hero),
		"image": str(node.get("image", "")),
		"style": str(node.get("style", def.get("style", "box"))),
		"board": def.get("board", {}),      # style "board": доска с листками (DialogueBox.BoardLayer)
		"page": int(node.get("page", -1)),  # какой листок доски сейчас читают
		"choices": visible_choices(s),
		"pid": int(s.dialogue.get("pid", 0)),
	}


static func substitute(s: GameSession, text: String, hero: Character) -> String:
	if hero != null:
		text = text.replace("{hero}", hero.display_name).replace("{name}", hero.display_name)
	var names: Array = []
	for h in s.heroes:
		names.append(h.display_name)
	return text.replace("{party}", ", ".join(names))


static func attribute_name(attr: String) -> String:
	var names: Dictionary = GameData.rule("attribute_names", {})
	return str(names.get(attr, attr))


## Атрибут по имени из сюжета: "strength" или «Сила».
static func attribute_id(attr: String) -> String:
	if GameData.attribute_list().has(attr):
		return attr
	var names: Dictionary = GameData.rule("attribute_names", {})
	for k in names:
		if str(names[k]).to_lower() == attr.to_lower():
			return str(k)
	return attr

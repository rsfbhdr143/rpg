extends RefCounted
## Раскладка панели умений, как в D:OS: у каждого героя ROWS линеек по COLS ячеек с навыками и расходниками, что куда
## ставить — решает игрок (перетаскиванием). Новый навык или расходник сам встаёт в первую свободную ячейку; убранный с панели остаётся изученным
## и обратно сам не возвращается (его можно перетащить из листа героя). Раскладка — удобство этого компьютера:
## хранится в user://hotbars.json, на сервер не уходит. Подключается через preload (const Hotbar := preload(...)).

const ROWS := 3
const COLS := 10
const PATH := "user://hotbars.json"

static var _data: Dictionary = {}     # uid -> {"slots": [ROWS*COLS id или ""], "known": [id], "row": int}
static var _loaded := false


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(PATH):
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f != null:
			var v: Variant = JSON.parse_string(f.get_as_text())
			if typeof(v) == TYPE_DICTIONARY:
				_data = v


static func _save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_data))


## Что может стоять на панели героя: его навыки и расходники партии ("item:<id>").
static func ids_for(u: Character) -> Array:
	var out: Array = []
	for sk in u.skills:
		out.append(str(sk))
	var s: GameSession = Net.session
	if s != null:
		for it in s.items:
			var def := GameData.item(str(it))
			if int(s.items[it]) > 0 and (def.has("use") or def.has("effect")):
				out.append("item:" + str(it))
	return out


## Раскладка героя, сверенная с тем, что у него есть: пропавшее убирается, новое встаёт в первую свободную ячейку.
static func entry(u: Character) -> Dictionary:
	_ensure()
	var e: Dictionary = _data.get(u.uid, {})
	var changed := false
	if e.is_empty():
		var fresh: Array = []
		fresh.resize(ROWS * COLS)
		fresh.fill("")
		e = {"slots": fresh, "known": [], "row": 0}
		_data[u.uid] = e
		changed = true
	var slots: Array = e["slots"]
	if slots.size() != ROWS * COLS:
		slots.resize(ROWS * COLS)
		for i in slots.size():
			if slots[i] == null:
				slots[i] = ""
		changed = true
	var known: Array = e["known"]
	var have := ids_for(u)
	for i in slots.size():
		if str(slots[i]) != "" and not have.has(str(slots[i])):
			slots[i] = ""
			changed = true
	for id in known.duplicate():
		if str(id).begins_with("item:") and not have.has(str(id)):
			known.erase(id)   # кончился расходник: когда появится снова, сам встанет на панель
			changed = true
	for id in have:
		if known.has(id):
			continue
		known.append(id)
		changed = true
		if slots.has(id):
			continue
		var free := slots.find("")
		if free >= 0:
			slots[free] = id
	if changed:
		_save()
	return e


static func row(u: Character) -> int:
	return clampi(int(entry(u).get("row", 0)), 0, ROWS - 1)


static func set_row(u: Character, r: int) -> void:
	entry(u)["row"] = posmod(r, ROWS)
	_save()


## Что в ячейке index текущей линейки (0..COLS-1): id навыка, "item:<id>" или "".
static func skill_at(u: Character, index: int) -> String:
	if index < 0 or index >= COLS:
		return ""
	return str(entry(u)["slots"][row(u) * COLS + index])


## Поставить навык или расходник в ячейку index текущей линейки. from — откуда его тащат (ячейка той же панели, иначе -1):
## навык, что стоял в целевой ячейке, переезжает на его место. Один навык стоит на панели один раз.
static func put(u: Character, index: int, skill: String, from := -1) -> void:
	var slots: Array = entry(u)["slots"]
	var to := row(u) * COLS + index
	var was := str(slots[to])
	var old := slots.find(skill)
	if from >= 0 and from < slots.size() and str(slots[from]) == skill:
		old = from
	if old >= 0:
		slots[old] = was
	slots[to] = skill
	_save()


static func clear(u: Character, abs_index: int) -> void:
	var slots: Array = entry(u)["slots"]
	if abs_index >= 0 and abs_index < slots.size():
		slots[abs_index] = ""
		_save()

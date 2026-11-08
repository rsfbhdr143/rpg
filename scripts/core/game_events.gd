class_name GameEvents
extends RefCounted
## События для показа: анимации ходьбы и ударов, всплывающие цифры, звуки, задания.
## Ядро только добавляет события, вид проигрывает новые по порядку номера (seq).
## Сервер пересылает хвост списка в снимке, поэтому клиенты видят те же события, что и хост.
## Клетки в событиях — массивы [x, y], чтобы событие спокойно проходило через сеть и JSON.

static var list: Array = []
static var seq := 0
static var max_events := 200


static func add(type: String, data: Dictionary = {}) -> void:
	seq += 1
	var e := data.duplicate()
	e["type"] = type
	e["seq"] = seq
	list.append(e)
	if list.size() > max_events:
		list.pop_front()


## События новее last_seq.
static func since(last_seq: int) -> Array:
	return list.filter(func(e): return int(e["seq"]) > last_seq)


static func tail(n: int) -> Array:
	return list.slice(maxi(0, list.size() - n))


## Клиент: заменить список хвостом из снимка сервера.
static func load_tail(events: Array) -> void:
	list = events.duplicate(true)
	if not list.is_empty():
		seq = maxi(seq, int(list[-1]["seq"]))


static func clear() -> void:
	list.clear()


static func cell(c: Vector2i) -> Array:
	return [c.x, c.y]

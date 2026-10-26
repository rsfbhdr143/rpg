class_name GameLog
extends RefCounted
## Простой журнал боя. UI подписывается через listeners.

static var lines: Array = []
static var listeners: Array = []   # Array of Callable(text: String)
static var echo_to_console := true
static var max_lines := 300


static func add(text: String) -> void:
	lines.append(text)
	if lines.size() > max_lines:
		lines.pop_front()
	if echo_to_console:
		print(text)
	for l in listeners:
		var cb: Callable = l
		if cb.is_valid():
			cb.call(text)


static func clear() -> void:
	lines.clear()

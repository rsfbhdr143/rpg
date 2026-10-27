extends Node
## Сетевой слой (автозагрузка "Net"). Модель: авторитарный сервер.
## - Сервер (хост или выделенный) держит живую GameSession, принимает команды,
##   проверяет их и рассылает всем снимок состояния. ИИ тоже ходит на сервере.
## - Клиент отправляет команды и только рисует присланные снимки.
## - Одиночная игра идёт по тому же пути, просто без сети.
## Транспорт — WebSocket: единственный вариант, который работает и в браузере
## (веб-экспорт), и на ПК. Браузер не может быть сервером, только клиентом.

signal lobby_changed
signal state_updated
signal game_started
signal notice(text: String)
signal disconnected(reason: String)

enum Mode { NONE, OFFLINE, HOST, CLIENT, DEDICATED }

const DEFAULT_PORT := 8910
const AI_DELAY := 0.6
const AI_MAX_WAIT := 4.0         # дольше анимации не ждём
const BUFFER_SIZE := 1 << 20   # снимок боя — десятки КБ, с запасом

var mode: Mode = Mode.NONE
var session: GameSession = null
var lobby: Dictionary = {}       # peer_id -> {"name": String}
var my_name := "Игрок"
var in_game := false
var presentation_busy := false   # вид ещё проигрывает анимации (ИИ на этом же компьютере подождёт)
var hero_choice: Array = []       # каких героев выбрал этот игрок (шаблоны)
var _ai_timer := 0.0


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_authority() -> bool:
	return mode == Mode.OFFLINE or mode == Mode.HOST or mode == Mode.DEDICATED


func is_networked() -> bool:
	return mode == Mode.HOST or mode == Mode.CLIENT or mode == Mode.DEDICATED


## В лобби по сети (хост или клиент), а не в одиночной игре.
func in_lobby() -> bool:
	return mode == Mode.HOST or mode == Mode.CLIENT


func my_id() -> int:
	if mode == Mode.OFFLINE or mode == Mode.NONE:
		return 1
	return multiplayer.get_unique_id()


## Лидер лобби (может начать бой) — игрок с наименьшим id.
func leader_id() -> int:
	if lobby.is_empty():
		return -1
	var ids := lobby.keys()
	ids.sort()
	return int(ids[0])


func is_leader() -> bool:
	return leader_id() == my_id()


# --- Запуск -------------------------------------------------------------------

func start_offline(load_save: bool = false) -> void:
	_reset()
	mode = Mode.OFFLINE
	lobby = {1: {"name": my_name, "heroes": hero_choice.duplicate()}}
	start_game()
	if load_save and session != null:
		GameEvents.clear()
		var err := session.load_game()
		if err != "":
			notice.emit(err)
		_broadcast_state()


## Хост: сервер и игрок в одном окне. dedicated=true — сервер без игрока.
func host(port: int = DEFAULT_PORT, dedicated: bool = false) -> String:
	_reset()
	var peer := _make_peer()
	var err := peer.create_server(port)
	if err != OK:
		return "Не удалось открыть порт %d (ошибка %d)." % [port, err]
	multiplayer.multiplayer_peer = peer
	mode = Mode.DEDICATED if dedicated else Mode.HOST
	lobby = {} if dedicated else {1: {"name": my_name}}
	print("Сервер слушает порт %d%s" % [port, " (выделенный)" if dedicated else ""])
	lobby_changed.emit()
	return ""


## url вида ws://1.2.3.4:8910 или wss://game.example.com (для сайта на https нужен wss).
func join(url: String) -> String:
	_reset()
	var peer := _make_peer()
	var err := peer.create_client(url)
	if err != OK:
		return "Не удалось подключиться к %s (ошибка %d)." % [url, err]
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	return ""


func leave() -> void:
	_reset()
	disconnected.emit("Вы вышли из игры.")


func _make_peer() -> WebSocketMultiplayerPeer:
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = BUFFER_SIZE
	peer.outbound_buffer_size = BUFFER_SIZE
	return peer


func _reset() -> void:
	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.NONE
	session = null
	lobby = {}
	in_game = false
	presentation_busy = false


# --- Лобби --------------------------------------------------------------------

func _on_connected() -> void:
	_register.rpc_id(1, my_name, hero_choice)


func _on_connection_failed() -> void:
	_reset()
	disconnected.emit("Не удалось подключиться к серверу.")


func _on_server_disconnected() -> void:
	_reset()
	disconnected.emit("Соединение с сервером потеряно.")


@rpc("any_peer", "reliable")
func _register(player_name: String, heroes_wanted: Array = []) -> void:
	if not is_authority():
		return
	var pid := multiplayer.get_remote_sender_id()
	var refuse := ""
	if in_game:
		refuse = "Игра уже идёт."
	elif lobby.size() >= GameSession.max_players():
		refuse = "Лобби заполнено (максимум %d игрока)." % GameSession.max_players()
	if refuse != "":
		_kicked.rpc_id(pid, refuse)
		get_tree().create_timer(0.5).timeout.connect(_drop_peer.bind(pid))
		return
	lobby[pid] = {"name": player_name.strip_edges().substr(0, 20), "heroes": heroes_wanted.slice(0, 1)}
	_broadcast_lobby()


## Игрок выбрал героя в лобби.
func choose_hero(template: String) -> void:
	hero_choice = [template]
	if is_authority():
		if lobby.has(my_id()):
			lobby[my_id()]["heroes"] = hero_choice.duplicate()
			_broadcast_lobby()
	elif mode == Mode.CLIENT:
		_choose_hero.rpc_id(1, template)


@rpc("any_peer", "reliable")
func _choose_hero(template: String) -> void:
	var pid := multiplayer.get_remote_sender_id()
	if is_authority() and lobby.has(pid) and not in_game:
		lobby[pid]["heroes"] = [template]
		_broadcast_lobby()


func _drop_peer(pid: int) -> void:
	if is_networked() and is_authority():
		multiplayer.multiplayer_peer.disconnect_peer(pid)


@rpc("authority", "reliable")
func _kicked(reason: String) -> void:
	_reset()
	disconnected.emit(reason)


@rpc("authority", "reliable")
func _lobby_update(new_lobby: Dictionary) -> void:
	lobby = new_lobby
	lobby_changed.emit()


func _broadcast_lobby() -> void:
	if is_networked():
		_lobby_update.rpc(lobby)
	lobby_changed.emit()


func _on_peer_disconnected(pid: int) -> void:
	if not is_authority():
		return
	lobby.erase(pid)
	if session != null:
		session.remove_player(pid)
		GameLog.add("Игрок %d отключился, его героев взял другой игрок." % pid)
	if in_game and lobby.is_empty():
		# все ушли — выделенный сервер возвращается в пустое лобби
		session = null
		in_game = false
	_broadcast_lobby()
	if session != null:
		_broadcast_state()


# --- Игра ---------------------------------------------------------------------

func request_start() -> void:
	if is_authority():
		start_game()
	elif mode == Mode.CLIENT:
		_request_start.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_start() -> void:
	if is_authority() and not in_game and multiplayer.get_remote_sender_id() == leader_id():
		start_game()


func start_game() -> void:
	if lobby.is_empty():
		return
	session = GameSession.new()
	GameLog.clear()
	GameEvents.clear()
	var ids := lobby.keys()
	ids.sort()
	var choices := {}
	for pid in ids:
		session.add_player(int(pid), str(lobby[pid]["name"]))
		choices[int(pid)] = lobby[pid].get("heroes", [])
	session.new_game(choices)
	in_game = true
	if is_networked():
		_game_started.rpc()
	game_started.emit()
	_broadcast_state()


@rpc("authority", "reliable")
func _game_started() -> void:
	in_game = true
	game_started.emit()


## Отправить команду (см. GameSession.submit).
func send_command(cmd: Dictionary) -> void:
	if is_authority():
		_apply_command(my_id(), cmd)
	elif mode == Mode.CLIENT:
		_submit.rpc_id(1, cmd)


@rpc("any_peer", "reliable")
func _submit(cmd: Dictionary) -> void:
	if is_authority():
		_apply_command(multiplayer.get_remote_sender_id(), cmd)


func _apply_command(pid: int, cmd: Dictionary) -> void:
	if session == null:
		return
	var err := session.submit(pid, cmd)
	if err != "":
		if pid == my_id() and mode != Mode.DEDICATED:
			notice.emit(err)
		else:
			_notice.rpc_id(pid, err)
		return
	_broadcast_state()


@rpc("authority", "reliable")
func _notice(text: String) -> void:
	notice.emit(text)


func _broadcast_state() -> void:
	if session == null:
		return
	if is_networked():
		_state.rpc(session.snapshot())
	state_updated.emit()


@rpc("authority", "reliable")
func _state(snap: Dictionary) -> void:
	if session == null:
		session = GameSession.new()
	session.load_snapshot(snap)
	in_game = true
	state_updated.emit()


func _process(delta: float) -> void:
	# ИИ ходит только на сервере, с паузой, чтобы игроки успевали следить.
	if not is_authority() or session == null or not session.is_ai_turn():
		_ai_timer = 0.0
		return
	_ai_timer += delta
	if presentation_busy and _ai_timer < AI_MAX_WAIT:
		return
	if _ai_timer >= AI_DELAY:
		_ai_timer = 0.0
		session.run_ai_turn()
		_broadcast_state()

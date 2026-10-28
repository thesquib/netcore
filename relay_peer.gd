class_name RelayPeer
extends MultiplayerPeerExtension
## Godot's multiplayer over a WebSocket to the relay (relay/room.js in this library). Two peers only: the host is
## 1, the client is 2. Each binary frame is [channel << 2 | transfer mode] + Godot's packet; text
## frames are the relay's JSON control messages. LAN play uses ENet instead.
## A dropped socket is not a disconnect: holding the seat's token, the peer rejoins every
## RETRY_S (link_changed) and SceneMultiplayer never notices. Only a real end (the other side
## left, the relay refused the seat, or GIVE_UP_S without success) reports one.

signal room_ready(code: String)
## no_room, full, version, relay_version, limit (from the relay); host_left (client: the host went); unreachable,
## lost (from the socket, or a seat that couldn't be got back).
signal relay_error(reason: String)
signal link_changed(up: bool)        # our own connection to the relay
signal peer_link_changed(up: bool)   # the other player's connection to the relay

## The relay wire version this peer speaks (relay/room.js RELAY_VERSIONS).
const RELAY_VERSION := 1
const HOST_ID := 1
const CLIENT_ID := 2
const RETRY_S := 2.0
const GIVE_UP_S := 125.0   # a little over the relay's 120 s grace

var room_code := ""
var link_up := false       # our socket to the relay is open and our seat is ours
var peer_up := true        # the other player's link (peer_away / peer_back)
var opens_fail_for_tests := false
var _socket: Object        # WebSocketPeer, or a test fake with the same API
var _factory: Callable     # makes a fresh socket for each attempt
var _base := ""
var _version := ""         # "relay=..&game=..&protocol=..&content=.."
var _token := ""           # our seat's rejoin token
var _host := false
var _status := MultiplayerPeer.CONNECTION_CONNECTING
var _paired := false
var _drop_client := false
var _ever_open := false
var _reconnecting := false
var _retry_at := 0.0
var _give_up_at := 0.0
var _closing := false
var _hold_until := 0.0     # drop_link(hold_s): no reconnect attempts before this
var _leave_socket: Object  # leaving while reconnecting: a short-lived socket just to say leave
var _leave_until := 0.0
var _inbox: Array = []     # [channel, mode, bytes]
var _channel := 0
var _mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE


## Hosts a room. `game`: the game's id (a room pairs only the same game). `protocol`, `content`:
## the session protocol and content digest; a client must match both exactly.
static func create_host(url: String, game: String, protocol: String, content: String, factory := Callable()) -> RelayPeer:
	var p := RelayPeer.new()
	p._host = true
	p._setup(url, game, protocol, content, factory)
	p._open("/host?" + p._version)
	return p


static func create_client(url: String, code: String, game: String, protocol: String, content: String, factory := Callable()) -> RelayPeer:
	var p := RelayPeer.new()
	p.room_code = code
	p._setup(url, game, protocol, content, factory)
	p._open("/join/%s?%s" % [code, p._version])
	return p


func _setup(url: String, game: String, protocol: String, content: String, factory: Callable) -> void:
	_base = url.trim_suffix("/")
	_version = "relay=%d&game=%s&protocol=%s&content=%s" % [RELAY_VERSION, game.uri_encode(),
		protocol.uri_encode(), content.uri_encode()]
	_factory = factory if factory.is_valid() else func(): return WebSocketPeer.new()


func _open(path: String) -> void:
	_socket = _factory.call()
	if opens_fail_for_tests and "opens" in _socket:
		_socket.opens = false  # tests: this attempt never connects
	var err: Error = _socket.connect_to_url(_base + path)
	if err != OK and not _reconnecting:
		_fail("unreachable")


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Closes the socket without a leave, as an app switch does (tests; the debug web hook).
## `hold_s`: don't try to reconnect for that long (an outage long enough to see the banners).
func drop_link(hold_s := 0.0) -> void:
	_hold_until = _now() + hold_s
	if _socket:
		_socket.close()


static func header(channel: int, mode: int) -> int:
	return (channel << 2) | mode


static func split_header(b: int) -> Array:
	return [b >> 2, b & 3]


func outbound_backlog() -> int:
	return _socket.get_current_outbound_buffered_amount() if _socket else 0


func _poll() -> void:
	if _socket == null or _status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	_socket.poll()
	var state: int = _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		_ever_open = true
		while _socket.get_available_packet_count() > 0:
			var bytes: PackedByteArray = _socket.get_packet()
			if _socket.was_string_packet():
				_control(bytes.get_string_from_utf8())
			elif bytes.size() >= 1 and _paired:
				var hc := split_header(bytes[0])
				_inbox.append([hc[0], hc[1], bytes.slice(1)])
	elif state == WebSocketPeer.STATE_CLOSED and not _closing:
		if _token != "":
			_reconnect()  # we hold a seat: get back to it
		else:
			_fail("lost" if _ever_open else "unreachable")


func _reconnect() -> void:
	var t := _now()
	if not _reconnecting:
		_reconnecting = true
		_give_up_at = t + GIVE_UP_S
		_retry_at = t
		if link_up:
			link_up = false
			link_changed.emit(false)
	if t > _give_up_at:
		_fail("lost")
	elif t >= _retry_at and t >= _hold_until:
		_retry_at = t + RETRY_S
		_open("/rejoin/%s?token=%s&%s" % [room_code, _token, _version])


func _control(text: String) -> void:
	var m: Variant = JSON.parse_string(text)
	if typeof(m) != TYPE_DICTIONARY:
		return
	match m.get("type", ""):
		"room":
			room_code = str(m.get("code", ""))
			_token = str(m.get("token", ""))
			_up()
			room_ready.emit(room_code)
		"paired":
			if m.has("token"):
				_token = str(m["token"])
			_up()
			peer_up = true
			if not _paired:
				_paired = true
				peer_connected.emit(CLIENT_ID if _host else HOST_ID)
		"resumed":
			_reconnecting = false
			_up()
			if _drop_client:
				_socket.send_text('{"type":"drop_client"}')
				_drop_client = false
				return
			var partner: bool = m.get("paired", false)
			if partner and not _paired:  # a host whose `paired` went to a dead socket
				_paired = true
				peer_up = true
				peer_connected.emit(CLIENT_ID if _host else HOST_ID)
			elif not partner and _paired:  # the other side left while we were away
				_inbox.clear()
				if _host:
					_paired = false
					peer_up = true
					peer_disconnected.emit(CLIENT_ID)
				else:
					_fail("host_left")
					return
			var up: bool = m.get("peer_up", true)
			if up != peer_up:
				peer_up = up
				peer_link_changed.emit(up)
		"peer_away":
			peer_up = false
			peer_link_changed.emit(false)
		"peer_back":
			peer_up = true
			peer_link_changed.emit(true)
		"peer_left":
			_inbox.clear()
			if _host:
				var was_paired := _paired
				_paired = false
				peer_up = true
				if was_paired:
					peer_disconnected.emit(CLIENT_ID)
			else:
				_fail("host_left")
		"error":
			var reason := str(m.get("reason", "lost"))
			_fail("lost" if _reconnecting and reason in ["no_seat", "no_room"] else reason)


func _up() -> void:
	_status = MultiplayerPeer.CONNECTION_CONNECTED
	if not link_up:
		link_up = true
		link_changed.emit(true)


func _fail(reason: String) -> void:
	var was_paired := _paired
	_paired = false
	_reconnecting = false
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	relay_error.emit(reason)
	if _host and was_paired:
		peer_disconnected.emit(CLIENT_ID)


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if not _paired or not link_up or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return OK  # dropped, as a lost unreliable packet would be (a just-closed socket too)
	var frame := PackedByteArray([header(_channel, _mode)])
	frame.append_array(buffer)
	return _socket.send(frame)


func _get_packet_script() -> PackedByteArray:
	return _inbox.pop_front()[2] if not _inbox.is_empty() else PackedByteArray()


func _get_available_packet_count() -> int:
	return _inbox.size()


func _get_packet_channel() -> int:
	return _inbox[0][0] if not _inbox.is_empty() else 0


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return _inbox[0][1] if not _inbox.is_empty() else MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _get_packet_peer() -> int:
	return CLIENT_ID if _host else HOST_ID


func _get_max_packet_size() -> int:
	return 65535


func _set_transfer_channel(channel: int) -> void:
	_channel = channel


func _get_transfer_channel() -> int:
	return _channel


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_mode = mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _mode


func _set_target_peer(_peer: int) -> void:
	pass  # only one other peer


func _is_server() -> bool:
	return _host


func _get_unique_id() -> int:
	return HOST_ID if _host else CLIENT_ID


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return _status


func _is_server_relay_supported() -> bool:
	return false


## Leaving on purpose: the relay vacates our seat at once (no grace time). If our link is down
## (reconnecting), a short-lived socket rejoins the seat just to say so (see poll_leave).
func _close() -> void:
	_closing = true
	if _socket and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text('{"type":"leave"}')
		_socket.close(1000, "bye")
	elif _token != "" and _reconnecting:
		_leave_socket = _factory.call()
		_leave_socket.connect_to_url("%s/rejoin/%s?token=%s&%s" % [_base, room_code, _token, _version])
		_leave_until = _now() + 3.0
	_paired = false
	_reconnecting = false
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED


## After closing while reconnecting: sends the leave once that socket opens. Returns true while
## there's still something to do (NetSession keeps polling it).
func poll_leave() -> bool:
	if _leave_socket == null:
		return false
	_leave_socket.poll()
	if _leave_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_leave_socket.send_text('{"type":"leave"}')
		_leave_socket.close(1000, "bye")
		_leave_socket = null
	elif _leave_socket.get_ready_state() == WebSocketPeer.STATE_CLOSED or _now() > _leave_until:
		_leave_socket = null
	return _leave_socket != null


func _disconnect_peer(peer: int, _force: bool) -> void:
	if not _host:
		_close()
	elif peer == CLIENT_ID:
		_drop_client = true
		if link_up and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_socket.send_text('{"type":"drop_client"}')
			_drop_client = false
		_inbox.clear()
		if _paired:
			_paired = false
			peer_disconnected.emit(CLIENT_ID)


func _is_refusing_new_connections() -> bool:
	return false


func _set_refuse_new_connections(_enable: bool) -> void:
	pass

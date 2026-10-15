class_name FakeRelay
extends RefCounted
## An in-process stand-in for relay/room.js, for tests: seats with tokens, drops held as "away",
## /rejoin, explicit leave, and optional latency (frames before delivery).

var code := "BQXK"
var latency := 0
var backlog := 0
var host := {}    # {socket, token, away}
var client := {}
var urls: Array = []  # every URL a socket opened, in order


func socket() -> FakeSocket:
	return FakeSocket.new(self)


func factory() -> Callable:
	return func(): return socket()


func _send_text(s: FakeSocket, obj: Dictionary) -> void:
	if s:
		s.deliver(true, JSON.stringify(obj))


func _open(s: FakeSocket, url: String) -> void:
	urls.append(url)
	var path := url.get_slice("://", 1)
	path = path.substr(path.find("/"))
	var route := path.get_slice("?", 0)
	var query := path.get_slice("?", 1)
	if route == "/host":
		host = {"socket": s, "token": "hosttoken", "away": false}
		client = {}
		_send_text(s, {"type": "room", "code": code, "token": "hosttoken"})
	elif route.begins_with("/join/"):
		if route.get_slice("/", 2).to_upper() != code or host.is_empty():
			_refuse(s, "no_room")
		elif not client.is_empty():
			_refuse(s, "full")
		else:
			client = {"socket": s, "token": "clienttoken", "away": false}
			_send_text(s, {"type": "paired", "token": "clienttoken"})
			if not host["away"]:  # an away host learns it from resumed's "paired"
				_send_text(host["socket"], {"type": "paired"})
	elif route.begins_with("/rejoin/"):
		var token := ""
		for part in query.split("&"):
			if part.begins_with("token="):
				token = part.get_slice("=", 1)
		var seat: Dictionary = host if not host.is_empty() and host["token"] == token else \
			(client if not client.is_empty() and client["token"] == token else {})
		if seat.is_empty() or route.get_slice("/", 2).to_upper() != code:
			_refuse(s, "no_seat")
			return
		var old: FakeSocket = seat["socket"]
		var was_away: bool = seat["away"]
		seat["socket"] = s
		seat["away"] = false
		if old and old != s:
			old.state = WebSocketPeer.STATE_CLOSED
		var other: Dictionary = client if seat == host else host
		_send_text(s, {"type": "resumed", "paired": not other.is_empty(),
			"peer_up": not other.is_empty() and not other["away"]})
		if was_away and not other.is_empty() and not other["away"]:
			_send_text(other["socket"], {"type": "peer_back"})


func _refuse(s: FakeSocket, reason: String) -> void:
	_send_text(s, {"type": "error", "reason": reason})
	s.closing = true


func _seat_of(s: FakeSocket) -> Dictionary:
	if not host.is_empty() and host["socket"] == s:
		return host
	if not client.is_empty() and client["socket"] == s:
		return client
	return {}


func _send(from: FakeSocket, bytes: PackedByteArray) -> void:
	var seat := _seat_of(from)
	if seat.is_empty():
		return
	var other: Dictionary = client if seat == host else host
	if not other.is_empty() and not other["away"]:
		other["socket"].deliver(false, bytes)


func _text(from: FakeSocket, text: String) -> void:
	var m: Variant = JSON.parse_string(text)
	if typeof(m) == TYPE_DICTIONARY and m.get("type") == "leave":
		_vacate(_seat_of(from))


func _closed(s: FakeSocket) -> void:
	var seat := _seat_of(s)
	if seat.is_empty() or seat["away"]:
		return
	seat["away"] = true
	seat["socket"] = null
	var other: Dictionary = client if seat == host else host
	if not other.is_empty() and not other["away"]:
		_send_text(other["socket"], {"type": "peer_away"})


func _vacate(seat: Dictionary) -> void:
	if seat.is_empty():
		return
	if seat == client:
		client = {}
		if not host.is_empty() and not host["away"]:
			_send_text(host["socket"], {"type": "peer_left"})
	else:
		host = {}
		if not client.is_empty() and not client["away"]:
			_send_text(client["socket"], {"type": "peer_left"})
			client["socket"].closing = true
		client = {}


## The relay sends a side an error, as it does before closing a room (e.g. "limit").
func send_error(side: String, reason: String) -> void:
	var seat: Dictionary = host if side == "host" else client
	if not seat.is_empty() and seat["socket"]:
		_refuse(seat["socket"], reason)


## A side's connection drops with no leave (an app switch): the relay holds its seat.
func drop(side: String) -> void:
	var seat: Dictionary = host if side == "host" else client
	if seat.is_empty() or seat["away"]:
		return
	var s: FakeSocket = seat["socket"]
	_closed(s)
	s.state = WebSocketPeer.STATE_CLOSED


## The grace time runs out for every away seat.
func expire_away() -> void:
	if not client.is_empty() and client["away"]:
		_vacate(client)
	if not host.is_empty() and host["away"]:
		_vacate(host)


## Every socket drops with no peer_left: the relay crashed. Seats are forgotten too.
func drop_all() -> void:
	for seat in [host, client]:
		if not seat.is_empty() and seat["socket"]:
			seat["socket"].state = WebSocketPeer.STATE_CLOSED
	host = {}
	client = {}


class FakeSocket extends RefCounted:
	var relay: FakeRelay
	var state := WebSocketPeer.STATE_CLOSED
	var inbox: Array = []  # [is_text, data, deliver_at]
	var frame := 0
	var _last_text := false
	var closing := false
	var opens := true

	func _init(r: FakeRelay) -> void:
		relay = r

	func deliver(is_text: bool, data: Variant) -> void:
		inbox.append([is_text, data, frame + relay.latency])

	func connect_to_url(url: String, _tls = null) -> Error:
		state = WebSocketPeer.STATE_CONNECTING
		if opens:
			state = WebSocketPeer.STATE_OPEN
			relay._open(self, url)
		return OK

	func poll() -> void:
		frame += 1
		if closing and inbox.is_empty():
			state = WebSocketPeer.STATE_CLOSED

	func get_ready_state() -> int:
		return state

	func get_available_packet_count() -> int:
		var n := 0
		for m in inbox:
			if m[2] <= frame:
				n += 1
			else:
				break
		return n

	func get_packet() -> PackedByteArray:
		var m: Array = inbox.pop_front()
		_last_text = m[0]
		return m[1].to_utf8_buffer() if m[0] else m[1]

	func was_string_packet() -> bool:
		return _last_text

	func send(bytes: PackedByteArray, _mode := 0) -> Error:
		if state == WebSocketPeer.STATE_OPEN:
			relay._send(self, bytes)
		return OK

	func send_text(t: String) -> Error:
		if state == WebSocketPeer.STATE_OPEN:
			relay._text(self, t)
		return OK

	func get_current_outbound_buffered_amount() -> int:
		return relay.backlog if not relay.host.is_empty() and relay.host["socket"] == self else 0

	func close(_code := 1000, _reason := "") -> void:
		if state == WebSocketPeer.STATE_OPEN:
			relay._closed(self)
		state = WebSocketPeer.STATE_CLOSED

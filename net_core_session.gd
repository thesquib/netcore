class_name NetCoreSession
extends Node
## Host-authoritative network play for two players, over ENet on a LAN or a RelayPeer
## (WebSocket) through the relay (relay/). The game's side is its NetAdapter (`adapter`): the
## world, the snapshot layout, the slots and the tuning. A game extends this class for its
## constants and wording, and uses it as an autoload (e.g. "Net").
##
## The host runs the only real world with its own player in adapter.host_slot() and the remote
## player in adapter.client_slot(). The client sends its input bits each tick (with a sequence
## number and the last few inputs repeated, unreliable_ordered); the host applies them in order
## through an InputQueue and sends back the world's snapshot:
##   - a **keyframe** (on join, or when the client has no usable baseline): adapter.body_of()
##     deflated;
##   - otherwise a **delta**: that body's Variant bytes XOR the bytes of a body the client has
##     acknowledged (its newest applied tick, which the input packets carry), deflated. Most of
##     the state doesn't change in a few ticks, so the XOR is nearly all zeros. A hash of the
##     result guards against a wrong baseline (the client then asks for a keyframe).
## Events travel beside the body, not in it; a snapshot also carries the events of the ticks
## sent without one (send_every > 1).
##
## Client prediction: the client draws `world` running ahead of the host by its own inputs the
## host hasn't applied yet. Each snapshot is restored and those inputs replayed on top (the sim is
## deterministic, so the replay matches the host unless the host's own player did something new).
##
## Reasons (disconnected, room_ended) are codes; the game words them:
##   from the relay: no_room, full, version, relay_version, limit, unreachable, lost, host_left;
##   from the session: unreachable (no relay answer in time), lost (silence for GRACE_S, or our
##   own link down), player_left, cant_connect, host_left, and the host's refusal codes
##   (adapter.accept_client, e.g. game_over).
##
## Tests create their own instances under nodes with their own MultiplayerAPI
## (SceneTree.set_multiplayer), so one process can be both host and client.

signal connected                       # client: joined the host; host: a client said hello
signal disconnected(reason: String)    # the other side is gone, the join failed, or we were refused
signal snapshot_applied                # client: `world` was just updated from a snapshot
signal room_ready(code: String)        # host on a relay: the relay gave us a room code
## Host on a relay with a game running: the room is gone (a relay reason code). The other player,
## if any, was dropped; the host plays on locally.
signal room_ended(reason: String)

## Bump when hello/input/snapshot framing or RPCs change. Both transports compare the combined
## session protocol "<NETCORE_PROTOCOL>.<adapter.game_protocol()>".
const NETCORE_PROTOCOL := 2
## Refuse to decompress snapshots bigger than this.
const MAX_SNAPSHOT_BYTES := 1 << 20
const BACKLOG_LIMIT := 16384     # bytes queued on the relay socket before snapshots are skipped
const CONNECT_TIMEOUT_S := 8.0
## A client says hello this often until the first snapshot arrives: a hello sent while the host
## was away is lost, and SceneMultiplayer has no reliable channel over the relay.
const HELLO_RETRY_S := 0.5
const SILENCE_S := 2.0     # a side unheard this long counts as away (a frozen window)
const GRACE_S := 120.0     # silence this long is a leave, as on the relay
const KEEPALIVE_S := 0.5   # a paused host still sends a snapshot this often
## A socket that says it's open but has brought nothing this long may be half-dead: rejoin the
## seat, at most once per STALE_RETRY_S.
const STALE_S := 4.0
const STALE_RETRY_S := 10.0

## The game's side; setting it resets the input queue and send rate to its tuning.
var adapter: NetAdapter = NetAdapter.new():
	set(value):
		adapter = value
		remote_inputs = new_input_queue()
		send_every = adapter.send_every_lan()
## Host: the authoritative world. Client: the mirror that snapshots are restored into.
var world: Object
var is_host := false
## Host: the client's peer id, or 0 when nobody has joined.
var remote_peer := 0
var remote_inputs := InputQueue.new()
## Snapshot and input packets every this many ticks (adapter.send_every_lan / _relay).
var send_every := 1
## Size of the last snapshot sent or received, of the last keyframe, the largest delta, and
## counts.
var stats := {"snapshot_bytes": 0, "keyframe_bytes": 0, "max_delta_bytes": 0, "sent": 0,
	"received": 0, "keyframes": 0}
var max_unacked_ticks := -1   # -1: adapter.max_unacked_ticks(); tests that aren't about the backlog raise it
var prediction := true
var connect_deadline_s := CONNECT_TIMEOUT_S  # tests shorten it
## Seconds; tests replace it to move time.
var clock: Callable = func(): return Time.get_ticks_msec() / 1000.0
## Client: microseconds spent restoring + replaying the last snapshot (prediction cost).
var last_replay_us := 0

var _bodies := {}              # both: tick -> snapshot body bytes (host: sent; client: applied)
var _bodies_world: Object      # host: the world _bodies came from
var _client_base := -1         # host: the client's newest stored body (-1: wants a keyframe)
var _client_acked_tick := -1   # host: the newest snapshot tick the client says it applied
var _last_sent_tick := -1      # host: the tick of the last snapshot sent
var _unsent_events: Array = [] # host: [tick, events] of ticks since the last snapshot
var _need_keyframe := false    # client: a delta didn't decode; ask for a keyframe
var _input_seq := 0            # client
var _last_tick := -1           # client: newest snapshot applied
var _hello_at := 0.0
var _content_digest := ""
var _last_heard := 0.0     # host: the newest client input; client: the newest snapshot
var _paused := false       # host: the world is waiting for the other player
var _keepalive_at := 0.0
var _stale_rejoin_at := -INF  # when we last forced a rejoin of a silent link
var _leaving: Array = []      # closed RelayPeers still delivering a leave (RelayPeer.poll_leave)
var _sent: Array = []      # client: the newest [seq, bits] sent, repeated in each packet
var _host_bits := 0        # host: our own input this tick (sent in snapshots for prediction)
var _pending: Array = []      # client: [seq, bits] sent but not yet applied by the host
var _host_bits_seen := 0      # client: the host's input in the newest snapshot
var _events: Array = []       # client: events to play
var _events_tick := -1        # client: the newest tick whose events were queued
var _played := {}             # client: tick -> events played for it (var_to_str), recent ticks only
var _host_paused := false     # client: the newest snapshot was a paused host's keep-alive
var _connect_started := -1.0  # seconds; -1 when not waiting on a relay
var _refused_reason := ""     # client: set between the host refusing us and our deferred close
var _adopt: Object = null     # host_relay_with: the world to run once the room is ready


func new_input_queue() -> InputQueue:
	return InputQueue.new(adapter.input_max_behind(), adapter.input_drain_ticks(), adapter.input_mask())


## The session protocol the relay compares: "<NETCORE_PROTOCOL>.<game protocol>".
func session_protocol() -> String:
	return "%d.%d" % [NETCORE_PROTOCOL, adapter.game_protocol()]


func host_game(port := -1) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(adapter.lan_port() if port < 0 else port, 1)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_host = true
	send_every = adapter.send_every_lan()
	_content_digest = adapter.content_digest()
	_watch(true)
	return OK


func join_game(address: String, port := -1) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, adapter.lan_port() if port < 0 else port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_host = false
	send_every = adapter.send_every_lan()
	_content_digest = adapter.content_digest()
	_watch(true)
	return OK


## Hosts through the relay at `url`; room_ready(code) fires once the relay assigns a room.
## `factory` makes sockets (tests pass FakeRelay.factory()); the default is WebSocketPeer.
func host_relay(url: String, factory := Callable()) -> void:
	close()
	_content_digest = adapter.content_digest()
	_use_relay(RelayPeer.create_host(url, adapter.game_id(), session_protocol(), _content_digest, factory))
	is_host = true


## Hosts a game already in progress: like host_relay, but `world` only becomes `adopt` on
## room_ready. Until then nothing touches it, so a failure leaves the local game exactly as it
## was (the reason arrives through disconnected).
func host_relay_with(adopt: Object, url: String, factory := Callable()) -> void:
	host_relay(url, factory)
	_adopt = adopt


## Joins room `code` through the relay at `url`.
func join_relay(url: String, code: String, factory := Callable()) -> void:
	close()
	_content_digest = adapter.content_digest()
	_use_relay(RelayPeer.create_client(url, code.to_upper(), adapter.game_id(), session_protocol(),
		_content_digest, factory))
	is_host = false


func _use_relay(peer: RelayPeer) -> void:
	peer.room_ready.connect(_on_room_ready)
	# Deferred: it fires inside the peer's poll, and closing the session there would replace
	# the peer while SceneMultiplayer is still polling it.
	peer.relay_error.connect(_on_relay_error, CONNECT_DEFERRED)
	multiplayer.multiplayer_peer = peer
	send_every = adapter.send_every_relay()
	_connect_started = Time.get_ticks_msec() / 1000.0
	_watch(true)


func _on_room_ready(code: String) -> void:
	_connect_started = -1.0
	if _adopt != null:
		world = _adopt
		_adopt = null
	room_ready.emit(code)


func _on_relay_error(reason: String) -> void:
	if is_host and world != null:
		room_ended.emit(reason)  # the other player, if any, was dropped (peer_disconnected)
		return
	close()
	disconnected.emit(reason)


## Client: the events (sounds, effects) not yet played, each tick's at most once.
func take_events() -> Array:
	var out := _events
	_events = []
	return out


## Queues a tick's events that haven't been played: everything for a new tick, and for a tick
## already predicted (a confirmed snapshot) only what the prediction missed, such as the host
## player's own actions.
func _queue_events_for(tick: int, events: Array) -> void:
	var played: Array = _played.get(tick, [])
	var keys := []
	for ev in events:
		var key := var_to_str(ev)
		keys.append(key)
		if key in played:
			played.erase(key)  # matched once; the same event twice in a tick plays twice
			continue
		_events.append(ev)
	_played[tick] = keys
	_events_tick = maxi(_events_tick, tick)
	for t in _played.keys():
		if t < _events_tick - adapter.event_window():
			_played.erase(t)


func _queue_events() -> void:
	_queue_events_for(adapter.world_tick(world), adapter.world_events(world))


func _predict(bits: int) -> void:
	adapter.tick(world, {adapter.client_slot(): bits, adapter.host_slot(): _host_bits_seen})
	_queue_events()


## Both players present: our link and theirs up on a relay, and the other side heard from
## within SILENCE_S. A paired host waits while this is false; an unpaired host can play alone.
func together() -> bool:
	var p := multiplayer.multiplayer_peer
	if p is RelayPeer and (not p.link_up or not p.peer_up):
		return false
	if not is_host and _host_paused:
		return false
	return clock.call() - _last_heard <= SILENCE_S


## Why an online game is paused, or "" while playing: reconnecting (our own link),
## waiting_player (host: the client is away), waiting_host (client: the host is away).
func away_state() -> String:
	var p := multiplayer.multiplayer_peer
	if p is RelayPeer and not p.link_up:
		return "reconnecting"
	if is_host:
		return "waiting_player" if remote_peer != 0 and not together() else ""
	return "waiting_host" if is_online() and not together() else ""


func close() -> void:
	_watch(false)
	if is_online():
		multiplayer.multiplayer_peer.close()
		if multiplayer.multiplayer_peer is RelayPeer and multiplayer.multiplayer_peer.poll_leave():
			_leaving.append(multiplayer.multiplayer_peer)  # still has a leave to deliver
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	is_host = false
	remote_peer = 0
	remote_inputs = new_input_queue()
	send_every = adapter.send_every_lan()
	_bodies = {}
	_bodies_world = null
	_client_base = -1
	_client_acked_tick = -1
	_last_sent_tick = -1
	_unsent_events = []
	_need_keyframe = false
	_input_seq = 0
	_last_tick = -1
	_connect_started = -1.0
	_sent = []
	_pending = []
	_events = []
	_events_tick = -1
	_played = {}
	_host_bits_seen = 0
	_host_paused = false
	_stale_rejoin_at = -INF
	_paused = false
	_adopt = null
	world = null  # a new session starts without the last game's world


func is_online() -> bool:
	return multiplayer.multiplayer_peer != null and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer


## Rejoins the seat if our link claims to be up but nothing has arrived for STALE_S. Runs every
## frame, and straight away when the window regains focus.
func check_stale_link() -> void:
	if not is_inside_tree():
		return  # focus notifications arrive before the autoload is in the tree
	var p := multiplayer.multiplayer_peer
	if not p is RelayPeer or not p.link_up or not p.peer_up:
		return  # reconnecting already, or the relay told us the other side is away
	if (is_host and remote_peer == 0) or (not is_host and _last_tick < 0):
		return  # no game yet: a host waiting for player 2 rightly hears nothing
	var t: float = clock.call()
	if t - _last_heard > STALE_S and t - _stale_rejoin_at >= STALE_RETRY_S:
		_stale_rejoin_at = t
		p.drop_link()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		check_stale_link()


func _process(_delta: float) -> void:
	_leaving = _leaving.filter(func(p): return p.poll_leave())
	check_stale_link()
	if _connect_started >= 0.0 and Time.get_ticks_msec() / 1000.0 - _connect_started > connect_deadline_s:
		close()
		disconnected.emit("unreachable")
		return
	if not is_host and _last_tick >= 0 and is_online() and clock.call() - _last_heard > GRACE_S:
		close()  # the host has been silent for the whole grace time
		disconnected.emit("lost")
		return
	var p := multiplayer.multiplayer_peer
	if not is_host and _last_tick < 0 and p is RelayPeer \
			and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and p.link_up:
		var t := Time.get_ticks_msec() / 1000.0
		if t >= _hello_at:  # until the first snapshot: an earlier hello may have been lost
			_hello_at = t + HELLO_RETRY_S
			_client_hello.rpc_id(1, session_protocol(), _content_digest, adapter.game_id())


## A meta command from this computer's player: the host applies it to its world; a client
## sends it to the host if adapter.client_commands() allows it.
func send_command(name: String) -> void:
	if is_host or not is_online():
		if world != null:
			adapter.apply_command(world, adapter.host_slot(), name)
	elif name in adapter.client_commands():
		_receive_command.rpc_id(1, name)


@rpc("any_peer", "call_remote", "reliable")
func _receive_command(name: String) -> void:
	if not is_host or multiplayer.get_remote_sender_id() != remote_peer or world == null:
		return
	if name in adapter.client_commands():
		adapter.apply_command(world, adapter.client_slot(), name)


# --- Host ---

## One host tick: simulate with the local and latest remote input, then send the snapshot (every
## send_every ticks).
func host_tick(local_bits: int) -> void:
	if remote_peer != 0 and not together():
		if clock.call() - _last_heard > GRACE_S:  # silent for the whole grace time: gone
			var p := multiplayer.multiplayer_peer
			var own_link_down: bool = p is RelayPeer and not p.link_up
			var departed := remote_peer
			remote_peer = 0
			p.disconnect_peer(departed)
			remote_inputs = new_input_queue()
			_paused = false
			drop_remote_player()
			disconnected.emit("lost" if own_link_down else "player_left")
			return  # the host plays on alone from the next tick
		else:
			_paused = true
			if clock.call() - _keepalive_at >= KEEPALIVE_S:  # so a silent-but-alive client hears us
				_keepalive_at = clock.call()
				_receive_snapshot.rpc_id(remote_peer, encode_snapshot(true))
				stats["sent"] += 1
			return  # the shared world waits for the other player
	if _paused:
		_paused = false
		remote_inputs.skip_to_newest()  # don't replay steering queued while paused
	_host_bits = local_bits
	adapter.tick(world, {adapter.host_slot(): local_bits, adapter.client_slot(): remote_inputs.take()})
	if remote_peer == 0:
		return
	var events := adapter.world_events(world)
	var tick := adapter.world_tick(world)
	if not events.is_empty():
		_unsent_events.append([tick, events.duplicate(true)])
	if tick - _last_sent_tick >= send_every and not _backlogged():
		_receive_snapshot.rpc_id(remote_peer, encode_snapshot())
		_last_sent_tick = tick
		stats["sent"] += 1


func _unacked_limit() -> int:
	return max_unacked_ticks if max_unacked_ticks >= 0 else adapter.max_unacked_ticks()


## On a relay, skip snapshots while the link is backed up (the next one carries the whole state
## anyway): either our socket has a queue (slow upload), or the client's acknowledged tick lags
## (slow download: frames queue at the relay).
func _backlogged() -> bool:
	var p := multiplayer.multiplayer_peer
	if not p is RelayPeer:
		return false
	if p.outbound_backlog() > BACKLOG_LIMIT:
		return true
	# A lagging client still gets one snapshot per max_unacked_ticks, so it can catch up.
	var tick := adapter.world_tick(world)
	var limit := _unacked_limit()
	return _client_acked_tick >= 0 and tick - _client_acked_tick > limit \
		and tick - _last_sent_tick < limit


## The snapshot bytes for the client: a delta against its newest stored body when the host
## still has that one, else a keyframe.
func encode_snapshot(paused := false) -> PackedByteArray:
	if _bodies_world != world:  # a new world: old bodies aren't baselines for it
		_bodies = {}
		_bodies_world = world
	var snap := adapter.snapshot(world)
	var t: int = snap["tick"]
	var meta := {"tick": t, "events": snap.get("events", []),
		"input_seq": remote_inputs.applied_seq,  # the client input this tick used (prediction)
		"host_bits": _host_bits}                 # our own input this tick (the client predicts with it)
	if paused:
		meta["paused"] = true  # a keep-alive: the world is waiting, so the client mustn't run ahead
	# Events of the ticks since the last snapshot (this tick's are in meta.events).
	var hist := _unsent_events.filter(func(e): return e[0] != t)
	if not hist.is_empty():
		meta["ev_hist"] = hist
	_unsent_events = []
	var body_dict := adapter.body_of(snap)
	var body := var_to_bytes(body_dict)
	_bodies[t] = body
	for k in _bodies.keys():
		if k < t - adapter.max_base_age():
			_bodies.erase(k)
	var payload: PackedByteArray
	if _client_base >= 0 and _bodies.has(_client_base):
		payload = encode_delta(meta, body, _client_base, _bodies[_client_base])
		stats["max_delta_bytes"] = maxi(stats["max_delta_bytes"], payload.size())
	else:
		payload = encode_keyframe(meta, body_dict)
		stats["keyframe_bytes"] = payload.size()
		stats["keyframes"] += 1
	stats["snapshot_bytes"] = payload.size()
	return payload


## A keyframe packet: `meta` plus the whole body, deflated.
static func encode_keyframe(meta: Dictionary, body_dict: Dictionary) -> PackedByteArray:
	var d := meta.duplicate()
	d["body"] = body_dict
	return var_to_bytes(d).compress(FileAccess.COMPRESSION_DEFLATE)


## A delta packet: `meta` plus body XOR base (deflated together), with the body's size and hash.
static func encode_delta(meta: Dictionary, body: PackedByteArray, base_tick: int, base: PackedByteArray) -> PackedByteArray:
	var d := meta.duplicate()
	d["base"] = base_tick
	d["len"] = body.size()
	d["hash"] = hash(body)
	d["xor"] = xor_bytes(body, base)
	return var_to_bytes(d).compress(FileAccess.COMPRESSION_DEFLATE)


## a XOR b over a's length (b zero-padded or cut), 8 bytes at a time.
static func xor_bytes(a: PackedByteArray, b: PackedByteArray) -> PackedByteArray:
	var n := a.size()
	var padded := (n + 7) / 8 * 8
	var x := a.duplicate()
	x.resize(padded)
	var y := b.duplicate()
	y.resize(padded)
	var xa := x.to_int64_array()
	var ya := y.to_int64_array()
	for i in xa.size():
		xa[i] ^= ya[i]
	var out := xa.to_byte_array()
	out.resize(n)
	return out


## Decodes a keyframe payload into its snapshot (events included), or null.
func decode_keyframe(payload: PackedByteArray) -> Variant:
	var raw := payload.decompress_dynamic(MAX_SNAPSHOT_BYTES, FileAccess.COMPRESSION_DEFLATE)
	var d: Variant = bytes_to_var(raw) if raw.size() > 0 else null
	if typeof(d) != TYPE_DICTIONARY or typeof(d.get("body")) != TYPE_DICTIONARY:
		return null
	var s: Variant = adapter.snapshot_of(d["body"])
	if s != null:
		s["events"] = d.get("events", [])
	return s


## The remote player left for good, so the host plays on alone.
func drop_remote_player() -> void:
	if world != null:
		adapter.drop_remote_player(world)


## A client joined: the remote player comes (back) into the game.
func restore_remote_player() -> void:
	if world != null:
		adapter.restore_remote_player(world)


@rpc("any_peer", "call_remote", "reliable")
func _client_hello(protocol := "", content := "", game := "") -> void:
	if not is_host or remote_peer != 0:
		return
	var refusal := "version" if protocol != session_protocol() or content != _content_digest or game != adapter.game_id() else ""
	if refusal == "" and world != null:
		refusal = adapter.accept_client(world)
	if refusal != "":
		_refused.rpc_id(multiplayer.get_remote_sender_id(), refusal)
		return
	remote_peer = multiplayer.get_remote_sender_id()
	_connect_started = -1.0
	_last_heard = clock.call()
	# A new client (possibly replacing one that left mid-game): it counts inputs from 1 and has
	# no baseline yet, and its player comes back into the game.
	remote_inputs = new_input_queue()
	_client_base = -1
	_client_acked_tick = -1
	_last_sent_tick = -1
	_unsent_events = []
	restore_remote_player()
	connected.emit()


## Defers closing until SceneMultiplayer finishes dispatching the refusal.
@rpc("authority", "call_remote", "reliable")
func _refused(reason: String) -> void:
	if is_host or _refused_reason != "":
		return  # the hello repeats until answered, so a refusal can arrive twice
	_refused_reason = reason
	(func(): close(); _refused_reason = ""; disconnected.emit(reason)).call_deferred()


## The client's newest inputs: one byte per tick, oldest first, the first with sequence number
## `first_seq`. A lost packet costs nothing because the next one repeats them.
## `base_tick`: the client's newest body to delta against (-1: send a keyframe).
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_inputs(first_seq: int, bits: PackedByteArray, base_tick: int, acked_tick: int) -> void:
	if not is_host or remote_peer == 0 or multiplayer.get_remote_sender_id() != remote_peer:
		return
	if bits.is_empty() or bits.size() > adapter.input_history() or first_seq < 0 \
			or first_seq > 0x7fffffffffffffff - bits.size():
		return
	_last_heard = clock.call()
	for i in bits.size():
		remote_inputs.accept(first_seq + i, bits[i])
	_client_base = base_tick
	_client_acked_tick = maxi(_client_acked_tick, acked_tick)


# --- Client ---

## This tick's input bits: kept and sent to the host every send_every ticks (with the last
## adapter.input_history() repeated), and predicted on our copy of the world straight away.
func client_tick(local_bits: int) -> void:
	if not is_online() or is_host:
		return
	_input_seq += 1
	var bits := local_bits & adapter.input_mask()
	_sent.append([_input_seq, bits])
	if _sent.size() > adapter.input_history():
		_sent.pop_front()
	if _input_seq % send_every == 0:
		flush_inputs()
	# While paused (the host away or silent) the input only keeps the link alive: no prediction,
	# and nothing to replay later.
	if prediction and together() and world != null and _last_tick >= 0:
		_pending.append([_input_seq, bits])
		if _pending.size() > adapter.max_replay():
			_pending.pop_front()
		_predict(bits)


func flush_inputs() -> void:
	if _sent.is_empty():
		return
	var bits := PackedByteArray()
	for e in _sent:
		bits.append(e[1])
	var base := -1 if _need_keyframe or not _bodies.has(_last_tick) else _last_tick
	_receive_inputs.rpc_id(1, _sent[0][0], bits, base, _last_tick)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_snapshot(payload: PackedByteArray) -> void:
	apply_snapshot(payload)


## Restores a host snapshot into `world`. Returns false for stale packets, and for deltas whose
## baseline the client doesn't have or that don't check out (it then asks for a keyframe).
func apply_snapshot(payload: PackedByteArray) -> bool:
	var raw := payload.decompress_dynamic(MAX_SNAPSHOT_BYTES, FileAccess.COMPRESSION_DEFLATE)
	var d: Variant = bytes_to_var(raw) if raw.size() > 0 else null
	if typeof(d) != TYPE_DICTIONARY or typeof(d.get("tick")) != TYPE_INT:
		return false
	_last_heard = clock.call()  # before the staleness check: a paused host's keep-alive repeats its tick
	if d.get("paused", false):
		_host_paused = true
		_pending.clear()  # the host drops what it queued meanwhile (skip_to_newest on resume)
	elif d["tick"] > _last_tick:
		_host_paused = false
	if d["tick"] <= _last_tick:
		return false
	var body: PackedByteArray
	var b: Variant
	if d.has("xor"):
		var base: PackedByteArray = _bodies.get(d.get("base", -1), PackedByteArray())
		if base.is_empty():
			_need_keyframe = true
			return false
		body = xor_bytes(d["xor"], base)
		if body.size() != d.get("len", -1) or hash(body) != d.get("hash", 0):
			_need_keyframe = true
			return false
		b = bytes_to_var(body)
	else:
		b = d.get("body")
		body = var_to_bytes(b)  # the same bytes the host keeps for this tick
	var s: Variant = adapter.snapshot_of(b) if typeof(b) == TYPE_DICTIONARY else null
	if s == null or s.get("tick") != d["tick"]:
		_need_keyframe = true
		return false
	s["events"] = d.get("events", [])
	var t0 := Time.get_ticks_usec()
	if world == null:
		world = adapter.new_world()
	adapter.restore(world, s)
	_last_tick = s["tick"]
	_need_keyframe = false
	_bodies[_last_tick] = body  # the baseline for later deltas
	for k in _bodies.keys():
		if k < _last_tick - 2 * adapter.max_base_age():
			_bodies.erase(k)
	_host_bits_seen = d.get("host_bits", 0)
	var acked: int = d.get("input_seq", -1)
	while not _pending.is_empty() and _pending[0][0] <= acked:
		_pending.pop_front()
	for e: Array in d.get("ev_hist", []):  # skipped ticks' events, unless already played
		_queue_events_for(e[0], e[1])
	_queue_events()  # the host's own events for this tick, unless already played
	if prediction:
		var limit := adapter.max_replay()
		if _pending.size() > limit:
			_pending = _pending.slice(_pending.size() - limit)
		for e in _pending:
			_predict(e[1])
	last_replay_us = Time.get_ticks_usec() - t0
	stats["snapshot_bytes"] = payload.size()
	stats["received"] += 1
	snapshot_applied.emit()
	return true


# --- Connection events ---

func _watch(on: bool) -> void:
	var pairs := [[multiplayer.peer_disconnected, _on_peer_disconnected],
		[multiplayer.connected_to_server, _on_connected_to_server],
		[multiplayer.connection_failed, _on_connection_failed],
		[multiplayer.server_disconnected, _on_server_disconnected]]
	for p in pairs:
		var sig: Signal = p[0]
		if on and not sig.is_connected(p[1]):
			sig.connect(p[1])
		elif not on and sig.is_connected(p[1]):
			sig.disconnect(p[1])


func _on_peer_disconnected(id: int) -> void:
	if is_host and id == remote_peer:
		remote_peer = 0
		drop_remote_player()
		disconnected.emit("player_left")


func _on_connected_to_server() -> void:
	_connect_started = -1.0
	_last_heard = clock.call()
	_client_hello.rpc_id(1, session_protocol(), _content_digest, adapter.game_id())
	connected.emit()


func _on_connection_failed() -> void:
	if multiplayer.multiplayer_peer is RelayPeer:
		return  # the reason arrives through RelayPeer.relay_error
	close()
	disconnected.emit("cant_connect")


func _on_server_disconnected() -> void:
	if multiplayer.multiplayer_peer is RelayPeer:
		return  # the reason arrives through RelayPeer.relay_error
	close()
	disconnected.emit("host_left")

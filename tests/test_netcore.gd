extends TestCase
## NetCoreSession with a toy game (ToyAdapter below): two sessions in one process, each under its
## own MultiplayerAPI, through FakeRelay. The toy game uses slots 0 and 1 and sends every tick,
## so these tests also cover settings other than the defaults a game might assume.


## A world: each slot's position moves by its input bits every tick; a "moved" event per move.
class ToyWorld extends RefCounted:
	var tick_count := 0
	var pos := {0: 0, 1: 0}
	var over := false
	var events: Array = []


class ToyAdapter extends NetAdapter:
	var refuse_when_over := "game_over"

	func game_id() -> String:
		return "toy"

	func game_protocol() -> int:
		return 7

	func content_digest() -> String:
		return "abc"

	func new_world() -> Object:
		return ToyWorld.new()

	func tick(world: Object, inputs: Dictionary) -> void:
		world.tick_count += 1
		world.events = []
		for slot in inputs:
			if inputs[slot] != 0:
				world.pos[slot] += inputs[slot]
				world.events.append(["moved", slot])

	func snapshot(world: Object) -> Dictionary:
		return {"tick": world.tick_count, "pos": world.pos.duplicate(), "over": world.over,
			"events": world.events.duplicate()}

	func restore(world: Object, snap: Dictionary) -> void:
		world.tick_count = snap["tick"]
		world.pos = snap["pos"].duplicate()
		world.over = snap["over"]
		world.events = snap["events"]

	func world_tick(world: Object) -> int:
		return world.tick_count

	func world_events(world: Object) -> Array:
		return world.events

	func accept_client(world: Object) -> String:
		return refuse_when_over if world.over else ""

	func client_commands() -> Array:
		return ["end"]

	func apply_command(world: Object, _slot: int, name: String) -> void:
		if name == "end":
			world.over = true


func _frame(f: int) -> void:
	for i in f:
		await (Engine.get_main_loop() as SceneTree).process_frame


func _sides(names: Array) -> Array:
	var tree := Engine.get_main_loop() as SceneTree
	var sides := []
	for side in names:
		var root := Node.new()
		root.name = side
		tree.root.add_child(root)
		tree.set_multiplayer(SceneMultiplayer.new(), root.get_path())
		var s := NetCoreSession.new()
		s.name = "Net"
		s.adapter = ToyAdapter.new()
		root.add_child(s)
		sides.append(s)
	return sides


func _free(sides: Array) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for s: NetCoreSession in sides:
		s.close()
		var root := s.get_parent()
		tree.set_multiplayer(null, root.get_path())
		root.queue_free()
	await tree.process_frame


## Host and client paired through `relay`, the host running a fresh ToyWorld.
func _paired(relay: FakeRelay, names: Array) -> Array:
	var sides := _sides(names)
	var host: NetCoreSession = sides[0]
	var client: NetCoreSession = sides[1]
	host.host_relay("ws://fake", relay.factory())
	await _frame(2)
	host.world = ToyWorld.new()
	client.join_relay("ws://fake", relay.code, relay.factory())
	for i in 200:
		if host.remote_peer != 0:
			break
		await _frame(1)
	return sides


func test_the_relay_url_names_the_game_relay_version_and_session_protocol() -> void:
	await _frame(1)
	var relay := FakeRelay.new()
	var sides := _sides(["UrlHost"])
	sides[0].host_relay("ws://fake", relay.factory())
	await _frame(2)
	var url: String = relay.urls[0]
	check(url.begins_with("ws://fake/host?"), url)
	for part in ["relay=%d" % RelayPeer.RELAY_VERSION, "game=toy", "protocol=%d.7" % NetCoreSession.NETCORE_PROTOCOL,
			"content=abc"]:
		check(part in url.split("?")[1].split("&"), "%s in %s" % [part, url])
	await _free(sides)


func test_the_client_mirrors_the_host_on_slots_0_and_1() -> void:
	await _frame(1)
	var relay := FakeRelay.new()
	var sides := await _paired(relay, ["ToyHost", "ToyClient"])
	var host: NetCoreSession = sides[0]
	var client: NetCoreSession = sides[1]
	check(host.remote_peer != 0, "client said hello")
	check_eq(host.send_every, 1, "the adapter's relay send rate")
	for i in 60:
		host.host_tick(2)
		client.client_tick(1)
		await _frame(1)
	for i in 60:
		host.host_tick(0)
		await _frame(1)
		if client.world != null and client.world.tick_count == host.world.tick_count and client._pending.is_empty():
			break
	check(host.world.pos[0] > 0 and host.world.pos[1] > 0, "both slots moved: %s" % host.world.pos)
	check_eq(client.world.tick_count, host.world.tick_count, "client caught up")
	check_eq(client.world.pos, host.world.pos, "client mirrors the host")
	check(host.stats["keyframes"] >= 1, "a keyframe first")
	check(host.stats["sent"] > host.stats["keyframes"], "then deltas")
	var moved := client.take_events().filter(func(e): return e[0] == "moved" and e[1] == 0)
	check(not moved.is_empty(), "the host's own moves reach the client as events")
	await _free(sides)


func test_a_client_command_reaches_the_host_world() -> void:
	await _frame(1)
	var relay := FakeRelay.new()
	var sides := await _paired(relay, ["CmdHost", "CmdClient"])
	sides[1].send_command("end")
	sides[1].send_command("not_allowed")
	for i in 20:
		sides[0].host_tick(0)
		sides[1].client_tick(0)
		await _frame(1)
		if sides[0].world.over:
			break
	check(sides[0].world.over, "the allowed command applied")
	await _free(sides)


func test_the_host_refuses_a_client_with_the_adapters_reason() -> void:
	await _frame(1)
	var relay := FakeRelay.new()
	var sides := _sides(["RefHost", "RefClient"])
	var host: NetCoreSession = sides[0]
	var client: NetCoreSession = sides[1]
	var reasons := []
	client.disconnected.connect(func(r): reasons.append(r))
	host.host_relay("ws://fake", relay.factory())
	await _frame(2)
	host.world = ToyWorld.new()
	host.world.over = true
	client.join_relay("ws://fake", relay.code, relay.factory())
	await _frame(60)
	check_eq(reasons, ["game_over"], "told once, with the code")
	check_eq(host.remote_peer, 0, "not let in")
	check(not client.is_online(), "the client left")
	await _free(sides)


func test_a_relay_error_with_a_game_running_ends_the_room_not_the_game() -> void:
	await _frame(1)
	var relay := FakeRelay.new()
	var sides := await _paired(relay, ["EndHost", "EndClient"])
	var host: NetCoreSession = sides[0]
	var ended := []
	var gone := []
	host.room_ended.connect(func(r): ended.append(r))
	host.disconnected.connect(func(r): gone.append(r))
	var world: Object = host.world
	relay.send_error("host", "limit")
	await _frame(5)
	check_eq(ended, ["limit"], "room_ended with the relay's reason")
	check(host.world == world, "the host keeps its world")
	check(not "limit" in gone, "not a disconnect")
	await _free(sides)


func test_host_relay_with_adopts_the_world_only_when_the_room_is_ready() -> void:
	await _frame(1)
	var relay := FakeRelay.new()
	var sides := _sides(["AdoptHost"])
	var host: NetCoreSession = sides[0]
	var running := ToyWorld.new()
	running.tick_count = 500
	host.host_relay_with(running, "ws://fake", relay.factory())
	check(host.world == null, "not adopted before the room exists")
	await _frame(2)
	check(host.world == running, "adopted on room_ready")
	await _free(sides)


func test_a_failed_host_relay_with_leaves_the_game_alone() -> void:
	await _frame(1)
	var sides := _sides(["AdoptFail"])
	var host: NetCoreSession = sides[0]
	var reasons := []
	host.disconnected.connect(func(r): reasons.append(r))
	var relay := FakeRelay.new()
	relay.drop_all()
	var running := ToyWorld.new()
	host.connect_deadline_s = 0.1
	host.host_relay_with(running, "ws://fake", func(): var s := relay.socket(); s.opens = false; return s)
	await _frame(30)
	check(host.world == null, "never adopted")
	check_eq(running.tick_count, 0, "the local game untouched")
	check(not reasons.is_empty(), "told why: %s" % [reasons])
	await _free(sides)


func test_away_state_is_a_code() -> void:
	await _frame(1)
	var relay := FakeRelay.new()
	var sides := await _paired(relay, ["AwayHost", "AwayClient"])
	var host: NetCoreSession = sides[0]
	for i in 5:
		host.host_tick(0)
		sides[1].client_tick(0)
		await _frame(1)
	check_eq(host.away_state(), "", "playing")
	var later: float = host.clock.call() + NetCoreSession.SILENCE_S + 1.0
	host.clock = func(): return later  # the client silent for longer than SILENCE_S
	check_eq(host.away_state(), "waiting_player", "the client is away")
	check_eq(sides[1].away_state(), "", "the client still hears the host")
	await _free(sides)


func test_digest_is_short_stable_and_ordered() -> void:
	var a := NetDigest.of({"b": "2".to_utf8_buffer(), "a": "1".to_utf8_buffer()})
	var b := NetDigest.of({"a": "1".to_utf8_buffer(), "b": "2".to_utf8_buffer()})
	check_eq(a, b, "key order doesn't matter")
	check_eq(a.length(), 12, "12 hex digits")
	check(a != NetDigest.of({"a": "1".to_utf8_buffer(), "b": "3".to_utf8_buffer()}), "bytes count")


func test_input_queue_masks_and_repeats() -> void:
	var q := InputQueue.new(3, 30, 0x0f)
	q.accept(1, 0xff)
	check_eq(q.take(), 0x0f, "masked")
	check_eq(q.take(), 0x0f, "repeats the last")
	for s in range(2, 12):
		q.accept(s, s)
	q.take()
	check_eq(q.applied_seq, 11 - 3, "skipped to within max_behind")

class_name NetAdapter
extends RefCounted
## A game's side of NetCoreSession: its world, its snapshot layout, its slots and its tuning.
## Each game extends this and sets it as its session's `adapter`. The defaults suit a 30 Hz game
## that sends every tick; a world is any object the game's hooks understand. NetCoreSession.world
## is typed Object, so game code reading it annotates its variables (`var w: MyWorld = Net.world`).
##
## A snapshot is a Dictionary with at least "tick" (int, the world's tick count) and "events"
## (Array, what happened that tick: sounds, effects). body_of() turns the rest of it into the
## Dictionary that goes on the wire; its Variant bytes should keep the same layout from tick to
## tick, because deltas are those bytes XOR an earlier body.
##
## Laying out a body: anything whose size changes (lists that grow and shrink, strings) goes
## last, because a size change shifts every byte after it and the XOR stops being mostly zeros.
## Give things that come and go fixed slots (a pool, or a per-cell array) and store records as
## columns of packed ints, so one entity appearing doesn't move the others. A badly laid out body
## can make deltas larger than keyframes; measure both.


## The game's id on the relay: a room only pairs connections with the same id.
func game_id() -> String:
	return ""


## Bump when the sim or the body layout changes: peers with different values never pair.
func game_protocol() -> int:
	return 1


## A hash of the data both sides must share (NetDigest helps build it).
func content_digest() -> String:
	return ""


func lan_port() -> int:
	return 47770


func host_slot() -> int:
	return 0


func client_slot() -> int:
	return 1


## Snapshot and input packets every this many ticks, on a LAN and on the relay.
func send_every_lan() -> int:
	return 1


func send_every_relay() -> int:
	return 1


## The bits of an input that count (inputs travel as one byte per tick).
func input_mask() -> int:
	return 0xff


## InputQueue: inputs queued beyond this are skipped; a backlog this many ticks long drains one.
func input_max_behind() -> int:
	return 6


func input_drain_ticks() -> int:
	return 30


## Inputs repeated in each client packet.
func input_history() -> int:
	return 8


## Client: inputs replayed on top of a snapshot, at most.
func max_replay() -> int:
	return 20


## The host stops sending once the client's newest applied snapshot is this many ticks behind.
func max_unacked_ticks() -> int:
	return 15


## Deltas only use a baseline at most this many ticks old (the client keeps twice as many).
func max_base_age() -> int:
	return 128


## Client: ticks of played events kept, to play each event once across replays.
func event_window() -> int:
	return 150


## Meta commands a client may send to the host.
func client_commands() -> Array:
	return []


# --- The world ---

## The client's mirror, before the first snapshot is restored into it.
func new_world() -> Object:
	return null


## One tick with each slot's input bits ({slot: int}).
func tick(_world: Object, _inputs: Dictionary) -> void:
	pass


func snapshot(_world: Object) -> Dictionary:
	return {}


func restore(_world: Object, _snap: Dictionary) -> void:
	pass


func world_tick(_world: Object) -> int:
	return 0


## The events of the world's last tick.
func world_events(_world: Object) -> Array:
	return []


## The wire layout of a snapshot, without its events.
func body_of(snap: Dictionary) -> Dictionary:
	var b := snap.duplicate()
	b.erase("events")
	return b


## The snapshot back from body_of() (without events), or null if the body is malformed.
func snapshot_of(body: Dictionary) -> Variant:
	return body.duplicate() if typeof(body.get("tick")) == TYPE_INT else null


func apply_command(_world: Object, _slot: int, _name: String) -> void:
	pass


## A reason code to turn a joining client away (e.g. "game_over"), or "" to accept it.
func accept_client(_world: Object) -> String:
	return ""


## The remote player left for good; the host plays on.
func drop_remote_player(_world: Object) -> void:
	pass


## A client joined: bring the remote player (back) into the game.
func restore_remote_player(_world: Object) -> void:
	pass

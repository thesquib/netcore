class_name InputQueue
extends RefCounted
## The host's queue of the remote player's inputs, by sequence number.
## Packets carry the newest few inputs, so a lost packet costs nothing; each host tick applies the
## next one in order, repeating the last when none is waiting, and skipping ahead when more than
## max_behind are queued (after a freeze), so old steering isn't replayed for seconds. A queue
## that stays backed up for drain_ticks drops one input, so a burst can't leave a standing delay.
## An input is the game's input bits (masked by `mask`), one per tick.

var max_behind: int
var drain_ticks: int     # about a second of continuous backlog
var mask: int
var newest_seq := -1
var applied_seq := -1
var _queue: Array = []  # [seq, bits]
var _bits := 0
var _backed_up := 0  # consecutive takes that left inputs waiting


func _init(p_max_behind := 6, p_drain_ticks := 30, p_mask := 0xff) -> void:
	max_behind = p_max_behind
	drain_ticks = p_drain_ticks
	mask = p_mask


func accept(seq: int, bits: int) -> bool:
	if seq <= newest_seq:
		return false
	newest_seq = seq
	_queue.append([seq, bits & mask])
	return true


func skip_to_newest() -> void:
	if _queue.size() > 1:
		_queue = [_queue.back()]


## The input bits for this tick.
func take() -> int:
	while _queue.size() > max_behind + 1:
		_queue.pop_front()
	if not _queue.is_empty():
		var e: Array = _queue.pop_front()
		applied_seq = e[0]
		_bits = e[1]
	# When inputs arrive in pairs (one packet every 2nd tick) the queue still empties every other
	# tick, so only a real standing delay counts up.
	_backed_up = _backed_up + 1 if not _queue.is_empty() else 0
	if _backed_up >= drain_ticks:  # a standing delay: catch up by one
		_backed_up = 0
		var e: Array = _queue.pop_front()
		applied_seq = e[0]
		_bits = e[1]
	return _bits

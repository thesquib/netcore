class_name NetBeacon
extends RefCounted
## LAN discovery, host side: once a second, broadcasts a small UDP packet announcing the game to
## a UDP port (broadcast plus loopback, so a second copy on the same machine sees it).
## NetBrowser listens for these packets. Each game picks its own port and magic string, so
## different games can run on one LAN.

const INTERVAL_MS := 1000

## What the game announces, e.g. {name, port, mode, level}.
var info := {}
var port: int
var magic: String
var _udp := PacketPeerUDP.new()
var _next_ms := 0


func _init(p_port: int, p_magic: String, p_info: Dictionary) -> void:
	port = p_port
	magic = p_magic
	info = p_info
	_udp.set_broadcast_enabled(true)


func poll(now_ms := Time.get_ticks_msec()) -> void:
	if now_ms < _next_ms:
		return
	_next_ms = now_ms + INTERVAL_MS
	var packet := info.duplicate()
	packet["magic"] = magic
	var bytes := var_to_bytes(packet)
	for address in ["255.255.255.255", "127.0.0.1"]:
		_udp.set_dest_address(address, port)
		_udp.put_packet(bytes)


func close() -> void:
	_udp.close()

class_name NetBrowser
extends RefCounted
## LAN discovery, joining side: listens on a UDP port for NetBeacon packets and keeps a list of
## the hosts it has heard from recently. bytes_to_var never decodes objects, so stray packets
## can't do harm; ones without the magic string are ignored.

const EXPIRE_MS := 3500

## "ip:port" -> the announced fields plus {ip, name, port, seen}
var hosts := {}
var port: int
var magic: String
var default_game_port: int
var _udp := PacketPeerUDP.new()


## `p_port`, `p_magic`: the beacon's. `p_game_port`: the game port when a packet names none.
func _init(p_port: int, p_magic: String, p_game_port: int) -> void:
	port = p_port
	magic = p_magic
	default_game_port = p_game_port


func start() -> Error:
	return _udp.bind(port)


func poll(now_ms := Time.get_ticks_msec()) -> void:
	while _udp.get_available_packet_count() > 0:
		var bytes := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var d: Variant = bytes_to_var(bytes)
		if typeof(d) != TYPE_DICTIONARY or d.get("magic") != magic:
			continue
		var game_port := default_game_port
		if typeof(d.get("port")) == TYPE_INT:
			game_port = d["port"]
		var entry: Dictionary = d.duplicate()
		entry.erase("magic")
		entry.merge({"ip": ip, "name": str(d.get("name", "HOST")), "port": game_port, "seen": now_ms}, true)
		hosts["%s:%d" % [ip, game_port]] = entry
	for key in hosts.keys():
		if now_ms - hosts[key]["seen"] > EXPIRE_MS:
			hosts.erase(key)


## Hosts sorted by name and then address, so the list doesn't jump around.
func sorted_hosts() -> Array:
	var list := hosts.values()
	list.sort_custom(func(a, b): return [a["name"], a["ip"]] < [b["name"], b["ip"]])
	return list


func close() -> void:
	_udp.close()

# netcore

Online and LAN play for two-player, host-authoritative Godot 4 games, plus the relay server
they meet through. Several games can share one relay: each names itself with a game id, and
rooms only pair the same game.

## Contents

- **Godot addon** (this folder, added to a game at `game/addons/netcore`):
  - `NetCoreSession`: host-authoritative play for two players over ENet (LAN) or the relay.
    The host runs the only world; the client sends its inputs, predicts its own player and
    restores the host's snapshots (keyframes, or XOR deltas against a snapshot it has
    acknowledged). Holds the link through drops (waits up to two minutes), refuses clients
    the game turns away, hosts a game already in progress (`host_relay_with`), and reports
    reasons as codes for the game to word.
  - `NetAdapter`: the game's side: its world, snapshot layout, slots, tuning and commands.
  - `NetDigest`: helpers for the content digest both sides must share.
  - `RelayPeer`: Godot's multiplayer over a WebSocket to the relay. Seat tokens, rejoin after a
    dropped link, explicit leave.
  - `InputQueue`: the host's queue of the remote player's inputs (in order, catch-up, drain).
  - `NetBeacon`, `NetBrowser`: LAN discovery over UDP broadcast.
  - `tests/`: `FakeRelay`, an in-process stand-in for the relay.
- **Relay** (`relay/`, ignored by Godot): rooms with four-letter codes, one host and one client
  seat, binary frames forwarded as they are, a held seat for two minutes after a drop.
  - `room.js` and `codes.js` hold the rooms and use no platform APIs.
  - `node.js` runs it standalone (`npm start`, port 8790); `worker.js` runs it as a Cloudflare
    Worker with one Durable Object per room.

## Adding it to a game

```sh
git submodule add https://github.com/thesquib/netcore.git game/addons/netcore
git config -f .gitmodules submodule.game/addons/netcore.ignore untracked   # relay/node_modules
```

Exclude `addons/netcore/tests/*` in the game's export presets, and have the game's test runner
also run `res://addons/netcore/tests/test_*.gd` (they extend the game's `TestCase`, with
`check`, `check_eq` and `skip`).

The game extends `NetCoreSession` for its constants and wording, sets its `NetAdapter` in
`_init`, and uses that script as an autoload:

```gdscript
class_name NetSession
extends NetCoreSession

func _init() -> void:
	adapter = MyGameAdapter.new()   # extends NetAdapter
```

Each tick the game calls `host_tick(bits)` on the host or `client_tick(bits)` on the client,
plays `take_events()` on the client, and shows `away_state()` (`reconnecting`,
`waiting_player`, `waiting_host`) while a game waits.

## Versions

A relay connection names three things in its query:

- `relay`: the relay wire version (`RelayPeer.RELAY_VERSION`). A relay refuses versions it
  doesn't speak with `relay_version`. None means 1.
- `game`: the game's id. A room only pairs connections with the same id; another game's room
  answers `no_room`. None means "", which only matches "".
- `protocol` and `content`: the session protocol (`"<NETCORE_PROTOCOL>.<game protocol>"`) and
  the game's data digest, compared as opaque strings. Different values are refused with
  `version`. `NetCoreSession.NETCORE_PROTOCOL` changes with the hello, input or snapshot
  framing; the game bumps its own protocol when its sim or snapshot layout changes.

Releases are tagged; `CHANGELOG.md` lists any protocol change.

## Relay

```sh
cd relay
npm install
npm test                      # the protocol suite against the room core, Node and wrangler dev
npm start                     # ws://localhost:8790
```

`startServer({ maxRooms, hostsPerMin, joinsPerMin, trustProxy, plugins })` caps open rooms and
room creations and joins per IP. `--trust-proxy` reads the client address from
`X-Forwarded-For`; use it only behind a proxy you control. On Cloudflare, add a rate limiting
rule on the relay's hostname instead.

A game adds its own HTTP routes with plugins:

- Node: `startServer({ plugins: [{ http(req, res, ctx) }] })`; return true once answered.
- Worker: the game's entry module exports `makeWorker({ plugins: [{ fetch(request, env, ctx) }] })`
  as its default (return a Response, or null to pass) and re-exports `RoomObject` plus its own
  Durable Object classes for its `wrangler.toml`.

## Licence

MIT, see `LICENSE`.

# Changelog

Protocol numbers that a release changes are listed with it: the relay wire version
(`RelayPeer.RELAY_VERSION`, `relay/room.js` `RELAY_VERSIONS`) and the session protocol
(`NetSession.NETCORE_PROTOCOL`).

## 1.0.0

Relay wire version 1, session protocol 1.

- Relay: rooms take a game id (`game=`) and a relay wire version (`relay=`, 1). A connection
  without them is game "" and version 1, so older builds pair as before.
- Relay: plugins for a game's own HTTP routes (`startServer({ plugins })`, `makeWorker({ plugins })`).
- `NetCoreSession` (session protocol 1) with `NetAdapter` for the game's side: keyframes and
  XOR deltas, prediction, held links, refusals (`accept_client`), `room_ended`,
  `host_relay_with`, reason codes and `away_state()`. `NetDigest` for content digests.
- RelayPeer, InputQueue, NetBeacon and NetBrowser take the game's id, tuning, ports and magic as
  arguments.

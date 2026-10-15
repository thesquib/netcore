# Changelog

Protocol numbers that a release changes are listed with it: the relay wire version
(`RelayPeer.RELAY_VERSION`, `relay/room.js` `RELAY_VERSIONS`) and the session protocol
(`NetSession.NETCORE_PROTOCOL`).

## Unreleased

- Relay: rooms take a game id (`game=`) and a relay wire version (`relay=`, 1). A connection
  without them is game "" and version 1, so older builds pair as before.
- Relay: plugins for a game's own HTTP routes (`startServer({ plugins })`, `makeWorker({ plugins })`).
- RelayPeer, InputQueue, NetBeacon and NetBrowser take the game's id, tuning, ports and magic as
  arguments.

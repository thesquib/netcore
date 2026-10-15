// Cloudflare Worker + one Durable Object per room. The Worker routes /host to a fresh code's
// object (retrying if the code is taken), and /join/<CODE> and /rejoin/<CODE> to that code's
// object. The object uses the WebSocket Hibernation API, so an idle room costs nothing. Its
// Room state lives in storage (while the host is away no socket holds it), and each socket's
// attachment says which seat it is, so the Room is rebuilt when the object wakes.
// A game adds HTTP routes of its own with plugins: makeWorker({ plugins: [{ fetch(request, env, ctx) }] })
// is the Worker's default export; each plugin returns a Response, or null to pass. Plugins see
// every request before the relay's own routes. The game's entry module re-exports RoomObject
// (and its plugins' Durable Object classes) for its wrangler.toml.
import { DurableObject } from 'cloudflare:workers';
import { Room, versionOf } from './room.js';
import { randomCode, normalise } from './codes.js';

export function makeWorker({ plugins = [] } = {}) {
  return {
    async fetch(request, env, ctx) {
      for (const p of plugins) {
        const res = p.fetch && await p.fetch(request, env, ctx);
        if (res) return res;
      }
      return relayFetch(request, env);
    },
  };
}

export default makeWorker();

async function relayFetch(request, env) {
  if (request.headers.get('Upgrade') !== 'websocket') return new Response('WebSocket only\n', { status: 426 });
  const url = new URL(request.url);
  const parts = url.pathname.split('/').filter(Boolean);
  if (parts.length === 1 && parts[0] === 'host') {
    for (let i = 0; i < 8; i++) {
      const code = randomCode();
      const res = await stub(env, code).fetch(roomRequest(request, url, code, 'host'));
      if (res.status !== 409) return res;  // 409: that code is in use, try another
    }
    return new Response('busy\n', { status: 503 });
  }
  if (parts.length === 2 && (parts[0] === 'join' || parts[0] === 'rejoin')) {
    const code = normalise(parts[1]) || '_';  // not a real code: an empty room answers no_room / no_seat
    return stub(env, code).fetch(roomRequest(request, url, code, parts[0]));
  }
  return new Response('not found\n', { status: 404 });
}

function stub(env, code) {
  return env.ROOMS.get(env.ROOMS.idFromName(code));
}

function roomRequest(request, url, code, role) {
  const u = new URL(`https://room/${role}`);
  u.search = url.search;
  u.searchParams.set('code', code);
  return new Request(u, request);
}

export class RoomObject extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.room = null;
    this.savedRev = -1;
    ctx.blockConcurrencyWhile(async () => { this.saved = await ctx.storage.get('room'); });
  }

  _room() {
    if (this.room) return this.room;
    this.room = this.saved ? Room.fromJSON(this.saved, Date.now) : new Room({ code: null, now: Date.now });
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() || {};
      if (!this.room.attach(att.role, this._conn(ws), att.token)) {
        try { ws.close(1000, 'stale'); } catch { /* already closed */ }
      }
    }
    this.savedRev = this.room.rev;
    this.room.settleAfterWake();  // bumps rev if a seat lost its socket: the next _save stores it
    return this.room;
  }

  _conn(ws) {
    if (!ws.__conn) {
      ws.__conn = {
        meta: {},
        send(d) { try { ws.send(d); } catch { /* already closed */ } },
        close(code, reason) {
          // Forget its seat first: a closed-but-lingering socket must never re-attach after a wake.
          try { ws.serializeAttachment({}); } catch { /* already gone */ }
          try { ws.close(code, reason); } catch { /* already closed */ }
        },
      };
    }
    return ws.__conn;
  }

  async _save() {
    const room = this.room;
    if (!room || room.rev === this.savedRev) return;
    this.savedRev = room.rev;
    if (room.isEmpty) await this.ctx.storage.delete('room');
    else await this.ctx.storage.put('room', room.toJSON());
  }

  async _schedule() {
    const at = this.room?.nextDeadline();
    if (at) await this.ctx.storage.setAlarm(at);
    else await this.ctx.storage.deleteAlarm();
  }

  async fetch(request) {
    const url = new URL(request.url);
    const role = url.pathname.slice(1);
    const code = url.searchParams.get('code');
    const room = this._room();
    if (room.code === null || room.isEmpty) room.code = code;
    if (role === 'host' && room.hasHost) return new Response('taken', { status: 409 });
    const version = versionOf(url.searchParams);
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    const conn = this._conn(server);
    if (role === 'host') room.addHost(conn, version);
    else if (role === 'rejoin') room.rejoin(conn, url.searchParams.get('token') || '', version);
    else room.addClient(conn, version);
    for (const r of ['host', 'client']) {
      if (room.seats[r]?.conn === conn) server.serializeAttachment({ role: r, token: room.seats[r].token });
    }
    await this._save();
    await this._schedule();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    this._room().message(this._conn(ws), message);
    if (this.room.rev !== this.savedRev) {
      await this._save();
      await this._schedule();
    }
  }

  async webSocketClose(ws) {
    this._room().leave(this._conn(ws));
    await this._save();
    await this._schedule();
  }

  async webSocketError(ws) {
    await this.webSocketClose(ws);
  }

  async alarm() {
    this._room().check();
    await this._save();
    await this._schedule();
  }
}

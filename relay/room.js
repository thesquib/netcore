// One relay room: a host seat and at most one client seat. Pairs them, forwards binary frames
// verbatim, holds a dropped seat for GRACE_MS so its owner can rejoin with its token, and
// enforces the limits. No platform APIs: worker.js (Durable Object) and node.js (ws) wrap it.
// A conn is {send(data), close(code, reason), meta: {}}; send() gets a string for control
// messages and binary otherwise. A seat is {conn|null, token, awayUntil|null}.
export const MAX_FRAME = 65536;
export const MAX_RATE = 120;            // messages per second per connection
export const UNJOINED_MS = 10 * 60 * 1000;
export const MAX_AGE_MS = 3 * 60 * 60 * 1000;
export const GRACE_MS = 2 * 60 * 1000;  // a dropped seat waits this long for its owner
// The relay wire versions this relay speaks (the room and control messages). A connection that
// names none is version 1, so builds from before the version existed keep working.
export const RELAY_VERSIONS = ['1'];

// A connection's version from its query: the relay wire version, the game id (a room only pairs
// one game; none is "", which only matches ""), and the game's session protocol and content
// digest, compared as opaque strings.
export function versionOf(params) {
  return {
    relay: params.get('relay') ?? '1',
    game: params.get('game') ?? '',
    protocol: params.get('protocol'),
    content: params.get('content'),
  };
}

const ctl = (conn, obj) => conn.send(JSON.stringify(obj));
const ROLES = ['host', 'client'];

function newToken() {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  return [...crypto.getRandomValues(new Uint8Array(16))].map(b => alphabet[b & 31]).join('');
}

export class Room {
  constructor({ code, now }) {
    this.code = code;
    this.now = now;
    this.seats = { host: null, client: null };
    this.version = null;            // {game, protocol, content} of the host
    this.created = now();
    this.lastAlone = this.created;  // when the host was last without a client seat
    this.rev = 0;                   // bumped on every state change (the Durable Object saves on change)
  }

  get hasHost() { return this.seats.host !== null; }
  get isEmpty() { return !this.seats.host && !this.seats.client; }

  addHost(conn, { relay = '1', game = '', protocol, content }) {
    if (!RELAY_VERSIONS.includes(String(relay))) { this._refuse(conn, 'relay_version'); return false; }
    if (this.seats.host) return false;
    this.version = { game: String(game), protocol: String(protocol), content: String(content) };
    this.created = this.lastAlone = this.now();
    this.seats.host = { conn, token: newToken(), awayUntil: null };
    this._changed();
    ctl(conn, { type: 'room', code: this.code, token: this.seats.host.token });
    return true;
  }

  addClient(conn, { relay = '1', game = '', protocol, content }) {
    if (!RELAY_VERSIONS.includes(String(relay))) return this._refuse(conn, 'relay_version');
    // Another game's room looks like no room at all.
    if (!this.seats.host || String(game) !== this.version.game) return this._refuse(conn, 'no_room');
    if (this.seats.client) return this._refuse(conn, 'full');
    if (!this._sameVersion(protocol, content)) return this._refuse(conn, 'version');
    this.seats.client = { conn, token: newToken(), awayUntil: null };
    this._changed();
    ctl(conn, { type: 'paired', token: this.seats.client.token });
    // If the host is away (or its socket is half-dead), its rejoin's `resumed` says paired.
    const host = this.seats.host;
    if (host.conn) ctl(host.conn, { type: 'paired' });
  }

  rejoin(conn, token, { relay = '1', game = '', protocol, content }) {
    if (!RELAY_VERSIONS.includes(String(relay))) return this._refuse(conn, 'relay_version');
    const role = ROLES.find(r => this.seats[r] && this.seats[r].token === token);
    if (!role || String(game) !== this.version.game || !this._sameVersion(protocol, content)) {
      return this._refuse(conn, 'no_seat');
    }
    const seat = this.seats[role];
    const old = seat.conn;
    const wasAway = seat.awayUntil !== null;
    seat.conn = conn;
    seat.awayUntil = null;
    this._changed();
    if (old) {  // its later close is ignored: it's no longer the seat's conn
      ctl(old, { type: 'replaced' });  // arrives even where a server-side close doesn't (workerd)
      old.close(1000, 'replaced');
    }
    const other = this.seats[role === 'host' ? 'client' : 'host'];
    // `paired` says whether the seat has a partner, so a host whose `paired` went to a dead
    // socket still learns it.
    ctl(conn, { type: 'resumed', paired: !!other, peer_up: !!other && other.awayUntil === null });
    if (wasAway && other?.conn) ctl(other.conn, { type: 'peer_back' });
  }

  // Rebuilds a seat's connection after a Durable Object wakes (no messages are sent).
  attach(role, conn, token) {
    const seat = this.seats[role];
    if (!seat || seat.token !== token || seat.awayUntil !== null) return false;
    seat.conn = conn;
    return true;
  }

  message(conn, data) {
    const role = this._roleOf(conn);
    if (!role) return;
    const size = typeof data === 'string' ? data.length : data.byteLength;
    if (size > MAX_FRAME || !this._withinRate(conn)) return this._kick(conn, 'limit');
    if (typeof data === 'string') {
      let m = null;
      try { m = JSON.parse(data); } catch { /* not ours */ }
      if (m && m.type === 'leave') this.leave(conn, true);
      return;
    }
    const other = this.seats[role === 'host' ? 'client' : 'host'];
    if (other?.conn) other.conn.send(data);
  }

  // A socket closed. Explicit (a leave message or a kick): the seat goes now. Otherwise it's a
  // drop: the seat is held for GRACE_MS and the other side hears peer_away.
  leave(conn, explicit = false) {
    const role = this._roleOf(conn);
    if (!role) return;  // e.g. an old socket already replaced by a rejoin
    if (explicit) return this._vacate(role);
    const seat = this.seats[role];
    seat.conn = null;
    seat.awayUntil = this.now() + GRACE_MS;
    this._changed();
    const other = this.seats[role === 'host' ? 'client' : 'host'];
    if (other?.conn) ctl(other.conn, { type: 'peer_away' });
  }

  // Runs the deadlines. An away client seat past its grace is vacated (the host hears
  // peer_left). Returns true when the whole room is over: too old, the host away too long,
  // nobody joined in time, or no host seat at all.
  check() {
    const t = this.now();
    const c = this.seats.client;
    if (c && c.awayUntil !== null && t > c.awayUntil) this._vacate('client');
    const h = this.seats.host;
    const over = !h || t - this.created > MAX_AGE_MS
      || (h.awayUntil !== null && t > h.awayUntil)
      || (!this.seats.client && t - this.lastAlone > UNJOINED_MS);
    if (over) this.expire();
    return over;
  }

  // The next time check() has something to do (for a Durable Object alarm), or null if empty.
  nextDeadline() {
    if (this.isEmpty) return null;
    const times = [this.created + MAX_AGE_MS + 1];
    for (const r of ROLES) {
      const s = this.seats[r];
      if (s && s.awayUntil !== null) times.push(s.awayUntil + 1);
    }
    if (!this.seats.client) times.push(this.lastAlone + UNJOINED_MS + 1);
    return Math.min(...times);
  }

  expire() {
    for (const r of ROLES) {
      const s = this.seats[r];
      if (s?.conn) {
        if (r === 'client' && this.seats.host) ctl(s.conn, { type: 'peer_left' });
        s.conn.close(1000, 'expired');
      }
    }
    this.seats = { host: null, client: null };
    this._changed();
  }

  // After a Durable Object wakes and re-attaches the sockets it still has: a seat that was
  // connected but whose socket didn't come back (e.g. a runtime restart) is now away, the other
  // side hears peer_away, and the change is saved and its deadline scheduled.
  settleAfterWake() {
    for (const r of ROLES) {
      const s = this.seats[r];
      if (s && s.conn === null && s.awayUntil === null) {
        s.awayUntil = this.now() + GRACE_MS;
        this._changed();
        const other = this.seats[r === 'host' ? 'client' : 'host'];
        if (other?.conn) ctl(other.conn, { type: 'peer_away' });
      }
    }
  }

  toJSON() {
    const seat = s => s && { token: s.token, awayUntil: s.awayUntil };
    return { code: this.code, version: this.version, created: this.created, lastAlone: this.lastAlone,
      seats: { host: seat(this.seats.host), client: seat(this.seats.client) } };
  }

  static fromJSON(data, now) {
    const room = new Room({ code: data.code, now });
    room.version = data.version && { game: '', ...data.version };  // saved before game ids: ''
    room.created = data.created;
    room.lastAlone = data.lastAlone;
    for (const r of ROLES) {
      const s = data.seats[r];
      room.seats[r] = s && { conn: null, token: s.token, awayUntil: s.awayUntil };
    }
    return room;
  }

  _vacate(role) {
    const seat = this.seats[role];
    if (!seat) return;
    this.seats[role] = null;
    if (role === 'client') {
      this.lastAlone = this.now();
      const h = this.seats.host;
      if (h?.conn) ctl(h.conn, { type: 'peer_left' });
    } else {
      const c = this.seats.client;
      if (c?.conn) {
        ctl(c.conn, { type: 'peer_left' });
        c.conn.close(1000, 'host left');
      }
      this.seats.client = null;
    }
    this._changed();
    if (seat.conn) seat.conn.close(1000, 'left');
  }

  _roleOf(conn) {
    return ROLES.find(r => this.seats[r] && this.seats[r].conn === conn) ?? null;
  }

  _sameVersion(protocol, content) {
    return this.version && String(protocol) === this.version.protocol && String(content) === this.version.content;
  }

  _changed() { this.rev += 1; }

  _refuse(conn, reason) {
    ctl(conn, { type: 'error', reason });
    conn.close(1000, reason);
  }

  _kick(conn, reason) {
    ctl(conn, { type: 'error', reason });
    this.leave(conn, true);
    conn.close(1008, reason);
  }

  _withinRate(conn) {
    const m = conn.meta;
    const t = this.now();
    if (!m.windowStart || t - m.windowStart >= 1000) { m.windowStart = t; m.count = 0; }
    m.count += 1;
    return m.count <= MAX_RATE;
  }
}

import { Room, versionOf } from '../room.js';
import { randomCode, normalise } from '../codes.js';

// A connection whose messages queue up for next().
function queueClient() {
  const queue = [], waiters = [];
  let closed = false;
  const push = m => { const w = waiters.shift(); if (w) w(m); else queue.push(m); };
  return {
    push, markClosed() { if (!closed) { closed = true; push({ closed: true }); } },
    next(timeoutMs = 3000) {
      if (queue.length) return Promise.resolve(queue.shift());
      return new Promise((res, rej) => {
        const t = setTimeout(() => rej(new Error('timeout waiting for a message')), timeoutMs);
        waiters.push(m => { clearTimeout(t); res(m); });
      });
    },
  };
}

// The room core in memory, with a fake clock.
export function memoryTarget() {
  let clock = 1_000_000;
  const rooms = new Map();
  const target = {
    name: 'memory',
    advance(ms) { clock += ms; },
    tick() { for (const [code, r] of rooms) if (r.check()) rooms.delete(code); },
    async connect(path) {
      const url = new URL(path, 'http://x');
      const meta = versionOf(url.searchParams);
      const q = queueClient();
      const conn = {
        meta: {},
        send(d) { q.push(typeof d === 'string' ? { text: d } : { binary: new Uint8Array(d) }); },
        close() { q.markClosed(); },
      };
      let room;
      if (url.pathname === '/host') {
        let code;
        do { code = randomCode(); } while (rooms.has(code));
        room = new Room({ code, now: () => clock });
        rooms.set(code, room);
        room.addHost(conn, meta);
      } else if (url.pathname.startsWith('/rejoin/')) {
        const code = normalise(url.pathname.split('/')[2] || '');
        room = rooms.get(code) || new Room({ code, now: () => clock });  // unknown: it answers no_seat
        room.rejoin(conn, url.searchParams.get('token') || '', meta);
      } else {
        const code = normalise(url.pathname.split('/')[2] || '');
        room = rooms.get(code) || new Room({ code, now: () => clock });  // no host: it answers no_room
        room.addClient(conn, meta);
      }
      return {
        send(d) { room.message(conn, d); },
        next: q.next,
        close() { room.leave(conn); q.markClosed(); },          // a drop: the seat waits
        leave() { room.message(conn, '{"type":"leave"}'); q.markClosed(); },
      };
    },
  };
  return target;
}

// A real WebSocket server (Node relay or wrangler dev) at `base` (ws://host:port).
export function socketTarget(name, base) {
  return {
    name,
    async connect(path) {
      const { WebSocket } = await import('ws');
      const ws = new WebSocket(base + path);
      ws.binaryType = 'arraybuffer';
      const q = queueClient();
      ws.on('message', (data, isBinary) => q.push(isBinary ? { binary: new Uint8Array(data) } : { text: data.toString() }));
      ws.on('close', () => q.markClosed());
      ws.on('error', () => q.markClosed());
      await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
      return {
        send(d) { ws.send(d); },
        sendText(bytes) { ws.send(bytes, { binary: false }); },  // raw bytes in a text frame
        leave() { ws.send('{"type":"leave"}'); ws.close(); },
        next: q.next,
        close() { ws.close(); },
      };
    },
  };
}

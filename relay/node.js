// Standalone relay: `node node.js --port 8790 [--trust-proxy]`. Same rooms and protocol as the
// Cloudflare Worker (room.js); rooms live in memory, so a restart drops every game.
// A game adds HTTP routes of its own with plugins: startServer({ plugins: [{ http(req, res, ctx) }] }).
// Each non-WebSocket request goes to the plugins in order until one returns true (it answered);
// ctx is { ip }. Unanswered requests get 426.
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { Room, versionOf } from './room.js';
import { randomCode, normalise } from './codes.js';

// Limits: a refused connection gets an HTTP error at the WebSocket upgrade.
// maxRooms caps memory, hostsPerMin / joinsPerMin count per client IP over a sliding minute
// (joinsPerMin covers join and rejoin). trustProxy reads the client IP from X-Forwarded-For,
// only for a relay behind a proxy you control.
export async function startServer({ port = 8790, maxRooms = 2000, hostsPerMin = 30, joinsPerMin = 120,
                                    trustProxy = false, plugins = [] } = {}) {
  const rooms = new Map();
  const hits = new Map();  // `${kind}:${ip}` -> timestamps within the last minute
  const limited = (kind, ip, max) => {
    const key = `${kind}:${ip}`;
    const now = Date.now();
    const list = (hits.get(key) || []).filter(t => now - t < 60000);
    if (list.length >= max) { hits.set(key, list); return true; }
    list.push(now);
    hits.set(key, list);
    return false;
  };
  const refuse = (socket, status, text) => {
    socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  };
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1 << 20 });
  const clientIp = req => {
    const ip = req.socket.remoteAddress || '?';
    return trustProxy ? String(req.headers['x-forwarded-for'] || ip).split(',')[0].trim() : ip;
  };
  const server = http.createServer(async (req, res) => {
    try {
      for (const p of plugins) if (p.http && await p.http(req, res, { ip: clientIp(req) })) return;
    } catch (e) {
      console.error(e);
      if (!res.headersSent) res.writeHead(500);
      res.end();
      return;
    }
    res.writeHead(426);
    res.end('WebSocket only\n');
  });

  server.on('clientError', (err, socket) => socket.destroy());  // malformed HTTP: drop that socket only

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://relay');
    const parts = url.pathname.split('/').filter(Boolean);
    const isHost = parts.length === 1 && parts[0] === 'host';
    const isJoin = parts.length === 2 && parts[0] === 'join';
    const isRejoin = parts.length === 2 && parts[0] === 'rejoin';
    if (!isHost && !isJoin && !isRejoin) { socket.destroy(); return; }
    const ip = clientIp(req);
    if (isHost ? limited('host', ip, hostsPerMin) : limited('join', ip, joinsPerMin)) { refuse(socket, 429, 'Too Many Requests'); return; }
    if (isHost && rooms.size >= maxRooms) { refuse(socket, 503, 'Relay Busy'); return; }
    let hostCode = null;
    if (isHost) {  // bounded: a nearly full code space must not spin forever
      for (let i = 0; i < 16 && !hostCode; i++) { const c = randomCode(); if (!rooms.has(c)) hostCode = c; }
      if (!hostCode) { refuse(socket, 503, 'Relay Busy'); return; }
    }
    wss.handleUpgrade(req, socket, head, ws => {
      const conn = {
        meta: {},
        send(d) { if (ws.readyState === ws.OPEN) ws.send(d); },
        close(code, reason) { ws.close(code, reason); },
      };
      const version = versionOf(url.searchParams);
      let room;
      if (isHost) {
        const code = hostCode;
        room = new Room({ code, now: Date.now });
        rooms.set(code, room);
        room.addHost(conn, version);
      } else if (isRejoin) {
        const code = normalise(parts[1]);
        room = (code && rooms.get(code)) || new Room({ code, now: Date.now });  // unknown: no_seat
        room.rejoin(conn, url.searchParams.get('token') || '', version);
      } else {
        const code = normalise(parts[1]);
        room = (code && rooms.get(code)) || new Room({ code, now: Date.now });
        room.addClient(conn, version);
      }
      // A frame over maxPayload or invalid UTF-8 makes ws emit 'error' (then 'close', which leaves
      // the room). Without a listener that error would crash the whole relay.
      ws.on('error', () => {});
      ws.on('message', (data, isBinary) => room.message(conn, isBinary ? new Uint8Array(data) : data.toString()));
      ws.on('close', () => {
        room.leave(conn);  // a drop: the seat waits for its owner (an explicit leave already vacated it)
        if (room.isEmpty && rooms.get(room.code) === room) rooms.delete(room.code);
      });
    });
  });

  const sweep = setInterval(() => {
    const now = Date.now();
    for (const [k, l] of hits) if (!l.some(t => now - t < 60000)) hits.delete(k);
    for (const [code, r] of rooms) if (r.check()) rooms.delete(code);
  }, 1000);

  await new Promise(res => server.listen(port, res));
  return {
    port: server.address().port,
    close() {
      clearInterval(sweep);
      for (const c of wss.clients) c.terminate();
      return new Promise(res => server.close(res));
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const i = process.argv.indexOf('--port');
  const port = i > 0 ? Number(process.argv[i + 1]) : 8790;
  const trustProxy = process.argv.includes('--trust-proxy') || process.argv.includes('--trust-proxy-header')
    || process.env.RELAY_TRUST_PROXY === '1';
  const s = await startServer({ port, trustProxy });
  console.log(`relay listening on ${s.port}`);
}

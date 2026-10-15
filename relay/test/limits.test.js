import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { startServer } from '../node.js';

function attempt(port, path) {
  return new Promise(res => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}${path}?protocol=1&content=x`);
    ws.on('open', () => res({ open: true, ws }));
    ws.on('unexpected-response', (_req, r) => { r.resume(); res({ open: false, status: r.statusCode }); });
    ws.on('error', () => {});
  });
}

test('room creations are limited per IP', async () => {
  const s = await startServer({ port: 0, hostsPerMin: 2 });
  const a = await attempt(s.port, '/host');
  const b = await attempt(s.port, '/host');
  const c = await attempt(s.port, '/host');
  assert.ok(a.open && b.open);
  assert.equal(c.status, 429);
  a.ws.terminate(); b.ws.terminate();
  await s.close();
});

test('the room count is capped', async () => {
  const s = await startServer({ port: 0, maxRooms: 1 });
  const a = await attempt(s.port, '/host');
  const b = await attempt(s.port, '/host');
  assert.ok(a.open);
  assert.equal(b.status, 503);
  a.ws.terminate();
  await s.close();
});

test('plugins answer HTTP requests in order; the rest get 426', async () => {
  const seen = [];
  const s = await startServer({ port: 0, plugins: [
    { http(req, res, ctx) { seen.push(ctx.ip); if (req.url !== '/hello') return false; res.writeHead(200); res.end('hi'); return true; } },
  ] });
  const a = await fetch(`http://127.0.0.1:${s.port}/hello`);
  assert.equal(a.status, 200);
  assert.equal(await a.text(), 'hi');
  const b = await fetch(`http://127.0.0.1:${s.port}/other`);
  assert.equal(b.status, 426);
  await b.text();
  assert.equal(seen.length, 2);
  await s.close();
});

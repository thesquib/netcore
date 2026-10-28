import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../worker.js', import.meta.url), 'utf8')
  .replace("import { DurableObject } from 'cloudflare:workers';", 'class DurableObject {}')
  .replaceAll("'./room.js'", JSON.stringify(new URL('../room.js', import.meta.url).href))
  .replaceAll("'./codes.js'", JSON.stringify(new URL('../codes.js', import.meta.url).href));
const { makeWorker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

function routing(reply = () => ({ status: 101 })) {
  const worker = makeWorker();
  let forwarded = 0;
  const env = { ROOMS: {
    idFromName: code => code,
    get: () => ({ async fetch() { forwarded++; return reply(); } }),
  } };
  return {
    fetch(path, ip = 'one') {
      return worker.fetch(new Request(`https://relay${path}`, {
        headers: { Upgrade: 'websocket', 'CF-Connecting-IP': ip },
      }), env);
    },
    count: () => forwarded,
  };
}

test('Worker host and join admissions are bounded per IP for one minute', async t => {
  let now = 100000;
  t.mock.method(Date, 'now', () => now);
  const r = routing();
  for (let i = 0; i < 30; i++) assert.equal((await r.fetch('/host')).status, 101);
  assert.equal((await r.fetch('/host')).status, 429);
  for (let i = 0; i < 120; i++) {
    assert.equal((await r.fetch(i % 2 ? '/join/BQXK' : '/rejoin/BQXK')).status, 101);
  }
  assert.equal((await r.fetch('/rejoin/BQXK')).status, 429);
  assert.equal(r.count(), 150);
  assert.equal((await r.fetch('/host', 'two')).status, 101);
  now += 60000;
  assert.equal((await r.fetch('/host')).status, 101);
  assert.equal((await r.fetch('/join/BQXK')).status, 101);
});

test('Worker room reservations cap concurrent allocations and expire', async t => {
  let now = 100000;
  t.mock.method(Date, 'now', () => now);
  const r = routing();
  const results = await Promise.all(Array.from({ length: 2001 }, (_, i) => r.fetch('/host', String(i))));
  assert.equal(results.filter(r => r.status === 101).length, 2000);
  assert.equal(results.filter(r => r.status === 503).length, 1);
  assert.equal(r.count(), 2000);
  now += 3 * 60 * 60 * 1000 + 1;
  assert.equal((await r.fetch('/host')).status, 101);
});


test('Worker releases room reservations when allocation fails', async () => {
  let failing = true;
  const r = routing(() => ({ status: failing ? 409 : 101 }));
  for (let i = 0; i < 2001; i++) assert.equal((await r.fetch('/host', String(i))).status, 503);
  assert.equal(r.count(), 2001 * 8);
  failing = false;
  assert.equal((await r.fetch('/host', 'replacement')).status, 101);
});

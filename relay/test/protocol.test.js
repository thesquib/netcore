import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { memoryTarget, socketTarget } from './clients.js';
import { ALPHABET, normalise, randomCode } from '../codes.js';

const V = '?protocol=1&content=abc';

async function json(c) {
  const m = await c.next();
  assert.ok(m.text, `expected a text frame, got ${JSON.stringify(m)}`);
  return JSON.parse(m.text);
}

async function pair(t) {
  const host = await t.connect('/host' + V);
  const { code } = await json(host);
  const client = await t.connect(`/join/${code}` + V);
  assert.equal((await json(client)).type, 'paired');
  assert.equal((await json(host)).type, 'paired');
  return { host, client, code };
}

export function protocolSuite(makeTarget) {
  let t;
  before(async () => { t = await makeTarget(); });
  after(async () => { await t.stop?.(); });

  test('host gets a 4-letter code from the alphabet', async () => {
    const host = await t.connect('/host' + V);
    const m = await json(host);
    assert.equal(m.type, 'room');
    assert.match(m.code, new RegExp(`^[${ALPHABET}]{4}$`));
    host.close();
  });

  test('join pairs both sides and forwards binary frames both ways, byte-exact', async () => {
    const { host, client } = await pair(t);
    host.send(new Uint8Array([1, 2, 3, 250]));
    assert.deepEqual([...(await client.next()).binary], [1, 2, 3, 250]);
    client.send(new Uint8Array([9, 0, 7]));
    assert.deepEqual([...(await host.next()).binary], [9, 0, 7]);
    host.close(); client.close();
  });

  test('a lower-case code still joins', async () => {
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const client = await t.connect(`/join/${code.toLowerCase()}` + V);
    assert.equal((await json(client)).type, 'paired');
    host.close(); client.close();
  });

  test('wrong code: no_room', async () => {
    const client = await t.connect('/join/BBBB' + V);
    assert.deepEqual(await json(client), { type: 'error', reason: 'no_room' });
  });

  test('third player: full', async () => {
    const { host, client, code } = await pair(t);
    const third = await t.connect(`/join/${code}` + V);
    assert.deepEqual(await json(third), { type: 'error', reason: 'full' });
    host.close(); client.close();
  });

  test('different protocol or content: version', async () => {
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const a = await t.connect(`/join/${code}?protocol=2&content=abc`);
    assert.deepEqual(await json(a), { type: 'error', reason: 'version' });
    const b = await t.connect(`/join/${code}?protocol=1&content=xyz`);
    assert.deepEqual(await json(b), { type: 'error', reason: 'version' });
    host.close();
  });

  test('a game id pairs only the same game; no id is a game of its own', async () => {
    const host = await t.connect('/host' + V + '&game=one');
    const { code } = await json(host);
    const other = await t.connect(`/join/${code}` + V + '&game=two');
    assert.deepEqual(await json(other), { type: 'error', reason: 'no_room' });
    const none = await t.connect(`/join/${code}` + V);
    assert.deepEqual(await json(none), { type: 'error', reason: 'no_room' });
    const same = await t.connect(`/join/${code}` + V + '&game=one&relay=1');
    assert.equal((await json(same)).type, 'paired');
    assert.equal((await json(host)).type, 'paired');
    host.close(); same.close();
  });

  test('a rejoin with another game id: no_seat', async () => {
    const host = await t.connect('/host' + V + '&game=one');
    const { code, token } = await json(host);
    const wrong = await t.connect(`/rejoin/${code}?token=${token}&game=two&` + V.slice(1));
    assert.deepEqual(await json(wrong), { type: 'error', reason: 'no_seat' });
    host.close();
  });

  test('an unknown relay version: relay_version, for host, join and rejoin', async () => {
    const h = await t.connect('/host' + V + '&relay=99');
    assert.deepEqual(await json(h), { type: 'error', reason: 'relay_version' });
    const host = await t.connect('/host' + V);
    const { code, token } = await json(host);
    const j = await t.connect(`/join/${code}` + V + '&relay=99');
    assert.deepEqual(await json(j), { type: 'error', reason: 'relay_version' });
    const r = await t.connect(`/rejoin/${code}?token=${token}&relay=99&` + V.slice(1));
    assert.deepEqual(await json(r), { type: 'error', reason: 'relay_version' });
    host.close();
  });

  test('client leaves: host hears peer_left, and a new client can rejoin the same code', async () => {
    const { host, client, code } = await pair(t);
    client.leave();
    assert.deepEqual(await json(host), { type: 'peer_left' });
    const again = await t.connect(`/join/${code}` + V);
    assert.equal((await json(again)).type, 'paired');
    assert.equal((await json(host)).type, 'paired');
    host.close(); again.close();
  });

  test('host leaves: client hears peer_left and the room is gone', async () => {
    const { host, client, code } = await pair(t);
    host.leave();
    assert.deepEqual(await json(client), { type: 'peer_left' });
    const late = await t.connect(`/join/${code}` + V);
    assert.deepEqual(await json(late), { type: 'error', reason: 'no_room' });
  });

  test('binary sent before pairing is dropped', async () => {
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    host.send(new Uint8Array([5]));
    const client = await t.connect(`/join/${code}` + V);
    assert.equal((await json(client)).type, 'paired');
    host.send(new Uint8Array([6]));
    await json(host);  // paired
    assert.deepEqual([...(await client.next()).binary], [6]);
    host.close(); client.close();
  });

  test('a frame over 64 KB: limit', async () => {
    const { host, client } = await pair(t);
    host.send(new Uint8Array(65537));
    assert.deepEqual(await json(host), { type: 'error', reason: 'limit' });
    client.close();
  });

  test('more than 120 messages in a second: limit', async () => {
    const { host, client } = await pair(t);
    for (let i = 0; i < 130; i++) host.send(new Uint8Array([i & 255]));
    let m;
    do { m = await host.next(); } while (m.binary);
    assert.deepEqual(JSON.parse(m.text), { type: 'error', reason: 'limit' });
    client.close();
  });

  // A bad frame must cost only that socket: it gets `limit` or is closed, and the relay keeps going.
  async function endsWithout(c) {
    for (;;) {
      const m = await c.next(5000);
      if (m.closed || (m.text && JSON.parse(m.text).reason === 'limit')) return;
    }
  }

  test('a frame over 1 MiB costs only that socket', async (ctx) => {
    if (t.advance) return ctx.skip('needs a real socket');
    const { host, client } = await pair(t);
    host.send(new Uint8Array(1100 * 1024));
    await endsWithout(host);
    const after = await t.connect('/host' + V);
    assert.equal((await json(after)).type, 'room');
    after.close(); client.close();
  });

  test('invalid UTF-8 in a text frame costs only that socket', async (ctx) => {
    if (t.advance) return ctx.skip('needs a real socket');
    const host = await t.connect('/host' + V);
    await json(host);
    host.sendText(Buffer.from([0xff, 0xfe, 0xfd]));
    await new Promise(res => setTimeout(res, 300));  // closed (Node) or ignored (Worker): either is fine
    const after = await t.connect('/host' + V);
    assert.equal((await json(after)).type, 'room');
    after.close();
  });

  test('room and paired carry private rejoin tokens', async () => {
    const host = await t.connect('/host' + V);
    const room = await json(host);
    assert.match(room.token, /^[a-z2-7]{16}$/);
    const client = await t.connect(`/join/${room.code}` + V);
    const cp = await json(client);
    const hp = await json(host);
    assert.match(cp.token, /^[a-z2-7]{16}$/);
    assert.notEqual(cp.token, room.token);
    assert.equal(hp.token, undefined, "the host never sees the client's token");
    host.leave(); client.leave();
  });

  test('a dropped client is away, and rejoins its seat with the token', async () => {
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const client = await t.connect(`/join/${code}` + V);
    const { token } = await json(client);
    await json(host);  // paired
    client.close();    // a drop, not a leave
    assert.deepEqual(await json(host), { type: 'peer_away' });
    const back = await t.connect(`/rejoin/${code}?token=${token}&protocol=1&content=abc`);
    assert.deepEqual(await json(back), { type: 'resumed', paired: true, peer_up: true });
    assert.deepEqual(await json(host), { type: 'peer_back' });
    host.send(new Uint8Array([7]));
    assert.deepEqual([...(await back.next()).binary], [7]);
    host.leave(); back.leave();
  });

  test('rejoin replaces a still-open socket without an away', async () => {
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const client = await t.connect(`/join/${code}` + V);
    const { token } = await json(client);
    await json(host);
    const fresh = await t.connect(`/rejoin/${code}?token=${token}&protocol=1&content=abc`);
    assert.deepEqual(await json(fresh), { type: 'resumed', paired: true, peer_up: true });
    const old = await client.next();
    assert.ok(old.closed || JSON.parse(old.text).type === 'replaced', `the old socket is told or closed: ${JSON.stringify(old)}`);
    host.send(new Uint8Array([8]));
    assert.deepEqual([...(await host.next(300).catch(() => ({ none: true })))?.binary ?? []], [], 'no peer_away/peer_back to the host');
    assert.deepEqual([...(await fresh.next()).binary], [8]);
    host.leave(); fresh.leave();
  });

  test('the host rejoins its seat too', async () => {
    const host = await t.connect('/host' + V);
    const { code, token } = await json(host);
    const client = await t.connect(`/join/${code}` + V);
    await json(client); await json(host);
    host.close();
    assert.deepEqual(await json(client), { type: 'peer_away' });
    const back = await t.connect(`/rejoin/${code}?token=${token}&protocol=1&content=abc`);
    assert.deepEqual(await json(back), { type: 'resumed', paired: true, peer_up: true });
    assert.deepEqual(await json(client), { type: 'peer_back' });
    back.leave(); client.leave();
  });

  test('client joins while the host is away: the host gets paired when it resumes', async () => {
    const host = await t.connect('/host' + V);
    const { code, token } = await json(host);
    host.close();
    // No wait: the join may reach the relay before or after the host's close. Both must work.
    const client = await t.connect(`/join/${code}` + V);
    assert.equal((await json(client)).type, 'paired');
    const back = await t.connect(`/rejoin/${code}?token=${token}&protocol=1&content=abc`);
    assert.deepEqual(await json(back), { type: 'resumed', paired: true, peer_up: true }, 'the host learns it has a partner');
    back.leave(); client.leave();
  });

  test('a host back after its partner left hears paired:false', async () => {
    const host = await t.connect('/host' + V);
    const { code, token } = await json(host);
    const client = await t.connect(`/join/${code}` + V);
    await json(client); await json(host);
    host.close();
    await json(client);  // peer_away
    client.leave();
    const back = await t.connect(`/rejoin/${code}?token=${token}&protocol=1&content=abc`);
    assert.deepEqual(await json(back), { type: 'resumed', paired: false, peer_up: false });
    back.leave();
  });

  test('a wrong token or code: no_seat', async () => {
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const a = await t.connect(`/rejoin/${code}?token=aaaaaaaaaaaaaaaa&protocol=1&content=abc`);
    assert.deepEqual(await json(a), { type: 'error', reason: 'no_seat' });
    const b = await t.connect(`/rejoin/BBBB?token=aaaaaaaaaaaaaaaa&protocol=1&content=abc`);
    assert.deepEqual(await json(b), { type: 'error', reason: 'no_seat' });
    host.leave();
  });

  test('an away client seat ends after the grace time; the room stays for a new client', async (ctx) => {
    if (!t.advance) return ctx.skip('needs a fake clock');
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const client = await t.connect(`/join/${code}` + V);
    await json(client); await json(host);
    client.close();
    assert.deepEqual(await json(host), { type: 'peer_away' });
    t.advance(120 * 1000 + 1); t.tick();
    assert.deepEqual(await json(host), { type: 'peer_left' });
    const next = await t.connect(`/join/${code}` + V);
    assert.equal((await json(next)).type, 'paired');
    host.leave(); next.leave();
  });

  test('an away host seat ends the room after the grace time', async (ctx) => {
    if (!t.advance) return ctx.skip('needs a fake clock');
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const client = await t.connect(`/join/${code}` + V);
    await json(client); await json(host);
    host.close();
    assert.deepEqual(await json(client), { type: 'peer_away' });
    t.advance(120 * 1000 + 1); t.tick();
    assert.deepEqual(await json(client), { type: 'peer_left' });
    assert.deepEqual(await client.next(), { closed: true });
  });

  test('binary frames to an away seat are dropped', async () => {
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    const client = await t.connect(`/join/${code}` + V);
    const { token } = await json(client);
    await json(host);
    client.close();
    await json(host);  // peer_away
    host.send(new Uint8Array([1]));
    const back = await t.connect(`/rejoin/${code}?token=${token}&protocol=1&content=abc`);
    assert.deepEqual(await json(back), { type: 'resumed', paired: true, peer_up: true });
    host.send(new Uint8Array([2]));
    assert.deepEqual([...(await back.next()).binary], [2], 'only frames sent after the rejoin');
    host.leave(); back.leave();
  });

  test('an unjoined room expires after 10 minutes', async (ctx) => {
    if (!t.advance) return ctx.skip('needs a fake clock');
    const host = await t.connect('/host' + V);
    const { code } = await json(host);
    t.advance(10 * 60 * 1000 + 1); t.tick();
    assert.deepEqual(await host.next(), { closed: true });
    const late = await t.connect(`/join/${code}` + V);
    assert.deepEqual(await json(late), { type: 'error', reason: 'no_room' });
  });

  test('any room ends after 3 hours', async (ctx) => {
    if (!t.advance) return ctx.skip('needs a fake clock');
    const { host, client } = await pair(t);
    t.advance(3 * 60 * 60 * 1000 + 1); t.tick();
    assert.deepEqual(await host.next(), { closed: true });
    assert.deepEqual(await json(client), { type: 'peer_left' });  // the room is over for the client too
    assert.deepEqual(await client.next(), { closed: true });
  });
}

describe('codes', () => {
  test('normalise accepts any case and spaces, rejects vowels and wrong lengths', () => {
    assert.equal(normalise(' bq xk '), 'BQXK');
    assert.equal(normalise('BQXA'), null);
    assert.equal(normalise('BQX'), null);
    assert.equal(normalise('BQXKK'), null);
    assert.equal(ALPHABET.length, 20);
    assert.ok(normalise(randomCode()));
  });
});

describe('memory', () => protocolSuite(memoryTarget));

describe('room state after a wake', () => {
  test('a seat whose socket did not come back is marked away, and the other side hears it', async () => {
    const { Room } = await import('../room.js');
    let clock = 1000;
    const before = new Room({ code: 'BQXK', now: () => clock });
    const sent = { host: [], client: [] };
    const conn = r => ({ meta: {}, send: d => sent[r].push(d), close() {} });
    before.addHost(conn('host'), { protocol: 1, content: 'abc' });
    before.addClient(conn('client'), { protocol: 1, content: 'abc' });
    const saved = JSON.parse(JSON.stringify(before.toJSON()));
    const room = Room.fromJSON(saved, () => clock);
    const rev = room.rev;
    sent.host.length = 0;
    room.attach('host', conn('host'), saved.seats.host.token);  // only the host's socket survived
    room.settleAfterWake();
    assert.equal(room.seats.client.awayUntil, clock + 120 * 1000, 'client seat away');
    assert.deepEqual(sent.host.map(d => JSON.parse(d)), [{ type: 'peer_away' }], 'host told');
    assert.ok(room.rev > rev, 'changed, so the Durable Object saves it and sets an alarm');
    assert.equal(room.nextDeadline(), clock + 120 * 1000 + 1);
  });

  test('a room saved before game ids wakes as game "" and still takes its rejoins', async () => {
    const { Room } = await import('../room.js');
    const sent = [];
    const conn = { meta: {}, send: d => sent.push(JSON.parse(d)), close() {} };
    const room = Room.fromJSON({ code: 'BQXK', version: { protocol: '1', content: 'abc' }, created: 0, lastAlone: 0,
      seats: { host: { token: 'tok', awayUntil: 5 }, client: null } }, () => 1);
    room.rejoin(conn, 'tok', { protocol: '1', content: 'abc' });
    assert.equal(sent[0].type, 'resumed');
  });
});

const RELAY_DIR = fileURLToPath(new URL('..', import.meta.url));

// The Node relay as its own process, as it really runs: if a frame crashes it, later tests fail.
describe('node', () => protocolSuite(async () => {
  const proc = spawn(process.execPath, ['node.js', '--port', '0'], { cwd: RELAY_DIR, stdio: ['ignore', 'pipe', 'inherit'] });
  const port = await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('node relay did not start')), 10000);
    proc.stdout.on('data', d => { const m = /relay listening on (\d+)/.exec(d.toString()); if (m) { clearTimeout(t); res(m[1]); } });
  });
  const t = socketTarget('node', `ws://127.0.0.1:${port}`);
  t.stop = () => { proc.kill(); };
  return t;
}));

describe('worker', () => protocolSuite(async () => {
  const port = 8791;
  // The tracked example config (the real wrangler.toml is local deployment config), with an
  // absolute entry point since it is written to a temporary folder.
  const dir = mkdtempSync(join(tmpdir(), 'relay-test-'));
  const config = join(dir, 'wrangler.toml');
  const example = readFileSync(join(RELAY_DIR, 'wrangler.toml.example'), 'utf8');
  writeFileSync(config, example.replace(/^main = .*$/m, `main = ${JSON.stringify(join(RELAY_DIR, 'worker.js'))}`));
  const wrangler = join(RELAY_DIR, 'node_modules', 'wrangler', 'bin', 'wrangler.js');
  const proc = spawn(process.execPath, [wrangler, 'dev', '--config', config, '--port', String(port), '--ip', '127.0.0.1', '--show-interactive-dev-session=false'],
    { cwd: RELAY_DIR, stdio: ['ignore', 'pipe', 'pipe'] });
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('wrangler dev did not start')), 60000);
    const onData = d => { if (/Ready on/.test(d.toString())) { clearTimeout(t); res(); } };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);
  });
  const t = socketTarget('worker', `ws://127.0.0.1:${port}`);
  t.stop = async () => {
    const exited = proc.exitCode !== null ? Promise.resolve() : new Promise(r => proc.once('exit', r));
    proc.kill('SIGINT');
    await Promise.race([exited, new Promise(r => setTimeout(r, 5000))]);
    // Windows can hold the folder briefly after the process ends; a leftover temp folder is harmless.
    try { rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 }); } catch {}
  };
  return t;
}));

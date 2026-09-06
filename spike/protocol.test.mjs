import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { append, validate, reconcile, recover, classify } from './model.mjs';
import { readStore, saveStore } from './store.mjs';

const peerFile = fileURLToPath(new URL('./peer.mjs', import.meta.url));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const open = (log, round) => append(log, { kind: 'open', round });
const close = (log, round, winner = 0) => append(log, { kind: 'close', round, winner, reason: 'combat' });
const ticket = (round = 1, offender = 0) => ({ round, offender, deadline: 60000 });

async function start(role, file) {
  const child = fork(peerFile, [role, file], { stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
  const pending = new Map(), errors = [];
  let seq = 0, stderr = '';
  child.stderr.on('data', bytes => stderr += bytes);
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('peer startup timeout: ' + stderr)), 5000);
    child.on('message', msg => {
      if (msg.type === 'ready') { clearTimeout(timer); resolve(msg); }
      if (msg.type === 'protocolError' || msg.type === 'fatal') errors.push(msg);
      if (msg.id && pending.has(msg.id)) {
        const p = pending.get(msg.id); pending.delete(msg.id); clearTimeout(p.timer); p.resolve(msg);
      }
    });
    child.once('exit', code => {
      clearTimeout(timer); reject(Error(`peer exited ${code}: ${stderr}`));
      for (const p of pending.values()) { clearTimeout(p.timer); p.resolve({ ok: false, error: 'process exited' }); }
      pending.clear();
    });
  });
  const info = await ready;
  return { child, file, errors, ...info,
    cmd(command, args = {}) {
      return new Promise((resolve, reject) => {
        const id = ++seq;
        const timer = setTimeout(() => { pending.delete(id); reject(Error('command timeout ' + command)); }, 5000);
        pending.set(id, { resolve, timer });
        child.send({ id, command, ...args });
      });
    },
    async stop() {
      if (child.exitCode !== null || child.signalCode !== null) return;
      await new Promise(resolve => { child.once('exit', resolve); child.kill('SIGKILL'); });
    }
  };
}

async function pair(t, initial = open([], 1)) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fps-spike-'));
  const peers = [];
  t.after(async () => {
    for (const peer of peers) await peer.stop();
    // 作成した一時フォルダだけをNode内で削除。別shellへパスを渡さない。
    assert.equal(path.dirname(directory), os.tmpdir());
    assert.ok(path.basename(directory).startsWith('fps-spike-'));
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const launch = async role => {
    const peer = await start(role, path.join(directory, role + '.json'));
    peers.push(peer); return peer;
  };
  for (const role of ['host', 'guest']) saveStore(path.join(directory, role + '.json'), initial);
  let host = await launch('host'), guest = await launch('guest');
  async function connect(h = host, g = guest) {
    await h.cmd('connect', { port: g.port });
    await g.cmd('connect', { port: h.port });
  }
  await connect();
  await converge(host, guest);
  return { host, guest, launch, connect };
}

async function converge(host, guest, predicate = () => true) {
  const until = Date.now() + 6000;
  while (Date.now() < until) {
    const [h, g] = await Promise.all([host.cmd('status'), guest.cmd('status')]);
    if (h.tip === g.tip && h.ack === h.tip && g.ack === g.tip && predicate(h)) return [h, g];
    await delay(25);
  }
  throw Error('convergence timeout');
}

test('履歴照合: 長い共通履歴へ進み、古い記録で巻き戻らない', () => {
  const a = open([], 1), b = close(a, 1);
  assert.deepEqual(reconcile(a, b), b);
  assert.deepEqual(reconcile(b, a), b);
});

test('同世代/異世代の分岐、改ざん、異なる試合を拒否', () => {
  const a = open([], 1), b = close(a, 1, 0), c = close(a, 1, 1);
  assert.throws(() => reconcile(b, c), /fork/);
  assert.throws(() => reconcile(open(b, 2), c), /fork/);
  const corrupt = structuredClone(b); corrupt[1].event.winner = 1;
  assert.throws(() => validate(corrupt), /invalid record/);
  const foreign = structuredClone(b); foreign[0].match = 'another-match';
  assert.throws(() => validate(foreign), /invalid record/);
  assert.throws(() => open(a, 9), /invalid open/);
});

test('復帰ペナルティは一回だけ、通常決着後・次ラウンドへの古い要求も無効', () => {
  const a = open([], 1), b = recover(a, ticket(), 59999);
  assert.deepEqual(validate(b).score, [0, 1]);
  assert.deepEqual(recover(b, ticket(), 59999), b);
  assert.deepEqual(recover(b, ticket(), 90000), b);
  const c = close(a, 1);
  const received = recover(c, ticket(), 59999);
  assert.deepEqual(validate(received).score, [1, 0]);
  assert.deepEqual(recover(received, ticket(), 90000), received);
  const d = open(c, 2);
  assert.deepEqual(recover(d, ticket(), 60001), d);
});

test('60秒境界は期限切れ、期限は再試行で延長しない', () => {
  const a = open([], 1);
  assert.equal(validate(recover(a, ticket(), 59999)).phase, 'between');
  for (const now of [60000, 60001, 90000]) {
    const s = validate(recover(a, ticket(), now));
    assert.equal(s.phase, 'finished'); assert.equal(s.winner, 1);
    assert.deepEqual(s.score, [0, 0]);
  }
});

test('切断復帰の得点で10勝に到達したら終了', () => {
  let log = [];
  for (let n = 1; n <= 9; n++) log = close(open(log, n), n, 1);
  log = recover(open(log, 10), ticket(10), 10);
  assert.deepEqual(validate(log), { round: 10, score: [0, 10], phase: 'finished', winner: 1 });
  assert.throws(() => open(log, 11), /finished/);
});

test('引き分けは得点なしでラウンド進行', () => {
  const log = open(close(open([], 1), 1, null), 2);
  assert.equal(validate(log).round, 2); assert.deepEqual(validate(log).score, [0, 0]);
});

test('通信断だけの責任判定と両者再起動は保留', () => {
  assert.equal(classify({}), 'ambiguous');
  assert.equal(classify({ hostRestarted: true }), 0);
  assert.equal(classify({ guestRestarted: true }), 1);
  assert.equal(classify({ hostRestarted: true, guestRestarted: true }), 'ambiguous');
});

test('実UDP: 損失・重複・遅延による並べ替えから収束', async t => {
  const { host, guest } = await pair(t);
  for (const p of [host, guest]) await p.cmd('chaos', { chaos: { dropEvery: 3, duplicate: true, delayEvery: 2 } });
  assert.equal((await host.cmd('event', { event: { kind: 'close', round: 1, winner: 0, reason: 'combat' } })).ok, true);
  const [h, g] = await converge(host, guest, s => s.state.score[0] === 1);
  assert.deepEqual(readStore(host.file), readStore(guest.file));
  assert.ok(h.dropped + g.dropped > 0);
  assert.deepEqual(host.errors.concat(guest.errors), []);
  t.diagnostic(JSON.stringify({ host: { tx: h.tx, rx: h.rx, dropped: h.dropped }, guest: { tx: g.tx, rx: g.rx, dropped: g.dropped } }));
});

test('実UDP: ACK消失中は次ラウンド開始を拒否、再接続後に進行', async t => {
  const { host, guest } = await pair(t);
  await guest.cmd('chaos', { chaos: { blackhole: true } });
  await delay(150);
  await host.cmd('event', { event: { kind: 'close', round: 1, winner: 0, reason: 'combat' } });
  await delay(150);
  const response = await host.cmd('event', { event: { kind: 'open', round: 2 } });
  assert.equal(response.ok, false); assert.match(response.error, /ACK/);
  await guest.cmd('chaos', { chaos: { blackhole: false } });
  await converge(host, guest);
  assert.equal((await host.cmd('event', { event: { kind: 'open', round: 2 } })).ok, true);
  await converge(host, guest, s => s.state.round === 2);
});

test('実プロセス: ホスト強制終了→再起動→復帰敗北を一回だけ保存', async t => {
  const { host, guest, launch, connect } = await pair(t);
  await host.stop();
  const replacement = await launch('host');
  assert.notEqual(replacement.boot, host.boot);
  await connect(replacement, guest); await converge(replacement, guest);
  assert.equal((await replacement.cmd('recover', { ticket: ticket(), now: 1000 })).ok, true);
  await converge(replacement, guest, s => s.state.score[1] === 1);
  await replacement.cmd('recover', { ticket: ticket(), now: 2000 });
  const [h] = await converge(replacement, guest);
  assert.deepEqual(h.state.score, [0, 1]);
});

test('実プロセス: ゲスト強制終了→再接続でゲストの敗北', async t => {
  const { host, guest, launch, connect } = await pair(t);
  await guest.stop();
  const replacement = await launch('guest');
  await connect(host, replacement); await converge(host, replacement);
  await host.cmd('recover', { ticket: ticket(1, 1), now: 2000 });
  const [h] = await converge(host, replacement, s => s.state.score[0] === 1);
  assert.deepEqual(h.state.score, [1, 0]);
});

for (const fault of ['partial', 'beforeRename', 'afterRename']) {
  test(`実ファイル: 保存${fault}でプロセス終了し、旧/新の完全な状態へ復元`, async t => {
    const { host, guest, launch, connect } = await pair(t);
    await host.cmd('fault', { fault });
    const exit = new Promise(resolve => host.child.once('exit', resolve));
    await host.cmd('event', { event: { kind: 'close', round: 1, winner: 0, reason: 'combat' } });
    await exit;
    assert.equal(validate(readStore(host.file)).phase, fault === 'afterRename' ? 'between' : 'open');
    const replacement = await launch('host');
    await connect(replacement, guest); await converge(replacement, guest);
    await replacement.cmd('recover', { ticket: ticket(), now: 3000 });
    const [h] = await converge(replacement, guest, s => s.state.phase === 'between');
    assert.deepEqual(h.state.score, fault === 'afterRename' ? [1, 0] : [0, 1]);
  });
}

test('実UDP: ゲストだけが新しい完全履歴を持つ場合にホストを修復', async t => {
  const { host, guest, launch, connect } = await pair(t);
  const old = readStore(host.file);
  await host.cmd('event', { event: { kind: 'close', round: 1, winner: 0, reason: 'combat' } });
  await converge(host, guest, s => s.state.score[0] === 1);
  await host.stop(); saveStore(host.file, old); // 明示的なディスク巻き戻り障害を注入
  const replacement = await launch('host');
  await connect(replacement, guest);
  const [h] = await converge(replacement, guest, s => s.state.score[0] === 1);
  assert.deepEqual(h.state.score, [1, 0]);
  assert.deepEqual(readStore(replacement.file), readStore(guest.file));
});

test('実ファイル: 本体破損は拒否し、一時ファイルを勝手に確定扱いしない', async t => {
  const { host } = await pair(t);
  await host.stop();
  fs.writeFileSync(host.file, '{broken');
  assert.throws(() => readStore(host.file));
  fs.unlinkSync(host.file);
  fs.writeFileSync(host.file + '.tmp', JSON.stringify({ schema: 1, log: open([], 1) }));
  assert.throws(() => readStore(host.file), /orphan/);
});

test('実UDP: 分岐履歴を受け取ると得点操作を停止する', async t => {
  const { host, guest, launch, connect } = await pair(t);
  await host.stop(); await guest.stop();
  saveStore(host.file, close(open([], 1), 1, 0));
  saveStore(guest.file, close(open([], 1), 1, 1));
  const h = await launch('host'), g = await launch('guest');
  await connect(h, g);
  const until = Date.now() + 5000;
  while (!(await h.cmd('status')).blocked && Date.now() < until) await delay(25);
  assert.equal((await h.cmd('status')).blocked, true);
  assert.equal((await h.cmd('event', { event: { kind: 'open', round: 2 } })).error, 'protocol blocked');
  assert.deepEqual(validate(readStore(h.file)).score, [1, 0]);
  assert.deepEqual(validate(readStore(g.file)).score, [0, 1]);
});

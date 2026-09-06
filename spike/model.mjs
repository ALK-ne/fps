import { createHash } from 'node:crypto';

export const MATCH = 'spike-match-001';
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const initial = () => ({ round: 0, score: [0, 0], phase: 'between', winner: null });

function transition(state, event) {
  const s = structuredClone(state);
  if (s.phase === 'finished') throw Error('match finished');
  if (event.kind === 'open') {
    if (s.phase !== 'between' || event.round !== s.round + 1) throw Error('invalid open');
    s.round = event.round;
    s.phase = 'open';
  } else if (event.kind === 'close') {
    if (s.phase !== 'open' || event.round !== s.round) throw Error('invalid close');
    if (![null, 0, 1].includes(event.winner)) throw Error('invalid winner');
    if (!['combat', 'timeout', 'disconnect'].includes(event.reason)) throw Error('invalid reason');
    if (event.winner !== null) s.score[event.winner]++;
    s.phase = s.score.some(n => n >= 10) ? 'finished' : 'between';
    if (s.phase === 'finished') s.winner = event.winner;
  } else if (event.kind === 'recovered') {
    if (s.phase !== 'between' || event.round !== s.round || !event.recoveryId) throw Error('invalid recovery receipt');
  } else if (event.kind === 'forfeit') {
    if (event.round !== s.round || ![0, 1].includes(event.winner)) throw Error('invalid forfeit');
    s.phase = 'finished';
    s.winner = event.winner; // 試合敗北は架空のラウンド得点を作らない
  } else throw Error('invalid event');
  return s;
}

export function validate(log) {
  if (!Array.isArray(log) || log.length > 10000) throw Error('invalid history');
  let state = initial(), prev = 'genesis';
  for (let i = 0; i < log.length; i++) {
    const record = log[i];
    const body = { match: MATCH, rules: 1, seq: i + 1, prev, event: record.event };
    if (record.match !== MATCH || record.rules !== 1 || record.seq !== i + 1 ||
        record.prev !== prev || record.hash !== hash(body)) throw Error('invalid record');
    state = transition(state, record.event);
    prev = record.hash;
  }
  return state;
}

export function append(log, event) {
  transition(validate(log), event);
  const body = { match: MATCH, rules: 1, seq: log.length + 1,
    prev: log.at(-1)?.hash ?? 'genesis', event };
  return [...log, { ...body, hash: hash(body) }];
}

export function reconcile(local, remote) {
  validate(local); validate(remote);
  const common = Math.min(local.length, remote.length);
  for (let i = 0; i < common; i++) {
    if (local[i].hash !== remote[i].hash) throw Error('history fork: manual resolution required');
  }
  return remote.length > local.length ? remote : local;
}

export function recover(log, { round, offender, deadline }, now) {
  if (![0, 1].includes(offender) || !Number.isFinite(deadline)) throw Error('invalid recovery');
  const s = validate(log);
  const recoveryId = `disconnect:${round}`;
  if (log.some(record => record.event.recoveryId === recoveryId)) return log;
  if (s.phase === 'finished' || round !== s.round) return log;
  // 期限切れは試合敗北。新しい60秒を再接続のたびに発行しない。
  if (now >= deadline) return append(log, { kind: 'forfeit', round, winner: 1 - offender, recoveryId });
  // 決着済みラウンドへの切断敗北は重ねない。
  if (s.phase !== 'open') return append(log, { kind: 'recovered', round, recoveryId });
  return append(log, { kind: 'close', round, winner: 1 - offender, reason: 'disconnect', recoveryId });
}

export function classify({ hostRestarted, guestRestarted, guestGracefulLeave = false }) {
  if (hostRestarted && guestRestarted) return 'ambiguous';
  if (hostRestarted) return 0;
  if (guestRestarted || guestGracefulLeave) return 1;
  return 'ambiguous'; // heartbeatの不達だけでは責任は証明できない
}

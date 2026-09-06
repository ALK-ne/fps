import dgram from 'node:dgram';
import { randomUUID } from 'node:crypto';
import { append, reconcile, recover, validate } from './model.mjs';
import { readStore, saveStore } from './store.mjs';

const [role, file] = process.argv.slice(2);
let log = readStore(file), remotePort = null, ack = null;
let tx = 0, rx = 0, dropped = 0, retransmits = 0;
let fault = null;
let blocked = false;
let chaos = { dropEvery: 0, duplicate: false, delayEvery: 0, blackhole: false };
const boot = randomUUID();
const socket = dgram.createSocket('udp4');
const timers = new Set();
const sendIPC = msg => process.connected && process.send(msg);
const tip = () => log.at(-1)?.hash ?? 'genesis';

function send(message) {
  if (!remotePort) return;
  const data = Buffer.from(JSON.stringify({ ...message, boot }));
  if (data.length > 60000) throw Error('spike history exceeds UDP budget');
  tx++;
  if (chaos.blackhole || (chaos.dropEvery && tx % chaos.dropEvery === 0)) { dropped++; return; }
  const deliver = () => {
    socket.send(data, remotePort, '127.0.0.1');
    if (chaos.duplicate) socket.send(data, remotePort, '127.0.0.1');
  };
  if (chaos.delayEvery && tx % chaos.delayEvery === 0) {
    const timer = setTimeout(() => { timers.delete(timer); deliver(); }, 100);
    timers.add(timer);
  } else deliver();
}

function persist(next) {
  saveStore(file, next, fault);
  fault = null;
  log = next;
}

socket.on('message', (bytes, from) => {
  if (from.address !== '127.0.0.1' || from.port !== remotePort || bytes.length > 60000) return;
  rx++;
  try {
    const packet = JSON.parse(bytes);
    if (packet.type === 'sync') {
      const next = reconcile(log, packet.log);
      if (next !== log) persist(next);
      send({ type: 'ack', tip: tip() }); // durable保存後のACK
      if (packet.log.at(-1)?.hash !== tip()) send({ type: 'sync', log });
    } else if (packet.type === 'ack') {
      if (packet.tip === tip()) ack = packet.tip;
    }
  } catch (error) { blocked = true; sendIPC({ type: 'protocolError', message: error.message }); }
});
socket.on('error', error => sendIPC({ type: 'fatal', message: error.message }));
socket.bind(0, '127.0.0.1', () => sendIPC({ type: 'ready', port: socket.address().port, boot }));
const retry = setInterval(() => { retransmits++; send({ type: 'sync', log }); }, 40);

process.on('message', ({ id, command, ...args }) => {
  try {
    if (command === 'connect') { remotePort = args.port; ack = null; }
    else if (command === 'chaos') chaos = { ...chaos, ...args.chaos };
    else if (command === 'fault') fault = args.fault;
    else if (command === 'event') {
      if (blocked) throw Error('protocol blocked');
      if (role !== 'host') throw Error('host only');
      if (args.event.kind === 'open' && ack !== tip()) throw Error('peer durable ACK required');
      persist(append(log, args.event));
      ack = null;
      send({ type: 'sync', log });
    } else if (command === 'recover') {
      if (blocked) throw Error('protocol blocked');
      if (role !== 'host') throw Error('host only');
      if (ack !== tip()) throw Error('reconcile before recovery');
      const next = recover(log, args.ticket, args.now);
      if (next !== log) { persist(next); ack = null; }
      send({ type: 'sync', log });
    } else if (command !== 'status') throw Error('unknown command');
    sendIPC({ id, ok: true, log, state: validate(log), ack, tip: tip(), blocked, tx, rx, dropped, retransmits });
  } catch (error) { sendIPC({ id, ok: false, error: error.message }); }
});
process.on('disconnect', () => {
  clearInterval(retry);
  for (const timer of timers) clearTimeout(timer);
  socket.close();
});

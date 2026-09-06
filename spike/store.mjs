import fs from 'node:fs';
import path from 'node:path';
import { validate } from './model.mjs';

export function readStore(file) {
  if (!fs.existsSync(file)) {
    if (fs.existsSync(file + '.tmp')) throw Error('no committed store; orphan temp requires reconciliation');
    return [];
  }
  const envelope = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (envelope.schema !== 1) throw Error('unsupported schema');
  validate(envelope.log);
  return envelope.log;
}

export function saveStore(file, log, fault = null) {
  validate(log);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const bytes = Buffer.from(JSON.stringify({ schema: 1, log }));
  const fd = fs.openSync(file + '.tmp', 'w');
  fs.writeFileSync(fd, fault === 'partial' ? bytes.subarray(0, bytes.length >> 1) : bytes);
  fs.fsyncSync(fd);
  fs.closeSync(fd);
  if (fault === 'partial' || fault === 'beforeRename') process.exit(91);
  fs.renameSync(file + '.tmp', file);
  if (fault === 'afterRename') process.exit(92);
  // process crashに対する試験。電源断時のdirectory flush保証ではない。
}

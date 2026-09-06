import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const folder = path.join(root, 'docs/implementation');
const spec = JSON.parse(fs.readFileSync(path.join(folder, 'spec.json'), 'utf8'));
const arena = JSON.parse(fs.readFileSync(path.join(folder, 'arena.json'), 'utf8'));
const checks = [];
function check(name, fn) { fn(); checks.push(name); }

check('approved rule constants', () => {
  assert.deepEqual(spec.match, { wins: 10, fightMs: 90000, selectionMs: 10000, countdownMs: 3000, recoveryMs: 60000, hp: 100, armorBands: [[1, 50], [4, 75], [8, 100], [12, 125]] });
  assert.deepEqual(spec.weapons.map(w => [w.magazine, w.ammoBox, w.reserveCap]), [[24, 24, 120], [6, 6, 30], [12, 12, 60]]);
  assert.deepEqual(spec.heals.map(h => [h.useMs, h.cap]), [[3750, 4], [6250, 2], [3000, 4], [5000, 2]]);
  assert.equal(spec.heals.reduce((n, h) => n + h.cap, 0), 12);
  assert.equal(spec.grenades.totalCap, 2);
  assert.equal(spec.grenades.selfDamageMultiplier, 0.5);
  assert.equal(spec.combat.swapHoldMs, 1000);
});

check('engine assets and timing', () => {
  for (const key of ['editorSha256', 'templateSha256']) assert.match(spec.engine[key], /^[0-9a-f]{64}$/);
  assert.equal(spec.simulation.hz, 60);
  assert.equal(spec.simulation.hz % spec.simulation.snapshotHz, 0);
  const tickMs = 1000 / spec.simulation.hz;
  for (const ms of [...spec.heals.map(h => h.useMs), spec.match.selectionMs, spec.match.fightMs, spec.match.countdownMs]) {
    assert.ok(Math.abs(ms / tickMs - Math.round(ms / tickMs)) < 1e-8);
  }
  const rifle = spec.weapons[0];
  assert.equal(Math.ceil((100 + 50) / rifle.damage), 10);
  assert.ok(Math.abs(9 * rifle.intervalUs / 1e6 - 0.99) < 1e-8);
  assert.ok(spec.network.maxHistoryChunkBytes <= spec.network.maxMessageBytes);
  assert.equal(spec.network.maxPacketBytes, 48 + 1120 + 32);
});

check('work dependencies and 38 acceptance cases', () => {
  const text = fs.readFileSync(path.join(folder, '07-acceptance.md'), 'utf8');
  const cases = [...text.matchAll(/^\| (A\d{2}) \|/gm)].map(m => m[1]);
  assert.equal(new Set(cases).size, 38);
  assert.equal(cases.length, 38);
  const done = new Set();
  const coverage = [];
  for (const task of spec.tasks) {
    assert.ok(!done.has(task.id), `duplicate ${task.id}`);
    for (const dependency of task.depends) assert.ok(done.has(dependency), `${task.id} before ${dependency}`);
    done.add(task.id);
    for (const id of task.acceptance) { assert.ok(cases.includes(id), `unknown ${id}`); coverage.push(id); }
  }
  assert.equal(done.size, 12);
  assert.deepEqual([...new Set(coverage)].sort(), cases.sort());
});

function listMarkdown(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? listMarkdown(full) : entry.name.endsWith('.md') ? [full] : [];
  });
}
check('all local Markdown links', () => {
  const files = [path.join(root, 'README.md'), ...listMarkdown(path.join(root, 'docs')), ...listMarkdown(path.join(root, 'spike'))];
  for (const file of files) {
    for (const m of fs.readFileSync(file, 'utf8').matchAll(/\]\(([^)]+)\)/g)) {
      const href = m[1];
      if (/^(?:https?:|#)/.test(href)) continue;
      assert.ok(fs.existsSync(path.resolve(path.dirname(file), href.split('#')[0])), `${path.relative(root, file)}: missing ${href}`);
    }
  }
});

const spawns = [-1, 1].flatMap(sign => arena.spawnZ.map(z => [sign * arena.spawnAbsX, 0.05, z]));
const boxes = arena.obstacles.map(o => ({ ...o }));
for (const sign of [-1, 1]) for (const z of arena.spawnZ) {
  boxes.push({ id: `front:${sign}:${z}`, position: [sign * arena.pockets.frontAbsX, 1.5, z], size: arena.pockets.frontSize });
  for (const dz of [-1, 1]) boxes.push({ id: `side:${sign}:${z}:${dz}`, position: [sign * arena.pockets.sideAbsX, 1.5, z + dz * arena.pockets.sideOffsetZ], size: arena.pockets.sideSize });
}
const overlapsXZ = (x, z, box, inflate = 0) =>
  Math.abs(x - box.position[0]) <= box.size[0] / 2 + inflate && Math.abs(z - box.position[2]) <= box.size[2] / 2 + inflate;

check('map symmetry and item anchors', () => {
  assert.equal(spawns.length, 6);
  for (const b of boxes) assert.ok(boxes.some(other => other.position[0] === -b.position[0] && other.position[1] === b.position[1] && other.position[2] === b.position[2] && JSON.stringify(other.size) === JSON.stringify(b.size)), `asymmetric ${b.id}`);
  const slots = [...spawns.map(([x, y, z]) => [x + Math.sign(x) * arena.weaponSlots.spawnOffsetX, 0, z]), ...arena.weaponSlots.extra];
  const ammo = slots.map(([x, y, z]) => [x, y, z + arena.weaponSlots.ammoOffsetZ]);
  for (const [x, y, z] of [...slots, ...ammo, ...arena.healSlots, ...arena.grenadeSlots]) {
    assert.ok(Math.abs(x) < arena.halfWidth && Math.abs(z) < arena.halfDepth);
    assert.ok(!boxes.some(b => overlapsXZ(x, z, b, 0.3)), `item overlaps wall at ${x},${z}`);
  }
  for (const weights of [arena.weaponSlots.weights, arena.healWeights, arena.grenadeWeights]) assert.equal(weights.reduce((a, b) => a + b, 0), 100);
  for (const chance of [arena.weaponSlots.ammoChance, arena.healChance, arena.grenadeChance]) assert.ok(chance >= 0 && chance <= 1);
});

// Slab intersection: 3D segment against a solid AABB, independent of Godot.
function segmentHitsBox(a, b, box) {
  let lo = 0, hi = 1;
  for (let axis = 0; axis < 3; axis++) {
    const min = box.position[axis] - box.size[axis] / 2;
    const max = box.position[axis] + box.size[axis] / 2;
    const d = b[axis] - a[axis];
    if (Math.abs(d) < 1e-10) { if (a[axis] < min || a[axis] > max) return false; }
    else {
      const t1 = (min - a[axis]) / d, t2 = (max - a[axis]) / d;
      lo = Math.max(lo, Math.min(t1, t2)); hi = Math.min(hi, Math.max(t1, t2));
      if (lo > hi) return false;
    }
  }
  return lo <= hi;
}
function canSee(from, to) {
  const eye = [from[0], from[1] + spec.movement.eyeHeight, from[2]];
  const samples = [[0, 1.62, 0], [-0.18, 1.62, 0], [0.18, 1.62, 0], [0, 0.9, 0], [0, 1.8, 0]];
  return samples.some(offset => {
    const target = to.map((n, axis) => n + offset[axis]);
    return !boxes.some(box => segmentHitsBox(eye, target, box));
  });
}

const step = arena.gridStep;
const nx = Math.round(2 * arena.halfWidth / step) + 1;
const nz = Math.round(2 * arena.halfDepth / step) + 1;
const walkable = new Uint8Array(nx * nz);
const at = (x, z) => z * nx + x;
for (let z = 0; z < nz; z++) for (let x = 0; x < nx; x++) {
  const wx = -arena.halfWidth + x * step, wz = -arena.halfDepth + z * step;
  const radius = spec.movement.radius;
  if (Math.abs(wx) >= arena.halfWidth - 0.25 - radius || Math.abs(wz) >= arena.halfDepth - 0.25 - radius) continue;
  if (!boxes.some(box => overlapsXZ(wx, wz, box, radius))) walkable[at(x, z)] = 1;
}
const spawnCells = spawns.map(([x, y, z]) => at(Math.round((x + arena.halfWidth) / step), Math.round((z + arena.halfDepth) / step)));
function distances(start) {
  assert.ok(walkable[start], 'spawn inside inflated collider');
  const result = new Int32Array(nx * nz).fill(-1);
  result[start] = 0;
  const queue = [start];
  for (let cursor = 0; cursor < queue.length; cursor++) {
    const id = queue[cursor], x = id % nx, z = Math.floor(id / nx);
    for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const xx = x + dx, zz = z + dz;
      if (xx < 0 || zz < 0 || xx >= nx || zz >= nz) continue;
      const next = at(xx, zz);
      if (!walkable[next] || result[next] >= 0) continue;
      result[next] = result[id] + 1; queue.push(next);
    }
  }
  return result;
}
const distanceMatrix = spawnCells.map(start => {
  const values = distances(start);
  return spawnCells.map(end => values[end] < 0 ? null : values[end] * step);
});
const allowed = spawns.map((from, i) => spawns.map((to, j) =>
  i !== j && distanceMatrix[i][j] !== null && distanceMatrix[i][j] >= arena.spawnMinPathDistance && !canSee(from, to) && !canSee(to, from)));
check('spawn paths and initial sightlines', () => {
  for (let i = 0; i < 6; i++) {
    assert.ok(allowed[i].some(Boolean), `spawn ${i} has no valid opponent; distances=${JSON.stringify(distanceMatrix[i])}`);
    for (let j = 0; j < 6; j++) {
      assert.equal(allowed[i][j], allowed[j][i]);
      if (i !== j) assert.notEqual(distanceMatrix[i][j], null, `spawn ${i} cannot reach ${j}`);
    }
  }
});

const report = {
  specVersion: spec.specVersion, checksPassed: checks.length, checks,
  workPackages: spec.tasks.length, acceptanceDefinitions: 38,
  spawnShortestWalkingDistances: distanceMatrix,
  allowedOpponents: allowed.map(row => row.flatMap((ok, i) => ok ? [i] : [])),
  limits: ['Static design validation only; no Godot physics, game, NAT or realtime recovery executed.']
};
if (process.argv.includes('--write')) fs.writeFileSync(path.join(folder, 'design-validation.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));

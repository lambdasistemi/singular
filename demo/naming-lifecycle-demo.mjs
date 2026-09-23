#!/usr/bin/env node
// D-02 naming rehearsal. Every verdict is produced by the accepted Lean model.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

const fast = process.argv.includes('--fast');
const pauseMs = fast ? 0 : Number(process.env.DEMO_PAUSE_MS ?? 3500);
assert(Number.isFinite(pauseMs) && pauseMs >= 0 && pauseMs <= 10000);
const source = readFileSync('lean/Singular/NamingLifecycle.lean');
const sourceHash = createHash('sha256').update(source).digest('hex');
const json = execFileSync('nix', ['develop', '--no-write-lock-file', '-c',
  'lake', 'env', 'lean', '--run', 'lean/LifecycleMain.lean'],
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
const corpus = JSON.parse(json.trimEnd().split('\n').at(-1));
assert.equal(corpus.schema, 'singular-naming-lifecycle-corpus-v2');
const rows = new Map([...corpus.steps, ...corpus.recovery].map(row => [row.id, row]));
const colors = { reset: '\x1b[0m', cyan: '\x1b[1;36m', dim: '\x1b[0;90m',
  green: '\x1b[1;32m', yellow: '\x1b[1;33m', red: '\x1b[0;31m' };
function line(color, value) { console.log(`${colors[color]}${value}${colors.reset}`); }
async function frame(title, comments, command, action) {
  process.stdout.write('\x1b[H\x1b[2J\x1b[3J');
  line('cyan', title); console.log();
  for (const comment of comments) line('dim', `# ${comment}`);
  console.log(); line('green', `$ ${command}`); console.log();
  action(); if (pauseMs) await sleep(pauseMs);
}
function result(id, reason) {
  const row = rows.get(id);
  assert(row && row.ok === true, `${id} did not hold in Lean`);
  if (reason) assert.equal(row.detail, reason);
  line(reason ? 'red' : 'yellow',
    `${reason ? 'EXPECTED REFUSAL' : 'LEAN ROW HELD'}: ${id}`);
  if (reason) line('red', `reason=${row.detail}`);
}

await frame('D-02 | naming lifecycle model rehearsal', [
  'Fictional alice is model key 42; addresses are fixture bytes.',
  'No real Cardano asset, destination, signature or transaction.',
], 'lake env lean --run lean/LifecycleMain.lean', () => {
  line('yellow', `Lean source SHA256: ${sourceHash}`);
});
await frame('1 | Maintain the payment destination', [
  'The current controller changes the fixture destination.',
  'The registry root must stay equal.',
], 'Lean maintenance rows LM01 and LM04', () => {
  result('LM01-maintenance-accepts'); result('LM04-root-equal-after-maintenance');
});
await frame('2 | Refuse unauthorized maintenance', [
  'A missing controller signature cannot change the record.',
], 'Lean maintenance row LM02', () => result('LM02-maintenance-unauthorized-refused', 'controller-signature'));
await frame('3 | Recover committed control', [
  'The revealed precommitted control signs; the root stays equal.',
], 'Lean recovery rows LR01 and LR11', () => {
  result('LR01-recovery-accepts'); result('LR11-root-equal-after-recovery');
});
await frame('4 | Refuse wrong or missing recovery evidence', [
  'The wrong revealed key and a missing signer each fail.',
], 'Lean recovery rows LR02 and LR03', () => {
  result('LR02-wrong-reveal-refused', 'recovery-commitment');
  result('LR03-missing-recovery-signer-refused', 'recovery-required-signer');
});
await frame('Model rehearsal complete | devnet target open', [
  'These are executable Lean rows, not ledger observations.',
  'No release, policy IDs, tx IDs or fresh node readbacks shown.',
], 'review the D-02 naming page', () => {
  line('yellow', 'Observed: maintenance and recovery rows held in Lean.');
});

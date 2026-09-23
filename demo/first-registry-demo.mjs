#!/usr/bin/env node
// D-01 model rehearsal. The names are presentation aliases for model integers;
// all verdicts, effects and observations come from the existing simulator.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { assetDelta, canonical, foldBatch, initial, view } from '../simulator/core.mjs';
import { approved, mismatched, read } from '../simulator/actions.mjs';

const fast = process.argv.includes('--fast');
const pauseMs = fast ? 0 : Number(process.env.DEMO_PAUSE_MS ?? 3500);
assert(Number.isFinite(pauseMs) && pauseMs >= 0 && pauseMs <= 10000);
const modelBytes = readFileSync(new URL('../lean/Singular/Model.lean', import.meta.url));
const modelHash = createHash('sha256').update(modelBytes).digest('hex');
const key = 42;
const colors = {
  reset: '\x1b[0m', cyan: '\x1b[1;36m', dim: '\x1b[0;90m',
  green: '\x1b[1;32m', yellow: '\x1b[1;33m', red: '\x1b[0;31m',
};
const line = (color, value) => console.log(`${colors[color]}${value}${colors.reset}`);
const frame = async (title, why, command, action) => {
  process.stdout.write('\x1b[H\x1b[2J\x1b[3J');
  line('cyan', title);
  console.log();
  for (const sentence of why) line('dim', `# ${sentence}`);
  if (command) { console.log(); line('green', `$ ${command}`); console.log(); }
  if (action) action();
  if (pauseMs) await sleep(pauseMs);
};
const claimed = request => ({ ...request, claimed: assetDelta(request)
  .map(({ kind, quantity }) => ({ kind, quantity })) });
const mintText = mint => mint.map(x => `${x.kind}${x.quantity > 0 ? '+' : ''}${x.quantity}`).join(', ');
const paidText = paid => paid.length
  ? paid.map(x => `${x.value} -> address ${x.destination}`).join(', ')
  : 'none';
const rootText = root => root.map(x => x.toString(16).padStart(2, '0')).join('');
let state = initial();
const initialState = canonical(state);

const accepted = request => {
  const result = foldBatch(state, [claimed(request)]);
  assert.equal(result.accepted, true, result.reason);
  state = result.value.state;
  const observation = view(state, key);
  line('yellow', `ACCEPTED  leaf=${observation.leaf}  mint=${mintText(result.value.mint)}`);
  line('yellow', `paid=${paidText(result.value.paid)}`);
  line('yellow', `custody=${state.custody.length}  active=${observation.witnesses.active}`);
  line('yellow', `terminal witnesses=${observation.witnesses.terminal}`);
  return { result, observation };
};
const refused = (request, reason) => {
  const before = canonical(state);
  const result = foldBatch(state, [request]);
  assert.equal(result.accepted, false);
  assert.equal(result.reason, reason);
  assert.equal(canonical(state), before);
  line('red', `EXPECTED REFUSAL: ${result.reason}`);
  line('yellow', `state unchanged; leaf=${view(state, key).leaf}`);
};

await frame('D-01 | Singular registry model rehearsal', [
  'Fictional asset ORCHID-42 is model key 42, not a Cardano token.',
  'Model play only; no release archive or ledger transaction.',
], 'node demo/first-registry-demo.mjs', () => {
  assert.equal(canonical(state), initialState);
  line('yellow', 'Starting leaf=unknown; custody=0; held tokens=0');
  line('yellow', `Model SHA256 prefix: ${modelHash.slice(0, 16)}`);
});

await frame('1 | Record the absence', [
  'The funder records that this key is not yet booked.',
  'The absent token and deposit enter registry custody.',
], 'foldBatch(insertAbsent, key=42, funder=91, deposit=200)', () => {
  const { observation } = accepted(approved('insertAbsent', key, {
    owner: 91, refundAddress: 91, deposit: 200,
  }));
  assert.equal(observation.leaf, 'absent');
  assert.deepEqual(state.custody, [{ key, refundAddress: 91, value: 200 }]);
});

await frame('2 | Wrong approval tuple is refused', [
  'An approval under the right policy still has to name this request.',
  'The custody entry survives this attempted booking.',
], 'foldBatch(updateActive, wrong approval key)', () => {
  refused(claimed(mismatched('updateActive', key, {
    owner: 42, output: 555,
  })), 'approval-mismatch');
  assert.equal(state.custody.length, 1);
});

await frame('3 | Book the key and return the deposit', [
  'A matching approval books the absent key as active.',
  'The recorded funder gets the 200 model units back.',
], 'foldBatch(updateActive, key=42, output=555)', () => {
  const { result, observation } = accepted(approved('updateActive', key, {
    owner: 42, output: 555,
  }));
  assert.equal(observation.leaf, 'active');
  assert.deepEqual(result.value.paid, [{ destination: 91, value: 200 }]);
  assert.equal(state.custody.length, 0);
  assert.deepEqual(state.held.filter(x => x.kind === 'active'),
    [{ key, kind: 'active', output: 555 }]);
  line('yellow', 'active token output=555');
});

await frame('4 | Retire the booked key', [
  'Retirement consumes the active token.',
  'The registry leaf becomes terminal.',
], 'foldBatch(updateTerminal, key=42)', () => {
  const { observation } = accepted(approved('updateTerminal', key, {
    owner: 42, output: 555,
  }));
  assert.equal(observation.leaf, 'terminal');
  assert.equal(observation.witnesses.active, 0);
});

const terminalRoot = rootText(view(state, key).root);
await frame('5 | First terminal witness', [
  'A terminal witness attests a leaf that has already ended.',
  'The leaf and registry root do not change.',
], 'foldBatch(witnessTerminal, key=42, output=700)', () => {
  const { observation } = accepted(read(key, 700));
  assert.equal(observation.witnesses.terminal, 1);
  assert.equal(rootText(observation.root), terminalRoot);
});

await frame('6 | Second terminal witness', [
  'The model permits a second witness for the same terminal leaf.',
  'Both witness holdings are visible; no new incarnation appears.',
], 'foldBatch(witnessTerminal, key=42, output=701)', () => {
  const { observation } = accepted(read(key, 701));
  assert.equal(observation.witnesses.terminal, 2);
  assert.equal(rootText(observation.root), terminalRoot);
  assert.deepEqual(state.held.filter(x => x.kind === 'terminal').map(x => x.output), [701, 700]);
});

await frame('7 | Terminal key cannot be booked again', [
  'A valid approval cannot override the terminal leaf.',
  'The two witnesses stay in place after refusal.',
], 'foldBatch(updateActive, key=42 after retirement)', () => {
  refused(claimed(approved('updateActive', key, { owner: 42, output: 555 })),
    'terminal-immutable');
  assert.equal(view(state, key).witnesses.terminal, 2);
});

await frame('8 | Missing token delta is refused', [
  'A folded witness must claim the model-required mint delta.',
  'Omitting that delta refuses the batch and keeps state unchanged.',
], 'foldBatch(witnessTerminal, claimed mint=[])', () => {
  refused(read(key, 702), 'net-mint-mismatch');
  assert.equal(view(state, key).witnesses.terminal, 2);
});

await frame('Model play complete | acceptance still open', [
  'Shown: custody refund, retirement, plural witnesses, refusals.',
  'Not shown: released archive, scripts, tx IDs, node readbacks.',
  'Those are the separate 8 October devnet acceptance gate.',
], null, () => {
  line('yellow', `Final leaf=${view(state, key).leaf}; witnesses=2`);
  line('yellow', 'Model source SHA256:');
  line('yellow', modelHash);
});

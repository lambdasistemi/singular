#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const file = process.argv[2];
assert(file, 'usage: validate-naming-lifecycle-cast.mjs FILE.cast');
const [first, ...rest] = readFileSync(file, 'utf8').trimEnd().split('\n');
const header = JSON.parse(first);
assert.equal(header.version, 2);
assert.equal(header.width, 80);
assert.equal(header.height, 24);
assert.equal(header.env?.SHELL, '/bin/bash');
const events = rest.map(line => JSON.parse(line));
assert(events.length > 0);
assert(events.every(row => Array.isArray(row) && row[1] === 'o' && typeof row[2] === 'string'));
const output = events.map(row => row[2]).join('');
assert(!/\/nix\/store|AssertionError|FailureResponse|ClientError|CallStack|HasCallStack/.test(output));
assert(Math.max(...events.map(row => row[2].length)) < 400);
for (const phrase of ['D-02 | naming lifecycle model rehearsal',
  'LM01-maintenance-accepts', 'LM04-root-equal-after-maintenance',
  'EXPECTED REFUSAL: LM02-maintenance-unauthorized-refused',
  'LR01-recovery-accepts', 'LR11-root-equal-after-recovery',
  'EXPECTED REFUSAL: LR02-wrong-reveal-refused',
  'EXPECTED REFUSAL: LR03-missing-recovery-signer-refused',
  'No release, policy IDs, tx IDs or fresh node readbacks shown.'])
  assert(output.includes(phrase), `cast is missing ${phrase}`);
console.log(JSON.stringify({ cast: file, events: events.length, width: header.width,
  height: header.height, modelRows: 7 }));

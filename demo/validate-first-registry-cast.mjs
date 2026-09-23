#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const file = process.argv[2];
assert(file, 'usage: validate-first-registry-cast.mjs FILE.cast');
const rows = readFileSync(file, 'utf8').trimEnd().split('\n');
const header = JSON.parse(rows.shift());
assert.equal(header.version, 2);
assert.equal(header.width, 80);
assert.equal(header.height, 24);
assert.equal(header.env?.SHELL, '/bin/bash');
const events = rows.map(line => JSON.parse(line));
assert(events.length > 0);
assert(events.every(row => Array.isArray(row) && row[1] === 'o'
  && typeof row[2] === 'string'));
const output = events.map(row => row[2]).join('');
assert(!/\/nix\/store|AssertionError|FailureResponse|ClientError|CallStack|HasCallStack/.test(output));
assert(Math.max(...events.map(row => row[2].length)) < 400);
for (const phrase of [
  'D-01 | Singular registry model rehearsal',
  'Fictional asset ORCHID-42',
  'ACCEPTED  leaf=absent  mint=absent+1',
  'EXPECTED REFUSAL: approval-mismatch',
  'paid=200 -> address 91',
  'active token output=555',
  'ACCEPTED  leaf=terminal  mint=active-1',
  'terminal witnesses=2',
  'EXPECTED REFUSAL: terminal-immutable',
  'EXPECTED REFUSAL: net-mint-mismatch',
  'Not shown: released archive, scripts, tx IDs, node readbacks.',
]) assert(output.includes(phrase), `cast is missing ${phrase}`);
assert.equal((output.match(/EXPECTED REFUSAL:/g) || []).length, 3);
assert.equal((output.match(/ACCEPTED  leaf=/g) || []).length, 5);
console.log(JSON.stringify({ cast: file, size: readFileSync(file).length,
  outputEvents: events.length, accepted: 5, refused: 3,
  width: header.width, height: header.height }));

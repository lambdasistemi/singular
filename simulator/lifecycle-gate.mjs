import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {
  aliceFixture, controllerAddress, decodeAddress, freshControllerAddress,
  freshControllerCommitment, namingInitial, nextControllerAddress,
  nextControllerCommitment, queueClaim, foldRequest,
} from './naming.mjs';
import {
  blake2b256, cardanoKeriRevision, checkLifecycleCorpus, initializeConsumer, lifecycleStep,
  namingConsumerBinding, nextCommitment, nextControlHashContract,
  nextControlHashInput, retirementRequest,
} from './lifecycle.mjs';

const lifecycleCorpus = JSON.parse(readFileSync(new URL('../lean/lifecycle-corpus.json', import.meta.url)));
const leanReplay = checkLifecycleCorpus(lifecycleCorpus);
const lifecycleDrift = structuredClone(lifecycleCorpus);
lifecycleDrift.steps[0].result = {accepted: false, reason: 'fabricated-result'};
assert.throws(() => checkLifecycleCorpus(lifecycleDrift), /lifecycle-corpus\/LM01-maintenance-accepts/);
const lifecycleIdentityDrop = structuredClone(lifecycleCorpus);
lifecycleIdentityDrop.steps.shift();
assert.throws(() => checkLifecycleCorpus(lifecycleIdentityDrop), /lifecycle corpus identity/);

const ok = verdict => {
  assert.equal(verdict.accepted, true, JSON.stringify(verdict));
  return verdict.value;
};
const refused = (verdict, reason) => assert.deepEqual(verdict, {accepted: false, reason});
const hex = bytes => bytes.map(byte => byte.toString(16).padStart(2, '0')).join('');
const pythonHash = bytes => {
  const script = 'import hashlib,sys;print(hashlib.blake2b(bytes.fromhex(sys.argv[1]),digest_size=32).hexdigest())';
  const result = spawnSync('python3', ['-c', script, hex(bytes)], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
};

assert.equal(nextControlHashContract.algorithm, 'BLAKE2b-256');
assert.equal(nextControlHashContract.digestBytes, 32);
assert.equal(hex(blake2b256([])), '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8');
assert.deepEqual(nextCommitment(nextControllerAddress), nextControllerCommitment);
assert.deepEqual(nextCommitment(freshControllerAddress), freshControllerCommitment);

// Dynamic, non-fixture correspondence: both supported forms and both payment
// credential kinds are checked against Python's independent hashlib adapter.
const addresses = [];
for (const network of [0, 1, 7, 15]) {
  for (const kind of [0, 1, 2, 3, 6, 7]) {
    const payloadLength = kind < 4 ? 56 : 28;
    const bytes = [kind * 16 + network,
      ...Array.from({length: payloadLength}, (_, index) => (network * 31 + kind * 17 + index * 7) % 256)];
    const address = decodeAddress(bytes);
    assert.notEqual(address, null);
    addresses.push(address);
  }
}
for (const address of addresses) {
  const preimage = nextControlHashInput(address);
  assert.equal(hex(nextCommitment(address).digest), pythonHash(preimage));
}

const queuedVerdict = queueClaim(namingInitial(), {spelling: 'alice', fixture: aliceFixture, accepted: true});
const queued = ok(queuedVerdict);
const active = ok(foldRequest(queued.state, queuedVerdict.requestId)).state;
const record = active.records[0];
assert.equal(record.outputId, active.registry.applications[0].id);

const cleared = {...aliceFixture, paymentDestination: null};
const maintain = {maintain: {source: record.outputId, successor: 3, key: record.key, candidate: cleared,
  witnesses: {requiredSigners: [controllerAddress], quorumSigners: []}}};
const maintained = ok(lifecycleStep(active, maintain)).state;
assert.equal(maintained.records[0].outputId, 3);
assert.equal(maintained.records[0].fixture.paymentDestination, null);
refused(lifecycleStep(active, {...maintain, maintain: {...maintain.maintain,
  witnesses: {requiredSigners: [], quorumSigners: []}}}), 'controller-signature');

const recoveredFixture = {...aliceFixture, controlAddress: nextControllerAddress,
  nextControlCommitment: freshControllerCommitment};
const recover = {recover: {source: record.outputId, successor: 3, key: record.key,
  revealed: nextControllerAddress, candidate: recoveredFixture,
  witnesses: {requiredSigners: [nextControllerAddress], quorumSigners: []}}};
const recovered = ok(lifecycleStep(active, recover)).state;
assert.deepEqual(recovered.records[0].fixture.controlAddress, nextControllerAddress);
const forgedFixture = {...aliceFixture, controlAddress: addresses[12], nextControlCommitment: freshControllerCommitment};
refused(lifecycleStep(active, {recover: {...recover.recover, revealed: addresses[12], candidate: forgedFixture,
  witnesses: {requiredSigners: [addresses[12]], quorumSigners: []}, computed: nextControllerCommitment}}), 'lifecycle-action');
refused(lifecycleStep(active, {recover: {...recover.recover, revealed: addresses[12], candidate: forgedFixture,
  witnesses: {requiredSigners: [addresses[12]], quorumSigners: []}}}), 'recovery-commitment');

const application = active.registry.applications.find(output => output.id === record.outputId);
const requestId = 3, request = retirementRequest(active, record, application, requestId);
const retire = {retire: {source: record.outputId, requestId, key: record.key, request, route: 'controller',
  witnesses: {requiredSigners: [controllerAddress], quorumSigners: []}}};
const pending = ok(lifecycleStep(active, retire)).state;
assert.equal(pending.records.length, 0);
const over = ok(lifecycleStep(pending, {completeRetirement: {requestId}})).state;
assert.equal(over.registry.entries.find(entry => entry.key === record.key).value, 'over');
assert.equal((await import('./naming.mjs')).namingResolve(pending, 'alice', true), 'pending');
assert.equal((await import('./naming.mjs')).namingResolve(over, 'alice', true), 'retired');
const requeueVerdict = queueClaim(over, {spelling: 'alice', fixture: aliceFixture, accepted: true});
const requeued = ok(requeueVerdict);
refused(foldRequest(requeued.state, requeueVerdict.requestId), 'occupied-key');
refused(lifecycleStep(active, {...retire, retire: {...retire.retire, route: 'quorum',
  witnesses: {requiredSigners: [], quorumSigners: [50]}}}), 'retirement-authorization');

const canonical = {sourceRevision: cardanoKeriRevision, seed: 400, seedConsumed: true,
  registry: 1, applicationPolicy: 7, representativePolicy: 8, validatorScript: 12};
assert.deepEqual(initializeConsumer(namingConsumerBinding, canonical), {accepted: true});
refused(initializeConsumer(namingConsumerBinding, {...canonical, seed: 401}), 'canonical-seed');

console.log(JSON.stringify({leanReplay, hashCorrespondence: {dynamicAddresses: addresses.length, oracle: 'python-hashlib'},
  lifecycle: ['maintenance', 'recovery', 'retirement-controller', 'retirement-completion', 'initialization'],
  negativeControls: 9}));

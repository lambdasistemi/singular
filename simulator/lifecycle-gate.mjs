import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {step} from './core.mjs';
import {
  aliceFixture, controllerAddress, decodeAddress, freshControllerAddress,
  freshControllerCommitment, namingInitial, nextControllerAddress,
  nextControllerCommitment, otherControllerAddress, otherFixture, queueClaim, foldRequest,
} from './naming.mjs';
import {
  blake2b256, cardanoKeriRevision, checkLifecycleCorpus, initializeConsumer,
  initializeConsumerTransition, lifecycleStep,
  namingConsumerBinding, nextCommitment, nextControlHashContract,
  nextControlHashInput, retirementRequest,
} from './lifecycle.mjs';
import {
  decodeNamingDatum, deserialiseNamingDatum, encodeNamingDatum, extractNamingDatum,
  namingDatumShape, serialiseNamingDatum, twoDestinationDatum,
} from './naming-wire.mjs';

const lifecycleCorpus = JSON.parse(readFileSync(new URL('../lean/lifecycle-corpus.json', import.meta.url)));
const leanReplay = checkLifecycleCorpus(lifecycleCorpus);
const lifecycleDrift = structuredClone(lifecycleCorpus);
const lifecycleDriftRow = lifecycleDrift.steps.find(row => row.id === 'LM01-maintenance-accepts');
lifecycleDriftRow.result = {accepted: false, reason: 'fabricated-result'};
assert.throws(() => checkLifecycleCorpus(lifecycleDrift), /lifecycle-corpus\/LM01-maintenance-accepts/);
const lifecycleIdentityDrop = structuredClone(lifecycleCorpus);
lifecycleIdentityDrop.steps.shift();
assert.throws(() => checkLifecycleCorpus(lifecycleIdentityDrop), /lifecycle corpus identity/);
const encodedDatum = encodeNamingDatum(aliceFixture);
assert.deepEqual(namingDatumShape(encodedDatum), {outerIndex: 0, innerIndex: 0, arity: 4});
assert.deepEqual(decodeNamingDatum(encodedDatum), aliceFixture);
assert.deepEqual(encodeNamingDatum(decodeNamingDatum(encodedDatum)), encodedDatum);
assert.deepEqual(extractNamingDatum({inline: encodedDatum}), aliceFixture);
assert.equal(extractNamingDatum({datumHash: [1, 2, 3]}), null);
assert.equal(decodeNamingDatum(twoDestinationDatum(aliceFixture)), null);
const wireRow = lifecycleCorpus.wire.find(row => row.id === 'WD01-four-field-roundtrip');
const encodedDatumBytes = serialiseNamingDatum(aliceFixture);
assert.deepEqual(encodedDatumBytes, wireRow.expectedBytes);
assert.deepEqual(deserialiseNamingDatum(wireRow.expectedBytes), aliceFixture);
assert.deepEqual(serialiseNamingDatum(deserialiseNamingDatum(wireRow.expectedBytes)), wireRow.expectedBytes);
assert.equal(deserialiseNamingDatum(wireRow.malformedBytes), null);

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
assert.equal(queued.state.registry.requests[0].proposal.refundAddress, 60,
  'queued Insert commits the stored cancellation refund address');
const cancellationRefund = {destination: 60, value: 0};
const cancellationAsset = {policy: queued.state.registry.config.applicationPolicy,
  name: {withdraw: {registry: queued.state.registry.config.registry,
    request: queuedVerdict.requestId, refund: cancellationRefund}}};
const approvedCancellationRegistry = ok(step(queued.state.registry, {mintWithdraw: {
  approval: {asset: cancellationAsset, accepted: true, conforms: true},
  witness: {applicationMint: true, applicationSpend: false, nativeSpend: false,
    representativeMint: false}}})).state;
const cancellationPending = {...queued.state, registry: approvedCancellationRegistry};
const cancel = {cancelClaim: {requestId: queuedVerdict.requestId, refundAddress: 60}};
const cancelled = ok(lifecycleStep(cancellationPending, cancel)).state;
refused(lifecycleStep(cancellationPending, {cancelClaim: {...cancel.cancelClaim,
  refundAddress: 61}}), 'withdraw-refund-address');
refused(lifecycleStep(queued.state, cancel), 'withdraw-binding');
refused(lifecycleStep(cancelled, cancel), 'request-unavailable');
const active = ok(foldRequest(queued.state, queuedVerdict.requestId)).state;
refused(lifecycleStep(active, cancel), 'request-unavailable');
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
refused(lifecycleStep(active, {...maintain, maintain: {...maintain.maintain,
  candidate: {...cleared, retirementQuorum: otherFixture.retirementQuorum}}}), 'destination-field-preservation');
refused(lifecycleStep(active, {...maintain, maintain: {...maintain.maintain,
  candidate: {...aliceFixture, controlAddress: otherControllerAddress},
  witnesses: {requiredSigners: [], quorumSigners: aliceFixture.retirementQuorum.members.slice(0, 2)}}}), 'controller-signature');
refused(lifecycleStep(active, {...maintain, maintain: {...maintain.maintain,
  candidate: {...aliceFixture, paymentDestination: otherControllerAddress},
  witnesses: {requiredSigners: [], quorumSigners: aliceFixture.retirementQuorum.members.slice(0, 2)}}}), 'controller-signature');

const recoveredFixture = {...aliceFixture, controlAddress: nextControllerAddress,
  nextControlCommitment: freshControllerCommitment};
const recover = {recover: {source: record.outputId, successor: 3, key: record.key,
  revealed: nextControllerAddress, candidateRegistry: active.registry.config.registry,
  candidateRepresentative: record.representative, candidate: recoveredFixture,
  witnesses: {requiredSigners: [nextControllerAddress], quorumSigners: []}}};
const recovered = ok(lifecycleStep(active, recover)).state;
assert.deepEqual(recovered.records[0].fixture.controlAddress, nextControllerAddress);
refused(lifecycleStep(active, {recover: {...recover.recover,
  candidateRegistry: active.registry.config.registry + 1}}), 'recovery-registry');
refused(lifecycleStep(active, {recover: {...recover.recover,
  candidateRepresentative: {...record.representative, policy: record.representative.policy + 1}}}), 'recovery-representative');
refused(lifecycleStep(active, {recover: {...recover.recover,
  candidate: {...recoveredFixture, retirementQuorum: otherFixture.retirementQuorum}}}), 'recovery-field-preservation');
refused(lifecycleStep(active, {recover: {...recover.recover,
  witnesses: {requiredSigners: [controllerAddress], quorumSigners: []}}}), 'recovery-required-signer');
refused(lifecycleStep(active, {recover: {...recover.recover,
  candidate: {...recoveredFixture, nextControlCommitment: nextControllerCommitment}}}), 'recovery-fresh-commitment');
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
refused(lifecycleStep(active, {retire: {...retire.retire,
  request: {...request, held: {...record.representative, policy: record.representative.policy + 1}}}}), 'retirement-request');
refused(lifecycleStep(pending, retire), 'naming-record-unavailable');
refused(lifecycleStep(pending, {withdrawRetirement: {requestId}}), 'retirement-withdrawal-refused');
const over = ok(lifecycleStep(pending, {completeRetirement: {requestId}})).state;
assert.equal(over.registry.entries.find(entry => entry.key === record.key).value, 'over');
assert.equal((await import('./naming.mjs')).namingResolve(pending, 'alice', true), 'pending');
assert.equal((await import('./naming.mjs')).namingResolve(over, 'alice', true), 'retired');
const requeueVerdict = queueClaim(over, {spelling: 'alice', fixture: aliceFixture, accepted: true});
const requeued = ok(requeueVerdict);
refused(foldRequest(requeued.state, requeueVerdict.requestId), 'occupied-key');
refused(lifecycleStep(active, {...retire, retire: {...retire.retire, route: 'quorum',
  witnesses: {requiredSigners: [], quorumSigners: [aliceFixture.retirementQuorum.members[0]]}}}), 'retirement-authorization');

const canonical = {sourceRevision: cardanoKeriRevision, seed: 400, seedConsumed: true,
  registry: 1, applicationPolicy: 7, representativePolicy: 8, validatorScript: 12};
assert.deepEqual(initializeConsumer(namingConsumerBinding, canonical), {accepted: true});
refused(initializeConsumer(namingConsumerBinding, {...canonical, seed: 401}), 'canonical-seed');
refused(initializeConsumer(namingConsumerBinding,
  {...canonical, representativePolicy: canonical.representativePolicy + 1}), 'representative-policy');
refused(initializeConsumer(namingConsumerBinding,
  {...canonical, validatorScript: canonical.validatorScript + 1}), 'validator-script');
const initialized = initializeConsumerTransition(namingConsumerBinding, {consumedSeeds: []}, canonical);
assert.deepEqual(initialized, {accepted: true, state: {consumedSeeds: [400]}});
refused(initializeConsumerTransition(namingConsumerBinding, initialized.state, canonical), 'canonical-seed-consumed');

console.log(JSON.stringify({leanReplay, hashCorrespondence: {dynamicAddresses: addresses.length, oracle: 'python-hashlib'},
  lifecycle: ['cancellation', 'maintenance', 'recovery', 'retirement-controller', 'retirement-completion', 'initialization'],
  wireCodec: {outerIndex: 0, innerIndex: 0, arity: 4, bytes: encodedDatumBytes.length,
    exactBytes: true, malformedBytesRefused: true, inlineOnly: true, zeroOrOneDestination: true},
  negativeControls: 30}));

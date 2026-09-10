import {aliceFixture, controllerAddress, decodeAddress, foldRequest, namingInitial, namingResolve, nextControllerCommitment, queueClaim} from './naming.mjs';
import {checkLifecycleCorpus, lifecycleStep, nextCommitment, retirementRequest} from './lifecycle.mjs';
import {
  decodeNamingDatum, deserialiseNamingDatum, encodeNamingDatum, extractNamingDatum,
  namingDatumShape, serialiseNamingDatum, twoDestinationDatum,
} from './naming-wire.mjs';

const result = document.querySelector('#result');
const show = value => { result.textContent = JSON.stringify(value, null, 2); result.className = 'pass'; };
const queued = queueClaim(namingInitial(), {spelling: 'alice', fixture: aliceFixture, accepted: true});
const active = foldRequest(queued.value.state, queued.requestId).value.state;
const record = active.records[0], application = active.registry.applications[0];
const nonFixture = decodeAddress([97, ...Array.from({length: 28}, (_, index) => 141 + index)]);
const lifecycleCorpus = await (await fetch('./lifecycle-corpus.json')).json();
const lifecycleCorpusReceipt = checkLifecycleCorpus(lifecycleCorpus);
window.lifecycleCorpusReceipt = lifecycleCorpusReceipt;
const encodedDatum = encodeNamingDatum(aliceFixture);
const wireRow = lifecycleCorpus.wire.find(row => row.id === 'WD01-four-field-roundtrip');
const encodedBytes = serialiseNamingDatum(aliceFixture);
const decodedBytes = deserialiseNamingDatum(wireRow.expectedBytes);
window.namingWireReceipt = {
  shape: namingDatumShape(encodedDatum),
  roundtrip: JSON.stringify(encodeNamingDatum(decodeNamingDatum(encodedDatum))) === JSON.stringify(encodedDatum),
  byteLength: encodedBytes.length,
  exactBytes: JSON.stringify(encodedBytes) === JSON.stringify(wireRow.expectedBytes),
  byteRoundtrip: JSON.stringify(serialiseNamingDatum(decodedBytes)) === JSON.stringify(wireRow.expectedBytes),
  malformedBytesRejected: deserialiseNamingDatum(wireRow.malformedBytes) === null,
  inline: extractNamingDatum({inline: encodedDatum}) !== null,
  hashRejected: extractNamingDatum({datumHash: [1, 2, 3]}) === null,
  twoRejected: decodeNamingDatum(twoDestinationDatum(aliceFixture)) === null,
};

document.querySelector('#hash').onclick = () => show({address: nonFixture.bytes, digest: nextCommitment(nonFixture).digest});
document.querySelector('#forge').onclick = () => {
  const candidate = {...aliceFixture, controlAddress: nonFixture, nextControlCommitment: nextCommitment(controllerAddress)};
  const verdict = lifecycleStep(active, {recover: {source: record.outputId, successor: 3, key: record.key,
    revealed: nonFixture, candidate, witnesses: {requiredSigners: [nonFixture], quorumSigners: []},
    computed: nextControllerCommitment}});
  show(verdict);
};
document.querySelector('#retire').onclick = () => {
  const requestId = 3, request = retirementRequest(active, record, application, requestId);
  const pending = lifecycleStep(active, {retire: {source: record.outputId, requestId, key: record.key, request,
    route: 'controller', witnesses: {requiredSigners: [controllerAddress], quorumSigners: []}}}).value.state;
  const over = lifecycleStep(pending, {completeRetirement: {requestId}}).value.state;
  show({pending: namingResolve(pending, 'alice', true), over: namingResolve(over, 'alice', true)});
};
window.lifecycleReady = true;

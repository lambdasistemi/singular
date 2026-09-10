import {aliceFixture, controllerAddress, decodeAddress, foldRequest, namingInitial, namingResolve, nextControllerCommitment, queueClaim} from './naming.mjs';
import {checkLifecycleCorpus, lifecycleStep, nextCommitment, retirementRequest} from './lifecycle.mjs';

const result = document.querySelector('#result');
const show = value => { result.textContent = JSON.stringify(value, null, 2); result.className = 'pass'; };
const queued = queueClaim(namingInitial(), {spelling: 'alice', fixture: aliceFixture, accepted: true});
const active = foldRequest(queued.value.state, queued.requestId).value.state;
const record = active.records[0], application = active.registry.applications[0];
const nonFixture = decodeAddress([97, ...Array.from({length: 28}, (_, index) => 141 + index)]);
const lifecycleCorpusReceipt = checkLifecycleCorpus(await (await fetch('./lifecycle-corpus.json')).json());
window.lifecycleCorpusReceipt = lifecycleCorpusReceipt;

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

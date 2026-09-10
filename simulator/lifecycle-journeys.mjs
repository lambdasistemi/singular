import {equal} from './core.mjs';
import {
  aliceFixture, controllerAddress, destinationAddress, foldRequest,
  freshControllerAddress, freshControllerCommitment, namingInitial,
  namingResolve, nextControllerAddress, otherControllerAddress, otherFixture, queueClaim,
} from './naming.mjs';
import {
  cardanoKeriRevision, checkLifecycleCorpus, initializeConsumer,
  initializeConsumerTransition, lifecycleCorpusIdentities,
  lifecycleExecutingWitness, lifecycleStep, namingConsumerBinding,
  nextCommitment, nextControlHashInput, retirementRequest,
} from './lifecycle.mjs';
import {
  decodeNamingDatum, deserialiseNamingDatum, encodeNamingDatum,
  extractNamingDatum, namingDatumShape, serialiseNamingDatum,
  twoDestinationDatum,
} from './naming-wire.mjs';

const element = id => document.querySelector(`#${id}`);
const clone = value => structuredClone(value);
const lifecycleCorpus = await (await fetch('./lifecycle-corpus.json')).json();
const lifecycleCorpusReceipt = checkLifecycleCorpus(lifecycleCorpus);
window.lifecycleCorpusReceipt = lifecycleCorpusReceipt;
if (!equal([...lifecycleCorpusReceipt.identities].sort(), [...lifecycleCorpusIdentities].sort())) {
  throw new Error('public lifecycle corpus identity mismatch');
}

const correspondence = {
  'LM01-maintenance-accepts': ['clear, set, or replace destination with preservation checks', '#destination-clear'],
  'LM02-maintenance-unauthorized-refused': ['missing controller signer is refused', '#destination-missing-signer'],
  'LM03-maintenance-field-tamper-refused': ['non-destination field tamper is refused', '#destination-tamper'],
  'LM04-maintenance-quorum-alteration-refused': ['destination maintenance cannot alter the retirement quorum', '#destination-quorum-tamper'],
  'LR01-recovery-accepts': ['committed next controller recovers the name', '#recovery-accept'],
  'LR02-wrong-reveal-refused': ['wrong revealed address is refused', '#recovery-wrong-reveal'],
  'LR03-missing-recovery-signer-refused': ['missing next-key signer is refused', '#recovery-missing-signer'],
  'LR04-recovery-replay-refused': ['consumed reveal cannot be replayed', '#recovery-replay'],
  'LR05-old-controller-refused': ['old controller loses authority after recovery', '#recovery-old-controller'],
  'LR06-forged-public-digest-refused': ['caller cannot override the internally computed digest', '#recovery-forged-digest'],
  'LR07-wrong-payment-key-signer-refused': ['correct reveal with the wrong payment-key signer is refused', '#recovery-wrong-signer'],
  'LR08-missing-fresh-commitment-refused': ['recovery must install a fresh next commitment', '#recovery-missing-fresh'],
  'LR09-representative-tamper-refused': ['recovery cannot substitute the representative', '#recovery-representative-tamper'],
  'LR10-registry-tamper-refused': ['recovery cannot substitute the registry', '#recovery-registry-tamper'],
  'LR11-quorum-tamper-refused': ['recovery cannot substitute the retirement quorum', '#recovery-quorum-tamper'],
  'LT01-controller-retirement-accepts': ['controller queues retirement without completing it', '#retirement-controller'],
  'LT02-quorum-retirement-accepts': ['quorum queues retirement without a controller signer', '#retirement-quorum'],
  'LT03-insufficient-quorum-refused': ['sub-threshold quorum is refused', '#retirement-insufficient'],
  'LT04-retirement-completes': ['separate permissionless fold completes retirement', '#retirement-fold'],
  'LT05-quorum-control-takeover-refused': ['retirement quorum cannot take over controller authority', '#retirement-quorum-takeover'],
  'LT06-quorum-payment-redirection-refused': ['retirement quorum cannot redirect payments', '#retirement-quorum-redirect'],
  'LT07-retirement-withdrawal-refused': ['a queued retirement cannot be withdrawn', '#retirement-withdraw'],
  'LT08-wrong-retirement-custody-refused': ['retirement refuses wrong representative custody', '#retirement-wrong-custody'],
  'LT09-retirement-replay-refused': ['retirement initiation cannot be replayed from pending', '#retirement-replay'],
  'LO01-retirement-pending-visible': ['authenticated resolve reports pending before fold', '#retirement-controller'],
  'LO02-retirement-over-visible': ['authenticated resolve reports retired after fold', '#retirement-fold'],
  'LI01-canonical-initialization-accepts': ['canonical consumer identity initializes', '#initialization-canonical'],
  'LI02-alternate-seed-refused': ['rival seed is refused', '#initialization-alternate'],
  'LI03-second-seed-rival-registry-refused': ['second seed cannot create a rival registry', '#initialization-rival'],
  'LI04-substituted-registry-refused': ['substituted registry identity is refused', '#initialization-registry'],
  'LI05-substituted-policy-refused': ['substituted application policy is refused', '#initialization-policy'],
  'LI06-repeated-canonical-seed-refused': ['consumed canonical seed cannot initialize twice', '#initialization-repeat'],
  'LI07-substituted-representative-policy-refused': ['substituted representative policy is refused', '#initialization-representative-policy'],
  'LI08-substituted-validator-script-refused': ['substituted validator script is refused', '#initialization-validator'],
  'LX01-re-registration-after-over-refused': ['registration after Over is refused', '#retirement-reregister'],
  'WD01-four-field-roundtrip': ['exact four-field datum bytes round-trip', '#wire-roundtrip'],
  'WD02-datum-hash-refused': ['datum-hash attachment is refused', '#wire-hash'],
  'WD03-two-destinations-refused': ['a second destination field is refused', '#wire-two-destinations'],
};

const observed = new Set();
let current;
let keyLost = false;
let recoveredController = false;
let initializationState = {consumedSeeds: []};
let lastExecutingWitness = null;
let lastRetirementAction = null;

function activeState() {
  const queued = queueClaim(namingInitial(), {spelling: 'alice', fixture: clone(aliceFixture), accepted: true});
  if (!queued.accepted) throw new Error(`active setup queue: ${queued.reason}`);
  const folded = foldRequest(queued.value.state, queued.requestId);
  if (!folded.accepted) throw new Error(`active setup fold: ${folded.reason}`);
  return clone(folded.value.state);
}

const record = () => current.records[0];
const application = () => current.registry.applications.find(output => output.id === record()?.outputId);
const freshId = () => Math.max(0, ...current.registry.used) + 1;
const resolution = () => namingResolve(current, 'alice', true);
const resolutionLabel = () => {
  const value = resolution();
  return typeof value === 'string' ? value : value?.status ?? value?.error ?? 'unknown';
};

const destinationControls = ['destination-clear', 'destination-set', 'destination-replace',
  'destination-missing-signer', 'destination-tamper', 'destination-quorum-tamper'];
const recoveryAttemptControls = ['recovery-wrong-reveal', 'recovery-missing-signer',
  'recovery-wrong-signer', 'recovery-missing-fresh', 'recovery-tamper',
  'recovery-representative-tamper', 'recovery-registry-tamper', 'recovery-quorum-tamper',
  'recovery-forged-digest', 'recovery-accept'];
const recoveredControls = ['recovery-replay', 'recovery-old-controller',
  'recovery-new-controller-update'];
const retirementStartControls = ['retirement-insufficient', 'retirement-quorum-takeover',
  'retirement-quorum-redirect', 'retirement-wrong-custody', 'retirement-controller',
  'retirement-quorum'];
const disable = (ids, disabled) => ids.forEach(id => { element(id).disabled = disabled; });

function renderReconciliation() {
  const body = element('reconciliation');
  body.replaceChildren();
  const missing = lifecycleCorpusReceipt.identities.filter(identity => !(identity in correspondence));
  if (missing.length) throw new Error(`public journey mapping missing: ${missing.join(', ')}`);
  for (const identity of lifecycleCorpusReceipt.identities) {
    const [behaviour, control] = correspondence[identity];
    const row = document.createElement('tr');
    row.dataset.identity = identity;
    row.innerHTML = `<td><code>${identity}</code></td><td>${behaviour}</td><td><code>${control}</code></td><td class="${observed.has(identity) ? 'covered' : ''}">${observed.has(identity) ? 'observed in this journey' : 'wired; not attempted yet'}</td>`;
    body.append(row);
  }
}

function mark(...identities) {
  identities.forEach(identity => observed.add(identity));
  renderReconciliation();
}

function renderState() {
  const summary = element('state-summary');
  const active = record();
  const destination = active?.fixture.paymentDestination;
  summary.replaceChildren();
  for (const text of [
    `registry: ${current.registry.config.registry}`,
    `name: alice / key 42`,
    `state: ${resolutionLabel()}`,
    `application: ${active ? `UTxO ${active.outputId}` : 'none'}`,
    `destination: ${destination === null || destination === undefined ? 'none' : `raw ${destination.bytes.length}-byte address`}`,
    `controller: ${active ? `raw ${active.fixture.controlAddress.bytes.length}-byte address${keyLost ? ' (marked lost)' : ''}` : 'none'}`,
  ]) {
    const item = document.createElement('span');
    item.textContent = text;
    summary.append(item);
  }
  const pending = current.registry.requests.find(request => request.operation === 'update');
  const hasActiveRecord = active !== undefined;
  disable(destinationControls, !hasActiveRecord || keyLost);
  disable(recoveryAttemptControls, !hasActiveRecord || !keyLost || recoveredController);
  disable(recoveredControls, !hasActiveRecord || !recoveredController);
  disable(retirementStartControls, !hasActiveRecord);
  element('recovery-key-loss').disabled = !hasActiveRecord || keyLost || recoveredController;
  element('retirement-fold').disabled = !pending;
  element('retirement-withdraw').disabled = !pending;
  element('retirement-replay').disabled = !pending || lastRetirementAction === null;
  element('retirement-reregister').disabled = resolutionLabel() !== 'retired';
  const initialized = initializationState.consumedSeeds.includes(namingConsumerBinding.canonicalSeed);
  element('initialization-canonical').disabled = initialized;
  element('initialization-repeat').disabled = !initialized;
  element('state-guidance').textContent = pending
    ? 'Retirement is pending. Use the explicit withdrawal or replay refusal, fold to Over, or Reset to active alice.'
    : resolutionLabel() === 'retired'
      ? 'The name is retired / Over. Active-name controls are unavailable. Reset to active alice to start another journey.'
      : keyLost
        ? 'The current key is marked lost. Use a recovery attempt or Reset to active alice.'
        : recoveredController
          ? 'Recovery completed. The replay, old-controller, and new-controller controls are now available.'
          : 'Active-name controls are available. Mark the current key lost to enable recovery attempts.';
}

function show(label, verdict, details = {}) {
  const output = element('result');
  output.className = verdict.accepted ? 'pass' : 'refused';
  output.textContent = JSON.stringify({action: label, verdict,
    ...(lastExecutingWitness === null ? {} : {executingWitness: lastExecutingWitness}), ...details}, null, 2);
  renderState();
}

function reset(label = 'Reset to active alice.') {
  current = activeState();
  keyLost = false;
  recoveredController = false;
  lastExecutingWitness = null;
  lastRetirementAction = null;
  show(label, {accepted: true}, {observation: resolutionLabel()});
}

function executeLifecycle(action) {
  lastExecutingWitness = lifecycleExecutingWitness(action);
  if (lastExecutingWitness === null) throw new Error(`missing lifecycle executing witness: ${JSON.stringify(action)}`);
  return lifecycleStep(current, action);
}

function expect(label, verdict, expectedReason, identities = []) {
  if (expectedReason === null && !verdict.accepted) throw new Error(`${label}: ${verdict.reason}`);
  if (expectedReason !== null && (verdict.accepted || verdict.reason !== expectedReason)) {
    throw new Error(`${label}: expected ${expectedReason}, got ${JSON.stringify(verdict)}`);
  }
  mark(...identities);
  show(label, verdict, {corpusIdentities: identities});
  return verdict;
}

function maintain(candidate, signers, label, expectedReason = null, identities = [],
  commit = expectedReason === null, quorumSigners = []) {
  const before = clone(current);
  const beforeRecord = record();
  const action = {maintain: {source: beforeRecord.outputId, successor: freshId(), key: beforeRecord.key,
    candidate: clone(candidate), witnesses: {
      requiredSigners: clone(signers), quorumSigners: clone(quorumSigners),
    }}};
  const verdict = expect(label, executeLifecycle(action), expectedReason, identities);
  if (verdict.accepted && commit) {
    current = verdict.value.state;
    const afterRecord = record();
    if (before.registry.config.registry !== current.registry.config.registry
        || beforeRecord.key !== afterRecord.key
        || !equal(beforeRecord.representative, afterRecord.representative)
        || !equal(beforeRecord.fixture.controlAddress, afterRecord.fixture.controlAddress)
        || !equal(beforeRecord.fixture.nextControlCommitment, afterRecord.fixture.nextControlCommitment)
        || !equal(beforeRecord.fixture.retirementQuorum, afterRecord.fixture.retirementQuorum)) {
      throw new Error('maintenance preservation invariant');
    }
    renderState();
  }
}

element('reset-active').onclick = () => reset();
element('destination-clear').onclick = () => {
  const candidate = {...clone(record().fixture), paymentDestination: null};
  maintain(candidate, [record().fixture.controlAddress], 'Clear payment destination', null, ['LM01-maintenance-accepts']);
};
element('destination-set').onclick = () => {
  const candidate = {...clone(record().fixture), paymentDestination: clone(destinationAddress)};
  maintain(candidate, [record().fixture.controlAddress], 'Set payment destination', null, ['LM01-maintenance-accepts']);
};
element('destination-replace').onclick = () => {
  const candidate = {...clone(record().fixture), paymentDestination: clone(otherControllerAddress)};
  maintain(candidate, [record().fixture.controlAddress], 'Replace payment destination', null, ['LM01-maintenance-accepts']);
};
element('destination-missing-signer').onclick = () => {
  const candidate = {...clone(record().fixture), paymentDestination: null};
  maintain(candidate, [], 'Destination change without controller signer', 'controller-signature', ['LM02-maintenance-unauthorized-refused']);
};
element('destination-tamper').onclick = () => {
  const candidate = {...clone(record().fixture), nextControlCommitment: nextCommitment(otherControllerAddress)};
  maintain(candidate, [record().fixture.controlAddress], 'Destination action with commitment tamper', 'destination-field-preservation', ['LM03-maintenance-field-tamper-refused']);
};
element('destination-quorum-tamper').onclick = () => {
  const candidate = {...clone(record().fixture), retirementQuorum: clone(otherFixture.retirementQuorum)};
  maintain(candidate, [record().fixture.controlAddress], 'Destination action with quorum alteration',
    'destination-field-preservation', ['LM04-maintenance-quorum-alteration-refused']);
};

element('recovery-key-loss').onclick = () => {
  reset('Recovery journey reset: alice is active.');
  keyLost = true;
  recoveredController = false;
  const hashInput = nextControlHashInput(nextControllerAddress);
  const computedCommitment = nextCommitment(nextControllerAddress);
  if (!equal(computedCommitment, record().fixture.nextControlCommitment)) {
    throw new Error('published next-controller commitment mismatch');
  }
  show('Current controller marked unavailable; no model state was changed.', {accepted: true}, {
    nextStep: 'reveal committed next controller',
    hashInputBytes: hashInput.length,
    computedCommitment,
  });
};

function recoveryAction({revealed = nextControllerAddress, signer = nextControllerAddress,
  candidate = null, candidateRegistry = current.registry.config.registry,
  candidateRepresentative = record().representative, extra = {}} = {}) {
  const beforeRecord = record();
  return {recover: {source: beforeRecord.outputId, successor: freshId(), key: beforeRecord.key,
    revealed: clone(revealed), candidateRegistry, candidateRepresentative: clone(candidateRepresentative),
    candidate: clone(candidate ?? {...beforeRecord.fixture,
      controlAddress: nextControllerAddress, nextControlCommitment: freshControllerCommitment}),
    witnesses: {requiredSigners: signer === null ? [] : [clone(signer)], quorumSigners: []}, ...extra}};
}

element('recovery-wrong-reveal').onclick = () => expect('Wrong recovery reveal', executeLifecycle(
  recoveryAction({revealed: otherControllerAddress, signer: otherControllerAddress,
    candidate: {...record().fixture, controlAddress: otherControllerAddress, nextControlCommitment: freshControllerCommitment}})),
'recovery-commitment', ['LR02-wrong-reveal-refused']);
element('recovery-missing-signer').onclick = () => expect('Recovery without next-key signer', executeLifecycle(
  recoveryAction({signer: null})), 'recovery-required-signer', ['LR03-missing-recovery-signer-refused']);
element('recovery-wrong-signer').onclick = () => expect('Correct reveal with wrong payment-key signer', executeLifecycle(
  recoveryAction({signer: controllerAddress})), 'recovery-required-signer', ['LR07-wrong-payment-key-signer-refused']);
element('recovery-missing-fresh').onclick = () => expect('Recovery without a fresh next commitment', executeLifecycle(
  recoveryAction({candidate: {...record().fixture, controlAddress: nextControllerAddress}})),
'recovery-fresh-commitment', ['LR08-missing-fresh-commitment-refused']);
element('recovery-tamper').onclick = () => expect('Recovery with payment destination tamper', executeLifecycle(
  recoveryAction({candidate: {...record().fixture, paymentDestination: null,
    controlAddress: nextControllerAddress, nextControlCommitment: freshControllerCommitment}})),
'recovery-field-preservation', []);
element('recovery-representative-tamper').onclick = () => expect('Recovery with representative substitution', executeLifecycle(
  recoveryAction({candidateRepresentative: {...record().representative, policy: record().representative.policy + 1}})),
'recovery-representative', ['LR09-representative-tamper-refused']);
element('recovery-registry-tamper').onclick = () => expect('Recovery with registry substitution', executeLifecycle(
  recoveryAction({candidateRegistry: current.registry.config.registry + 1})),
'recovery-registry', ['LR10-registry-tamper-refused']);
element('recovery-quorum-tamper').onclick = () => expect('Recovery with quorum substitution', executeLifecycle(
  recoveryAction({candidate: {...record().fixture, controlAddress: nextControllerAddress,
    nextControlCommitment: freshControllerCommitment, retirementQuorum: clone(otherFixture.retirementQuorum)}})),
'recovery-field-preservation', ['LR11-quorum-tamper-refused']);
element('recovery-forged-digest').onclick = () => expect('Forged caller-supplied digest', executeLifecycle(
  recoveryAction({revealed: otherControllerAddress, signer: otherControllerAddress,
    candidate: {...record().fixture, controlAddress: otherControllerAddress, nextControlCommitment: freshControllerCommitment},
    extra: {computed: clone(record().fixture.nextControlCommitment)}})), 'lifecycle-action', ['LR06-forged-public-digest-refused']);
element('recovery-accept').onclick = () => {
  const verdict = expect('Recover with committed next controller', executeLifecycle(recoveryAction()), null,
    ['LR01-recovery-accepts']);
  current = verdict.value.state;
  keyLost = false;
  recoveredController = true;
  renderState();
};
element('recovery-replay').onclick = () => expect('Replay consumed next-controller reveal', executeLifecycle(
  recoveryAction({revealed: nextControllerAddress, signer: nextControllerAddress,
    candidate: {...record().fixture, controlAddress: nextControllerAddress, nextControlCommitment: freshControllerCommitment}})),
'recovery-commitment', ['LR04-recovery-replay-refused']);
element('recovery-old-controller').onclick = () => {
  const candidate = {...clone(record().fixture), paymentDestination: clone(otherControllerAddress)};
  maintain(candidate, [controllerAddress], 'Old controller after recovery', 'controller-signature', ['LR05-old-controller-refused']);
};
element('recovery-new-controller-update').onclick = () => {
  const candidate = {...clone(record().fixture), paymentDestination: clone(freshControllerAddress)};
  maintain(candidate, [record().fixture.controlAddress], 'Destination update by recovered controller', null, ['LM01-maintenance-accepts']);
};

function retire(route, quorumSigners, label, expectedReason = null, identities = []) {
  const beforeRecord = record();
  const requestId = freshId();
  const request = retirementRequest(current, beforeRecord, application(), requestId);
  const action = {retire: {source: beforeRecord.outputId, requestId, key: beforeRecord.key, request, route,
    witnesses: {requiredSigners: route === 'controller' ? [clone(beforeRecord.fixture.controlAddress)] : [],
      quorumSigners: clone(quorumSigners)}}};
  const verdict = expect(label, executeLifecycle(action), expectedReason, identities);
  if (verdict.accepted) {
    lastRetirementAction = clone(action);
    current = verdict.value.state;
    if (resolutionLabel() !== 'pending') throw new Error('retirement must be pending before completion');
    mark('LO01-retirement-pending-visible');
    show(label, verdict, {corpusIdentities: identities, observation: 'pending', completion: 'not run'});
  }
}

element('retirement-insufficient').onclick = () => {
  const quorum = record().fixture.retirementQuorum;
  retire('quorum', quorum.members.slice(0, Math.max(0, quorum.threshold - 1)), 'Insufficient retirement quorum',
    'retirement-authorization', ['LT03-insufficient-quorum-refused']);
};
element('retirement-quorum-takeover').onclick = () => {
  const quorum = record().fixture.retirementQuorum;
  const candidate = {...clone(record().fixture), controlAddress: clone(otherControllerAddress)};
  maintain(candidate, [], 'Retirement quorum attempts control takeover', 'controller-signature',
    ['LT05-quorum-control-takeover-refused'], false, quorum.members.slice(0, quorum.threshold));
};
element('retirement-quorum-redirect').onclick = () => {
  const quorum = record().fixture.retirementQuorum;
  const candidate = {...clone(record().fixture), paymentDestination: clone(otherControllerAddress)};
  maintain(candidate, [], 'Retirement quorum attempts payment redirection', 'controller-signature',
    ['LT06-quorum-payment-redirection-refused'], false, quorum.members.slice(0, quorum.threshold));
};
element('retirement-wrong-custody').onclick = () => {
  const beforeRecord = record();
  const requestId = freshId();
  const request = retirementRequest(current, beforeRecord, application(), requestId);
  request.held = {...request.held, policy: request.held.policy + 1};
  const action = {retire: {source: beforeRecord.outputId, requestId, key: beforeRecord.key,
    request, route: 'controller', witnesses: {requiredSigners: [clone(beforeRecord.fixture.controlAddress)], quorumSigners: []}}};
  expect('Retirement with wrong representative custody', executeLifecycle(action), 'retirement-request',
    ['LT08-wrong-retirement-custody-refused']);
};
element('retirement-controller').onclick = () => retire('controller', [], 'Queue retirement with controller', null,
  ['LT01-controller-retirement-accepts']);
element('retirement-quorum').onclick = () => {
  const quorum = record().fixture.retirementQuorum;
  retire('quorum', quorum.members.slice(0, quorum.threshold), 'Queue retirement with quorum and no controller signer', null,
    ['LT02-quorum-retirement-accepts']);
};
element('retirement-withdraw').onclick = () => {
  const pending = current.registry.requests.find(request => request.operation === 'update');
  expect('Withdraw queued retirement', executeLifecycle({withdrawRetirement: {requestId: pending.id}}),
    'retirement-withdrawal-refused', ['LT07-retirement-withdrawal-refused']);
};
element('retirement-replay').onclick = () => expect('Replay retirement initiation',
  executeLifecycle(clone(lastRetirementAction)), 'naming-record-unavailable', ['LT09-retirement-replay-refused']);
element('retirement-fold').onclick = () => {
  const pending = current.registry.requests.find(request => request.operation === 'update');
  const verdict = expect('Permissionless retirement fold', executeLifecycle(
    {completeRetirement: {requestId: pending.id}}), null, ['LT04-retirement-completes']);
  current = verdict.value.state;
  if (resolutionLabel() !== 'retired') throw new Error('retirement completion must resolve retired');
  mark('LO02-retirement-over-visible');
  show('Permissionless retirement fold', verdict, {observation: 'retired / Over'});
};
element('retirement-reregister').onclick = () => {
  const queued = queueClaim(current, {spelling: 'alice', fixture: clone(aliceFixture), accepted: true});
  const verdict = queued.accepted ? foldRequest(queued.value.state, queued.requestId) : queued;
  expect('Re-register alice after Over', verdict, 'occupied-key', ['LX01-re-registration-after-over-refused']);
};
element('retirement-reset').onclick = () => reset('Retirement journey reset for the other authorization route.');

const canonicalAttempt = () => ({sourceRevision: cardanoKeriRevision, seed: namingConsumerBinding.canonicalSeed,
  seedConsumed: true, registry: namingConsumerBinding.registry,
  applicationPolicy: namingConsumerBinding.applicationPolicy,
  representativePolicy: namingConsumerBinding.representativePolicy,
  validatorScript: namingConsumerBinding.validatorScript});
function initialize(label, attempt, expectedReason, identities, commit = false) {
  const shape = initializeConsumer(namingConsumerBinding, attempt);
  const verdict = initializeConsumerTransition(namingConsumerBinding, initializationState, attempt);
  lastExecutingWitness = null;
  expect(label, verdict, expectedReason, identities);
  if (verdict.accepted && commit) initializationState = verdict.state;
  show(label, verdict, {shapePredicate: shape, consumedSeeds: initializationState.consumedSeeds});
}
element('initialization-canonical').onclick = () => initialize('Canonical consumer initialization', canonicalAttempt(), null,
  ['LI01-canonical-initialization-accepts'], true);
element('initialization-repeat').onclick = () => initialize('Repeat consumed canonical seed', canonicalAttempt(),
  'canonical-seed-consumed', ['LI06-repeated-canonical-seed-refused']);
element('initialization-alternate').onclick = () => initialize('Alternate seed initialization',
  {...canonicalAttempt(), seed: namingConsumerBinding.canonicalSeed + 1}, 'canonical-seed', ['LI02-alternate-seed-refused']);
element('initialization-rival').onclick = () => initialize('Second seed rival registry initialization',
  {...canonicalAttempt(), seed: namingConsumerBinding.canonicalSeed + 1, registry: namingConsumerBinding.registry + 1},
  'canonical-seed', ['LI03-second-seed-rival-registry-refused']);
element('initialization-registry').onclick = () => initialize('Substituted registry initialization',
  {...canonicalAttempt(), registry: namingConsumerBinding.registry + 1}, 'registry-authenticity',
  ['LI04-substituted-registry-refused']);
element('initialization-policy').onclick = () => initialize('Substituted application policy initialization',
  {...canonicalAttempt(), applicationPolicy: namingConsumerBinding.applicationPolicy + 1}, 'application-policy',
  ['LI05-substituted-policy-refused']);
element('initialization-representative-policy').onclick = () => initialize('Substituted representative policy initialization',
  {...canonicalAttempt(), representativePolicy: namingConsumerBinding.representativePolicy + 1},
  'representative-policy', ['LI07-substituted-representative-policy-refused']);
element('initialization-validator').onclick = () => initialize('Substituted validator script initialization',
  {...canonicalAttempt(), validatorScript: namingConsumerBinding.validatorScript + 1},
  'validator-script', ['LI08-substituted-validator-script-refused']);

const wireRow = identity => lifecycleCorpus.wire.find(row => row.id === identity);
element('wire-roundtrip').onclick = () => {
  const row = wireRow('WD01-four-field-roundtrip');
  const encoded = encodeNamingDatum(aliceFixture);
  const bytes = serialiseNamingDatum(aliceFixture);
  const decoded = decodeNamingDatum(encoded);
  const decodedBytes = deserialiseNamingDatum(bytes);
  if (!equal(namingDatumShape(encoded), {outerIndex: 0, innerIndex: 0, arity: 4}) || !equal(bytes, row.expectedBytes)
      || !equal(decoded, aliceFixture) || !equal(decodedBytes, aliceFixture)
      || !equal(serialiseNamingDatum(decodedBytes), bytes)) throw new Error('four-field wire roundtrip');
  lastExecutingWitness = null;
  mark('WD01-four-field-roundtrip');
  show('Encode, decode, and re-encode exact four-field datum bytes', {accepted: true},
    {shape: namingDatumShape(encoded), byteLength: bytes.length});
};
element('wire-hash').onclick = () => {
  if (extractNamingDatum({datumHash: [1, 2, 3]}) !== null) throw new Error('datum hash accepted');
  lastExecutingWitness = null;
  mark('WD02-datum-hash-refused');
  show('Datum-hash attachment', {accepted: false, reason: 'inline-datum-required'});
};
element('wire-two-destinations').onclick = () => {
  if (decodeNamingDatum(twoDestinationDatum(aliceFixture)) !== null) throw new Error('two destinations accepted');
  lastExecutingWitness = null;
  mark('WD03-two-destinations-refused');
  show('Two destination fields', {accepted: false, reason: 'four-field-datum-shape'});
};

element('replay-status').textContent = `PASS · ${lifecycleCorpusReceipt.executed}/${lifecycleCorpusReceipt.discovered} exact Lean-derived lifecycle rows replayed`;
renderReconciliation();
reset();
window.lifecycleJourney = {correspondence, current: () => clone(current), observed: () => [...observed]};

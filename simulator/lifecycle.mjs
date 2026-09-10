// Executable adapter for Singular.NamingLifecycle. Lean owns the complete hash
// preimage contract; this module supplies BLAKE2b-256 for every canonical
// supported address and mirrors the lifecycle verdicts.
import {step, equal} from './core.mjs';
import {
  canonicalAddress, paymentKeyAddress, commitmentShape, foldRequest,
  demoRefundAddress, namingResolve, queueClaim, wellFormedFixture,
} from './naming.mjs';
import {
  decodeNamingDatum, deserialiseNamingDatum, encodeNamingDatum, extractNamingDatum,
  namingDatumShape, serialiseNamingDatum,
} from './naming-wire.mjs';

const fail = reason => { throw new Error(reason); };
const mask64 = (1n << 64n) - 1n;
const iv = [
  0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
  0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n,
];
const sigma = [
  [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15], [14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],
  [11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4], [7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8],
  [9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13], [2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9],
  [12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11], [13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10],
  [6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5], [10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0],
];
const rotr = (x, n) => ((x >> BigInt(n)) | (x << BigInt(64 - n))) & mask64;
const word = (block, offset) => {
  let value = 0n;
  for (let i = 0; i < 8; i++) value |= BigInt(block[offset + i] ?? 0) << BigInt(8 * i);
  return value;
};
const putWord = value => Array.from({length: 8}, (_, i) => Number((value >> BigInt(8 * i)) & 255n));

/** Unkeyed BLAKE2b with a 32-byte digest, over an arbitrary byte array. */
export function blake2b256(input) {
  if (!Array.isArray(input) || !input.every(x => Number.isInteger(x) && x >= 0 && x < 256)) fail('hash-input');
  const h = [...iv];
  h[0] ^= 0x01010020n;
  const blocks = Math.max(1, Math.ceil(input.length / 128));
  for (let blockIndex = 0; blockIndex < blocks; blockIndex++) {
    const offset = blockIndex * 128;
    const chunk = input.slice(offset, offset + 128);
    const final = blockIndex === blocks - 1;
    const total = BigInt(Math.min(input.length, offset + chunk.length));
    const m = Array.from({length: 16}, (_, i) => word(chunk, i * 8));
    const v = [...h, ...iv];
    v[12] ^= total & mask64;
    v[13] ^= total >> 64n;
    if (final) v[14] ^= mask64;
    const g = (a, b, c, d, x, y) => {
      v[a] = (v[a] + v[b] + x) & mask64; v[d] = rotr(v[d] ^ v[a], 32);
      v[c] = (v[c] + v[d]) & mask64; v[b] = rotr(v[b] ^ v[c], 24);
      v[a] = (v[a] + v[b] + y) & mask64; v[d] = rotr(v[d] ^ v[a], 16);
      v[c] = (v[c] + v[d]) & mask64; v[b] = rotr(v[b] ^ v[c], 63);
    };
    for (let round = 0; round < 12; round++) {
      const s = sigma[round % 10];
      g(0,4,8,12,m[s[0]],m[s[1]]); g(1,5,9,13,m[s[2]],m[s[3]]);
      g(2,6,10,14,m[s[4]],m[s[5]]); g(3,7,11,15,m[s[6]],m[s[7]]);
      g(0,5,10,15,m[s[8]],m[s[9]]); g(1,6,11,12,m[s[10]],m[s[11]]);
      g(2,7,8,13,m[s[12]],m[s[13]]); g(3,4,9,14,m[s[14]],m[s[15]]);
    }
    for (let i = 0; i < 8; i++) h[i] = (h[i] ^ v[i] ^ v[i + 8]) & mask64;
  }
  return h.flatMap(putWord).slice(0, 32);
}

export const nextControlHashContract = Object.freeze({
  algorithm: 'BLAKE2b-256',
  domain: [...new TextEncoder().encode('singular/naming/next-control/v1')],
  separator: 0,
  digestBytes: 32,
});
export const nextControlHashInput = address => {
  if (!canonicalAddress(address)) fail('noncanonical-address');
  return [...nextControlHashContract.domain, nextControlHashContract.separator, ...address.bytes];
};
export const nextCommitment = address => ({digest: blake2b256(nextControlHashInput(address))});

const findRecord = (state, key) => state.records.find(record => record.key === key) ?? fail('naming-record-unavailable');
const findApplication = (state, record) => state.registry.applications.find(output => output.id === record.outputId) ?? fail('application-unavailable');
const fresh = (state, id) => !state.registry.used.includes(id);
const exactFields = (value, fields) => equal(Object.keys(value ?? {}).sort(), [...fields].sort());
const authorized = (fixture, witnesses) => paymentKeyAddress(fixture.controlAddress)
  && witnesses.requiredSigners.some(signer => equal(signer, fixture.controlAddress));
const quorumAuthorized = (fixture, witnesses) => {
  const signed = fixture.retirementQuorum.members.filter(member =>
    witnesses.quorumSigners.some(signer => equal(signer, member)));
  const distinct = new Set(signed.map(member => JSON.stringify(member))).size;
  return fixture.retirementQuorum.threshold > 0 && distinct >= fixture.retirementQuorum.threshold;
};
const validateOutput = (state, record, application, source, successor) => {
  if (source !== record.outputId || application.id !== source || application.key !== record.key
      || !equal(application.output.representative, record.representative) || application.output.quantity !== 1) fail('application-custody');
  if (!fresh(state, successor)) fail('utxo-id-reuse');
};
const replaceOutput = (state, record, application, successor, fixture) => {
  const registry = {...state.registry,
    requests: state.registry.requests.filter(request => request.id !== record.outputId),
    applications: [{...application, id: successor}, ...state.registry.applications.filter(output => output.id !== record.outputId)],
    used: [successor, ...state.registry.used],
  };
  return {...state, registry, records: [{...record, outputId: successor, fixture}, ...state.records.filter(other => other.key !== record.key)]};
};

export const retirementRequest = (state, record, application, requestId) => ({
  id: requestId, operation: 'update',
  proposal: {registry: state.registry.config.registry, key: record.key,
    applicationPolicy: state.registry.config.applicationPolicy, refundAddress: 0, initial: application.output,
    scope: [state.registry.entries.find(entry => entry.key === record.key)?.incarnation ?? 0]},
  token: null, held: record.representative, destination: state.registry.config.requestAddress,
  authenticatedOrigin: true,
});

const cancellationRefund = refundAddress => ({destination: refundAddress, value: 0});
const cancellationAsset = (state, requestId, refundAddress) => ({
  policy: state.registry.config.applicationPolicy,
  name: {withdraw: {registry: state.registry.config.registry, request: requestId,
    refund: cancellationRefund(refundAddress)}},
});

function transition(state, action) {
  const kind = Object.keys(action ?? {})[0], data = action?.[kind];
  if (!data || Object.keys(action).length !== 1) fail('lifecycle-action');
  if (kind === 'maintain') {
    const record = findRecord(state, data.key), application = findApplication(state, record);
    validateOutput(state, record, application, data.source, data.successor);
    if (!authorized(record.fixture, data.witnesses)) fail('controller-signature');
    if (!equal(data.candidate.controlAddress, record.fixture.controlAddress)
        || !equal(data.candidate.nextControlCommitment, record.fixture.nextControlCommitment)
        || !equal(data.candidate.retirementQuorum, record.fixture.retirementQuorum)) fail('destination-field-preservation');
    if (!wellFormedFixture(data.candidate)) fail('invalid-fixture');
    return {state: replaceOutput(state, record, application, data.successor, data.candidate), logical: []};
  }
  if (kind === 'recover') {
    if (!exactFields(data, ['source', 'successor', 'key', 'revealed', 'candidateRegistry',
      'candidateRepresentative', 'candidate', 'witnesses'])) fail('lifecycle-action');
    const record = findRecord(state, data.key), application = findApplication(state, record);
    validateOutput(state, record, application, data.source, data.successor);
    if (data.candidateRegistry !== state.registry.config.registry) fail('recovery-registry');
    if (!equal(data.candidateRepresentative, record.representative)) fail('recovery-representative');
    if (!paymentKeyAddress(data.revealed)) fail('recovery-payment-key');
    const computed = nextCommitment(data.revealed);
    if (!commitmentShape(computed)) fail('recovery-hash-shape');
    if (!equal(computed, record.fixture.nextControlCommitment)) fail('recovery-commitment');
    if (!data.witnesses.requiredSigners.some(signer => equal(signer, data.revealed))) fail('recovery-required-signer');
    if (!equal(data.candidate.controlAddress, data.revealed)
        || !equal(data.candidate.paymentDestination, record.fixture.paymentDestination)
        || !equal(data.candidate.retirementQuorum, record.fixture.retirementQuorum)) fail('recovery-field-preservation');
    if (!commitmentShape(data.candidate.nextControlCommitment)
        || equal(data.candidate.nextControlCommitment, record.fixture.nextControlCommitment)) fail('recovery-fresh-commitment');
    if (!wellFormedFixture(data.candidate)) fail('invalid-fixture');
    return {state: replaceOutput(state, record, application, data.successor, data.candidate), logical: []};
  }
  if (kind === 'retire') {
    const record = findRecord(state, data.key), application = findApplication(state, record);
    validateOutput(state, record, application, data.source, data.requestId);
    const permitted = data.route === 'controller' ? authorized(record.fixture, data.witnesses)
      : data.route === 'quorum' && quorumAuthorized(record.fixture, data.witnesses);
    if (!permitted) fail('retirement-authorization');
    if (!equal(data.request, retirementRequest(state, record, application, data.requestId))) fail('retirement-request');
    const result = step(state.registry, {release: {source: data.source, request: data.request,
      evidence: {source: data.source, request: data.request, accepted: true, conforms: true},
      witness: {applicationMint: false, applicationSpend: true, nativeSpend: false, representativeMint: false}}});
    if (!result.accepted) fail(result.reason);
    return {state: {...state, registry: result.value.state, records: state.records.filter(other => other.key !== data.key)}, logical: result.value.logical};
  }
  if (kind === 'cancelClaim') {
    if (!exactFields(data, ['requestId', 'refundAddress'])) fail('lifecycle-action');
    const request = state.registry.requests.find(candidate => candidate.id === data.requestId)
      ?? fail('request-unavailable');
    if (request.operation !== 'insert') fail('cancellation-insert-only');
    if (data.refundAddress !== request.proposal.refundAddress) fail('withdraw-refund-address');
    const result = step(state.registry, {withdraw: {request: data.requestId,
      asset: cancellationAsset(state, data.requestId, data.refundAddress),
      refund: cancellationRefund(data.refundAddress),
      witness: {applicationMint: false, applicationSpend: false, nativeSpend: true,
        representativeMint: false}}});
    if (!result.accepted) fail(result.reason);
    return {state: {...state, registry: result.value.state,
      claims: state.claims.filter(claim => claim.requestId !== data.requestId)},
    logical: result.value.logical};
  }
  if (kind === 'completeRetirement') {
    const request = state.registry.requests.find(candidate => candidate.id === data.requestId) ?? fail('request-unavailable');
    if (request.operation !== 'update') fail('retirement-update-only');
    const representative = {registry: state.registry.config.registry, key: request.proposal.key,
      policy: state.registry.config.representativePolicy, assetScope: request.proposal.scope[0]};
    const result = step(state.registry, {fold: {items: [{request: data.requestId, outputId: 0, output: null}],
      mint: [{asset: representative, quantity: -1}], actionNet: [],
      witness: {applicationMint: false, applicationSpend: false, nativeSpend: true, representativeMint: true}}});
    if (!result.accepted) fail(result.reason);
    return {state: {...state, registry: result.value.state}, logical: result.value.logical};
  }
  if (kind === 'withdrawRetirement') {
    const request = state.registry.requests.find(candidate => candidate.id === data.requestId) ?? fail('request-unavailable');
    if (request.operation !== 'update') fail('retirement-update-only');
    fail('retirement-withdrawal-refused');
  }
  fail('lifecycle-action');
}

export function lifecycleStep(state, action) {
  try { return {accepted: true, value: transition(state, action)}; }
  catch (error) { return {accepted: false, reason: error.message}; }
}

const emptyExecutionWitness = () => ({applicationMint: false, applicationSpend: false,
  nativeSpend: false, representativeMint: false, seedSpend: false, authenticatedRead: false,
  requiredSigners: [], quorumSigners: []});

export function lifecycleExecutingWitness(action) {
  const witness = emptyExecutionWitness();
  const kind = Object.keys(action ?? {})[0];
  if (['maintain', 'recover', 'retire'].includes(kind)) return {...witness, applicationSpend: true,
    requiredSigners: action[kind].witnesses.requiredSigners,
    quorumSigners: action[kind].witnesses.quorumSigners};
  if (kind === 'cancelClaim') return {...witness, nativeSpend: true};
  if (kind === 'completeRetirement') return {...witness, nativeSpend: true, representativeMint: true};
  if (kind === 'withdrawRetirement') return witness;
  return null;
}

export const cardanoKeriRevision = '14a64a4681d3e429fab5877062b5c476c2a4bfe2';
export {demoRefundAddress};
export const namingConsumerBinding = Object.freeze({sourceRevision: cardanoKeriRevision, canonicalSeed: 400,
  registry: 1, applicationPolicy: 7, representativePolicy: 8, validatorScript: 12});
export function initializeConsumer(binding, attempt) {
  if (attempt.sourceRevision !== binding.sourceRevision) return {accepted: false, reason: 'source-revision'};
  if (attempt.seed !== binding.canonicalSeed || attempt.seedConsumed !== true) return {accepted: false, reason: 'canonical-seed'};
  for (const [field, reason] of [['registry','registry-authenticity'], ['applicationPolicy','application-policy'],
    ['representativePolicy','representative-policy'], ['validatorScript','validator-script']]) {
    if (attempt[field] !== binding[field]) return {accepted: false, reason};
  }
  return {accepted: true};
}

export function initializeConsumerTransition(binding, state, attempt) {
  const shape = initializeConsumer(binding, attempt);
  if (!shape.accepted) return shape;
  if (state.consumedSeeds.includes(attempt.seed)) return {accepted: false, reason: 'canonical-seed-consumed'};
  return {accepted: true, state: {consumedSeeds: [attempt.seed, ...state.consumedSeeds]}};
}

export function initializationExecutingWitness(binding, state, attempt) {
  return {...emptyExecutionWitness(),
    seedSpend: initializeConsumerTransition(binding, state, attempt).accepted};
}

export const lifecycleCorpusIdentities = Object.freeze([
  'LC01-cancellation-stored-refund-accepts', 'LC02-cancellation-redirect-refused',
  'LC03-insert-attestation-cancellation-refused', 'LC04-folded-claim-cancellation-refused',
  'LC06-cancellation-replay-refused',
  'LI01-canonical-initialization-accepts', 'LI02-alternate-seed-refused',
  'LI03-second-seed-rival-registry-refused', 'LI04-substituted-registry-refused',
  'LI05-substituted-policy-refused', 'LI06-repeated-canonical-seed-refused',
  'LI07-substituted-representative-policy-refused', 'LI08-substituted-validator-script-refused',
  'LM01-maintenance-accepts', 'LM02-maintenance-unauthorized-refused',
  'LM03-maintenance-field-tamper-refused', 'LM04-maintenance-quorum-alteration-refused',
  'LO01-retirement-pending-visible',
  'LO02-retirement-over-visible', 'LR01-recovery-accepts',
  'LR02-wrong-reveal-refused', 'LR03-missing-recovery-signer-refused',
  'LR04-recovery-replay-refused', 'LR05-old-controller-refused',
  'LR06-forged-public-digest-refused', 'LR07-wrong-payment-key-signer-refused',
  'LR08-missing-fresh-commitment-refused', 'LR09-representative-tamper-refused',
  'LR10-registry-tamper-refused', 'LR11-quorum-tamper-refused',
  'LT01-controller-retirement-accepts',
  'LT02-quorum-retirement-accepts', 'LT03-insufficient-quorum-refused',
  'LT04-retirement-completes', 'LX01-re-registration-after-over-refused',
  'LT05-quorum-control-takeover-refused', 'LT06-quorum-payment-redirection-refused',
  'LT07-retirement-withdrawal-refused', 'LT08-wrong-retirement-custody-refused',
  'LT09-retirement-replay-refused',
  'WD01-four-field-roundtrip', 'WD02-datum-hash-refused', 'WD03-two-destinations-refused',
]);

function checkWireRow(row) {
  if (row.id === 'WD01-four-field-roundtrip') {
    const encoded = encodeNamingDatum(row.fixture);
    const decoded = decodeNamingDatum(encoded);
    const encodedBytes = serialiseNamingDatum(row.fixture);
    const decodedBytes = deserialiseNamingDatum(row.expectedBytes);
    return equal(encoded, row.encoded) && equal(decoded, row.decoded)
      && equal(decoded === null ? null : encodeNamingDatum(decoded), row.reencoded)
      && equal(encodedBytes, row.encodedBytes) && equal(encodedBytes, row.expectedBytes)
      && equal(decodedBytes, row.decodedBytes)
      && equal(decodedBytes === null ? null : serialiseNamingDatum(decodedBytes), row.reencodedBytes)
      && deserialiseNamingDatum(row.malformedBytes) === null && row.malformedResult === null
      && equal(namingDatumShape(encoded), row.shape)
      && equal(row.shape, {outerIndex: 0, innerIndex: 0, arity: 4});
  }
  if (row.id === 'WD02-datum-hash-refused') {
    return extractNamingDatum(row.attachment) === null && row.result === null;
  }
  if (row.id === 'WD03-two-destinations-refused') {
    return decodeNamingDatum(row.encoded) === null && row.result === null;
  }
  return false;
}

/** Replay the single Lean-produced lifecycle corpus through public adapters. */
export function checkLifecycleCorpus(corpus) {
  const sections = ['steps', 'resolutions', 'initializations', 'registrations', 'wire'];
  if (corpus?.schema !== 'singular-naming-lifecycle-corpus-v1'
      || !sections.every(section => Array.isArray(corpus[section]) && corpus[section].length > 0)) fail('zero lifecycle corpus');
  const rows = sections.flatMap(section => corpus[section]);
  const ids = rows.map(row => row.id);
  if (!equal([...ids].sort(), [...lifecycleCorpusIdentities].sort()) || new Set(ids).size !== ids.length) fail('lifecycle corpus identity');
  let executed = 0;
  for (const row of corpus.steps) {
    if (!equal(lifecycleStep(row.before, row.action), row.result)) fail(`lifecycle-corpus/${row.id}`);
    if (!equal(lifecycleExecutingWitness(row.action), row.executingWitness)) fail(`lifecycle-witness/${row.id}`);
    executed++;
  }
  for (const row of corpus.resolutions) {
    if (!equal(namingResolve(row.before, row.spelling, row.authenticated), row.expected)) fail(`lifecycle-corpus/${row.id}`);
    if (!equal({...emptyExecutionWitness(), authenticatedRead: row.authenticated}, row.executingWitness)) fail(`lifecycle-witness/${row.id}`);
    executed++;
  }
  for (const row of corpus.initializations) {
    if (!equal(initializeConsumer(row.binding, row.attempt), row.shapeResult)) fail(`lifecycle-shape/${row.id}`);
    if (!equal(initializeConsumerTransition(row.binding, row.before, row.attempt), row.result)) fail(`lifecycle-corpus/${row.id}`);
    if (!equal(initializationExecutingWitness(row.binding, row.before, row.attempt), row.executingWitness)) fail(`lifecycle-witness/${row.id}`);
    executed++;
  }
  for (const row of corpus.registrations) {
    const queue = queueClaim(row.before, {spelling: row.spelling, fixture: row.fixture, accepted: row.accepted});
    if (!equal(queue, row.queueResult)) fail(`lifecycle-corpus/${row.id}/queue`);
    const fold = queue.accepted ? foldRequest(queue.value.state, queue.requestId) : queue;
    if (!equal(fold, row.foldResult)) fail(`lifecycle-corpus/${row.id}/fold`);
    if (!equal({...emptyExecutionWitness(), applicationMint: true, nativeSpend: true,
      representativeMint: true}, row.executingWitness)) fail(`lifecycle-witness/${row.id}`);
    executed++;
  }
  for (const row of corpus.wire) {
    if (!checkWireRow(row)) fail(`lifecycle-corpus/${row.id}`);
    executed++;
  }
  if (executed !== lifecycleCorpusIdentities.length) fail('lifecycle corpus denominator');
  return {discovered: ids.length, executed, identities: ids};
}

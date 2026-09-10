// Exact transcription of Singular.Naming — the first-release naming profile.
// This is an unaccepted candidate surface: certification proves allowed request
// and initial construction only. The demo spelling table is a frozen finite-model
// fixture, not a name standard. `spellingKey` refuses unknown spellings by
// returning no key (null); queueClaim refuses them with `unknown-spelling`.
// Extra `invalid-shape/*` refusals are runtime limits on the untyped boundary,
// mirroring the Lean type system's guarantees for claims, records and fixtures.
// Delete, release, reuse and maintenance transitions are refused with
// `naming-no-delete`; uniqueness is decided only when a certified Insert folds.
import {initial, step, resolve, inspect, replay, checkCorpus, view, equal} from './core.mjs';

const namingFail = reason => { throw new Error(reason); };

export const demoSpellings = [['alice', 42]];
export const aliceKey = 42;
export const demoDestination = 50, demoDatum = 100, demoValue = 20;
export const spellingKey = spelling => {
  if (typeof spelling !== 'string') namingFail('invalid-shape/naming.spelling');
  const hit = demoSpellings.find(([s]) => s === spelling);
  return hit ? hit[1] : null;
};

const nat = x => Number.isSafeInteger(x) && x >= 0;
const exactObject = (x, keys) => x && typeof x === 'object' && !Array.isArray(x)
  && equal(Object.keys(x).sort(), [...keys].sort());
const bytesShape = xs => Array.isArray(xs) && xs.every(x => nat(x) && x < 256);
const credential = x => x === 'paymentKey' || x === 'script';
export const addressShape = a => exactObject(a, ['bytes', 'form', 'network', 'paymentCredential', 'paymentHash', 'stakeCredential', 'stakeHash'])
  && bytesShape(a.bytes) && (a.form === 'enterprise' || a.form === 'base') && nat(a.network)
  && credential(a.paymentCredential) && bytesShape(a.paymentHash)
  && (a.stakeCredential === null || credential(a.stakeCredential)) && bytesShape(a.stakeHash);
const credentialOffset = c => c === 'paymentKey' ? 0 : 1;
export function encodeAddress(a) {
  if (!addressShape(a) || a.network >= 16 || a.paymentHash.length !== 28) return null;
  if (a.form === 'enterprise') {
    if (a.stakeCredential !== null || a.stakeHash.length !== 0) return null;
    return [(6 + credentialOffset(a.paymentCredential)) * 16 + a.network, ...a.paymentHash];
  }
  if (a.stakeCredential === null || a.stakeHash.length !== 28) return null;
  return [(credentialOffset(a.paymentCredential) + 2 * credentialOffset(a.stakeCredential)) * 16 + a.network,
    ...a.paymentHash, ...a.stakeHash];
}
export function decodeAddress(bytes) {
  if (!bytesShape(bytes) || bytes.length === 0) return null;
  const [header, ...payload] = bytes, kind = Math.floor(header / 16), network = header % 16;
  if ((kind === 6 || kind === 7) && payload.length === 28) return {bytes: [...bytes], form: 'enterprise', network,
    paymentCredential: kind === 6 ? 'paymentKey' : 'script', paymentHash: payload, stakeCredential: null, stakeHash: []};
  if (kind < 4 && payload.length === 56) return {bytes: [...bytes], form: 'base', network,
    paymentCredential: kind % 2 === 0 ? 'paymentKey' : 'script', paymentHash: payload.slice(0, 28),
    stakeCredential: kind < 2 ? 'paymentKey' : 'script', stakeHash: payload.slice(28)};
  return null;
}
export const canonicalAddress = a => addressShape(a) && equal(decodeAddress(a.bytes), a) && equal(encodeAddress(a), a.bytes);
export const paymentKeyAddress = a => canonicalAddress(a) && a.paymentCredential === 'paymentKey';
const address = start => ({bytes: [97, ...Array.from({length: 28}, (_, i) => start + i)], form: 'enterprise', network: 1,
  paymentCredential: 'paymentKey', paymentHash: Array.from({length: 28}, (_, i) => start + i), stakeCredential: null, stakeHash: []});
export const controllerAddress = address(1), nextControllerAddress = address(29), freshControllerAddress = address(57),
  destinationAddress = address(85), otherControllerAddress = address(113);
export const nextControllerCommitment = {digest: [194,219,76,247,78,175,65,208,95,243,240,210,186,25,12,72,45,189,40,94,86,21,171,104,133,192,82,134,196,194,60,190]};
export const freshControllerCommitment = {digest: [21,97,193,91,73,128,133,127,176,110,74,179,92,201,188,236,175,9,11,10,168,189,239,25,246,51,21,101,163,51,32,79]};
export const commitmentShape = c => exactObject(c, ['digest']) && bytesShape(c.digest) && c.digest.length === 32;
const repShape = r => r && typeof r === 'object' && !Array.isArray(r)
  && exactObject(r, ['registry', 'key', 'policy', 'assetScope'])
  && ['registry', 'key', 'policy', 'assetScope'].every(k => nat(r[k]));
const quorumShape = q => q && typeof q === 'object' && !Array.isArray(q)
  && exactObject(q, ['members', 'threshold'])
  && Array.isArray(q.members) && q.members.every(member => bytesShape(member) && member.length === 28)
  && nat(q.threshold) && q.threshold > 0
  && q.threshold <= new Set(q.members.map(member => JSON.stringify(member))).size;
const fixtureShape = f => f && typeof f === 'object' && !Array.isArray(f)
  && exactObject(f, ['paymentDestination', 'controlAddress', 'nextControlCommitment', 'retirementQuorum'])
  && (f.paymentDestination === null || canonicalAddress(f.paymentDestination))
  && paymentKeyAddress(f.controlAddress) && commitmentShape(f.nextControlCommitment) && quorumShape(f.retirementQuorum);
const claimShape = c => c && typeof c === 'object' && !Array.isArray(c)
  && exactObject(c, ['requestId', 'spelling', 'key', 'fixture'])
  && nat(c.requestId) && typeof c.spelling === 'string' && nat(c.key) && fixtureShape(c.fixture);
const recordShape = r => r && typeof r === 'object' && !Array.isArray(r)
  && exactObject(r, ['outputId', 'key', 'representative', 'fixture'])
  && nat(r.outputId) && nat(r.key) && repShape(r.representative) && fixtureShape(r.fixture);
function validateNaming(state) {
  if (!exactObject(state, ['registry', 'claims', 'records'])) namingFail('invalid-shape/naming.state');
  replay(state.registry, []);
  if (!Array.isArray(state.claims) || !state.claims.every(claimShape)) namingFail('invalid-shape/naming.claims');
  if (!Array.isArray(state.records) || !state.records.every(recordShape)) namingFail('invalid-shape/naming.records');
}

export const wellFormedFixture = f => fixtureShape(f)
  && (f.paymentDestination === null || !equal(f.paymentDestination, f.controlAddress));
export const quorumKeyHash = start => Array.from({length: 28}, (_, index) => start + index);
export const aliceFixture = {paymentDestination: destinationAddress, controlAddress: controllerAddress,
  nextControlCommitment: nextControllerCommitment,
  retirementQuorum: {members: [quorumKeyHash(1), quorumKeyHash(29), quorumKeyHash(57)], threshold: 2}};
export const otherFixture = {paymentDestination: null, controlAddress: otherControllerAddress,
  nextControlCommitment: nextControllerCommitment,
  retirementQuorum: {members: [quorumKeyHash(85), quorumKeyHash(113)], threshold: 2}};

const namingEntry = (s, k) => s.entries.find(e => e.key === k) ?? { key: k, value: null, incarnation: 0 };
const namingRepresentative = (s, k) => ({ registry: s.config.registry, key: k, policy: s.config.representativePolicy, assetScope: s.config.reuseIdentity ? 0 : namingEntry(s, k).incarnation });
const namingInsertAsset = p => ({ policy: p.applicationPolicy, name: { insert: { proposal: p } } });
const freshId = s => s.used.reduce((m, n) => Math.max(m, n), 0) + 1;

function migrateClaims(state, items, registry) {
  return {
    registry,
    claims: state.claims.filter(c => !items.some(i => i.request === c.requestId)),
    records: [...state.records, ...items.flatMap(i => {
      const c = state.claims.find(c => c.requestId === i.request);
      return c ? [{ outputId: i.outputId, key: c.key, representative: namingRepresentative(registry, c.key), fixture: c.fixture }] : [];
    })],
  };
}

export const namingInitial = () => ({ registry: initial(), claims: [], records: [] });

export function namingStep(state, action) {
  try {
    validateNaming(state);
    const kind = Object.keys(action ?? {})[0];
    if (kind === 'createInsert') {
      replay(state.registry, [action]);
      const r = step(state.registry, action);
      if (!r.accepted) return { accepted: false, reason: r.reason };
      const value = { state: { registry: r.value.state, claims: state.claims, records: state.records }, logical: r.value.logical };
      validateNaming(value.state);
      return { accepted: true, value };
    }
    if (kind === 'fold') {
      replay(state.registry, [action]);
      const terminal = action.fold.items.some(i => {
        const q = state.registry.requests.find(q => q.id === i.request);
        return q ? q.operation !== 'insert' : false;
      });
      if (terminal) return { accepted: false, reason: 'naming-no-delete' };
      const r = step(state.registry, action);
      if (!r.accepted) return { accepted: false, reason: r.reason };
      const value = { state: migrateClaims(state, action.fold.items, r.value.state), logical: r.value.logical };
      validateNaming(value.state);
      return { accepted: true, value };
    }
    return { accepted: false, reason: 'naming-no-delete' };
  } catch (e) {
    return { accepted: false, reason: e.message };
  }
}

export function namingQueueAction(state, key) {
  const output = { representative: namingRepresentative(state.registry, key), quantity: 1, destination: demoDestination, datum: demoDatum, value: demoValue };
  const proposal = { registry: state.registry.config.registry, key, applicationPolicy: state.registry.config.applicationPolicy, initial: output, scope: [namingEntry(state.registry, key).incarnation] };
  const asset = namingInsertAsset(proposal);
  return { createInsert: { request: { id: freshId(state.registry), operation: 'insert', proposal, token: asset, held: null, destination: state.registry.config.requestAddress, authenticatedOrigin: true }, approval: { asset, accepted: true, conforms: true }, witness: { applicationMint: true, applicationSpend: false, nativeSpend: false, representativeMint: false } } };
}

export function queueClaim(state, input) {
  try {
    validateNaming(state);
    if (!exactObject(input, ['spelling', 'fixture', 'accepted'])) namingFail('invalid-shape/naming.queue');
    const { spelling, fixture, accepted } = input;
    const key = spellingKey(spelling);
    if (key === null) return { accepted: false, reason: 'unknown-spelling' };
    if (!wellFormedFixture(fixture)) return { accepted: false, reason: 'invalid-fixture' };
    if (accepted !== true) return { accepted: false, reason: 'application-approval' };
    const id = freshId(state.registry);
    const r = namingStep(state, namingQueueAction(state, key));
    if (!r.accepted) return { accepted: false, reason: r.reason };
    const ns = r.value.state;
    const certifiedFixture = structuredClone(fixture);
    const next = { ...ns, claims: [...ns.claims, { requestId: id, spelling, key, fixture: certifiedFixture }] };
    validateNaming(next);
    return { accepted: true, requestId: id, value: { state: next } };
  } catch (e) {
    return { accepted: false, reason: e.message };
  }
}

function namingFoldAction(state, requestId) {
  const r = state.registry.requests.find(q => q.id === requestId);
  if (!r) namingFail('request-unavailable');
  return { fold: { items: [{ request: requestId, outputId: freshId(state.registry), output: r.proposal.initial }], mint: [{ asset: namingRepresentative(state.registry, r.proposal.key), quantity: 1 }], actionNet: [], witness: { applicationMint: false, applicationSpend: false, nativeSpend: true, representativeMint: true } } };
}

export function foldRequest(state, requestId) {
  try {
    validateNaming(state);
    if (!nat(requestId)) namingFail('invalid-shape/naming.requestId');
    if (!state.claims.some(c => c.requestId === requestId)) return { accepted: false, reason: 'request-unavailable' };
    return namingStep(state, namingFoldAction(state, requestId));
  } catch (e) {
    return { accepted: false, reason: e.message };
  }
}

function resolveByKey(state, key, authenticated) {
  if (!nat(key)) namingFail('invalid-shape/naming.key');
  if (authenticated !== true) return 'unauthenticated';
  const record = state.records.find(r => r.key === key);
  if (record) return { status: 'active', fixture: record.fixture };
  if (namingEntry(state.registry, key).value === 'over') return 'retired';
  if (namingEntry(state.registry, key).value === 'active' || state.claims.some(c => c.key === key)) return 'pending';
  return 'absent';
}

export function namingResolve(state, spelling, authenticated) {
  try {
    validateNaming(state);
    if (typeof authenticated !== 'boolean') namingFail('invalid-shape/naming.authenticated');
    if (!authenticated) return 'unauthenticated';
    const key = spellingKey(spelling);
    if (key === null) return { error: 'unknown-spelling' };
    return resolveByKey(state, key, authenticated);
  } catch (e) {
    return { error: e.message };
  }
}

export function namingReplay(state, actions) {
  validateNaming(state);
  if (!Array.isArray(actions)) namingFail('invalid-shape/naming.actions');
  const records = [];
  let current = state;
  for (const action of actions) {
    const verdict = namingStep(current, action);
    records.push({ action, result: verdict });
    if (verdict.accepted) current = verdict.value.state;
  }
  return { state: current, records };
}

const namingApi = {
  namingInitial, spellingKey, queueClaim, foldRequest, namingStep, namingResolve,
  namingReplay, namingQueueAction, wellFormedFixture, aliceKey, demoSpellings,
};
const genericEngine = { initial, step, resolve, inspect, replay, checkCorpus, view };

// Profile selection: only the two labelled engines, never an implicit fallback.
export function selectProfile(profileId) {
  if (profileId === 'generic') return { id: 'generic', engine: genericEngine };
  if (profileId === 'm1-naming') return { id: 'm1-naming', engine: namingApi };
  namingFail('unknown-profile');
}

// Replay the Lean-authored naming corpus: every row must reproduce exactly.
export function checkNamingCorpus(corpus) {
  const sections = ['spellings', 'queues', 'folds', 'steps', 'resolves', 'replays'];
  if (!sections.every(s => Array.isArray(corpus[s]) && corpus[s].length)) namingFail('zero naming corpus');
  let executed = 0;
  const compare = (actual, expected, id) => {
    if (!equal(actual, expected)) namingFail(`naming-corpus/${id}`);
    executed++;
  };
  for (const row of corpus.spellings) compare(spellingKey(row.spelling), row.expected, row.id);
  for (const row of corpus.queues) compare(queueClaim(row.before, { spelling: row.spelling, fixture: row.fixture, accepted: row.accepted }), row.result, row.id);
  for (const row of corpus.folds) compare(foldRequest(row.before, row.requestId), row.result, row.id);
  for (const row of corpus.steps) compare(namingStep(row.before, row.action), row.result, row.id);
  for (const row of corpus.resolves) compare(namingResolve(row.before, row.spelling, row.authenticated), row.expected, row.id);
  for (const row of corpus.replays) compare(namingReplay(row.before, row.actions), row.expected, row.id);
  if (executed !== sections.reduce((n, s) => n + corpus[s].length, 0)) namingFail('naming corpus denominator');
  return { discovered: executed, executed };
}

const namingRow = (corpus, section, id) => corpus[section]?.find(row => row.id === id);
const property = (section, id, test, fault) => ({
  section,
  id,
  on: corpus => Boolean(namingRow(corpus, section, id)),
  test,
  fault,
});
const refusal = (section, id, reason) => property(
  section,
  id,
  corpus => {
    const row = namingRow(corpus, section, id);
    return row.result?.accepted === false && row.result.reason === reason;
  },
  corpus => { namingRow(corpus, section, id).result.reason = 'fabricated-violation'; },
);
const resolution = (id, expected) => property(
  'resolves',
  id,
  corpus => equal(namingRow(corpus, 'resolves', id).expected, expected),
  corpus => { namingRow(corpus, 'resolves', id).expected = 'fabricated-violation'; },
);

// One exact-name finite property row per naming declaration. The two equation
// theorems are explicit exhibits-only rows; every other finite consequent has
// a fabricated-result mutation used by the gate as a negative control.
export const namingChecks = {
  naming_delete_refused: refusal('steps', 'NS01-crafted-release-delete', 'naming-no-delete'),
  naming_approval_reserves_nothing: property('queues', 'NQ02-competing-claim-queues', corpus => {
    const state = namingRow(corpus, 'queues', 'NQ02-competing-claim-queues').result.value.state;
    return state.claims.length === 2 && state.records.length === 0 && state.registry.entries.length === 0;
  }, corpus => { namingRow(corpus, 'queues', 'NQ02-competing-claim-queues').result.value.state.claims = []; }),
  naming_absent_certified_insert_activates: property('folds', 'NF01-first-absent-key-fold', corpus => {
    const row = namingRow(corpus, 'folds', 'NF01-first-absent-key-fold');
    return row.result.accepted === true
      && row.result.value.state.registry.entries.some(entry => entry.key === aliceKey && entry.value === 'active')
      && row.result.value.state.registry.applications.length === 1;
  }, corpus => {
    const state = namingRow(corpus, 'folds', 'NF01-first-absent-key-fold').result.value.state.registry;
    state.entries.find(entry => entry.key === aliceKey).value = null;
  }),
  naming_occupied_key_refuses_duplicate: refusal('folds', 'NF02-competing-fold-occupied', 'occupied-key'),
  naming_fixture_fields_preserved_on_insert: property('folds', 'NF01-first-absent-key-fold', corpus => {
    const row = namingRow(corpus, 'folds', 'NF01-first-absent-key-fold');
    const item = row.result.value.state.records[0];
    const claim = row.before.claims.find(candidate => candidate.requestId === row.requestId);
    return Boolean(claim && item && item.key === claim.key && equal(item.fixture, claim.fixture));
  }, corpus => {
    namingRow(corpus, 'folds', 'NF01-first-absent-key-fold').result.value.state.records[0].fixture.nextControlCommitment.digest[0] ^= 1;
  }),
  naming_unauthenticated_resolve: resolution('NR01-unauthenticated-view', 'unauthenticated'),
  naming_payment_destination_distinct_from_control: property('queues', 'NQ01-alice-first-queues', corpus => {
    const first = namingRow(corpus, 'queues', 'NQ01-alice-first-queues').fixture;
    const other = namingRow(corpus, 'queues', 'NQ02-competing-claim-queues').fixture;
    return first.paymentDestination !== null && !equal(first.paymentDestination, first.controlAddress)
      && other.paymentDestination === null && wellFormedFixture(first) && wellFormedFixture(other);
  }, corpus => {
    const fixture = namingRow(corpus, 'queues', 'NQ01-alice-first-queues').fixture;
    fixture.paymentDestination = fixture.controlAddress;
  }),
  naming_step_create_insert: property('steps', 'NS10-unapproved-insert'),
  naming_step_fold_generic_when_all_insert: property('steps', 'NS12-fold-request-parity'),
  naming_step_refuses_other: refusal('steps', 'NS01-crafted-release-delete', 'naming-no-delete'),
  naming_queue_unknown_spelling_iff: refusal('queues', 'NQ04-unknown-spelling-refused', 'unknown-spelling'),
  naming_queue_malformed_fixture_iff: refusal('queues', 'NQ05-malformed-fixture-refused', 'invalid-fixture'),
  naming_queue_unapproved_refused: refusal('queues', 'NQ03-unapproved-refused', 'application-approval'),
  naming_resolve_unauthenticated_iff: resolution('NR01-unauthenticated-view', 'unauthenticated'),
  naming_resolve_active_iff: property('resolves', 'NR03-active-certified-fixture', corpus => {
    const row = namingRow(corpus, 'resolves', 'NR03-active-certified-fixture');
    const record = row.before.records.find(candidate => candidate.key === aliceKey);
    return Boolean(record && row.expected?.status === 'active' && equal(row.expected.fixture, record.fixture));
  }, corpus => { namingRow(corpus, 'resolves', 'NR03-active-certified-fixture').expected.fixture.controlAddress.bytes[0] ^= 16; }),
  naming_resolve_pending_iff: resolution('NR02-two-claims-pending', 'pending'),
  naming_resolve_absent_iff: resolution('NR04-absent-initial', 'absent'),
};

export function namingPropertyReport(ledger, corpus) {
  if (!Array.isArray(ledger) || ledger.length === 0) namingFail('zero naming property ledger');
  return ledger.map(declaration => {
    const short = declaration.name.split('.').at(-1);
    const check = namingChecks[short];
    if (!check || !check.on(corpus)) namingFail(`missing naming property exhibit/${short}`);
    const controlled = typeof check.test === 'function';
    return {
      name: declaration.name,
      status: `${declaration.status} / ${declaration.debt}`,
      coverage: controlled ? 'controlled-check' : 'exhibits-only',
      exhibits: [check.id],
      holds: controlled ? Boolean(check.test(corpus)) : null,
      notes: controlled
        ? 'Finite consequent check; a fabricated violating record is required to fail in the gate.'
        : 'Action exhibit only; the quantified equation is proved in Lean, not re-proved by JavaScript.',
    };
  });
}

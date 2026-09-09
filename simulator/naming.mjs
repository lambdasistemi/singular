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
const repShape = r => r && typeof r === 'object' && !Array.isArray(r)
  && ['registry', 'key', 'policy', 'assetScope'].every(k => nat(r[k]));
const quorumShape = q => q && typeof q === 'object' && !Array.isArray(q)
  && Array.isArray(q.members) && q.members.every(nat) && nat(q.threshold);
const fixtureShape = f => f && typeof f === 'object' && !Array.isArray(f)
  && (f.paymentDestination === null || nat(f.paymentDestination))
  && nat(f.controlAddress) && nat(f.nextControlCommitment) && quorumShape(f.retirementQuorum);
const claimShape = c => c && typeof c === 'object' && !Array.isArray(c)
  && nat(c.requestId) && typeof c.spelling === 'string' && nat(c.key) && fixtureShape(c.fixture);
const recordShape = r => r && typeof r === 'object' && !Array.isArray(r)
  && nat(r.key) && repShape(r.representative) && fixtureShape(r.fixture);
function validateNaming(state) {
  if (!state || typeof state !== 'object' || Array.isArray(state)) namingFail('invalid-shape/naming.state');
  if (!Array.isArray(state.claims) || !state.claims.every(claimShape)) namingFail('invalid-shape/naming.claims');
  if (!Array.isArray(state.records) || !state.records.every(recordShape)) namingFail('invalid-shape/naming.records');
}

export const wellFormedFixture = f => fixtureShape(f)
  && (f.paymentDestination === null || f.paymentDestination !== f.controlAddress);

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
      return c ? [{ key: c.key, representative: namingRepresentative(registry, c.key), fixture: c.fixture }] : [];
    })],
  };
}

export const namingInitial = () => ({ registry: initial(), claims: [], records: [] });

export function namingStep(state, action) {
  try {
    validateNaming(state);
    const kind = Object.keys(action ?? {})[0];
    if (kind === 'createInsert') {
      const r = step(state.registry, action);
      if (!r.accepted) return { accepted: false, reason: r.reason };
      return { accepted: true, value: { state: { registry: r.value.state, claims: state.claims, records: state.records }, logical: r.value.logical } };
    }
    if (kind === 'fold') {
      const terminal = action.fold.items.some(i => {
        const q = state.registry.requests.find(q => q.id === i.request);
        return q ? q.operation !== 'insert' : false;
      });
      if (terminal) return { accepted: false, reason: 'naming-no-delete' };
      const r = step(state.registry, action);
      if (!r.accepted) return { accepted: false, reason: r.reason };
      return { accepted: true, value: { state: migrateClaims(state, action.fold.items, r.value.state), logical: r.value.logical } };
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

export function queueClaim(state, { spelling, fixture, accepted }) {
  try {
    validateNaming(state);
    const key = spellingKey(spelling);
    if (key === null) return { accepted: false, reason: 'unknown-spelling' };
    if (!wellFormedFixture(fixture)) return { accepted: false, reason: 'invalid-fixture' };
    if (accepted !== true) return { accepted: false, reason: 'application-approval' };
    const id = freshId(state.registry);
    const r = namingStep(state, namingQueueAction(state, key));
    if (!r.accepted) return { accepted: false, reason: r.reason };
    const ns = r.value.state;
    return { accepted: true, requestId: id, value: { state: { ...ns, claims: [...ns.claims, { requestId: id, spelling, key, fixture }] } } };
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
  if (namingEntry(state.registry, key).value !== null || state.claims.some(c => c.key === key)) return 'pending';
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
  for (const row of corpus.resolves) compare(resolveByKey(row.before, row.key, row.authenticated), row.expected, row.id);
  for (const row of corpus.replays) compare(namingReplay(row.before, row.actions), row.expected, row.id);
  if (executed !== sections.reduce((n, s) => n + corpus[s].length, 0)) namingFail('naming corpus denominator');
  return { discovered: executed, executed };
}

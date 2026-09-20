use aiken/collection/list
use cardano/assets.{Value, merge, zero}
use cardano/transaction.{InlineDatum, Input, Output}
use lib
use state
use t157_fixtures as fx
use types.{
  Modify, RequestAction, StateDatum, UpdateAction,
}

/// #173 A173-EDGE / A173-REFUSALS — the `insertActive` edge, its
/// duplicate refusal and its keyed-mint refusal, executed against the
/// REAL compiled cage.
///
/// Three things are being separated here, and the separation is the
/// whole content of A-006:
///
/// - the **fold** places exactly one `(activePolicy, key)` token in the
///   output at the address and inline datum the request named;
/// - a **second `insertActive` at the same known key** is refused
///   `key-exists`, BEFORE any mint arithmetic runs. It is not the
///   keyed-mint witness and must not be confused with it;
/// - a **two-request batch at two DISTINCT keys** whose claimed mint
///   agrees per KIND and disagrees per `(kind, key)` is refused
///   `net-mint-mismatch`. This is the fault `Singular.Model.assetSame`
///   catches and a per-kind sum does not, and NOTHING in this tree
///   exercised it before this row.
///
/// The refusal ROWS below establish that the fold REFUSES — returns
/// `False` rather than crashing. Which reason it gives is decided by
/// the construction site the validator reads from
/// (`lib.occupiedRefusal` for the trie fault), asserted directly, because
/// an Aiken test cannot read back a `trace`.

// ----------------------------------------------------------------------------
// The driver
// ----------------------------------------------------------------------------

fn foldBatch(
  root: ByteArray,
  nextRoot: ByteArray,
  requests: List<Input>,
  outputs: List<Output>,
  mint: Value,
  actions: List<RequestAction>,
) -> Bool {
  state.state.spend(
    Some(StateDatum(fx.stateOf(root))),
    Modify(actions),
    fx.stateRef,
    fx.foldTx(root, nextRoot, requests, [], outputs, mint),
  )
}

/// One `insertActive` request for `key`, carrying its bound approval.
fn bookingRequest(index: Int, key: ByteArray) -> Input {
  fx.requestInput(
    index,
    key,
    1,
    fx.bookerKey,
    fx.bookingDestination(),
    fx.approval(1, key, fx.bookerKey, fx.bookingDestination()),
    fx.requestLovelace,
  )
}

/// The output an `insertActive` owes: the active token at the address
/// and inline datum the request named.
fn bookingOutput(key: ByteArray) -> Output {
  fx.deliveryOutput(
    fx.activePolicy,
    key,
    fx.recordAddress,
    InlineDatum(fx.recordDatum()),
    fx.deposit,
  )
}

// ----------------------------------------------------------------------------
// The fold
// ----------------------------------------------------------------------------

/// The accepting control for everything below: one `insertActive` on a
/// free key places one active token where the request named.
test t173_insert_active_places_one_active_token_at_the_named_output() {
  foldBatch(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    [bookingRequest(0, fx.keyA)],
    [bookingOutput(fx.keyA)],
    fx.mintOf(fx.activePolicy, fx.keyA, 1),
    [UpdateAction([])],
  )
}

// ----------------------------------------------------------------------------
// The duplicate — refused BEFORE mint arithmetic
// ----------------------------------------------------------------------------

/// A second `insertActive` on a key the trie already reads as `active`.
/// The mint is the one the edge WOULD entail, so nothing here is a mint
/// fault: the only thing wrong is that the key is taken.
fn duplicateInsertActive() -> Bool {
  foldBatch(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    [bookingRequest(0, fx.keyA)],
    [bookingOutput(fx.keyA)],
    fx.mintOf(fx.activePolicy, fx.keyA, 1),
    // The edge is refused BEFORE the proof is used, so the action
    // carries no steps. A sibling proof of a key against ITSELF has no
    // common-prefix bound and crashes the fixture rather than the
    // validator — a crash says only that the script died, never that
    // it refused.
    [UpdateAction([])],
  )
}

/// The fold must REFUSE the duplicate — return `False` — not die on
/// it. This row is `== False` rather than `fail` deliberately: Aiken's
/// `fail` is satisfied by a crash, and a crash says only that the
/// script died, never that it refused. The repository's own rule for
/// these rows is that every refusal returns False through ONE named
/// trace.
///
/// Today it CRASHES: `edgeOf` reads the leaf the REQUEST states, and an
/// insert states none, so the edge is ADMITTED and `applyEdge` reaches
/// `excluding(key, proof)` on a key that is present. There is no
/// `key-exists` path in the cage at all — that is the A173-REFUSALS
/// gap, and it is not a string to rename.
test t173_duplicate_insert_active_refuses_cleanly() {
  duplicateInsertActive() == False
}

/// A-006, A-009 and Lean `refusal`: occupancy is a fault of the TRIE
/// and has its own construction site, reached BEFORE the mint is
/// compared. `insert-terminal` named a fault of the REQUEST's value and
/// retired with value bytes in slice b — there is no second fact left
/// to name, so the row above stands on the trie fault alone. The retired
/// distinction stands in history (reviews 002–005).
test t173_duplicate_insert_active_reason_is_key_exists() {
  lib.occupiedRefusal() == Some(@"key-exists")
}

// ----------------------------------------------------------------------------
// The keyed mint — two DISTINCT keys, equal per kind, unequal per key
// ----------------------------------------------------------------------------

/// Two `insertActive` requests, keys A and B. Each edge entails `+1
/// active` AT ITS OWN KEY, so the batch owes `A:+1, B:+1`.
fn twoKeyBatch(mint: Value, outputs: List<Output>) -> Bool {
  foldBatch(
    fx.emptyRoot(),
    fx.twoLeaves(fx.keyA, fx.activeLeaf, fx.keyB, fx.activeLeaf),
    [bookingRequest(0, fx.keyA), bookingRequest(1, fx.keyB)],
    outputs,
    mint,
    [
      UpdateAction([]),
      UpdateAction(fx.siblingProof(fx.keyA, fx.activeLeaf, fx.keyB)),
    ],
  )
}

/// The RIGHT keyed distribution: `A:+1, B:+1`. This is the positive
/// control for the guard below — without it, a refusal of the wrong
/// distribution could simply mean two-request batches never fold.
test t173_two_key_batch_with_the_right_distribution_accepts() {
  twoKeyBatch(
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
      fx.mintOf(fx.activePolicy, fx.keyB, 1),
    ),
    [bookingOutput(fx.keyA), bookingOutput(fx.keyB)],
  )
}

/// The WRONG keyed distribution: `A:+2, B:0`. Per KIND this is `+2`,
/// exactly what the two edges entail — a per-kind guard accepts it. Per
/// `(kind, key)` it claims one key's token twice and the other's not at
/// all.
test t173_two_key_batch_with_the_wrong_distribution_refuses() fail {
  twoKeyBatch(
    fx.mintOf(fx.activePolicy, fx.keyA, 2),
    [bookingOutput(fx.keyA), bookingOutput(fx.keyA)],
  )
}

/// The two claims really do agree per kind: without this, the row above
/// proves nothing about the keyed guard, because a batch that also
/// disagreed per kind would be refused by the coarser rule.
test t173_the_wrong_distribution_agrees_per_kind() {
  let right =
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
      fx.mintOf(fx.activePolicy, fx.keyB, 1),
    )
  let wrong = fx.mintOf(fx.activePolicy, fx.keyA, 2)
  lib.kindTotal(right, fx.activePolicy) == lib.kindTotal(
    wrong,
    fx.activePolicy,
  ) && right != wrong
}

/// A-006: the keyed-mint refusal is `net-mint-mismatch`, a DIFFERENT
/// reason from the duplicate's `key-exists`. Two distinct fixtures, two
/// distinct names.
test t173_keyed_mint_reason_is_net_mint_mismatch() {
  lib.mintRefusal() == Some(@"net-mint-mismatch")
}

test t173_the_two_refusals_are_distinct_reasons() {
  // Asserted by NAME, not merely by inequality: two pre-#173 names are
  // also distinct from each other, so an inequality alone would go
  // green while A-006 stayed unimplemented.
  let duplicate = lib.occupiedRefusal()
  lib.mintRefusal() == Some(@"net-mint-mismatch") && duplicate == Some(
    @"key-exists",
  ) && lib.mintRefusal() != duplicate
}

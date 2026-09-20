use aiken/merkle_patricia_forestry as mpf
use cardano/assets.{Value}
use cardano/transaction.{InlineDatum, Input, Output}
use lib
use state
use t157_fixtures as fx
use types.{Modify, StateDatum, UpdateAction}

/// #177 I177-CHAIN — the `updateTerminal` edge (ordinal 3) against the
/// REAL compiled cage: the retirement that lands, and the four refusals
/// the Lean row names.
///
/// `Singular.Statements.update_terminal_transaction_row` states four
/// complements over an arbitrary state, each exhibited at the very state
/// of the accepting fold with one fact moved:
///
/// - a key the trie does not bind at all         -> `key-unknown`
/// - a key bound `Absent`                        -> `not-booked`
/// - a key bound `Terminal`                      -> `terminal-immutable`
/// - a key bound `Active` with no active witness
///   among the inputs                            -> `token-missing`
///
/// Every refusal row below is `== False`, never `fail`. Aiken's `fail`
/// is satisfied by a CRASH, and a crash says only that the script died —
/// never that it refused, and never which fact it refused for. The three
/// trie faults are exactly where the cage crashes today: `mpf.update`
/// dies inside the library on a proof that does not match the leaf, so
/// there is no attributable refusal to read. That is the I177-CHAIN gap,
/// and it is not a string to rename.
///
/// The refusal NAMES cannot be read back from an Aiken test — a `trace`
/// is not observable — so each one is asserted at the single
/// construction site the validator itself reads (`state.terminalFault`,
/// `state.tokenMissingRefusal`), the pattern #173 fixed for
/// `lib.occupiedRefusal` and `lib.mintRefusal`.
///
/// Each refusal carries an ACCEPTING control that repairs ONLY the named
/// bad fact: the same fold, the same builder, the same batch, with the
/// leaf moved back to `Active` or the witness input restored. Without
/// it, "refused" is consistent with "this shape never folds at all".

// ----------------------------------------------------------------------------
// The driver
// ----------------------------------------------------------------------------

/// One `updateTerminal` request at `key`, folded from `root` to
/// `nextRoot`, with `held` supplying the witness inputs and `extra` the
/// outputs beyond the continuation.
fn retire(
  root: ByteArray,
  nextRoot: ByteArray,
  key: ByteArray,
  held: List<Input>,
  extra: List<Output>,
  mint: Value,
) -> Bool {
  state.state.spend(
    Some(StateDatum(fx.stateOf(root))),
    Modify([UpdateAction([])]),
    fx.stateRef,
    fx.foldTx(
      root,
      nextRoot,
      [
        fx.requestInput(
          0,
          key,
          3,
          fx.bookerKey,
          fx.noDestination(),
          fx.approval(3, key, fx.bookerKey, fx.noDestination()),
          fx.requestLovelace,
        ),
      ],
      held,
      extra,
      mint,
    ),
  )
}

/// The witness the retirement burns: one `(activePolicy, key)` token,
/// held at the wallet the booking delivered it to.
fn witnessHeld() -> List<Input> {
  [fx.tokenInput(0, fx.activePolicy, fx.keyA)]
}

/// The exact keyed burn the edge entails.
fn theBurn() -> Value {
  fx.mintOf(fx.activePolicy, fx.keyA, -1)
}

/// The retirement fold, from a trie whose only leaf is `leaf` at `keyA`.
fn retireFrom(leaf: ByteArray) -> Bool {
  retire(
    fx.oneLeaf(fx.keyA, leaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    witnessHeld(),
    [],
    theBurn(),
  )
}

// ----------------------------------------------------------------------------
// The accepting control — every refusal below is measured against it
// ----------------------------------------------------------------------------

/// The row itself: an `Active` leaf, its own witness among the inputs,
/// the exact keyed `-1` mint, no carrier output, no signer. This is the
/// control for every refusal in this file: each one moves exactly one
/// fact away from here.
test t177_update_terminal_retires_the_active_token() {
  retireFrom(fx.activeLeaf)
}

// ----------------------------------------------------------------------------
// The three trie faults
// ----------------------------------------------------------------------------

/// The key is not in the trie at all. Lean: `key-unknown`.
fn unknownKey() -> Bool {
  retire(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    witnessHeld(),
    [],
    theBurn(),
  )
}

test t177_unknown_key_refuses_cleanly() {
  unknownKey() == False
}

/// The key is bound, but only witnessed `Absent` — nobody booked it.
/// Lean: `not-booked`.
test t177_absent_key_refuses_cleanly() {
  retireFrom(fx.absentLeaf) == False
}

/// The key is already `Terminal`: retirement completes, and a second
/// one builds no transaction. Lean: `terminal-immutable`.
test t177_terminal_key_refuses_cleanly() {
  retireFrom(fx.terminalLeaf) == False
}

/// The control the three rows above are measured against, restated at
/// the point of use: move the leaf BACK to `Active` and the same fold
/// lands. Without it each `== False` is consistent with "this fixture
/// never folds".
test t177_the_trie_fault_control_accepts() {
  retireFrom(fx.activeLeaf)
}

// ----------------------------------------------------------------------------
// The witness the burn destroys
// ----------------------------------------------------------------------------

/// An `Active` leaf whose active witness is not among the inputs: the
/// mint claims a burn with nothing to burn. Lean: `token-missing`.
fn withoutTheWitness() -> Bool {
  retire(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    [],
    [],
    theBurn(),
  )
}

test t177_without_the_active_witness_refuses_cleanly() {
  withoutTheWitness() == False
}

/// The control: restore the witness input and nothing else. The mint,
/// the leaves, the request and the batch are byte-identical.
test t177_the_witness_control_accepts() {
  retireFrom(fx.activeLeaf)
}

/// The burn must destroy THE key's own witness, not merely find some
/// input under the policy. Two witnesses ride in, the mint destroys
/// one, and one SURVIVES in an output — the active asset the Lean row
/// says no output carries (`kindCount t.state .active r.key = 0`).
/// Nothing here is a mint fault: the mint is the exact `-1` the edge
/// entails.
///
/// A-003: this row is not parked and not weakened. The guard that
/// refuses it is what made the state validator outgrow the boot
/// transaction, and the repair was to stop carrying that validator
/// inline at boot rather than to drop the guard.
fn leftoverCarrier() -> Bool {
  retire(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    [
      fx.tokenInput(0, fx.activePolicy, fx.keyA),
      fx.tokenInput(1, fx.activePolicy, fx.keyA),
    ],
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ],
    theBurn(),
  )
}

test t177_a_surviving_active_carrier_refuses_cleanly() {
  leftoverCarrier() == False
}

/// The control for the row above: drop the second witness and the
/// carrier output, change nothing else, and the retirement lands. The
/// difference is exactly the surviving token.
test t177_the_surviving_carrier_control_accepts() {
  retireFrom(fx.activeLeaf)
}


/// A witness for ANOTHER key is not this key's witness. `keyB`'s token
/// rides in and `keyA`'s does not; the mint is still `keyA: -1`.
fn wrongKeyWitness() -> Bool {
  retire(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    [fx.tokenInput(0, fx.activePolicy, fx.keyB)],
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyB,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ],
    theBurn(),
  )
}

test t177_another_keys_witness_refuses_cleanly() {
  wrongKeyWitness() == False
}

// ----------------------------------------------------------------------------
// The edge that shares the duty must not move
// ----------------------------------------------------------------------------

/// `deleteActive` (edge 5) also requires its witness among the inputs,
/// and its trace is `burn-from-input`. #177 moves edge 3 to its OWN duty
/// so that name keeps meaning what it meant; this row is the guard that
/// edge 5 still folds exactly as it did.
test t177_delete_active_still_folds() {
  state.state.spend(
    Some(StateDatum(fx.stateOf(fx.oneLeaf(fx.keyA, fx.activeLeaf)))),
    Modify([UpdateAction([])]),
    fx.stateRef,
    fx.foldTx(
      fx.oneLeaf(fx.keyA, fx.activeLeaf),
      fx.emptyRoot(),
      [
        fx.requestInput(
          0,
          fx.keyA,
          5,
          fx.bookerKey,
          fx.noDestination(),
          fx.approval(5, fx.keyA, fx.bookerKey, fx.noDestination()),
          fx.requestLovelace,
        ),
      ],
      witnessHeld(),
      [],
      theBurn(),
    ),
  )
}


// ----------------------------------------------------------------------------
// The reason each refusal gives
// ----------------------------------------------------------------------------

/// A-006's rule, applied to this edge: the reasons come from the
/// construction sites the validator itself reads, so a test asserting a
/// reason asserts the value the cage actually traces rather than a
/// helper nothing calls. An Aiken test cannot read a `trace` back, and
/// this is the repository's answer to that.
test t177_unknown_key_reason_is_key_unknown() {
  state.terminalFault(mpf.from_root(fx.emptyRoot()), fx.keyA, []) == Some(
    @"key-unknown",
  )
}

test t177_absent_key_reason_is_not_booked() {
  state.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.absentLeaf)),
    fx.keyA,
    [],
  ) == Some(@"not-booked")
}

test t177_terminal_key_reason_is_terminal_immutable() {
  state.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.terminalLeaf)),
    fx.keyA,
    [],
  ) == Some(@"terminal-immutable")
}

/// An `Active` leaf is NOT a trie fault: the retirement proceeds and the
/// witness duty decides. Without this row every answer could have become
/// a refusal and the accepting control would be the only thing left to
/// notice it.
test t177_an_active_leaf_is_not_a_trie_fault() {
  state.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.activeLeaf)),
    fx.keyA,
    [],
  ) == None
}

test t177_missing_witness_reason_is_token_missing() {
  state.tokenMissingRefusal() == @"token-missing"
}

/// The reasons are pairwise distinct, asserted by NAME rather than by
/// inequality: two pre-#177 names are also distinct from each other, so
/// an inequality alone would go green while this row stayed
/// unimplemented.
test t177_the_reasons_are_distinct_names() {
  and {
    state.terminalFault(mpf.from_root(fx.emptyRoot()), fx.keyA, []) == Some(
      @"key-unknown",
    ),
    state.terminalFault(
      mpf.from_root(fx.oneLeaf(fx.keyA, fx.absentLeaf)),
      fx.keyA,
      [],
    ) == Some(@"not-booked"),
    state.terminalFault(
      mpf.from_root(fx.oneLeaf(fx.keyA, fx.terminalLeaf)),
      fx.keyA,
      [],
    ) == Some(@"terminal-immutable"),
    state.tokenMissingRefusal() == @"token-missing",
    lib.occupiedRefusal() == Some(@"key-exists"),
    lib.mintRefusal() == Some(@"net-mint-mismatch"),
  }
}

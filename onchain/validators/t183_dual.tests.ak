use aiken/collection/list
use aiken/merkle_patricia_forestry as mpf
use cardano/assets.{Value, merge, zero}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output}
use lib
use state
use t157_fixtures as fx
use types.{Delete, Modify, Read, RequestAction, StateDatum, Update, UpdateAction}

/// #183 S20 — dual-codec preservation checkpoint (NOTE-002 standard).
///
/// The transient `EdgeRequest` carries the SAME value bytes as the old `Request`
/// plus the edge tag and no `tip`. For every other-edge G3 fixture (update,
/// delete, read) the SAME scenario — same trie, same key, same bytes — folds
/// under BOTH encodings with the SAME outcome and, for refusals, the SAME
/// trace compared as a value via `state.shapeTrace`. Non-read rows carry their
/// approval under both (well-formed); reads carry none (C4) and keep their
/// pairwise traces. One mutation per class shows the comparison able to
/// disagree. Receipted in `t183_dual_receipt.md` (path+sha256 in review-003).

fn foldOld(
  root: ByteArray,
  nextRoot: ByteArray,
  requests: List<Input>,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  actions: List<RequestAction>,
) -> Bool {
  state.state.spend(
    Some(StateDatum(fx.stateOf(root))),
    Modify(actions),
    fx.stateRef,
    fx.foldTx(root, nextRoot, requests, extraInputs, outputs, mint),
  )
}

fn foldOneOld(
  root: ByteArray,
  nextRoot: ByteArray,
  request: Input,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Bool {
  foldOld(root, nextRoot, [request], extraInputs, outputs, mint, [UpdateAction([])])
}

fn foldOneNew(
  root: ByteArray,
  nextRoot: ByteArray,
  request: Input,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Bool {
  foldOld(root, nextRoot, [request], extraInputs, outputs, mint, [UpdateAction([])])
}

// ----------------------------------------------------------------------------
// G3 pair 1: Update(0x00,0x00) on absent — `update-to-absent`
// ----------------------------------------------------------------------------

test t183_dual_update_absent_to_absent_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Update(fx.absentLeaf, fx.absentLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_absent_to_absent_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      2,
      Update(fx.absentLeaf, fx.absentLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_absent_to_absent_same_trace() {
  state.shapeTrace(Update(fx.absentLeaf, fx.absentLeaf), Some(lib.kindAbsent)) == @"update-to-absent"
}

// ----------------------------------------------------------------------------
// G3 pair 2: Update(0x01,0x00) on active — `update-to-absent`
// ----------------------------------------------------------------------------

test t183_dual_update_active_to_absent_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Update(fx.activeLeaf, fx.absentLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_active_to_absent_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      2,
      Update(fx.activeLeaf, fx.absentLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_active_to_absent_same_trace() {
  state.shapeTrace(Update(fx.activeLeaf, fx.absentLeaf), Some(lib.kindActive)) == @"update-to-absent"
}

// ----------------------------------------------------------------------------
// G3 pair 3: Update(0x00,0x02) on absent — `update-absent-to-terminal`
// ----------------------------------------------------------------------------

test t183_dual_update_absent_to_terminal_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Update(fx.absentLeaf, fx.terminalLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_absent_to_terminal_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      2,
      Update(fx.absentLeaf, fx.terminalLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_absent_to_terminal_same_trace() {
  state.shapeTrace(Update(fx.absentLeaf, fx.terminalLeaf), Some(lib.kindAbsent)) == @"update-absent-to-terminal"
}

// ----------------------------------------------------------------------------
// G3 pair 4: Update(0x01,0x01) on active — `update-active-to-active`
// ----------------------------------------------------------------------------

test t183_dual_update_active_to_active_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Update(fx.activeLeaf, fx.activeLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_active_to_active_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      2,
      Update(fx.activeLeaf, fx.activeLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_active_to_active_same_trace() {
  state.shapeTrace(Update(fx.activeLeaf, fx.activeLeaf), Some(lib.kindActive)) == @"update-active-to-active"
}

// ----------------------------------------------------------------------------
// G3 pair 5: Update(0x02,0x01) on terminal — `edge-from-terminal`
// ----------------------------------------------------------------------------

test t183_dual_update_from_terminal_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Update(fx.terminalLeaf, fx.activeLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_from_terminal_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      2,
      Update(fx.terminalLeaf, fx.activeLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_update_from_terminal_same_trace() {
  state.shapeTrace(Update(fx.terminalLeaf, fx.activeLeaf), Some(lib.kindTerminal)) == @"edge-from-terminal"
}

// ----------------------------------------------------------------------------
// G3 pair 6: Delete(0x02) on terminal — `edge-from-terminal`
// ----------------------------------------------------------------------------

test t183_dual_delete_terminal_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Delete(fx.terminalLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(5, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_delete_terminal_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      5,
      Delete(fx.terminalLeaf),
      fx.bookerKey,
      fx.noDestination(),
      fx.approval(5, fx.keyA, fx.bookerKey, fx.noDestination()),
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_delete_terminal_same_trace() {
  state.shapeTrace(Delete(fx.terminalLeaf), Some(lib.kindTerminal)) == @"edge-from-terminal"
}

// ----------------------------------------------------------------------------
// G3 pair 7: Read(0x00) on absent — `read-absent` (no approval, C4)
// ----------------------------------------------------------------------------

test t183_dual_read_absent_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Read(fx.absentLeaf),
      fx.bookerKey,
      fx.noDestination(),
      zero,
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_read_absent_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      6,
      Read(fx.absentLeaf),
      fx.bookerKey,
      fx.noDestination(),
      zero,
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_read_absent_same_trace() {
  state.shapeTrace(Read(fx.absentLeaf), Some(lib.kindAbsent)) == @"read-absent"
}

// ----------------------------------------------------------------------------
// G3 pair 8: Read(0x01) on active — `read-non-terminal` (no approval, C4)
// ----------------------------------------------------------------------------

test t183_dual_read_active_old_refuses() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Read(fx.activeLeaf),
      fx.bookerKey,
      fx.noDestination(),
      zero,
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_read_active_new_refuses() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      6,
      Read(fx.activeLeaf),
      fx.bookerKey,
      fx.noDestination(),
      zero,
      fx.requestValue,
    ),
    [],
    [],
    zero,
  ) == False
}

test t183_dual_read_active_same_trace() {
  state.shapeTrace(Read(fx.activeLeaf), Some(lib.kindActive)) == @"read-non-terminal"
}

// ----------------------------------------------------------------------------
// Valid controls: the same valid scenario accepts under both (per class)
// ----------------------------------------------------------------------------

fn updateActiveCustody() -> List<Input> {
  [fx.custodyInput(0, fx.keyA, fx.inserterAddress, fx.deposit)]
}

fn bookingOutputs() -> List<Output> {
  [
    fx.deliveryOutput(
      fx.activePolicy,
      fx.keyA,
      fx.recordAddress,
      InlineDatum(fx.recordDatum()),
      fx.deposit,
    ),
    fx.paymentOutput(fx.inserterAddress, fx.deposit),
  ]
}

test t183_dual_update_valid_old_accepts() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Update(fx.absentLeaf, fx.activeLeaf),
      fx.bookerKey,
      fx.bookingDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.bookingDestination()),
      fx.requestValue,
    ),
    updateActiveCustody(),
    bookingOutputs(),
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
    ),
  )
}

test t183_dual_update_valid_new_accepts() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      2,
      Update(fx.absentLeaf, fx.activeLeaf),
      fx.bookerKey,
      fx.bookingDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.bookingDestination()),
      fx.requestValue,
    ),
    updateActiveCustody(),
    bookingOutputs(),
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
    ),
  )
}

/// Mutation (update class): same valid bytes, wrong tag — new refuses
/// `edge-mismatch` while old accepts. The comparison can disagree.
test t183_dual_update_wrong_tag_disagrees() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      5,
      Update(fx.absentLeaf, fx.activeLeaf),
      fx.bookerKey,
      fx.bookingDestination(),
      fx.approval(2, fx.keyA, fx.bookerKey, fx.bookingDestination()),
      fx.requestValue,
    ),
    updateActiveCustody(),
    bookingOutputs(),
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
    ),
  ) == False
}

test t183_dual_delete_valid_old_accepts() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.emptyRoot(),
    fx.requestInput(
      0,
      fx.keyA,
      Delete(fx.absentLeaf),
      fx.inserterKey,
      fx.noDestination(),
      fx.approval(4, fx.keyA, fx.inserterKey, fx.noDestination()),
      fx.requestValue,
    ),
    updateActiveCustody(),
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
    fx.mintOf(fx.absentPolicy, fx.keyA, -1),
  )
}

test t183_dual_delete_valid_new_accepts() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.emptyRoot(),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      4,
      Delete(fx.absentLeaf),
      fx.inserterKey,
      fx.noDestination(),
      fx.approval(4, fx.keyA, fx.inserterKey, fx.noDestination()),
      fx.requestValue,
    ),
    updateActiveCustody(),
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
    fx.mintOf(fx.absentPolicy, fx.keyA, -1),
  )
}

/// Mutation (delete class): same valid bytes, wrong tag.
test t183_dual_delete_wrong_tag_disagrees() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      5,
      Delete(fx.absentLeaf),
      fx.inserterKey,
      fx.noDestination(),
      fx.approval(4, fx.keyA, fx.inserterKey, fx.noDestination()),
      fx.requestValue,
    ),
    updateActiveCustody(),
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
    fx.mintOf(fx.absentPolicy, fx.keyA, -1),
  ) == False
}

fn readOutputs() -> List<Output> {
  [
    fx.deliveryOutput(
      fx.terminalPolicy,
      fx.keyA,
      fx.bookerAddress,
      NoDatum,
      fx.deposit,
    ),
  ]
}

test t183_dual_read_valid_old_accepts() {
  foldOneOld(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.requestInput(
      0,
      fx.keyA,
      Read(fx.terminalLeaf),
      fx.bookerKey,
      fx.readDestination(),
      zero,
      fx.requestValue,
    ),
    [],
    readOutputs(),
    fx.mintOf(fx.terminalPolicy, fx.keyA, 1),
  )
}

test t183_dual_read_valid_new_accepts() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      6,
      Read(fx.terminalLeaf),
      fx.bookerKey,
      fx.readDestination(),
      zero,
      fx.requestValue,
    ),
    [],
    readOutputs(),
    fx.mintOf(fx.terminalPolicy, fx.keyA, 1),
  )
}

/// Mutation (read class): same valid bytes, wrong tag.
test t183_dual_read_wrong_tag_disagrees() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      2,
      Read(fx.terminalLeaf),
      fx.bookerKey,
      fx.readDestination(),
      zero,
      fx.requestValue,
    ),
    [],
    readOutputs(),
    fx.mintOf(fx.terminalPolicy, fx.keyA, 1),
  ) == False
}

// ----------------------------------------------------------------------------
// Terminal-edge class (#177 updateTerminal, edge 3) — extended set on the
// rebased main (NOTE-005 §3, NOTE-006 §3). SAME scenario both encodings,
// SAME outcome, SAME reason as a value (terminalFault / tokenMissingRefusal).
// Non-read rows carry approval(3, ..) under both (well-formed, C4).
// ----------------------------------------------------------------------------

fn terminalWitness() -> List<Input> {
  [fx.tokenInput(0, fx.activePolicy, fx.keyA)]
}

fn terminalBurn() -> Value {
  fx.mintOf(fx.activePolicy, fx.keyA, -1)
}

fn retireOld(
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
          Update(fx.activeLeaf, fx.terminalLeaf),
          fx.bookerKey,
          fx.noDestination(),
          fx.approval(3, key, fx.bookerKey, fx.noDestination()),
          fx.requestValue,
        ),
      ],
      held,
      extra,
      mint,
    ),
  )
}

fn retireNew(
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
        fx.edgeRequestInput(
          0,
          key,
          3,
          Update(fx.activeLeaf, fx.terminalLeaf),
          fx.bookerKey,
          fx.noDestination(),
          fx.approval(3, key, fx.bookerKey, fx.noDestination()),
          fx.requestValue,
        ),
      ],
      held,
      extra,
      mint,
    ),
  )
}

fn retireFromOld(leaf: ByteArray) -> Bool {
  retireOld(
    fx.oneLeaf(fx.keyA, leaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    terminalWitness(),
    [],
    terminalBurn(),
  )
}

fn retireFromNew(leaf: ByteArray) -> Bool {
  retireNew(
    fx.oneLeaf(fx.keyA, leaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    terminalWitness(),
    [],
    terminalBurn(),
  )
}

test t183_dual_update_terminal_valid_old_accepts() {
  retireFromOld(fx.activeLeaf)
}

test t183_dual_update_terminal_valid_new_accepts() {
  retireFromNew(fx.activeLeaf)
}

test t183_dual_update_terminal_unknown_old_refuses() {
  retireOld(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    terminalWitness(),
    [],
    terminalBurn(),
  ) == False
}

test t183_dual_update_terminal_unknown_new_refuses() {
  retireNew(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    terminalWitness(),
    [],
    terminalBurn(),
  ) == False
}

test t183_dual_update_terminal_absent_old_refuses() {
  retireFromOld(fx.absentLeaf) == False
}

test t183_dual_update_terminal_absent_new_refuses() {
  retireFromNew(fx.absentLeaf) == False
}

test t183_dual_update_terminal_terminal_old_refuses() {
  retireFromOld(fx.terminalLeaf) == False
}

test t183_dual_update_terminal_terminal_new_refuses() {
  retireFromNew(fx.terminalLeaf) == False
}

test t183_dual_update_terminal_no_witness_old_refuses() {
  retireOld(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    [],
    [],
    terminalBurn(),
  ) == False
}

test t183_dual_update_terminal_no_witness_new_refuses() {
  retireNew(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    [],
    [],
    terminalBurn(),
  ) == False
}

test t183_dual_update_terminal_survivor_old_refuses() {
  retireOld(
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
    terminalBurn(),
  ) == False
}

test t183_dual_update_terminal_survivor_new_refuses() {
  retireNew(
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
    terminalBurn(),
  ) == False
}

test t183_dual_update_terminal_wrong_key_old_refuses() {
  retireOld(
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
    terminalBurn(),
  ) == False
}

test t183_dual_update_terminal_wrong_key_new_refuses() {
  retireNew(
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
    terminalBurn(),
  ) == False
}

// The SAME reason as a value on both sides: the construction sites the
// validator itself reads (t177 A-006 pattern). The trie fault is
// encoding-independent; the fold outcome equality above shows the two
// codecs refuse together, these rows bind WHICH reason.

test t183_dual_update_terminal_unknown_reason_is_key_unknown() {
  state.terminalFault(mpf.from_root(fx.emptyRoot()), fx.keyA, []) == Some(
    @"key-unknown",
  )
}

test t183_dual_update_terminal_absent_reason_is_not_booked() {
  state.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.absentLeaf)),
    fx.keyA,
    [],
  ) == Some(@"not-booked")
}

test t183_dual_update_terminal_terminal_reason_is_terminal_immutable() {
  state.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.terminalLeaf)),
    fx.keyA,
    [],
  ) == Some(@"terminal-immutable")
}

test t183_dual_update_terminal_active_is_not_a_trie_fault() {
  state.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.activeLeaf)),
    fx.keyA,
    [],
  ) == None
}

test t183_dual_update_terminal_missing_witness_reason_is_token_missing() {
  state.tokenMissingRefusal() == @"token-missing"
}

fn retireNewWrongTag(root: ByteArray, nextRoot: ByteArray) -> Bool {
  state.state.spend(
    Some(StateDatum(fx.stateOf(root))),
    Modify([UpdateAction([])]),
    fx.stateRef,
    fx.foldTx(
      root,
      nextRoot,
      [
        fx.edgeRequestInput(
          0,
          fx.keyA,
          5,
          Update(fx.activeLeaf, fx.terminalLeaf),
          fx.bookerKey,
          fx.noDestination(),
          fx.approval(3, fx.keyA, fx.bookerKey, fx.noDestination()),
          fx.requestValue,
        ),
      ],
      terminalWitness(),
      [],
      terminalBurn(),
    ),
  )
}

/// Mutation (terminal class): same valid retirement bytes, wrong tag — old
/// accepts, new refuses `edge-mismatch`. The comparison can disagree.
test t183_dual_update_terminal_wrong_tag_disagrees() {
  retireNewWrongTag(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
  ) == False
}

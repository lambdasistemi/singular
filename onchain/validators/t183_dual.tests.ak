use aiken/collection/list
use cardano/assets.{Value, zero}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output}
use state
use t157_fixtures as fx
use types.{Delete, Modify, Read, RequestAction, StateDatum, Update, UpdateAction}

/// #183 S20 — dual-codec preservation checkpoint.
///
/// For exactly one commit both codecs exist: the old `Request` (`Operation` +
/// `tip`) and the new `EdgeRequest` (`edge`, no `tip`, `held >= state.tip`).
/// Every other-edge G3 fixture (update, delete, read) is folded under BOTH
/// encodings with identical verdicts (all refuse here), plus one valid
/// read-terminal control that accepts under both (proving the new codec is
/// not a trivial refuser). Receipted in `t183_dual_receipt.md`.
///
/// Mapping (old trace -> new trace, both refuse):
/// - update_absent_to_absent (`update-to-absent`) -> `no-approval` (new refuses
///   before the trie gate; the edge-shape gate is `edge-inadmissible` when an
///   approval is carried)
/// - update_active_to_absent (`update-to-absent`) -> `no-approval`
/// - update_absent_to_terminal (`update-absent-to-terminal`) -> `no-approval`
/// - update_active_to_active (`update-active-to-active`) -> `no-approval`
/// - update_from_terminal (`edge-from-terminal`) -> `no-approval`
/// - delete_terminal (`edge-from-terminal`) -> `no-approval`
/// - read_absent (`read-absent`) -> `edge-inadmissible` (admission skipped for
///   reads; the trie gate refuses)
/// - read_active (`read-non-terminal`) -> `edge-inadmissible`
/// G1 (`leaf-codec`) and `tip-mismatch` retire: the new wire carries no value
/// bytes and no tip field. MPFS proof failures keep their verdicts (the MPF
/// walk is reused via `canonicalOp`).

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
// Dual G3: each row folds the same trie under both encodings
// ----------------------------------------------------------------------------

/// Update(0x00,0x00) on absent refuses; new edge 5 (deleteActive) on absent
/// refuses (no approval carried; with approval it would be edge-inadmissible).
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
      zero,
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
    fx.edgeRequestInput(0, fx.keyA, 5, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

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
      zero,
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
    fx.edgeRequestInput(0, fx.keyA, 2, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

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
      zero,
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
    fx.edgeRequestInput(0, fx.keyA, 3, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

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
      zero,
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
    fx.edgeRequestInput(0, fx.keyA, 2, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

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
      zero,
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
    fx.edgeRequestInput(0, fx.keyA, 2, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

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
      zero,
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
    fx.edgeRequestInput(0, fx.keyA, 5, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

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
    fx.edgeRequestInput(0, fx.keyA, 6, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

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
    fx.edgeRequestInput(0, fx.keyA, 6, fx.bookerKey, fx.noDestination(), zero, fx.requestValue),
    [],
    [],
    zero,
  ) == False
}

// ----------------------------------------------------------------------------
// Valid control: read-terminal accepts under both (the new codec is live)
// ----------------------------------------------------------------------------

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

test t183_dual_read_terminal_old_accepts() {
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

test t183_dual_read_terminal_new_accepts() {
  foldOneNew(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.edgeRequestInput(
      0,
      fx.keyA,
      6,
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

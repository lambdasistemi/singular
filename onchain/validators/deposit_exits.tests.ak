use aiken/interval.{Interval}
use cardano/assets.{Value, merge, zero}
use cardano/transaction.{Input, Output, Transaction}
use registry_fixtures as fx
use state
use types.{Modify, Rejected, RequestAction, State, StateDatum, UpdateAction}

// ============================================================================
// The retired deposit exits: legacy folds are refused as folds with no member
// ============================================================================
//
// #253 owed the deposit of a fold that delivers nothing back to its owner:
// a fold on the `updateTerminal` edge paid the request's deposit to the
// booker, and a state-spending reject paid the owner the request less the tip.
// The accepted fold (`Economics/Fold.lean`) has neither: a registration donates
// its cost, a termination donates its held value less the tip, and there is no
// state-spending rejection and no deposit returned to the controller. A legacy
// edge-only request is no pending request, so a fold that holds only legacy
// requests has no member and the state refuses it as `empty-fold`.
//
// Each fixture below is a legacy fold the cage accepted before CP2 (the RED
// run of this module shows each accepted), kept as the refusal witness of the
// retired route. The authentic tagged requests refused for `Rejected` are in
// `tagged_fold.tests.ak`.
//
// Old to new map of the retired rows (their obligation no longer exists, or it
// is carried by the tagged fold):
//
// - `retirement_deposit_paid_to_the_owner_accepts`, `update_in_the_processing_window_accepts`,
//   `carrier_and_deposit_in_two_outputs_accepts`, `reject_refund_paid_to_the_owner_accepts`
//   and the other `*_accepts` rows are the valid tagged folds
//   (`tagged_fold_state_folds_*`);
// - the ten `retirement_deposit_*`, `two_deposits_*`, `carrier_*`,
//   `refund_*` and `reject_refund_*` refusals by `deposit-returned` have no
//   counterpart: no deposit is returned to a controller or an owner, so their
//   floors are retired with the obligation. What the fold owes instead is the
//   exact donation (`tagged_fold_*_refuses_a_tampered_donation`, the held
//   value less the tip) and the gross allocation of ordinary value
//   (`tagged_fold_refuses_ordinary_change_one_lovelace_short`);
// - `two_deposits_in_one_output_accepts` and `two_deposits_in_two_outputs_accepts`
//   are `tagged_fold_state_folds_two_terminations_with_aggregate_donation`;
// - the four `update_*_refuses_not_phase1` rows are the registration window
//   (`tagged_fold_registration_refuses_after_its_window`,
//   `..._in_the_retraction_window`) and the termination without a window
//   (`tagged_fold_state_folds_a_termination_after_both_windows`): a termination
//   folds in any window since CP2.

/// One `Modify` of the registry state, as the cage sees it.
type Scenario {
  pins: State,
  input: Input,
  actions: List<RequestAction>,
  tx: Transaction,
}

fn scenario(
  root: ByteArray,
  nextRoot: ByteArray,
  requests: List<Input>,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  actions: List<RequestAction>,
) -> Scenario {
  Scenario {
    pins: fx.stateOf(root),
    input: fx.stateInput(root),
    actions,
    tx: fx.foldTx(root, nextRoot, requests, extraInputs, outputs, mint),
  }
}

fn spend(s: Scenario) -> Bool {
  state.state.spend(
    Some(StateDatum(s.pins)),
    Modify(s.actions),
    s.input.output_reference,
    s.tx,
  )
}

fn refusalOf(s: Scenario) -> Option<String> {
  state.modifyRefusal(s.pins, s.actions, s.input, s.tx)
}

/// A legacy request of `owner` for `key` on a non-delivering edge, with its
/// approval and exactly `tip + deposit`.
fn ownedRequest(
  index: Int,
  key: ByteArray,
  edge: Int,
  owner: ByteArray,
) -> Input {
  fx.requestInput(
    index,
    key,
    edge,
    owner,
    fx.noDestination(),
    fx.approval(edge, key, owner, fx.noDestination()),
    fx.requestLovelace,
  )
}

fn activeWitness(index: Int, key: ByteArray) -> Input {
  fx.tokenInput(index, fx.activePolicy, key)
}

fn burnActive(key: ByteArray) -> Value {
  fx.mintOf(fx.activePolicy, key, -1)
}

fn paid(address: ByteArray, lovelace: Int) -> Output {
  fx.paymentOutput(address, lovelace)
}

/// The legacy `updateTerminal` fold of `keyA`, its deposit paid to the booker.
fn updateTerminal(outputs: List<Output>) -> Scenario {
  scenario(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    [ownedRequest(0, fx.keyA, 3, fx.bookerKey)],
    [activeWitness(0, fx.keyA)],
    outputs,
    burnActive(fx.keyA),
    [UpdateAction([])],
  )
}

/// The booker retires two active keys in one fold: `keyA` against the
/// two-leaf trie, then `keyB` against the updated two-leaf trie.
fn retireTwoActive(outputs: List<Output>) -> Scenario {
  scenario(
    fx.twoLeaves(fx.keyA, fx.activeLeaf, fx.keyB, fx.activeLeaf),
    fx.twoLeaves(fx.keyA, fx.terminalLeaf, fx.keyB, fx.terminalLeaf),
    [
      ownedRequest(0, fx.keyA, 3, fx.bookerKey),
      ownedRequest(1, fx.keyB, 3, fx.bookerKey),
    ],
    [activeWitness(0, fx.keyA), activeWitness(1, fx.keyB)],
    outputs,
    merge(burnActive(fx.keyA), burnActive(fx.keyB)),
    [
      UpdateAction(fx.siblingProof(fx.keyB, fx.activeLeaf, fx.keyA)),
      UpdateAction(fx.siblingProof(fx.keyA, fx.terminalLeaf, fx.keyB)),
    ],
  )
}

/// A reject of the booker's request, valid over `range`: the root stays,
/// and the refund is owed positionally from the first output after the
/// state.
fn rejectIn(range: Interval<Int>, outputs: List<Output>) -> Scenario {
  let root = fx.emptyRoot()
  let s =
    scenario(
      root,
      root,
      [ownedRequest(0, fx.keyA, 1, fx.bookerKey)],
      [],
      outputs,
      zero,
      [Rejected],
    )
  Scenario { ..s, tx: Transaction { ..s.tx, validity_range: range } }
}

/// The same reject after the windows.
fn reject(outputs: List<Output>) -> Scenario {
  rejectIn(fx.phase3(), outputs)
}

fn refusesAsEmptyFold(s: Scenario) -> Bool {
  !spend(s) && refusalOf(s) == Some(@"empty-fold")
}

test tagged_fold_retires_the_legacy_rejection_after_the_windows() {
  refusesAsEmptyFold(reject([paid(fx.bookerAddress, fx.deposit)]))
}

test tagged_fold_retires_the_legacy_early_rejection_in_the_processing_window() {
  refusesAsEmptyFold(
    rejectIn(fx.phase1(), [paid(fx.bookerAddress, fx.deposit)]),
  )
}

test tagged_fold_retires_the_legacy_early_rejection_in_the_retraction_window() {
  refusesAsEmptyFold(
    rejectIn(fx.phase2(), [paid(fx.bookerAddress, fx.deposit)]),
  )
}

test tagged_fold_retires_the_controller_refund_termination() {
  refusesAsEmptyFold(updateTerminal([paid(fx.bookerAddress, fx.deposit)]))
}

test tagged_fold_retires_two_controller_refund_terminations_in_one_fold() {
  refusesAsEmptyFold(retireTwoActive([paid(fx.bookerAddress, fx.deposit * 2)]))
}

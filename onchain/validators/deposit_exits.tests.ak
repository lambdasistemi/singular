use aiken/interval.{Interval}
use cardano/assets.{Value, from_lovelace, merge, zero}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, Transaction}
use registry_fixtures as fx
use state
use types.{
  Modify, Rejected, Request, RequestAction, RequestDatum, State, StateDatum,
  UpdateAction,
}

// ============================================================================
// #253 — the deposit of a fold that delivers nothing goes back to its owner
// ============================================================================
//
// Rule (issue #253): a fold on edge 3 (`updateTerminal`) delivers no token, so the deposit the request rode
// with is paid to `requestOwner`'s key, at least the deposit; a reject pays
// the same owner at least the deposit. The folder earns the tip and nothing
// else. Deposits and refunds owed to one owner in one fold are settled on
// the summed lovelace of the outputs paying that owner's key, not counting
// the state continuation, token carriers, so one output
// cannot pay two obligations.
//
// Each refusal row changes one output of an accepting twin and asserts the
// NAME the cage refuses the whole transaction for: `state.modifyRefusal` is
// the reason the spend handler traces, so a row the cage refused for any
// other reason, or crashed on inside an `expect`, fails. Each row also runs
// the spend handler itself, which must agree.

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

/// The cage folds it: the handler accepts, and no reason. The handler runs
/// first, so a refusal prints the reason it traces.
fn accepts(s: Scenario) -> Bool {
  spend(s) && refusalOf(s) == None
}

/// The cage refuses it for `deposit-returned` and for nothing else, and
/// the handler returns False rather than crashing. The handler runs first,
/// so the reason it traces is printed when the name differs.
fn refusesDepositReturned(s: Scenario) -> Bool {
  !spend(s) && refusalOf(s) == Some(@"deposit-returned")
}

/// A request of `owner` for `key` on a non-delivering edge, with its
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

// ----------------------------------------------------------------------------
// Edge 3 — `updateTerminal`
// ----------------------------------------------------------------------------

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

test retirement_deposit_paid_to_the_owner_accepts() {
  accepts(updateTerminal([paid(fx.bookerAddress, fx.deposit)]))
}

test retirement_deposit_diverted_to_another_address_refuses() {
  refusesDepositReturned(updateTerminal([paid(fx.strangerAddress, fx.deposit)]))
}

test retirement_deposit_one_lovelace_short_refuses() {
  refusesDepositReturned(
    updateTerminal([paid(fx.bookerAddress, fx.deposit - 1)]),
  )
}

// ----------------------------------------------------------------------------
// An update is folded in the processing window only (spec KR-01)
//
// Current validator behaviour, with no counterpart in Lean: Lean admits a
// fold in every window, and this rule stays under the fold-correspondence
// hold. The retirement fold above is valid in every other respect, so outside the
// processing window the first reason the cage gives is `not-phase1`, the
// fold's first check on an update; a carriage, action, edge, approval or
// trie refusal would name itself instead.
// ----------------------------------------------------------------------------

/// The retirement fold, paying its owner the deposit, valid over `range`.
fn retireIn(range: Interval<Int>) -> Scenario {
  let s = updateTerminal([paid(fx.bookerAddress, fx.deposit)])
  Scenario { ..s, tx: Transaction { ..s.tx, validity_range: range } }
}

/// The cage refuses it for `not-phase1` as its first reason, and the handler
/// returns False rather than crashing. The handler runs first, so a different
/// reason is printed.
fn refusesNotPhase1(s: Scenario) -> Bool {
  !spend(s) && refusalOf(s) == Some(@"not-phase1")
}

/// The control the four refusals below share: the same fold inside the
/// processing window.
test update_in_the_processing_window_accepts() {
  accepts(retireIn(fx.phase1()))
}

test update_in_the_retraction_window_refuses_not_phase1() {
  refusesNotPhase1(retireIn(fx.phase2()))
}

test update_after_the_windows_refuses_not_phase1() {
  refusesNotPhase1(retireIn(fx.phase3()))
}

test update_across_the_processing_deadline_refuses_not_phase1() {
  refusesNotPhase1(retireIn(interval.between(5_000, 15_000)))
}

test update_with_no_validity_bounds_refuses_not_phase1() {
  refusesNotPhase1(retireIn(interval.everything))
}

// ----------------------------------------------------------------------------
// Two deposits of one owner in one fold are owed as their sum
// ----------------------------------------------------------------------------

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

test two_deposits_in_one_output_accepts() {
  accepts(retireTwoActive([paid(fx.bookerAddress, fx.deposit * 2)]))
}

test two_deposits_in_two_outputs_accepts() {
  accepts(
    retireTwoActive(
      [paid(fx.bookerAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

test two_deposits_paid_one_deposit_refuses() {
  refusesDepositReturned(retireTwoActive([paid(fx.bookerAddress, fx.deposit)]))
}

// ----------------------------------------------------------------------------
// A deposit and a token carrier to the owner's key are two payments
// ----------------------------------------------------------------------------

/// The booker books `keyB` to their own key address and retires `keyA` in
/// the same fold. The carrier owes the booking's deposit; the retirement's
/// deposit is owed separately.
fn bookAndRetire(outputs: List<Output>) -> Scenario {
  let booking = (fx.bookerAddress, None)
  scenario(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.twoLeaves(fx.keyA, fx.terminalLeaf, fx.keyB, fx.activeLeaf),
    [
      fx.requestInput(
        0,
        fx.keyB,
        1,
        fx.bookerKey,
        booking,
        fx.approval(1, fx.keyB, fx.bookerKey, booking),
        fx.requestLovelace,
      ),
      ownedRequest(1, fx.keyA, 3, fx.bookerKey),
    ],
    [activeWitness(0, fx.keyA)],
    outputs,
    merge(fx.mintOf(fx.activePolicy, fx.keyB, 1), burnActive(fx.keyA)),
    [
      UpdateAction([fx.leafStep(fx.keyA, fx.activeLeaf, fx.keyB)]),
      UpdateAction(fx.siblingProof(fx.keyB, fx.activeLeaf, fx.keyA)),
    ],
  )
}

fn carrierOf(lovelace: Int) -> Output {
  fx.deliveryOutput(
    fx.activePolicy,
    fx.keyB,
    fx.bookerAddress,
    NoDatum,
    lovelace,
  )
}

test carrier_and_deposit_in_two_outputs_accepts() {
  accepts(
    bookAndRetire([carrierOf(fx.deposit), paid(fx.bookerAddress, fx.deposit)]),
  )
}

test carrier_holding_both_deposits_refuses() {
  refusesDepositReturned(bookAndRetire([carrierOf(fx.deposit * 2)]))
}

// ----------------------------------------------------------------------------
// A deposit and a reject refund of one owner are two payments
// ----------------------------------------------------------------------------

/// A request dated in the future, rejected inside a phase-1 range: one
/// fold retires `keyA` for the booker
/// and rejects another request of the booker's.
fn futureRequest(index: Int) -> Input {
  Input {
    output_reference: fx.requestRef(index),
    output: Output {
      address: fx.cageAddress(),
      value: from_lovelace(fx.requestLovelace),
      datum: InlineDatum(
        RequestDatum(
          Request {
            requestToken: fx.cageToken,
            requestOwner: fx.bookerKey,
            requestKey: fx.keyB,
            edge: 1,
            submitted_at: 1_000_000,
            destination: fx.bookingDestination(),
            deposit: fx.deposit,
          },
        ),
      ),
      reference_script: None,
    },
  }
}

fn retireAndReject(outputs: List<Output>) -> Scenario {
  scenario(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    [ownedRequest(0, fx.keyA, 3, fx.bookerKey), futureRequest(1)],
    [activeWitness(0, fx.keyA)],
    outputs,
    burnActive(fx.keyA),
    [UpdateAction([]), Rejected],
  )
}

test refund_and_deposit_in_two_outputs_accepts() {
  accepts(
    retireAndReject(
      [paid(fx.bookerAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

test refund_and_deposit_in_one_output_sized_for_both_accepts() {
  accepts(retireAndReject([paid(fx.bookerAddress, fx.deposit * 2)]))
}

/// The one output pays the rejected row positionally, and is then offered
/// for the retirement's deposit as well.
test refund_output_offered_for_the_deposit_too_refuses() {
  refusesDepositReturned(retireAndReject([paid(fx.bookerAddress, fx.deposit)]))
}

// ----------------------------------------------------------------------------
// Reject — the refund is refused by name
// ----------------------------------------------------------------------------

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

test reject_refund_paid_to_the_owner_accepts() {
  accepts(reject([paid(fx.bookerAddress, fx.deposit)]))
}

test reject_refund_one_lovelace_short_refuses_by_name() {
  refusesDepositReturned(reject([paid(fx.bookerAddress, fx.deposit - 1)]))
}

test reject_refund_to_another_key_refuses_by_name() {
  refusesDepositReturned(reject([paid(fx.strangerAddress, fx.deposit)]))
}

test reject_refund_to_a_script_refuses_by_name() {
  refusesDepositReturned(reject([paid(fx.recordAddress, fx.deposit)]))
}

test reject_refund_missing_refuses_by_name() {
  refusesDepositReturned(reject([]))
}

// ----------------------------------------------------------------------------
// An early reject owes the same refund (#320): the refund floor holds in the
// processing window and in the retraction window, refused by the same name
// ----------------------------------------------------------------------------

test early_reject_refund_paid_to_the_owner_in_the_processing_window_accepts() {
  accepts(rejectIn(fx.phase1(), [paid(fx.bookerAddress, fx.deposit)]))
}

test early_reject_refund_one_lovelace_short_in_the_processing_window_refuses_by_name() {
  refusesDepositReturned(
    rejectIn(fx.phase1(), [paid(fx.bookerAddress, fx.deposit - 1)]),
  )
}

test early_reject_refund_to_another_key_in_the_processing_window_refuses_by_name() {
  refusesDepositReturned(
    rejectIn(fx.phase1(), [paid(fx.strangerAddress, fx.deposit)]),
  )
}

test early_reject_refund_to_a_script_in_the_processing_window_refuses_by_name() {
  refusesDepositReturned(
    rejectIn(fx.phase1(), [paid(fx.recordAddress, fx.deposit)]),
  )
}

test early_reject_refund_missing_in_the_processing_window_refuses_by_name() {
  refusesDepositReturned(rejectIn(fx.phase1(), []))
}

test early_reject_refund_paid_to_the_owner_in_the_retraction_window_accepts() {
  accepts(rejectIn(fx.phase2(), [paid(fx.bookerAddress, fx.deposit)]))
}

test early_reject_refund_one_lovelace_short_in_the_retraction_window_refuses_by_name() {
  refusesDepositReturned(
    rejectIn(fx.phase2(), [paid(fx.bookerAddress, fx.deposit - 1)]),
  )
}

test early_reject_refund_to_another_key_in_the_retraction_window_refuses_by_name() {
  refusesDepositReturned(
    rejectIn(fx.phase2(), [paid(fx.strangerAddress, fx.deposit)]),
  )
}

test early_reject_refund_to_a_script_in_the_retraction_window_refuses_by_name() {
  refusesDepositReturned(
    rejectIn(fx.phase2(), [paid(fx.recordAddress, fx.deposit)]),
  )
}

test early_reject_refund_missing_in_the_retraction_window_refuses_by_name() {
  refusesDepositReturned(rejectIn(fx.phase2(), []))
}

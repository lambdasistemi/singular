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
// Rule (issue #253): a fold on edge 3 (`updateTerminal`), 4 (`deleteAbsent`)
// or 5 (`deleteActive`) delivers no token, so the deposit the request rode
// with is paid to `requestOwner`'s key, at least the deposit; a reject pays
// the same owner at least the deposit. The folder earns the tip and nothing
// else. Deposits and refunds owed to one owner in one fold are settled on
// the summed lovelace of the outputs paying that owner's key, not counting
// the state continuation, token carriers or cage custody, so one output
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

/// The cage folds it: no reason, and the handler accepts.
fn accepts(s: Scenario) -> Bool {
  refusalOf(s) == None && spend(s)
}

/// The cage refuses it for `deposit-returned` and for nothing else, and
/// the handler returns False rather than crashing.
fn refusesDepositReturned(s: Scenario) -> Bool {
  refusalOf(s) == Some(@"deposit-returned") && !spend(s)
}

/// A request of `owner` for `key` on a non-delivering edge, with its
/// approval and exactly `tip + deposit`.
fn ownedRequest(index: Int, key: ByteArray, edge: Int, owner: ByteArray) -> Input {
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

test e3_deposit_paid_to_the_owner_accepts() {
  accepts(updateTerminal([paid(fx.bookerAddress, fx.deposit)]))
}

test e3_deposit_diverted_to_another_address_refuses() {
  refusesDepositReturned(updateTerminal([paid(fx.strangerAddress, fx.deposit)]))
}

test e3_deposit_one_lovelace_short_refuses() {
  refusesDepositReturned(
    updateTerminal([paid(fx.bookerAddress, fx.deposit - 1)]),
  )
}

// ----------------------------------------------------------------------------
// Edge 4 — `deleteAbsent`
// ----------------------------------------------------------------------------

/// The request's owner is the booker; the custody it consumes records the
/// inserter's refund address. The two payments go to two different keys,
/// so the custody refund cannot be what pays the deposit.
fn deleteAbsent(outputs: List<Output>) -> Scenario {
  scenario(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.emptyRoot(),
    [ownedRequest(0, fx.keyA, 4, fx.bookerKey)],
    [fx.custodyInput(0, fx.keyA, fx.inserterAddress, fx.deposit)],
    outputs,
    fx.mintOf(fx.absentPolicy, fx.keyA, -1),
    [UpdateAction([])],
  )
}

test e4_deposit_paid_to_the_owner_accepts() {
  accepts(
    deleteAbsent(
      [paid(fx.inserterAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

test e4_deposit_diverted_to_another_address_refuses() {
  refusesDepositReturned(
    deleteAbsent(
      [
        paid(fx.inserterAddress, fx.deposit),
        paid(fx.strangerAddress, fx.deposit),
      ],
    ),
  )
}

test e4_deposit_one_lovelace_short_refuses() {
  refusesDepositReturned(
    deleteAbsent(
      [
        paid(fx.inserterAddress, fx.deposit),
        paid(fx.bookerAddress, fx.deposit - 1),
      ],
    ),
  )
}

// ----------------------------------------------------------------------------
// Edge 5 — `deleteActive`
// ----------------------------------------------------------------------------

fn deleteActive(outputs: List<Output>) -> Scenario {
  scenario(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.emptyRoot(),
    [ownedRequest(0, fx.keyA, 5, fx.bookerKey)],
    [activeWitness(0, fx.keyA)],
    outputs,
    burnActive(fx.keyA),
    [UpdateAction([])],
  )
}

test e5_deposit_paid_to_the_owner_accepts() {
  accepts(deleteActive([paid(fx.bookerAddress, fx.deposit)]))
}

test e5_deposit_diverted_to_another_address_refuses() {
  refusesDepositReturned(deleteActive([paid(fx.strangerAddress, fx.deposit)]))
}

test e5_deposit_one_lovelace_short_refuses() {
  refusesDepositReturned(deleteActive([paid(fx.bookerAddress, fx.deposit - 1)]))
}

// ----------------------------------------------------------------------------
// Two deposits of one owner in one fold are owed as their sum
// ----------------------------------------------------------------------------

/// The booker deletes two active keys in one fold: `keyA` against the
/// two-leaf trie, then `keyB` against the one leaf left.
fn deleteTwoActive(outputs: List<Output>) -> Scenario {
  scenario(
    fx.twoLeaves(fx.keyA, fx.activeLeaf, fx.keyB, fx.activeLeaf),
    fx.emptyRoot(),
    [
      ownedRequest(0, fx.keyA, 5, fx.bookerKey),
      ownedRequest(1, fx.keyB, 5, fx.bookerKey),
    ],
    [activeWitness(0, fx.keyA), activeWitness(1, fx.keyB)],
    outputs,
    merge(burnActive(fx.keyA), burnActive(fx.keyB)),
    [
      UpdateAction(fx.siblingProof(fx.keyB, fx.activeLeaf, fx.keyA)),
      UpdateAction([]),
    ],
  )
}

test two_deposits_in_one_output_accepts() {
  accepts(deleteTwoActive([paid(fx.bookerAddress, fx.deposit * 2)]))
}

test two_deposits_in_two_outputs_accepts() {
  accepts(
    deleteTwoActive(
      [paid(fx.bookerAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

test two_deposits_paid_one_deposit_refuses() {
  refusesDepositReturned(deleteTwoActive([paid(fx.bookerAddress, fx.deposit)]))
}

// ----------------------------------------------------------------------------
// A deposit and a token carrier to the owner's key are two payments
// ----------------------------------------------------------------------------

/// The booker books `keyB` to their own key address and deletes `keyA` in
/// the same fold. The carrier owes the booking's deposit; the deletion's
/// deposit is owed separately.
fn bookAndDelete(outputs: List<Output>) -> Scenario {
  let booking = (fx.bookerAddress, #"")
  scenario(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyB, fx.activeLeaf),
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
      ownedRequest(1, fx.keyA, 5, fx.bookerKey),
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
  fx.deliveryOutput(fx.activePolicy, fx.keyB, fx.bookerAddress, NoDatum, lovelace)
}

test carrier_and_deposit_in_two_outputs_accepts() {
  accepts(
    bookAndDelete([carrierOf(fx.deposit), paid(fx.bookerAddress, fx.deposit)]),
  )
}

test carrier_holding_both_deposits_refuses() {
  refusesDepositReturned(bookAndDelete([carrierOf(fx.deposit * 2)]))
}

// ----------------------------------------------------------------------------
// A deposit and a reject refund of one owner are two payments
// ----------------------------------------------------------------------------

/// A request dated in the future is rejectable inside a phase-1 range
/// (`shared.is_rejectable`), so one fold can delete `keyA` for the booker
/// and reject another request of the booker's.
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

fn deleteAndReject(outputs: List<Output>) -> Scenario {
  scenario(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.emptyRoot(),
    [ownedRequest(0, fx.keyA, 5, fx.bookerKey), futureRequest(1)],
    [activeWitness(0, fx.keyA)],
    outputs,
    burnActive(fx.keyA),
    [UpdateAction([]), Rejected],
  )
}

test refund_and_deposit_in_two_outputs_accepts() {
  accepts(
    deleteAndReject(
      [paid(fx.bookerAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

test refund_and_deposit_in_one_output_sized_for_both_accepts() {
  accepts(deleteAndReject([paid(fx.bookerAddress, fx.deposit * 2)]))
}

/// The one output pays the rejected row positionally, and is then offered
/// for the deletion's deposit as well.
test refund_output_offered_for_the_deposit_too_refuses() {
  refusesDepositReturned(deleteAndReject([paid(fx.bookerAddress, fx.deposit)]))
}

// ----------------------------------------------------------------------------
// Reject — the refund is refused by name
// ----------------------------------------------------------------------------

/// A phase-3 reject of the booker's request: the root stays, and the
/// refund is owed positionally from the first output after the state.
fn reject(outputs: List<Output>) -> Scenario {
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
  Scenario { ..s, tx: Transaction { ..s.tx, validity_range: fx.phase3() } }
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
// One settlement per payee: custody refunds and deposits to one key
// ----------------------------------------------------------------------------

/// The cage refuses it for `refund` and for nothing else.
fn refusesRefund(s: Scenario) -> Bool {
  refusalOf(s) == Some(@"refund") && !spend(s)
}

/// The inserter deletes their own witness: the custody refund and the
/// request's deposit are owed to the same key, in two outputs. The
/// deposit output carries the returned approval, as the builder pays it;
/// the custody refund is ada-only. Both land at one address, so no output
/// can be told apart as "the refund": the payee is owed their sum.
fn deleteOwnAbsent(refund: Int, deposit: Int) -> Scenario {
  scenario(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.emptyRoot(),
    [ownedRequest(0, fx.keyA, 4, fx.inserterKey)],
    [fx.custodyInput(0, fx.keyA, fx.inserterAddress, fx.deposit)],
    [
      paid(fx.inserterAddress, refund),
      Output {
        ..paid(fx.inserterAddress, deposit),
        value: merge(
          from_lovelace(deposit),
          fx.approval(4, fx.keyA, fx.inserterKey, fx.noDestination()),
        ),
      },
    ],
    fx.mintOf(fx.absentPolicy, fx.keyA, -1),
    [UpdateAction([])],
  )
}

test own_custody_refund_and_deposit_exact_accepts() {
  accepts(deleteOwnAbsent(fx.deposit, fx.deposit))
}

test own_custody_refund_one_short_refuses() {
  refusesDepositReturned(deleteOwnAbsent(fx.deposit - 1, fx.deposit))
}

test own_deposit_one_short_refuses() {
  refusesDepositReturned(deleteOwnAbsent(fx.deposit, fx.deposit - 1))
}

// Two custody refunds to one address (the #254 reproduction): both
// custodies record the inserter's refund address, with 2 and 3 ada.

const smallCustody: Int = 2_000_000

const largeCustody: Int = 3_000_000

/// Two `deleteAbsent` requests of `owner`, on `keyA` and `keyB`.
fn deleteTwoAbsent(owner: ByteArray, outputs: List<Output>) -> Scenario {
  scenario(
    fx.twoLeaves(fx.keyA, fx.absentLeaf, fx.keyB, fx.absentLeaf),
    fx.emptyRoot(),
    [ownedRequest(0, fx.keyA, 4, owner), ownedRequest(1, fx.keyB, 4, owner)],
    [
      fx.custodyInput(0, fx.keyA, fx.inserterAddress, smallCustody),
      fx.custodyInput(1, fx.keyB, fx.inserterAddress, largeCustody),
    ],
    outputs,
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.absentPolicy, fx.keyB, -1),
    ),
    [
      UpdateAction(fx.siblingProof(fx.keyB, fx.absentLeaf, fx.keyA)),
      UpdateAction([]),
    ],
  )
}

/// The booker deletes, so the two deposits go to the booker and only the
/// two custody refunds go to the inserter's address.
test two_custody_refunds_to_one_address_paid_in_full_accepts() {
  accepts(
    deleteTwoAbsent(
      fx.bookerKey,
      [
        paid(fx.inserterAddress, smallCustody),
        paid(fx.inserterAddress, largeCustody),
        paid(fx.bookerAddress, fx.deposit * 2),
      ],
    ),
  )
}

test two_custody_refunds_paid_by_the_larger_one_refuses() {
  refusesRefund(
    deleteTwoAbsent(
      fx.bookerKey,
      [
        paid(fx.inserterAddress, largeCustody),
        paid(fx.bookerAddress, fx.deposit * 2),
      ],
    ),
  )
}

/// The booker deletes one key the inserter witnessed absent: the custody
/// refund is owed to the inserter's address and to no other payee.
fn deleteOthersAbsent(custody: List<Input>, outputs: List<Output>) -> Scenario {
  scenario(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.emptyRoot(),
    [ownedRequest(0, fx.keyA, 4, fx.bookerKey)],
    custody,
    outputs,
    fx.mintOf(fx.absentPolicy, fx.keyA, -1),
    [UpdateAction([])],
  )
}

fn inserterCustody() -> List<Input> {
  [fx.custodyInput(0, fx.keyA, fx.inserterAddress, fx.deposit)]
}

test custody_refund_paid_to_the_inserter_accepts() {
  accepts(
    deleteOthersAbsent(
      inserterCustody(),
      [paid(fx.inserterAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

test custody_refund_one_lovelace_short_refuses_by_name() {
  refusesRefund(
    deleteOthersAbsent(
      inserterCustody(),
      [
        paid(fx.inserterAddress, fx.deposit - 1),
        paid(fx.bookerAddress, fx.deposit),
      ],
    ),
  )
}

test custody_refund_to_another_address_refuses_by_name() {
  refusesRefund(
    deleteOthersAbsent(
      inserterCustody(),
      [paid(fx.strangerAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

/// The absent token is burned but its custody UTxO is not an input: no
/// output can pay a refund the fold never collected.
test custody_left_unspent_refuses_by_name() {
  refusesRefund(
    deleteOthersAbsent(
      [],
      [paid(fx.inserterAddress, fx.deposit), paid(fx.bookerAddress, fx.deposit)],
    ),
  )
}

/// #254 as filed: the inserter deletes both, so the address is owed the
/// two custody refunds AND the two deposits.
test own_two_custody_refunds_and_deposits_paid_in_full_accepts() {
  accepts(
    deleteTwoAbsent(
      fx.inserterKey,
      [
        paid(fx.inserterAddress, smallCustody),
        paid(fx.inserterAddress, largeCustody),
        paid(fx.inserterAddress, fx.deposit * 2),
      ],
    ),
  )
}

test own_two_custody_refunds_paid_by_the_larger_one_refuses() {
  refusesDepositReturned(
    deleteTwoAbsent(
      fx.inserterKey,
      [
        paid(fx.inserterAddress, largeCustody),
        paid(fx.inserterAddress, fx.deposit * 2),
      ],
    ),
  )
}

// ----------------------------------------------------------------------------
// Edge 2 — a custody refund and a delivery to one address
// ----------------------------------------------------------------------------

/// The inserter books the key they witnessed absent, to their own
/// address: the custody refund and the token carrier land at one address.
/// The carrier owes the booking's deposit; the refund is owed apart.
fn updateOwnAbsent(outputs: List<Output>) -> Scenario {
  let booking = (fx.inserterAddress, #"")
  scenario(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    [
      fx.requestInput(
        0,
        fx.keyA,
        2,
        fx.inserterKey,
        booking,
        fx.approval(2, fx.keyA, fx.inserterKey, booking),
        fx.requestLovelace,
      ),
    ],
    [fx.custodyInput(0, fx.keyA, fx.inserterAddress, fx.deposit)],
    outputs,
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
    ),
    [UpdateAction([])],
  )
}

fn ownCarrier(lovelace: Int) -> Output {
  fx.deliveryOutput(fx.activePolicy, fx.keyA, fx.inserterAddress, NoDatum, lovelace)
}

test own_refund_and_delivery_at_one_address_accepts() {
  accepts(
    updateOwnAbsent([ownCarrier(fx.deposit), paid(fx.inserterAddress, fx.deposit)]),
  )
}

/// The carrier holds the deposit and the refund, and no other output pays
/// the refund address: a carrier owes its own deposit and pays nothing else.
test carrier_holding_the_custody_refund_too_refuses() {
  refusesRefund(updateOwnAbsent([ownCarrier(fx.deposit * 2)]))
}

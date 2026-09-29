//// Rows for the open-datum application (#299, #310).
////
//// Every refusal is `== False` and sits beside an accepting control that
//// moves exactly one fact back. The release rows run the SAME transaction
//// through the registry's own state validator as well, so an accepted
//// release is a fold the registry accepts too, and a refused one is
//// refused by the application while the registry alone would accept it.

use aiken/cbor
use aiken/collection/dict
use aiken/collection/list
use aiken/primitive/bytearray
use application/envelope.{
  BookInsert, BookTerminate, Control, Envelope, OpenDatumMint, Release,
  StateAsset, Update, envelopeHash, envelopeVersion,
}
use cardano/address.{Address, Script}
use cardano/assets.{Value, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction,
}
use lib.{approvalName}
use open_datum
use registry_fixtures as fx
use state
use types.{
  Modify, Rejected, Request, RequestAction, RequestDatum, State, StateDatum,
  TokenId, UpdateAction,
}
use witness.{registryStateHash}

// ----------------------------------------------------------------------------
// Fixtures
// ----------------------------------------------------------------------------

/// This instance's own hash: its approval policy and its address. The
/// registry state pins it as its application policy (`fx.stateOf`).
const app: ByteArray = fx.appPolicy

const stateName: ByteArray = #"636167652d746f6b656e"

fn registry() -> ByteArray {
  bytearray.concat(registryStateHash, stateName)
}

const controller: ByteArray = fx.bookerKey

const controllerAddress: ByteArray = fx.bookerAddress

/// Enterprise script address bytes of this instance.
fn appAddress() -> ByteArray {
  bytearray.concat(#"70", app)
}

fn appAddr() -> Address {
  address.from_script(app)
}

const appDeposit: Int = 2_000_000

fn control() -> Control {
  Control {
    version: envelopeVersion,
    registry: StateAsset { statePolicy: registryStateHash, stateName },
    activePolicy: fx.activePolicy,
    key: fx.keyA,
    controller,
    deposit: appDeposit,
  }
}

fn payloadA() -> Data {
  let d: Data = #"616c696365"
  d
}

fn payloadB() -> Data {
  let d: Data = [1, -2, 3]
  d
}

fn envelopeOf(c: Control, payload: Data) -> Envelope {
  Envelope { control: c, payload }
}

fn envelopeA() -> Envelope {
  envelopeOf(control(), payloadA())
}

const stateRef: OutputReference =
  OutputReference { transaction_id: #"5354415445", output_index: 0 }

fn stateValue() -> Value {
  from_asset(registryStateHash, stateName, 1) |> merge(from_lovelace(5_000_000))
}

fn stateOutputAt(root: ByteArray, s: State) -> Output {
  Output {
    address: address.from_script(registryStateHash),
    value: stateValue(),
    datum: InlineDatum(StateDatum(State { ..s, root })),
    reference_script: None,
  }
}

fn stateInputWith(s: State) -> Input {
  Input { output_reference: stateRef, output: stateOutputAt(s.root, s) }
}

fn theState() -> State {
  fx.stateOf(fx.oneLeaf(fx.keyA, fx.activeLeaf))
}

fn stateInput() -> Input {
  stateInputWith(theState())
}

const holdingRef: OutputReference =
  OutputReference { transaction_id: #"484f4c44", output_index: 0 }

fn holdingOutput(e: Envelope, lovelace: Int, extra: Value) -> Output {
  Output {
    address: appAddr(),
    value: from_lovelace(lovelace)
      |> merge(from_asset(fx.activePolicy, e.control.key, 1))
      |> merge(extra),
    datum: InlineDatum(e),
    reference_script: None,
  }
}

fn holding() -> Input {
  Input {
    output_reference: holdingRef,
    output: holdingOutput(envelopeA(), appDeposit, zero),
  }
}

// ----------------------------------------------------------------------------
// Golden vector shared with the off-chain codec
// ----------------------------------------------------------------------------

/// The CBOR and BLAKE2b-256 of `envelopeA`, byte for byte what
/// `Singular.Application.OpenDatum.EnvelopeSpec` asserts for the same
/// envelope.
test envelope_a_serialises_to_the_shared_cbor() {
  cbor.serialise(envelopeA()) == #"d8799fd8799f01d8799f581c1f06886c357b5b31b43baf142cb19d0c8e5259110de19056694264284a636167652d746f6b656eff581caaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa446b657941581cd1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d11a001e8480ff45616c696365ff"
}

test envelope_a_hashes_to_the_shared_digest() {
  envelopeHash(envelopeA()) == #"98e07c4c9ae428381b4eb4e8f0b76376fe3a83291b71c6714e66cf0c9dd63af0"
}

// ----------------------------------------------------------------------------
// Booking an insertion
// ----------------------------------------------------------------------------

fn insertDestination(e: Envelope) -> (ByteArray, ByteArray) {
  (appAddress(), envelopeHash(e))
}

fn insertName(e: Envelope) -> ByteArray {
  approvalName(1, e.control.key, controller, insertDestination(e))
}

/// The booked request, carrying its approval.
fn requestOutput(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
  depositAmount: Int,
  name: ByteArray,
) -> Output {
  Output {
    address: fx.cageAddress(),
    value: from_lovelace(fx.tip + depositAmount)
      |> merge(from_asset(app, name, 1)),
    datum: InlineDatum(
      RequestDatum(
        Request {
          requestToken: TokenId { assetName: stateName },
          requestOwner: owner,
          requestKey: key,
          edge,
          submitted_at: 0,
          destination,
          deposit: depositAmount,
        },
      ),
    ),
    reference_script: None,
  }
}

fn insertTx(
  e: Envelope,
  references: List<Input>,
  signers: List<ByteArray>,
  requestDeposit: Int,
  name: ByteArray,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    reference_inputs: references,
    outputs: [
      requestOutput(
        1,
        e.control.key,
        controller,
        insertDestination(e),
        requestDeposit,
        name,
      ),
    ],
    extra_signatories: signers,
    mint: from_asset(app, name, 1),
  }
}

fn bookInsertWith(
  e: Envelope,
  redeemerKey: ByteArray,
  owner: ByteArray,
  address: ByteArray,
  tx: Transaction,
) -> Bool {
  open_datum.open_datum.mint(
    registry(),
    BookInsert { key: redeemerKey, owner, address, envelope: e },
    app,
    tx,
  )
}

fn bookInsert(e: Envelope, tx: Transaction) -> Bool {
  bookInsertWith(e, e.control.key, controller, appAddress(), tx)
}

fn honestInsertTx(e: Envelope) -> Transaction {
  insertTx(e, [stateInput()], [controller], e.control.deposit, insertName(e))
}

test insert_booking_control_accepts() {
  bookInsert(envelopeA(), honestInsertTx(envelopeA()))
}

test insert_booking_admits_any_payload() {
  list_all(
    payloads(),
    fn(p) {
      let e = envelopeOf(control(), p)
      bookInsert(e, honestInsertTx(e))
    },
  )
}

/// Payloads of every Plutus Data shape: bytes, a signed integer, empty
/// bytes, a constructor, a map and nested lists.
fn payloads() -> List<Data> {
  let negative: Data = -42
  let empty: Data = #""
  let constructor: Data = Some(#"00")
  let map: Data = dict.empty |> dict.insert(#"6b", [1, 2])
  let nested: Data = [[1], []]
  [payloadA(), payloadB(), negative, empty, constructor, map, nested]
}

fn list_all(items: List<Data>, predicate: fn(Data) -> Bool) -> Bool {
  when items is {
    [] -> True
    [x, ..rest] -> predicate(x) && list_all(rest, predicate)
  }
}

test insert_booking_wrong_version_refuses() {
  let e = envelopeOf(Control { ..control(), version: 2 }, payloadA())
  bookInsert(e, honestInsertTx(e)) == False
}

test insert_booking_wrong_registry_refuses() {
  let e =
    envelopeOf(
      Control {
        ..control(),
        registry: StateAsset {
          statePolicy: registryStateHash,
          stateName: #"6f74686572",
        },
      },
      payloadA(),
    )
  bookInsert(e, honestInsertTx(e)) == False
}

test insert_booking_wrong_active_policy_refuses() {
  let e =
    envelopeOf(
      Control { ..control(), activePolicy: fx.foreignPolicy },
      payloadA(),
    )
  bookInsert(e, honestInsertTx(e)) == False
}

test insert_booking_other_key_refuses() {
  let e = envelopeA()
  bookInsertWith(e, fx.keyB, controller, appAddress(), honestInsertTx(e)) == False
}

test insert_booking_other_owner_refuses() {
  let e = envelopeA()
  bookInsertWith(
    e,
    e.control.key,
    fx.inserterKey,
    appAddress(),
    honestInsertTx(e),
  ) == False
}

test insert_booking_unsigned_refuses() {
  let e = envelopeA()
  bookInsert(
    e,
    insertTx(
      e,
      [stateInput()],
      [fx.inserterKey],
      e.control.deposit,
      insertName(e),
    ),
  ) == False
}

test insert_booking_other_destination_refuses() {
  let e = envelopeA()
  let elsewhere = bytearray.concat(#"70", fx.foreignPolicy)
  let name =
    approvalName(1, e.control.key, controller, (elsewhere, envelopeHash(e)))
  bookInsertWith(
    e,
    e.control.key,
    controller,
    elsewhere,
    insertTx(e, [stateInput()], [controller], e.control.deposit, name),
  ) == False
}

test insert_booking_short_request_deposit_refuses() {
  let e = envelopeA()
  bookInsert(
    e,
    insertTx(
      e,
      [stateInput()],
      [controller],
      e.control.deposit - 1,
      insertName(e),
    ),
  ) == False
}

/// A request that names no datum: its destination is this script with an
/// EMPTY datum hash, and the minted name binds exactly that request, so
/// nothing but the missing datum is wrong. The mint refuses at
/// `app-envelope-datum`; `insert_booking_control_accepts` is the same
/// booking naming the envelope's hash.
test insert_booking_naming_no_datum_refuses() {
  let e = envelopeA()
  let bare = (appAddress(), #"")
  bookInsert(
    e,
    insertTxTo(e, bare, approvalName(1, e.control.key, controller, bare)),
  ) == False
}

/// The honest booking with the request naming `destination` and the
/// approval named `name`.
fn insertTxTo(
  e: Envelope,
  destination: (ByteArray, ByteArray),
  name: ByteArray,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    reference_inputs: [stateInput()],
    outputs: [
      requestOutput(
        1,
        e.control.key,
        controller,
        destination,
        e.control.deposit,
        name,
      ),
    ],
    extra_signatories: [controller],
    mint: from_asset(app, name, 1),
  }
}

test insert_booking_other_edge_refuses() {
  let e = envelopeA()
  let updateActive =
    approvalName(2, e.control.key, controller, insertDestination(e))
  bookInsert(
    e,
    insertTx(e, [stateInput()], [controller], e.control.deposit, updateActive),
  ) == False
}

test insert_booking_without_state_refuses() {
  let e = envelopeA()
  bookInsert(e, insertTx(e, [], [controller], e.control.deposit, insertName(e))) == False
}

test insert_booking_state_elsewhere_refuses() {
  let e = envelopeA()
  let s = stateInput()
  let displaced =
    Input {
      ..s,
      output: Output {
        ..s.output,
        address: address.from_script(fx.foreignPolicy),
      },
    }
  bookInsert(
    e,
    insertTx(e, [displaced], [controller], e.control.deposit, insertName(e)),
  ) == False
}

test insert_booking_state_of_other_application_refuses() {
  let e = envelopeA()
  let other =
    stateInputWith(State { ..theState(), application_policy: fx.foreignPolicy })
  bookInsert(
    e,
    insertTx(e, [other], [controller], e.control.deposit, insertName(e)),
  ) == False
}

test insert_booking_two_approvals_refuses() {
  let e = envelopeA()
  let tx = honestInsertTx(e)
  bookInsert(
    e,
    Transaction {
      ..tx,
      mint: merge(tx.mint, from_asset(app, #"6f74686572", 1)),
    },
  ) == False
}

// ----------------------------------------------------------------------------
// Booking a termination
// ----------------------------------------------------------------------------

fn terminateName(owner: ByteArray) -> ByteArray {
  approvalName(3, fx.keyA, owner, (#"", #""))
}

fn terminateTx(
  references: List<Input>,
  signers: List<ByteArray>,
  name: ByteArray,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    reference_inputs: references,
    extra_signatories: signers,
    mint: from_asset(app, name, 1),
  }
}

fn bookTerminateAs(owner: ByteArray, tx: Transaction) -> Bool {
  open_datum.open_datum.mint(
    registry(),
    BookTerminate { key: fx.keyA, owner, holding: holdingRef },
    app,
    tx,
  )
}

fn liveWith(e: Envelope, value: Value, at: Address) -> Input {
  Input {
    output_reference: holdingRef,
    output: Output {
      address: at,
      value,
      datum: InlineDatum(e),
      reference_script: None,
    },
  }
}

fn heldValue() -> Value {
  from_lovelace(appDeposit) |> merge(from_asset(fx.activePolicy, fx.keyA, 1))
}

test terminate_booking_control_accepts() {
  bookTerminateAs(
    controller,
    terminateTx(
      [stateInput(), holding()],
      [controller],
      terminateName(controller),
    ),
  )
}

test terminate_booking_without_live_output_refuses() {
  bookTerminateAs(
    controller,
    terminateTx([stateInput()], [controller], terminateName(controller)),
  ) == False
}

test terminate_booking_live_output_without_token_refuses() {
  bookTerminateAs(
    controller,
    terminateTx(
      [
        stateInput(),
        liveWith(envelopeA(), from_lovelace(appDeposit), appAddr()),
      ],
      [controller],
      terminateName(controller),
    ),
  ) == False
}

test terminate_booking_live_output_elsewhere_refuses() {
  bookTerminateAs(
    controller,
    terminateTx(
      [
        stateInput(),
        liveWith(
          envelopeA(),
          heldValue(),
          address.from_script(fx.foreignPolicy),
        ),
      ],
      [controller],
      terminateName(controller),
    ),
  ) == False
}

test terminate_booking_envelope_of_other_registry_refuses() {
  let e =
    envelopeOf(
      Control {
        ..control(),
        registry: StateAsset {
          statePolicy: registryStateHash,
          stateName: #"6f74686572",
        },
      },
      payloadA(),
    )
  bookTerminateAs(
    controller,
    terminateTx(
      [stateInput(), liveWith(e, heldValue(), appAddr())],
      [controller],
      terminateName(controller),
    ),
  ) == False
}

test terminate_booking_envelope_of_other_key_refuses() {
  let e = envelopeOf(Control { ..control(), key: fx.keyB }, payloadA())
  bookTerminateAs(
    controller,
    terminateTx(
      [stateInput(), liveWith(e, heldValue(), appAddr())],
      [controller],
      terminateName(controller),
    ),
  ) == False
}

test terminate_booking_envelope_of_other_active_policy_refuses() {
  let e =
    envelopeOf(
      Control { ..control(), activePolicy: fx.foreignPolicy },
      payloadA(),
    )
  bookTerminateAs(
    controller,
    terminateTx(
      [stateInput(), liveWith(e, heldValue(), appAddr())],
      [controller],
      terminateName(controller),
    ),
  ) == False
}

test terminate_booking_by_non_controller_refuses() {
  bookTerminateAs(
    fx.inserterKey,
    terminateTx(
      [stateInput(), holding()],
      [fx.inserterKey],
      terminateName(fx.inserterKey),
    ),
  ) == False
}

test terminate_booking_unsigned_refuses() {
  bookTerminateAs(
    controller,
    terminateTx([stateInput(), holding()], [], terminateName(controller)),
  ) == False
}

test terminate_booking_naming_a_destination_refuses() {
  let named = approvalName(3, fx.keyA, controller, (controllerAddress, #""))
  bookTerminateAs(
    controller,
    terminateTx([stateInput(), holding()], [controller], named),
  ) == False
}

// ----------------------------------------------------------------------------
// Update
// ----------------------------------------------------------------------------

fn updateTx(outputs: List<Output>, signers: List<ByteArray>) -> Transaction {
  updateTxFrom(holding(), outputs, signers)
}

fn updateTxFrom(
  h: Input,
  outputs: List<Output>,
  signers: List<ByteArray>,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [h],
    outputs,
    extra_signatories: signers,
  }
}

fn update(tx: Transaction) -> Bool {
  open_datum.open_datum.spend(
    registry(),
    Some(envelopeA() |> as_data_envelope),
    Update,
    holdingRef,
    tx,
  )
}

fn as_data_envelope(e: Envelope) -> Data {
  let d: Data = e
  d
}

fn next(payload: Data) -> Output {
  holdingOutput(envelopeOf(control(), payload), appDeposit, zero)
}

test update_control_accepts() {
  update(updateTx([next(payloadB())], [controller]))
}

test update_admits_any_payload() {
  list_all(payloads(), fn(p) { update(updateTx([next(p)], [controller])) })
}

/// A spent envelope at this address without its key's token is not a
/// live holding; the control is `update_control_accepts`.
fn holdingCarrying(quantity: Int) -> Input {
  Input {
    output_reference: holdingRef,
    output: Output {
      address: appAddr(),
      value: from_lovelace(appDeposit)
        |> merge(from_asset(fx.activePolicy, fx.keyA, quantity)),
      datum: InlineDatum(envelopeA()),
      reference_script: None,
    },
  }
}

fn nextCarrying(quantity: Int) -> Output {
  Output {
    ..next(payloadB()),
    value: from_lovelace(appDeposit)
      |> merge(from_asset(fx.activePolicy, fx.keyA, quantity)),
  }
}

test update_of_a_holding_without_its_token_refuses() {
  update(updateTxFrom(holdingCarrying(0), [nextCarrying(1)], [controller])) == False
}

test update_of_a_holding_with_two_tokens_refuses() {
  update(updateTxFrom(holdingCarrying(2), [nextCarrying(2)], [controller])) == False
}

test update_unsigned_refuses() {
  update(updateTx([next(payloadB())], [fx.inserterKey])) == False
}

test update_control_tamper_refuses() {
  let tampered =
    holdingOutput(
      envelopeOf(
        Control { ..control(), controller: fx.inserterKey },
        payloadB(),
      ),
      appDeposit,
      zero,
    )
  update(updateTx([tampered], [controller])) == False
}

test update_deposit_tamper_refuses() {
  let tampered =
    holdingOutput(
      envelopeOf(Control { ..control(), deposit: 1 }, payloadB()),
      appDeposit,
      zero,
    )
  update(updateTx([tampered], [controller])) == False
}

test update_escape_refuses() {
  let escaped =
    Output { ..next(payloadB()), address: fx.addressOf(controllerAddress) }
  update(updateTx([escaped], [controller])) == False
}

test update_missing_token_refuses() {
  let bare =
    Output {
      address: appAddr(),
      value: from_lovelace(appDeposit),
      datum: InlineDatum(envelopeA()),
      reference_script: None,
    }
  update(updateTx([bare], [controller])) == False
}

test update_duplicated_carrier_refuses() {
  update(updateTx([next(payloadB()), next(payloadA())], [controller])) == False
}

test update_added_asset_refuses() {
  let more =
    holdingOutput(
      envelopeOf(control(), payloadB()),
      appDeposit,
      from_asset(fx.foreignPolicy, #"01", 1),
    )
  update(updateTx([more], [controller])) == False
}

test update_short_deposit_refuses() {
  let short =
    holdingOutput(envelopeOf(control(), payloadB()), appDeposit - 1, zero)
  update(updateTx([short], [controller])) == False
}

test update_without_datum_refuses() {
  let bare = Output { ..next(payloadB()), datum: NoDatum }
  update(updateTx([bare], [controller])) == False
}

// ----------------------------------------------------------------------------
// Release inside the terminating fold
// ----------------------------------------------------------------------------

const requestRef: OutputReference =
  OutputReference { transaction_id: #"52455155455354", output_index: 0 }

fn terminateRequest(owner: ByteArray, key: ByteArray) -> Input {
  Input {
    output_reference: requestRef,
    output: requestOutput(
      3,
      key,
      owner,
      (#"", #""),
      fx.deposit,
      approvalName(3, key, owner, (#"", #"")),
    ),
  }
}

/// The retirement fold of `keyA`: the state, the controller's terminate
/// request and the live output, spent together; the active token burned;
/// the controller paid `paid`.
fn releaseTx(
  s: State,
  request: Input,
  action: RequestAction,
  paid: List<Output>,
  mint: Value,
) -> Transaction {
  releaseTxFrom(holding(), s, request, action, paid, mint)
}

fn releaseTxFrom(
  h: Input,
  s: State,
  request: Input,
  action: RequestAction,
  paid: List<Output>,
  mint: Value,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    validity_range: fx.phase1(),
    inputs: [stateInputWith(s), request, h],
    outputs: [stateOutputAt(fx.oneLeaf(fx.keyA, fx.terminalLeaf), s), ..paid],
    mint,
    redeemers: [
      Pair(Spend(stateRef), Modify([action]) |> as_data_modify),
      Pair(Spend(holdingRef), Release |> as_data_spend),
    ],
  }
}

fn as_data_modify(r: types.UpdateRedeemer) -> Data {
  let d: Data = r
  d
}

fn as_data_spend(r: envelope.OpenDatumSpend) -> Data {
  let d: Data = r
  d
}

fn theBurn() -> Value {
  from_asset(fx.activePolicy, fx.keyA, -1)
}

fn release(tx: Transaction) -> Bool {
  open_datum.open_datum.spend(
    registry(),
    Some(envelopeA() |> as_data_envelope),
    Release,
    holdingRef,
    tx,
  )
}

fn registryFolds(tx: Transaction) -> Bool {
  state.state.spend(
    Some(StateDatum(theState())),
    Modify([UpdateAction([])]),
    stateRef,
    tx,
  )
}

fn payController(lovelace: Int) -> Output {
  fx.paymentOutput(controllerAddress, lovelace)
}

fn honestRelease() -> Transaction {
  releaseTx(
    theState(),
    terminateRequest(controller, fx.keyA),
    UpdateAction([]),
    [payController(fx.deposit + appDeposit)],
    theBurn(),
  )
}

test release_control_accepts_with_the_registry() {
  let tx = honestRelease()
  registryFolds(tx) && release(tx)
}

test release_split_payments_to_the_controller_accept() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit), payController(appDeposit)],
      theBurn(),
    )
  registryFolds(tx) && release(tx)
}

test release_non_additive_payment_refuses_where_the_registry_accepts() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit + appDeposit - 1)],
      theBurn(),
    )
  registryFolds(tx) && release(tx) == False
}

test release_one_output_for_both_floors_refuses() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit)],
      theBurn(),
    )
  registryFolds(tx) && release(tx) == False
}

/// The same fold spending a holding whose token count is wrong. With two
/// units, one is burned and the registry would still fold; the other
/// would be released with the deposit. With none, the burned unit comes
/// from another input.
test release_of_a_holding_with_two_tokens_refuses() {
  release(
    releaseTxFrom(
      holdingCarrying(2),
      theState(),
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit + appDeposit)],
      theBurn(),
    ),
  ) == False
}

test release_of_a_holding_without_its_token_refuses() {
  let tx =
    releaseTxFrom(
      holdingCarrying(0),
      theState(),
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit + appDeposit)],
      theBurn(),
    )
  release(
    Transaction {
      ..tx,
      inputs: list.concat(
        tx.inputs,
        [fx.tokenInput(0, fx.activePolicy, fx.keyA)],
      ),
    },
  ) == False
}

test release_without_fold_refuses() {
  let tx =
    Transaction {
      ..transaction.placeholder,
      inputs: [holding()],
      outputs: [payController(appDeposit)],
      extra_signatories: [controller],
      redeemers: [Pair(Spend(holdingRef), Release |> as_data_spend)],
    }
  release(tx) == False
}

test release_with_state_not_folding_refuses() {
  let tx = honestRelease()
  release(
    Transaction {
      ..tx,
      redeemers: [Pair(Spend(holdingRef), Release |> as_data_spend)],
    },
  ) == False
}

test release_of_another_registry_refuses() {
  let tx = honestRelease()
  let s = stateInput()
  let foreign =
    Input {
      ..s,
      output: Output {
        ..s.output,
        value: from_asset(registryStateHash, #"6f74686572", 1)
          |> merge(from_lovelace(5_000_000)),
      },
    }
  expect [_, ..rest] = tx.inputs
  release(Transaction { ..tx, inputs: [foreign, ..rest] }) == False
}

test release_terminating_another_key_refuses() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(controller, fx.keyB),
      UpdateAction([]),
      [payController(fx.deposit + appDeposit)],
      theBurn(),
    )
  release(tx) == False
}

test release_for_a_request_by_another_owner_refuses() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(fx.inserterKey, fx.keyA),
      UpdateAction([]),
      [
        fx.paymentOutput(fx.inserterAddress, fx.deposit),
        payController(appDeposit),
      ],
      theBurn(),
    )
  release(tx) == False
}

test release_without_the_burn_refuses() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit + appDeposit)],
      zero,
    )
  release(tx) == False
}

test release_when_the_termination_is_rejected_refuses() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(controller, fx.keyA),
      Rejected,
      [payController(fx.deposit + appDeposit)],
      theBurn(),
    )
  release(tx) == False
}

test release_under_a_state_pinning_another_application_refuses() {
  let tx =
    releaseTx(
      State { ..theState(), application_policy: fx.foreignPolicy },
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit + appDeposit)],
      theBurn(),
    )
  release(tx) == False
}

// Two releases to one controller in one fold of one registry, both keys
// Active: the registry retires both and the application releases both,
// on the same transaction. Every registry deposit and every released
// deposit to that key is owed as one sum.

const holdingRefB: OutputReference =
  OutputReference { transaction_id: #"484f4c44", output_index: 1 }

const requestRefB: OutputReference =
  OutputReference { transaction_id: #"52455155455354", output_index: 1 }

fn envelopeB() -> Envelope {
  envelopeOf(Control { ..control(), key: fx.keyB }, payloadB())
}

fn bothActive() -> State {
  fx.stateOf(fx.twoLeaves(fx.keyA, fx.activeLeaf, fx.keyB, fx.activeLeaf))
}

/// keyA against the two-leaf trie, then keyB against the trie keyA left.
fn bothRetired() -> List<RequestAction> {
  [
    UpdateAction(fx.siblingProof(fx.keyB, fx.activeLeaf, fx.keyA)),
    UpdateAction(fx.siblingProof(fx.keyA, fx.terminalLeaf, fx.keyB)),
  ]
}

fn twoReleases(paid: List<Output>) -> Transaction {
  let holdingB =
    Input {
      output_reference: holdingRefB,
      output: holdingOutput(envelopeB(), appDeposit, zero),
    }
  let requestB =
    Input {
      ..terminateRequest(controller, fx.keyB),
      output_reference: requestRefB,
    }
  Transaction {
    ..transaction.placeholder,
    validity_range: fx.phase1(),
    inputs: [
      stateInputWith(bothActive()),
      terminateRequest(controller, fx.keyA),
      requestB,
      holding(),
      holdingB,
    ],
    outputs: [
      stateOutputAt(
        fx.twoLeaves(fx.keyA, fx.terminalLeaf, fx.keyB, fx.terminalLeaf),
        bothActive(),
      ),
      ..paid
    ],
    mint: theBurn() |> merge(from_asset(fx.activePolicy, fx.keyB, -1)),
    redeemers: [
      Pair(Spend(stateRef), Modify(bothRetired()) |> as_data_modify),
      Pair(Spend(holdingRef), Release |> as_data_spend),
      Pair(Spend(holdingRefB), Release |> as_data_spend),
    ],
  }
}

fn registryRetiresBoth(tx: Transaction) -> Bool {
  state.state.spend(
    Some(StateDatum(bothActive())),
    Modify(bothRetired()),
    stateRef,
    tx,
  )
}

fn releaseB(tx: Transaction) -> Bool {
  open_datum.open_datum.spend(
    registry(),
    Some(envelopeB() |> as_data_envelope),
    Release,
    holdingRefB,
    tx,
  )
}

test two_releases_to_one_controller_paid_in_full_accept_with_the_registry() {
  let tx = twoReleases([payController(2 * fx.deposit + 2 * appDeposit)])
  registryRetiresBoth(tx) && release(tx) && releaseB(tx)
}

test two_releases_paid_one_short_refuse_where_the_registry_accepts() {
  let tx = twoReleases([payController(2 * fx.deposit + 2 * appDeposit - 1)])
  registryRetiresBoth(tx) && release(tx) == False && releaseB(tx) == False
}

test two_releases_paid_for_one_refuse_where_the_registry_accepts() {
  let tx = twoReleases([payController(fx.deposit + appDeposit)])
  registryRetiresBoth(tx) && release(tx) == False && releaseB(tx) == False
}

// Two registries in one transaction cannot both fold. Every fold's
// continuation is the transaction's first output, which must hold exactly
// one state token, this registry's (`registry/modify` `state-token`). Both
// registries share the one state policy, so whichever registry's token
// the first output carries, the other registry's own validator refuses.
// The application's release therefore never has a second fold's
// obligations, or a second instance's releases, to add to its own.
// Each registry folds and releases alone, below.

const stateNameTwo: ByteArray = #"636167652d74776f"

const appTwo: ByteArray =
  #"a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8"

const activeTwo: ByteArray =
  #"abababababababababababababababababababababababababababab"

const stateRefTwo: OutputReference =
  OutputReference { transaction_id: #"5354415445", output_index: 1 }

const holdingRefTwo: OutputReference =
  OutputReference { transaction_id: #"484f4c44", output_index: 2 }

const requestRefTwo: OutputReference =
  OutputReference { transaction_id: #"52455155455354", output_index: 2 }

fn registryTwo() -> ByteArray {
  bytearray.concat(registryStateHash, stateNameTwo)
}

fn stateTwo() -> State {
  State { ..theState(), application_policy: appTwo, active_policy: activeTwo }
}

fn stateValueTwo() -> Value {
  from_asset(registryStateHash, stateNameTwo, 1)
    |> merge(from_lovelace(5_000_000))
}

fn stateInputTwo() -> Input {
  Input {
    output_reference: stateRefTwo,
    output: Output {
      address: address.from_script(registryStateHash),
      value: stateValueTwo(),
      datum: InlineDatum(StateDatum(stateTwo())),
      reference_script: None,
    },
  }
}

fn continuationTwo() -> Output {
  Output {
    address: address.from_script(registryStateHash),
    value: stateValueTwo(),
    datum: InlineDatum(
      StateDatum(
        State { ..stateTwo(), root: fx.oneLeaf(fx.keyA, fx.terminalLeaf) },
      ),
    ),
    reference_script: None,
  }
}

fn envelopeTwo() -> Envelope {
  envelopeOf(
    Control {
      ..control(),
      registry: StateAsset {
        statePolicy: registryStateHash,
        stateName: stateNameTwo,
      },
      activePolicy: activeTwo,
    },
    payloadB(),
  )
}

fn holdingTwo() -> Input {
  Input {
    output_reference: holdingRefTwo,
    output: Output {
      address: address.from_script(appTwo),
      value: from_lovelace(appDeposit)
        |> merge(from_asset(activeTwo, fx.keyA, 1)),
      datum: InlineDatum(envelopeTwo()),
      reference_script: None,
    },
  }
}

fn requestTwo() -> Input {
  Input {
    output_reference: requestRefTwo,
    output: Output {
      address: fx.cageAddress(),
      value: from_lovelace(fx.tip + fx.deposit)
        |> merge(
            from_asset(
              appTwo,
              approvalName(3, fx.keyA, controller, (#"", #"")),
              1,
            ),
          ),
      datum: InlineDatum(
        RequestDatum(
          Request {
            requestToken: TokenId { assetName: stateNameTwo },
            requestOwner: controller,
            requestKey: fx.keyA,
            edge: 3,
            submitted_at: 0,
            destination: (#"", #""),
            deposit: fx.deposit,
          },
        ),
      ),
      reference_script: None,
    },
  }
}

fn burnTwo() -> Value {
  from_asset(activeTwo, fx.keyA, -1)
}

/// Registry two's own retirement of keyA, releasing instance two's
/// holding.
fn registryTwoAlone(paid: List<Output>) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    validity_range: fx.phase1(),
    inputs: [stateInputTwo(), requestTwo(), holdingTwo()],
    outputs: [continuationTwo(), ..paid],
    mint: burnTwo(),
    redeemers: [
      Pair(Spend(stateRefTwo), Modify([UpdateAction([])]) |> as_data_modify),
      Pair(Spend(holdingRefTwo), Release |> as_data_spend),
    ],
  }
}

/// Both registries' retirements and both releases in one transaction,
/// registry one's continuation first.
fn twoRegistries(paid: List<Output>) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    validity_range: fx.phase1(),
    inputs: [
      stateInput(),
      stateInputTwo(),
      terminateRequest(controller, fx.keyA),
      requestTwo(),
      holding(),
      holdingTwo(),
    ],
    outputs: [
      stateOutputAt(fx.oneLeaf(fx.keyA, fx.terminalLeaf), theState()),
      continuationTwo(),
      ..paid
    ],
    mint: theBurn() |> merge(burnTwo()),
    redeemers: [
      Pair(Spend(stateRef), Modify([UpdateAction([])]) |> as_data_modify),
      Pair(Spend(stateRefTwo), Modify([UpdateAction([])]) |> as_data_modify),
      Pair(Spend(holdingRef), Release |> as_data_spend),
      Pair(Spend(holdingRefTwo), Release |> as_data_spend),
    ],
  }
}

fn releaseTwo(tx: Transaction) -> Bool {
  open_datum.open_datum.spend(
    registryTwo(),
    Some(envelopeTwo() |> as_data_envelope),
    Release,
    holdingRefTwo,
    tx,
  )
}

fn registryTwoFolds(tx: Transaction) -> Bool {
  state.state.spend(
    Some(StateDatum(stateTwo())),
    Modify([UpdateAction([])]),
    stateRefTwo,
    tx,
  )
}

test registry_one_alone_folds_and_releases() {
  let tx = honestRelease()
  registryFolds(tx) && release(tx)
}

test registry_two_alone_folds_and_releases() {
  let tx = registryTwoAlone([payController(fx.deposit + appDeposit)])
  registryTwoFolds(tx) && releaseTwo(tx)
}

test registry_two_alone_paid_one_short_refuses_where_the_registry_accepts() {
  let tx = registryTwoAlone([payController(fx.deposit + appDeposit - 1)])
  registryTwoFolds(tx) && releaseTwo(tx) == False
}

/// The same transaction with both folds: registry one's continuation is
/// first, so registry one folds and registry two's own validator refuses
/// at `state-token` — read from the registry's own refusal function.
test two_registries_in_one_transaction_the_second_refuses_state_token() {
  let tx = twoRegistries([payController(2 * fx.deposit + 2 * appDeposit)])
  and {
    registryFolds(tx),
    state.modifyRefusal(stateTwo(), [UpdateAction([])], stateInputTwo(), tx) == Some(
      @"state-token",
    ),
    registryTwoFolds(tx) == False,
  }
}

/// With registry two's continuation first instead, registry one refuses
/// at `state-token`: neither order folds both.
test two_registries_in_either_order_the_other_refuses_state_token() {
  let tx = twoRegistries([payController(2 * fx.deposit + 2 * appDeposit)])
  expect [first, second, ..rest] = tx.outputs
  let swapped = Transaction { ..tx, outputs: [second, first, ..rest] }
  and {
    registryTwoFolds(swapped),
    state.modifyRefusal(theState(), [UpdateAction([])], stateInput(), swapped) == Some(
      @"state-token",
    ),
    registryFolds(swapped) == False,
  }
}

// ----------------------------------------------------------------------------
// No other spending path
// ----------------------------------------------------------------------------

test withdrawal_as_update_to_a_wallet_refuses() {
  update(
    updateTx(
      [
        fx.deliveryOutput(
          fx.activePolicy,
          fx.keyA,
          controllerAddress,
          NoDatum,
          appDeposit,
        ),
      ],
      [controller],
    ),
  ) == False
}

//// The preserved application controls, rebound to the permanent contract.
////
//// Every refusal is `== False` and sits beside an accepting control that
//// moves exactly one fact back. The release rows run the SAME transaction
//// through the registry's own state validator as well, so an accepted
//// release is a fold the registry accepts too, and a refused one is
//// refused by the application while the registry alone would accept it.

use aiken/builtin
use aiken/cbor
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval
use aiken/primitive/bytearray
use aiken/primitive/int
use aiken/primitive/string
use application/envelope.{
  BookInsert, BookTerminate, BookTermination, Control, Envelope, OpenDatumMint,
  Release, StateAsset, Update, envelopeHash, envelopeVersion,
}
use booking.{applicationTagName, trieReadyTagName}
use cardano/address.{Address, Script}
use cardano/assets.{Value, from_asset, from_lovelace, lovelace_of, merge, zero}
use cardano/script_context.{Minting, ScriptContext, ScriptInfo, Spending}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction,
}
use lib.{approvalDestination, approvalName}
use open_datum as open_datum
use registry_fixtures as fx
use registry_pin.{registryStateHash}
use request as request_validator
use state as state
use types.{
  Modify, RegistrationDatum, RegistrationRequest, Rejected, Request,
  RequestAction, RequestDatum, State, StateDatum, TerminationDatum,
  TerminationRequest, TokenId, UpdateAction,
}

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

/// The original envelope vector with only its state-policy bytes rebound;
/// the CBOR and BLAKE2b-256 were independently regenerated from that vector.
test envelope_a_serialises_to_the_shared_cbor() {
  cbor.serialise(envelopeA()) == #"d8799fd8799f01d8799f581c4d9efebdde87e0b29a8fe1887022a6b802769172842f4dca4460c94f4a636167652d746f6b656eff581caaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa446b657941581cd1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d11a001e8480ff45616c696365ff"
}

test envelope_a_hashes_to_the_shared_digest() {
  envelopeHash(envelopeA()) == #"5579874d8ccfe363082548c0b1590b62eb21ec70bc0e3a70630132650fe6b1e8"
}

// ----------------------------------------------------------------------------
// The legacy insertion witness (retired)
// ----------------------------------------------------------------------------
//
// The fixtures below build the legacy booking the application accepted before
// the registration migration: an edge-1 `RequestDatum` carrying an approval
// named by `approvalName`. They stay as the refusal witness of the retired route
// (`tagged_registration_*_refuses_the_legacy_request_witness`). The tagged
// registration booking is at the end of this file.
//
// Old to new map of the retired `insert_booking_*` and `closed_booking_*` rows
// (each started from the legacy witness, whose accepting control is now a
// refusal, so none can stay as an individual guard):
//
// - `insert_booking_control_accepts`, `closed_booking_accepts_insertion`:
//   `tagged_registration_open_datum_mint_accepts_the_booking`,
//   `..._closed_datum_mint_...`;
// - `insert_booking_admits_any_payload`:
//   `tagged_registration_open_datum_mint_admits_any_payload` (all seven
//   payload shapes complete);
// - `insert_booking_wrong_version_refuses`, `..._wrong_registry_refuses`,
//   `..._wrong_active_policy_refuses`, `..._other_key_refuses`,
//   `..._other_owner_refuses`, `..._unsigned_refuses`,
//   `..._other_destination_refuses`, `..._without_state_refuses`,
//   `..._state_elsewhere_refuses`, `..._state_of_other_application_refuses`,
//   `..._two_approvals_refuses`, and `closed_booking_refuses_wrong_version_where_open_refuses`:
//   the same-named `tagged_registration_*` rows, each one fact from the
//   accepting tagged witness;
// - `insert_booking_short_request_deposit_refuses`: `tagged_registration_short_carrier_refuses`;
// - `insert_booking_naming_no_datum_refuses`:
//   `tagged_registration_request_carrying_no_datum_refuses` and
//   `..._another_envelope_refuses`;
// - `insert_booking_other_edge_refuses`: retired with the edge number; the minted
//   name binds the nonce instead (`tagged_registration_application_tag_of_another_nonce_refuses`).
// ----------------------------------------------------------------------------

/// An insertion's request destination: this script, carrying the
/// envelope itself as the datum the delivered output must hold.
fn insertDestination(e: Envelope) -> (ByteArray, Option<Data>) {
  let carried: Data = e
  (appAddress(), Some(carried))
}

fn insertName(e: Envelope) -> ByteArray {
  approvalName(
    1,
    e.control.key,
    controller,
    approvalDestination(insertDestination(e)),
  )
}

/// The booked request, carrying its approval.
fn requestOutput(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, Option<Data>),
  depositAmount: Int,
  name: ByteArray,
) -> Output {
  Output {
    address: address.from_script(registryStateHash),
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

// ----------------------------------------------------------------------------
// Booking a termination: the retired mint certification
// ----------------------------------------------------------------------------
//
// The model has no application approval for a termination: the booking is the
// application's `BookTermination` spend plus the request policy's mint, and
// the legacy `BookTerminate` mint arm certifies nothing (the success
// expectations `terminate_booking_control_accepts` and
// `closed_booking_accepts_termination` are retired with it; the valid booking
// is `open_datum_termination_booking_valid_witness_is_accepted_by_the_spend`
// and its closed twin). The refusals below stay as executable controls of the
// retired arm, and each observation they made now lives at the spend:
//
// - no live output: the spent output is the input of the spend itself
//   (`..._without_the_spent_output_refuses`);
// - live output without the token: `..._refuses_a_custody_without_the_token`;
// - live output elsewhere: a spend handler only runs for an input at its own
//   script address, so the ledger carries it;
// - envelope of another registry, key or active policy: the three
//   `..._refuses_an_envelope_...` rows (`app-terminate-binding`);
// - a non-controller or unsigned booking: `..._refuses_an_unsigned_booking`
//   and `..._a_booking_signed_by_another_party` (`app-controller-signature`;
//   the approval's `owner` has no counterpart because no approval is minted);
// - a named destination: `..._refuses_a_named_destination`
//   (`app-terminate-destination`).

// ----------------------------------------------------------------------------
// Booking a termination (the retired mint arm)
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
      (#"", None),
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

fn exportApplication(
  number: Int,
  tx: Transaction,
  redeemer: Data,
  info: ScriptInfo,
) -> Bool {
  let context: Data = ScriptContext { transaction: tx, redeemer, info }
  let parameter: Data = registry()
  let arguments: Data = [parameter, context]
  trace string.join(
    [
      @"M1-APPLICATION",
      int.to_string(number),
      bytearray.to_hex(cbor.serialise(arguments)),
    ],
    @":",
  )
  True
}

test export_application_contexts() {
  let e = envelopeA()
  let insert: Data =
    BookInsert {
      key: e.control.key,
      owner: controller,
      address: appAddress(),
      envelope: e,
    }
  let terminate: Data =
    BookTerminate { key: fx.keyA, owner: controller, holding: holdingRef }
  let update: Data = Update
  let release: Data = Release
  let datum: Data = e
  and {
    exportApplication(0, honestTagged(openInstance(), e), insert, Minting(app)),
    exportApplication(
      1,
      terminateTx(
        [stateInput(), holding()],
        [controller],
        terminateName(controller),
      ),
      terminate,
      Minting(app),
    ),
    exportApplication(
      2,
      updateTx([next(payloadB())], [controller]),
      update,
      Spending { output: holdingRef, datum: Some(datum) },
    ),
    exportApplication(
      3,
      honestRelease(),
      release,
      Spending { output: holdingRef, datum: Some(datum) },
    ),
  }
}

// ---------------------------------------------------------------------
// Closed datum (issue 651): the same code with every update refused.
// ---------------------------------------------------------------------

fn closedUpdate(tx: Transaction) -> Bool {
  open_datum.closed_datum.spend(
    registry(),
    Some(envelopeA() |> as_data_envelope),
    Update,
    holdingRef,
    tx,
  )
}

fn closedRelease(tx: Transaction) -> Bool {
  open_datum.closed_datum.spend(
    registry(),
    Some(envelopeA() |> as_data_envelope),
    Release,
    holdingRef,
    tx,
  )
}

fn closedBookInsertWith(
  e: Envelope,
  redeemerKey: ByteArray,
  owner: ByteArray,
  address: ByteArray,
  tx: Transaction,
) -> Bool {
  open_datum.closed_datum.mint(
    registry(),
    BookInsert { key: redeemerKey, owner, address, envelope: e },
    app,
    tx,
  )
}

fn closedBookInsert(e: Envelope, tx: Transaction) -> Bool {
  closedBookInsertWith(e, e.control.key, controller, appAddress(), tx)
}

fn closedBookTerminateAs(owner: ByteArray, tx: Transaction) -> Bool {
  open_datum.closed_datum.mint(
    registry(),
    BookTerminate { key: fx.keyA, owner, holding: holdingRef },
    app,
    tx,
  )
}

test closed_update_refuses_every_payload() {
  list_all(
    payloads(),
    fn(p) { closedUpdate(updateTx([next(p)], [controller])) == False },
  )
}

test closed_update_refusal_is_the_closed_rule() {
  list_all(
    payloads(),
    fn(p) {
      let tx = updateTx([next(p)], [controller])
      closedUpdate(tx) == False && update(tx)
    },
  )
}

test closed_booking_refuses_termination_without_live_output_where_open_refuses() {
  let tx = terminateTx([stateInput()], [controller], terminateName(controller))
  bookTerminateAs(controller, tx) == False && closedBookTerminateAs(
    controller,
    tx,
  ) == False
}

test closed_else_refuses() fail {
  open_datum.closed_datum.else(#"", #"")
}

// ============================================================================
// CP1 RED: the termination booking is the application's spend plus the
// request policy's mint (no approval is minted)
// ============================================================================
//
// One valid whole-transfer booking: Alice's 4 ADA live output (singular tag,
// deposit and surplus) is spent now and every lovelace of it moves into one
// termination request, H = V + A, A the booker's declared ordinary addition
// (a natural number in the model).
//
// A `Case` is one complete booking: the actual spent custody output (its
// inline envelope and value), the transaction around it, and the declared
// addition. Every negative changes one field of the case; the real typed
// `spend` of `open_datum` and the real forwarding of `closed_datum` are called
// with that same case's envelope as the datum and its input as the spent
// output, and the named judgement is read from that same input and control.
// A helper that answers correctly cannot make a row pass while the handler
// accepts: each negative asserts the handler refusal itself.
//
// RED: the judgement is absent. The valid positives fail because the arm
// refuses everything; every row that expects the model's name fails for that
// absence; the retired approvals are still certified. A negative's handler
// refusal passes today only because the absent judgement refuses everything:
// that conjunct is a guard against an accepting GREEN, not RED evidence, and
// the reason conjunct beside it is the RED part.

const tbValue: Int = 4_000_000

/// The Lean preimage `bookingCommitment 1 ([1, key, destination] ++ [nonce])`.
fn tbTrieName(key: ByteArray, destination: ByteArray, n: Int) -> ByteArray {
  blake2b_256(
    builtin.serialise_data(
      builtin.list_data(
        [
          builtin.i_data(1),
          builtin.i_data(1),
          builtin.b_data(key),
          builtin.b_data(destination),
          builtin.i_data(n),
        ],
      ),
    ),
  )
}

/// A request holding `lovelace` less the tip, declared consistently.
fn tbRequestHolding(lovelace: Int) -> TerminationRequest {
  TerminationRequest {
    registry: fx.cageToken,
    key: fx.keyA,
    destination: #"",
    declared_tip: fx.tip,
    carrier_ada: lovelace - fx.tip,
    nonce: 1,
  }
}

fn tbTag(r: TerminationRequest) -> Value {
  from_asset(
    fx.bookingRequestPolicy,
    tbTrieName(r.key, r.destination, r.nonce),
    1,
  )
}

fn tbRequestOutput(r: TerminationRequest, lovelace: Int) -> Output {
  Output {
    address: address.from_script(fx.bookingRequestPolicy),
    value: from_lovelace(lovelace)
      |> merge(from_asset(fx.activePolicy, r.key, 1))
      |> merge(tbTag(r)),
    datum: InlineDatum(TerminationDatum(r)),
    reference_script: None,
  }
}

fn tbOrdinary() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"4f524449",
      output_index: 0,
    },
    output: Output {
      address: address.from_verification_key(controller),
      value: from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn tbHeld() -> Value {
  from_lovelace(tbValue) |> merge(from_asset(fx.activePolicy, fx.keyA, 1))
}

type Case {
  /// The inline datum of the spent output and the datum handed to the spend.
  envelope: Envelope,
  /// The value of the spent output.
  held: Value,
  request: TerminationRequest,
  request_lovelace: Int,
  extra_outputs: List<Output>,
  references: List<Input>,
  signers: List<ByteArray>,
  added: Int,
}

fn tbCase() -> Case {
  Case {
    envelope: envelopeA(),
    held: tbHeld(),
    request: tbRequestHolding(tbValue),
    request_lovelace: tbValue,
    extra_outputs: [],
    references: [stateInput()],
    signers: [controller],
    added: 0,
  }
}

/// The spent output, at the address, reference, value and inline envelope the
/// case says.
fn tbSpent(c: Case) -> Input {
  liveWith(c.envelope, c.held, appAddr())
}

fn tbTx(c: Case) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [tbSpent(c), tbOrdinary()],
    reference_inputs: c.references,
    outputs: [tbRequestOutput(c.request, c.request_lovelace), ..c.extra_outputs],
    mint: tbTag(c.request),
    extra_signatories: c.signers,
  }
}

fn tbRedeemer(c: Case) -> envelope.OpenDatumSpend {
  BookTermination { ordinary_added: c.added }
}

/// The real typed spend of `open_datum`.
fn tbSpend(c: Case) -> Bool {
  open_datum.open_datum.spend(
    registry(),
    Some(c.envelope |> as_data_envelope),
    tbRedeemer(c),
    holdingRef,
    tbTx(c),
  )
}

/// The real typed spend of `closed_datum`, which forwards it.
fn tbClosedSpend(c: Case) -> Bool {
  open_datum.closed_datum.spend(
    registry(),
    Some(c.envelope |> as_data_envelope),
    tbRedeemer(c),
    holdingRef,
    tbTx(c),
  )
}

/// The named judgement, read from the same spent input and control.
fn tbReason(c: Case) -> Option<String> {
  open_datum.bookTerminationRefusal(
    registry(),
    c.envelope.control,
    tbSpent(c),
    c.added,
    tbTx(c),
  )
}

/// Both handlers refuse the case and the judgement names `why`.
fn tbRefusedAs(c: Case, why: String) -> Bool {
  tbSpend(c) == False && tbClosedSpend(c) == False && tbReason(c) == Some(why)
}

fn tbAccepted(c: Case) -> Bool {
  tbSpend(c) && tbClosedSpend(c) && tbReason(c) == None
}

// ----------------------------------------------------------------------------
// Positives: the valid whole transfer, the zero boundary, lawful funding
// ----------------------------------------------------------------------------

test open_datum_termination_booking_valid_witness_is_accepted_by_the_spend() {
  tbSpend(tbCase())
}

test closed_datum_termination_booking_valid_witness_is_accepted_by_the_spend() {
  tbClosedSpend(tbCase())
}

test open_datum_termination_booking_valid_witness_names_no_refusal() {
  tbReason(tbCase()) == None
}

test open_datum_termination_booking_accepts_a_declared_ordinary_addition() {
  let added = 1_000_000
  tbAccepted(
    Case {
      ..tbCase(),
      request: tbRequestHolding(tbValue + added),
      request_lovelace: tbValue + added,
      added,
    },
  )
}

test open_datum_termination_booking_allows_an_unrelated_payment_to_the_controller() {
  tbAccepted(
    Case {
      ..tbCase(),
      extra_outputs: [fx.paymentOutput(controllerAddress, 5_000_000)],
    },
  )
}

// ----------------------------------------------------------------------------
// Negatives: one field of the case each, refused by the actual spend
// ----------------------------------------------------------------------------

test open_datum_termination_booking_refuses_an_unpinned_application() {
  let foreign = State { ..theState(), application_policy: fx.foreignPolicy }
  tbRefusedAs(
    Case { ..tbCase(), references: [stateInputWith(foreign)] },
    @"app-not-pinned",
  )
}

test open_datum_termination_booking_refuses_a_missing_registry_state() {
  tbRefusedAs(Case { ..tbCase(), references: [] }, @"app-registry-asset")
}

test open_datum_termination_booking_refuses_a_second_asset_in_the_custody() {
  tbRefusedAs(
    Case {
      ..tbCase(),
      held: tbHeld() |> merge(from_asset(fx.foreignPolicy, "extra", 1)),
    },
    @"app-terminate-token",
  )
}

test open_datum_termination_booking_refuses_an_envelope_for_another_registry() {
  let other =
    Control {
      ..control(),
      registry: StateAsset { statePolicy: #"6f74686572", stateName },
    }
  tbRefusedAs(
    Case { ..tbCase(), envelope: envelopeOf(other, payloadA()) },
    @"app-terminate-binding",
  )
}

test open_datum_termination_booking_refuses_an_unsigned_booking() {
  tbRefusedAs(Case { ..tbCase(), signers: [] }, @"app-controller-signature")
}

test open_datum_termination_booking_refuses_a_named_destination() {
  tbRefusedAs(
    Case {
      ..tbCase(),
      request: TerminationRequest { ..tbCase().request, destination: #"01" },
    },
    @"app-terminate-destination",
  )
}

test open_datum_termination_booking_refuses_a_custody_without_the_token() {
  tbRefusedAs(
    Case { ..tbCase(), held: from_lovelace(tbValue) },
    @"app-terminate-token",
  )
}

test open_datum_termination_booking_refuses_an_envelope_of_another_key() {
  let other = Control { ..control(), key: fx.keyB }
  tbRefusedAs(
    Case { ..tbCase(), envelope: envelopeOf(other, payloadA()) },
    @"app-terminate-binding",
  )
}

test open_datum_termination_booking_refuses_an_envelope_of_another_active_policy() {
  let other = Control { ..control(), activePolicy: fx.foreignPolicy }
  tbRefusedAs(
    Case { ..tbCase(), envelope: envelopeOf(other, payloadA()) },
    @"app-terminate-binding",
  )
}

test open_datum_termination_booking_refuses_a_booking_signed_by_another_party() {
  tbRefusedAs(
    Case { ..tbCase(), signers: [fx.inserterKey] },
    @"app-controller-signature",
  )
}

test open_datum_termination_booking_without_the_spent_output_refuses() fail {
  open_datum.open_datum.spend(
    registry(),
    Some(tbCase().envelope |> as_data_envelope),
    tbRedeemer(tbCase()),
    holdingRef,
    Transaction { ..tbTx(tbCase()), inputs: [tbOrdinary()] },
  )
}

test open_datum_termination_booking_refuses_a_diverted_part_of_the_value() {
  tbRefusedAs(
    Case {
      ..tbCase(),
      request: tbRequestHolding(tbValue - 1),
      request_lovelace: tbValue - 1,
      extra_outputs: [fx.paymentOutput(controllerAddress, 1)],
    },
    @"app-termination-value",
  )
}

test open_datum_termination_booking_refuses_an_undeclared_addition() {
  tbRefusedAs(
    Case { ..tbCase(), request_lovelace: tbValue + 1 },
    @"app-termination-value",
  )
}

// ----------------------------------------------------------------------------
// The natural-number domain of the declared addition (Lean `ordinaryAdded : Nat`)
// ----------------------------------------------------------------------------

/// Alice's custody is 4 ADA, the booking declares an addition of minus 1 ADA,
/// the request is declared consistently at 3 ADA and the removed 1 ADA leaves
/// as an ordinary output: an equality-only `H = V + A` would accept it.
fn tbNegativeAddition() -> Case {
  let added = 0 - 1_000_000
  Case {
    ..tbCase(),
    request: tbRequestHolding(tbValue + added),
    request_lovelace: tbValue + added,
    extra_outputs: [fx.paymentOutput(controllerAddress, 1_000_000)],
    added,
  }
}

test open_datum_termination_booking_refuses_a_negative_declared_addition() {
  tbRefusedAs(tbNegativeAddition(), @"app-termination-value")
}

test open_datum_termination_booking_refuses_a_negative_addition_of_one_lovelace() {
  let added = 0 - 1
  tbRefusedAs(
    Case {
      ..tbCase(),
      request: tbRequestHolding(tbValue + added),
      request_lovelace: tbValue + added,
      added,
    },
    @"app-termination-value",
  )
}

// The model has no application approval for a termination: the booking is
// the application's spend plus the request policy's mint. The legacy mint
// certification is retired.

test open_datum_termination_approval_is_retired() {
  bookTerminateAs(
    controller,
    terminateTx(
      [stateInput(), holding()],
      [controller],
      terminateName(controller),
    ),
  ) == False
}

test closed_datum_termination_approval_is_retired() {
  closedBookTerminateAs(
    controller,
    terminateTx(
      [stateInput(), holding()],
      [controller],
      terminateName(controller),
    ),
  ) == False
}

// ----------------------------------------------------------------------------
// The old Release route is refused (CP2)
// ----------------------------------------------------------------------------
//
// The accepted fold has no state-spending rejection, no deposit returned to
// the controller and no approval-admitted request (`Economics/Fold.lean`). The
// valid old release (`honestRelease`: a legacy terminate request, the live
// output and the burn, folded together) was accepted by both the state spend
// and the `Release` arm before CP2 (the RED run shows each accepted). A key
// is terminated by booking and a permissionless fold of the pending request
// (`tagged_fold.tests.ak`), so `Release` is refused for every transaction and
// the registry no longer folds the old request. The `Release` constructor
// stays for the wire shape.
//
// Old to new map of the retired rows. The rows that asserted the old release
// is accepted with the registry (`release_control_accepts_with_the_registry`,
// `release_split_payments_to_the_controller_accept`,
// `two_releases_to_one_controller_paid_in_full_accept_with_the_registry`,
// `registry_one_alone_folds_and_releases`,
// `registry_two_alone_folds_and_releases`, `closed_release_accepts_with_the_registry`)
// are the valid tagged folds in `tagged_fold.tests.ak`. The rows that refused one
// fact of the old release (additive payment, one output for both floors,
// a holding with two tokens or none, no fold, a state not folding, another
// registry, another key, another owner, no burn, a rejected termination, a state
// pinning another application, two releases paid short, two registries in one
// transaction) guarded obligations of the old fold that the model does not
// have: no deposit is returned to a controller, the burn belongs to the fold of
// the pending termination, and the pending request holds the custody the live
// output booked. They are retired with the route, not kept as guards: against
// a blanket refusal they would each pass for the same reason. What they
// protected survives where the model keeps it: the custody of a booking is
// judged by `BookTermination` (the `open_datum_termination_*` rows), the burn
// and the tags by the tagged fold (`fold-singular-mismatch`,
// `fold-tag-not-burned`), and a second state in one transaction by
// `tagged_fold_refuses_a_second_input_holding_a_state_token` and `..._output_...`.

/// The registry's fold: a legacy request is no pending request, so the fold
/// has no member.
test tagged_fold_retires_the_legacy_release_fold() {
  let tx = honestRelease()
  registryFolds(tx) == False && state.modifyRefusal(
    theState(),
    [UpdateAction([])],
    stateInput(),
    tx,
  ) == Some(@"empty-fold")
}

/// The application's `Release` arm refuses the old route whatever the state
/// does with it.
test tagged_fold_retires_the_legacy_release_arm() {
  release(honestRelease()) == False
}

/// The old split payments to the controller refuse the same way.
test tagged_fold_retires_the_legacy_release_with_split_payments() {
  let tx =
    releaseTx(
      theState(),
      terminateRequest(controller, fx.keyA),
      UpdateAction([]),
      [payController(fx.deposit), payController(appDeposit)],
      theBurn(),
    )
  registryFolds(tx) == False && release(tx) == False
}

/// The closed instance forwards `Release` to the same refusal.
test closed_datum_retires_the_release_arm() {
  closedRelease(honestRelease()) == False
}

/// `Release` is refused for a transaction that has nothing to do with the old
/// fold: no state, no request, only the live output and a payment. The refusal
/// is the arm's own, not a side effect of a fold that did not land.
test tagged_fold_release_is_refused_without_any_fold() {
  let tx =
    Transaction {
      ..transaction.placeholder,
      inputs: [holding()],
      outputs: [payController(appDeposit)],
      extra_signatories: [controller],
      redeemers: [Pair(Spend(holdingRef), Release |> as_data_spend)],
    }
  release(tx) == False && closedRelease(tx) == False
}

// ----------------------------------------------------------------------
// Composition with the fold: the application tag is burned by the fold
// ----------------------------------------------------------------------
//
// A registration's fold burns its application tag under the application
// policy. These rows run the real mint handlers of this application, open and
// closed, on a transaction that only burns an application tag, as the fold
// does (`tagged_fold.tests.ak` runs the generic `open` policy on the whole
// fold transaction): a pure burn is evidence destroyed and costs the registry
// nothing, so it is accepted without a redeemer's content and without a state.
// They are preservation tests of a correct guard and pass at once.

fn applicationBurn() -> Transaction {
  Transaction {
    ..transaction.placeholder,
    mint: from_asset(app, #"6170706c69636174696f6e2d746167", -1),
  }
}

test open_datum_accepts_the_burn_of_an_application_tag() {
  let redeemer: OpenDatumMint =
    BookTerminate { key: fx.keyA, owner: controller, holding: holdingRef }
  open_datum.open_datum.mint(registry(), redeemer, app, applicationBurn())
}

test closed_datum_accepts_the_burn_of_an_application_tag() {
  let redeemer: OpenDatumMint =
    BookTerminate { key: fx.keyA, owner: controller, holding: holdingRef }
  open_datum.closed_datum.mint(registry(), redeemer, app, applicationBurn())
}

/// A mint beside the burn is not a pure burn: the fold's transaction cannot
/// use the application policy to mint.
test open_datum_refuses_a_mint_beside_a_burn_of_application_tags() {
  let tx = applicationBurn()
  let redeemer: OpenDatumMint =
    BookTerminate { key: fx.keyA, owner: controller, holding: holdingRef }
  open_datum.open_datum.mint(
    registry(),
    redeemer,
    app,
    Transaction {
      ..tx,
      mint: tx.mint |> merge(from_asset(app, #"6f74686572", 1)),
    },
  ) == False
}

// ============================================================================
// The tagged registration booking (A-035)
// ============================================================================
//
// The model's registration booking by the application (`OpenDatumApplication`
// `insertionBinding`, `bookInsertStep`): the booking is one transaction that
// leaves one tagged request output at the request address and mints, under
// the application policy, the application tag of exactly that request, and
// under the request policy its trie-ready tag. The application's mint judges
// the whole-envelope binding of the request it certifies:
//
// - the application pin of the registry state (a reference input), the full
//   registry asset, the envelope version, the registry's active policy;
// - the key, the controller as the request's refund address, the destination
//   as this script, and the carried datum as the complete envelope;
// - the envelope's deposit as the request's carrier lovelace;
// - the controller's signature; and the minted name as the request's own
//   application tag (key, refund address, destination, nonce).
//
// The request policy judges the request itself and its trie-ready tag
// (`registration_booking.tests.ak`); the two mints are run on the same
// transaction, apart, so the failure of one cannot hide the observation of
// the other. This is composition of constructed handlers on constructed
// transactions, not a compiled identity and not a ledger run.
//
// Classes of rows (`tagged_registration_*`): the accepting witnesses and the
// refusal of the formerly accepted legacy witness were RED (absent behavior)
// and are the GREEN of this continuation. At RED the one-fact refusals below
// gave no sensitivity: thirteen reached an application guard that already
// existed (version, registry, active policy, key, owner, signature,
// destination, state, a second tag) and six stopped at `app-request` because
// the legacy request was expected and absent. With the positive control
// accepting they are one fact from a witness that lands. The request-policy rows
// existed already and are preservation evidence. The rows of the last two
// sections (one registry, the request's tags) were added with the implementation
// and passed at once: preservation tests of checks traced in the source, with
// no failing control observed.

/// A second application instance, the closed one, with its own policy hash:
/// the registry state pins it, the destination is its address and the tags are
/// minted under it.
const closedApp: ByteArray =
  #"c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"

type Instance {
  closed: Bool,
  policy: ByteArray,
  state: State,
}

fn openInstance() -> Instance {
  Instance { closed: False, policy: app, state: theState() }
}

fn closedInstance() -> Instance {
  Instance {
    closed: True,
    policy: closedApp,
    state: State { ..theState(), application_policy: closedApp },
  }
}

fn instanceAddress(i: Instance) -> ByteArray {
  bytearray.concat(#"70", i.policy)
}

/// The booked request of envelope `e` at this instance: its destination is the
/// instance, its carried datum the complete envelope, its carrier the
/// envelope's deposit, its refund address the controller, booked at 5 000.
fn taggedRequest(i: Instance, e: Envelope, nonce: Int) -> RegistrationRequest {
  let carried: Data = e
  RegistrationRequest {
    registry: TokenId { assetName: stateName },
    key: e.control.key,
    refund_address: e.control.controller,
    destination: instanceAddress(i),
    datum: Some(carried),
    submitted_at: 5_000,
    registration_cost: fx.registrationCost,
    declared_tip: fx.tip,
    carrier_ada: e.control.deposit,
    nonce,
  }
}

fn applicationTagOf(r: RegistrationRequest) -> ByteArray {
  applicationTagName(r.key, r.refund_address, r.destination, r.nonce)
}

/// The request output the booking leaves: at the request address, holding the
/// declared lovelace, the trie-ready tag, and the application tag `name`.
fn taggedOutput(i: Instance, r: RegistrationRequest, name: ByteArray) -> Output {
  Output {
    address: address.from_script(i.state.request_policy),
    value: from_lovelace(r.registration_cost + r.declared_tip + r.carrier_ada)
      |> merge(from_asset(i.state.request_policy, trieReadyTagName(r), 1))
      |> merge(from_asset(i.policy, name, 1)),
    datum: InlineDatum(RegistrationDatum(r)),
    reference_script: None,
  }
}

/// The booking transaction: the request output, its two tags minted, the
/// bounded validity interval ending at the booked time, the signers and the
/// reference inputs.
fn taggedTx(
  i: Instance,
  r: RegistrationRequest,
  references: List<Input>,
  signers: List<ByteArray>,
  name: ByteArray,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    validity_range: interval.between(1_000, 5_000),
    reference_inputs: references,
    outputs: [taggedOutput(i, r, name)],
    extra_signatories: signers,
    mint: from_asset(i.policy, name, 1)
      |> merge(from_asset(i.state.request_policy, trieReadyTagName(r), 1)),
  }
}

fn honestTagged(i: Instance, e: Envelope) -> Transaction {
  let r = taggedRequest(i, e, 1)
  taggedTx(
    i,
    r,
    [stateInputWith(i.state)],
    [e.control.controller],
    applicationTagOf(r),
  )
}

/// The real application mint of this instance for `BookInsert`.
fn bookTaggedWith(
  i: Instance,
  e: Envelope,
  redeemerKey: ByteArray,
  owner: ByteArray,
  address: ByteArray,
  tx: Transaction,
) -> Bool {
  let redeemer = BookInsert { key: redeemerKey, owner, address, envelope: e }
  if i.closed {
    open_datum.closed_datum.mint(registry(), redeemer, i.policy, tx)
  } else {
    open_datum.open_datum.mint(registry(), redeemer, i.policy, tx)
  }
}

fn bookTagged(i: Instance, e: Envelope, tx: Transaction) -> Bool {
  bookTaggedWith(
    i,
    e,
    e.control.key,
    e.control.controller,
    instanceAddress(i),
    tx,
  )
}

/// The real request-policy mint on a booking transaction, with the policy the
/// registry state pins.
fn requestMints(i: Instance, tx: Transaction) -> Bool {
  let redeemer: Data = #""
  request_validator.request.mint(
    registryStateHash,
    stateName,
    redeemer,
    i.state.request_policy,
    tx,
  )
}

// ---- the accepting witnesses (RED: the application still reads the legacy request)

test tagged_registration_open_datum_mint_accepts_the_booking() {
  let e = envelopeA()
  bookTagged(openInstance(), e, honestTagged(openInstance(), e))
}

test tagged_registration_closed_datum_mint_accepts_the_booking() {
  let e = envelopeA()
  bookTagged(closedInstance(), e, honestTagged(closedInstance(), e))
}

/// Arbitrary payload stays arbitrary: the payload rides in the carried
/// envelope and is not read.
test tagged_registration_open_datum_mint_admits_any_payload() {
  list_all(
    payloads(),
    fn(p) {
      let e = envelopeOf(control(), p)
      bookTagged(openInstance(), e, honestTagged(openInstance(), e))
    },
  )
}

// ---- the request policy on the same coherent transactions (preservation)

test tagged_registration_request_mint_accepts_the_open_booking() {
  requestMints(openInstance(), honestTagged(openInstance(), envelopeA()))
}

test tagged_registration_request_mint_accepts_the_closed_booking() {
  requestMints(closedInstance(), honestTagged(closedInstance(), envelopeA()))
}

// ---- the formerly accepted legacy witness is refused (RED)

test tagged_registration_open_datum_mint_refuses_the_legacy_request_witness() {
  bookInsert(envelopeA(), honestInsertTx(envelopeA())) == False
}

test tagged_registration_closed_datum_mint_refuses_the_legacy_request_witness() {
  closedBookInsert(envelopeA(), honestInsertTx(envelopeA())) == False
}

// ---- one fact from the accepting witness (incidental refusals until GREEN)

fn refusesTagged(i: Instance, e: Envelope, tx: Transaction) -> Bool {
  bookTagged(i, e, tx) == False
}

test tagged_registration_wrong_version_refuses() {
  let e = envelopeOf(Control { ..control(), version: 2 }, payloadA())
  refusesTagged(openInstance(), e, honestTagged(openInstance(), e))
}

test tagged_registration_wrong_registry_refuses() {
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
  refusesTagged(openInstance(), e, honestTagged(openInstance(), e))
}

test tagged_registration_wrong_active_policy_refuses() {
  let e =
    envelopeOf(
      Control { ..control(), activePolicy: fx.foreignPolicy },
      payloadA(),
    )
  refusesTagged(openInstance(), e, honestTagged(openInstance(), e))
}

test tagged_registration_other_key_in_the_redeemer_refuses() {
  let i = openInstance()
  let e = envelopeA()
  bookTaggedWith(
    i,
    e,
    fx.keyB,
    e.control.controller,
    instanceAddress(i),
    honestTagged(i, e),
  ) == False
}

test tagged_registration_other_owner_in_the_redeemer_refuses() {
  let i = openInstance()
  let e = envelopeA()
  bookTaggedWith(
    i,
    e,
    e.control.key,
    fx.inserterKey,
    instanceAddress(i),
    honestTagged(i, e),
  ) == False
}

test tagged_registration_request_for_another_key_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = RegistrationRequest { ..taggedRequest(i, e, 1), key: fx.keyB }
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [e.control.controller],
      applicationTagOf(r),
    ),
  )
}

test tagged_registration_request_with_another_refund_address_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r =
    RegistrationRequest {
      ..taggedRequest(i, e, 1),
      refund_address: fx.inserterKey,
    }
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [e.control.controller],
      applicationTagOf(r),
    ),
  )
}

test tagged_registration_unsigned_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [fx.inserterKey],
      applicationTagOf(r),
    ),
  )
}

test tagged_registration_other_destination_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let elsewhere = bytearray.concat(#"70", fx.foreignPolicy)
  let r =
    RegistrationRequest { ..taggedRequest(i, e, 1), destination: elsewhere }
  bookTaggedWith(
    i,
    e,
    e.control.key,
    e.control.controller,
    elsewhere,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [e.control.controller],
      applicationTagOf(r),
    ),
  ) == False
}

test tagged_registration_short_carrier_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r =
    RegistrationRequest {
      ..taggedRequest(i, e, 1),
      carrier_ada: e.control.deposit - 1,
    }
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [e.control.controller],
      applicationTagOf(r),
    ),
  )
}

/// The request carries no datum: the fold would deliver the token to an
/// output carrying none. Nothing but the missing datum is wrong.
test tagged_registration_request_carrying_no_datum_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = RegistrationRequest { ..taggedRequest(i, e, 1), datum: None }
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [e.control.controller],
      applicationTagOf(r),
    ),
  )
}

/// The request carries another envelope than the redeemer's: the booked datum
/// is not the complete envelope the application certifies.
test tagged_registration_request_carrying_another_envelope_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let other: Data = envelopeOf(control(), payloadB())
  let r = RegistrationRequest { ..taggedRequest(i, e, 1), datum: Some(other) }
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [e.control.controller],
      applicationTagOf(r),
    ),
  )
}

/// The minted application tag is the name of another nonce: it is not the
/// request's own tag.
test tagged_registration_application_tag_of_another_nonce_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [e.control.controller],
      applicationTagOf(RegistrationRequest { ..r, nonce: 2 }),
    ),
  )
}

test tagged_registration_without_state_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  refusesTagged(
    i,
    e,
    taggedTx(i, r, [], [e.control.controller], applicationTagOf(r)),
  )
}

test tagged_registration_state_elsewhere_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  let s = stateInputWith(i.state)
  let displaced =
    Input {
      ..s,
      output: Output {
        ..s.output,
        address: address.from_script(fx.foreignPolicy),
      },
    }
  refusesTagged(
    i,
    e,
    taggedTx(i, r, [displaced], [e.control.controller], applicationTagOf(r)),
  )
}

test tagged_registration_state_of_other_application_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  let other =
    stateInputWith(State { ..i.state, application_policy: fx.foreignPolicy })
  refusesTagged(
    i,
    e,
    taggedTx(i, r, [other], [e.control.controller], applicationTagOf(r)),
  )
}

test tagged_registration_two_application_tags_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let tx = honestTagged(i, e)
  refusesTagged(
    i,
    e,
    Transaction {
      ..tx,
      mint: merge(tx.mint, from_asset(i.policy, #"6f74686572", 1)),
    },
  )
}

test tagged_registration_closed_other_key_in_the_redeemer_refuses() {
  let i = closedInstance()
  let e = envelopeA()
  bookTaggedWith(
    i,
    e,
    fx.keyB,
    e.control.controller,
    instanceAddress(i),
    honestTagged(i, e),
  ) == False
}

test tagged_registration_closed_unsigned_refuses() {
  let i = closedInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  refusesTagged(
    i,
    e,
    taggedTx(
      i,
      r,
      [stateInputWith(i.state)],
      [fx.inserterKey],
      applicationTagOf(r),
    ),
  )
}

// ---- one registry: the application, the request and the state agree ----------
//
// An application instance serves one registry and consults that registry's
// state (the one reference input that holds its full state asset). The request
// it certifies must be that registry's: the request's own `registry` names the
// registry's token, the output sits at the request policy that state pins, and
// that policy's trie-ready tag is minted in the same booking, so the pinned
// request policy, which consults the same state, judges the same booking. A
// request of another registry, or one judged under another request policy, is
// not authenticated by this instance's state.

/// The booking of `r` with the request output at `address` and its trie-ready
/// tag under `tagPolicy`, minted when `minted`.
fn taggedTxAt(
  i: Instance,
  r: RegistrationRequest,
  address: Address,
  tagPolicy: ByteArray,
  minted: Bool,
) -> Transaction {
  let name = applicationTagOf(r)
  let tag = trieReadyTagName(r)
  Transaction {
    ..transaction.placeholder,
    validity_range: interval.between(1_000, 5_000),
    reference_inputs: [stateInputWith(i.state)],
    outputs: [
      Output {
        address,
        value: from_lovelace(
          r.registration_cost + r.declared_tip + r.carrier_ada,
        )
          |> merge(from_asset(tagPolicy, tag, 1))
          |> merge(from_asset(i.policy, name, 1)),
        datum: InlineDatum(RegistrationDatum(r)),
        reference_script: None,
      },
    ],
    extra_signatories: [r.refund_address],
    mint: from_asset(i.policy, name, 1)
      |> merge(
          if minted {
            from_asset(tagPolicy, tag, 1)
          } else {
            zero
          },
        ),
  }
}

/// A request of another registry: its wire `registry` names another token.
/// The root's request policy refuses it too (`dirty-request`), so the two
/// handlers agree on one registry.
test tagged_registration_request_of_another_registry_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r =
    RegistrationRequest {
      ..taggedRequest(i, e, 1),
      registry: TokenId { assetName: #"6f74686572" },
    }
  let tx =
    taggedTxAt(
      i,
      r,
      address.from_script(i.state.request_policy),
      i.state.request_policy,
      True,
    )
  refusesTagged(i, e, tx) && requestMints(i, tx) == False
}

/// The request sits at, and its trie-ready tag is minted under, another request
/// policy than the one this registry's state pins: a request policy of another
/// registry would consult that registry's state, not this one.
test tagged_registration_request_under_another_request_policy_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  refusesTagged(
    i,
    e,
    taggedTxAt(
      i,
      r,
      address.from_script(fx.foreignPolicy),
      fx.foreignPolicy,
      True,
    ),
  )
}

/// The request output holds its trie-ready tag, but the tag is not minted in
/// this booking: the pinned request policy does not run and nothing judges the
/// request.
test tagged_registration_trie_ready_tag_not_minted_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  refusesTagged(
    i,
    e,
    taggedTxAt(
      i,
      r,
      address.from_script(i.state.request_policy),
      i.state.request_policy,
      False,
    ),
  )
}

/// The request output at the pinned request address does not hold the
/// request's trie-ready tag at all (another tag name is minted and held).
test tagged_registration_request_without_its_trie_ready_tag_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let r = taggedRequest(i, e, 1)
  let tx = honestTagged(i, e)
  let other = trieReadyTagName(RegistrationRequest { ..r, nonce: 2 })
  expect [out] = tx.outputs
  refusesTagged(
    i,
    e,
    Transaction {
      ..tx,
      outputs: [
        Output {
          ..out,
          value: from_lovelace(lovelace_of(out.value))
            |> merge(from_asset(i.policy, applicationTagOf(r), 1))
            |> merge(from_asset(i.state.request_policy, other, 1)),
        },
      ],
      mint: from_asset(i.policy, applicationTagOf(r), 1)
        |> merge(from_asset(i.state.request_policy, other, 1)),
    },
  )
}

/// Another registry's state beside this one in the same transaction is
/// ignored by both consumers: the application takes the one reference input
/// that is its own registry's state, and the request policy takes the one that
/// holds its own token. The booking lands for both, and each consulted the same
/// state.
test tagged_registration_another_registrys_state_beside_this_one_is_ignored() {
  let i = openInstance()
  let e = envelopeA()
  let tx = honestTagged(i, e)
  let other =
    Input {
      output_reference: OutputReference {
        transaction_id: #"4f54484552",
        output_index: 0,
      },
      output: Output {
        address: address.from_script(registryStateHash),
        value: from_asset(registryStateHash, #"6f74686572", 1)
          |> merge(from_lovelace(5_000_000)),
        datum: InlineDatum(StateDatum(i.state)),
        reference_script: None,
      },
    }
  let both =
    Transaction { ..tx, reference_inputs: [other, ..tx.reference_inputs] }
  bookTagged(i, e, both) && requestMints(i, both)
}

/// And a state of another registry alone does not authenticate the booking.
test tagged_registration_another_registrys_state_alone_refuses() {
  let i = openInstance()
  let e = envelopeA()
  let tx = honestTagged(i, e)
  let s = stateInputWith(i.state)
  let other =
    Input {
      ..s,
      output: Output {
        ..s.output,
        value: from_asset(registryStateHash, #"6f74686572", 1)
          |> merge(from_lovelace(5_000_000)),
      },
    }
  refusesTagged(i, e, Transaction { ..tx, reference_inputs: [other] })
}

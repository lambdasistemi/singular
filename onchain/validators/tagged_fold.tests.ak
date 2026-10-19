use aiken/builtin
use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval.{Interval}
use booking.{applicationTagName, trieReadyTagName}
use cardano/address
use cardano/assets.{Value, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction,
}
use lib
use registry_fixtures as fx
use request as request_validator
use state
use types.{
  CageDatum, Contribute, Modify, RegistrationDatum, RegistrationRequest,
  Rejected, RequestAction, Retract, StateDatum, TerminationDatum,
  TerminationRequest, UpdateAction,
}

// ============================================================================
// CP2 RED: the fold of tagged requests (the accepted root fold)
// ============================================================================
//
// The accepted fold (`Economics/Fold.lean`, `FoldRouting.lean`,
// `Observation.lean`) folds the pending requests a booking left behind,
// whatever their kind:
//
// - a REGISTRATION folds only inside its processing window; it mints the
//   key's singular tag, delivers it to the booked destination with exactly
//   the declared carrier lovelace and the booked datum, donates the
//   registration cost, and burns both of its request tags;
// - a TERMINATION has no window: its custody already moved at booking, so the
//   fold burns the singular tag the request holds and the trie-ready tag,
//   delivers nothing and donates held minus tip;
// - in both, the exact tip stays in ordinary value (ordinary output lovelace
//   plus fee equals ordinary input lovelace plus the sum of declared tips),
//   the continuation keeps the state's lovelace, no other asset moves, every
//   pending request tag is burned and no singular tag survives that the
//   members did not deliver.
//
// Two real typed boundaries are exercised, each by its own rows and never
// through a short-circuited conjunct of the other: the registry's
// `state.spend` (`Modify`), whose named reason is read from
// `state.modifyRefusal`, the one construction site the handler traces; and
// the request's `request.spend` (`Contribute`) of each member. Names are the
// model's, except where the cage already has one for the same check
// (`state-drain`, `root`, `empty-fold`, `lib.occupiedRefusal`, the trie
// faults).
//
// How each row relates to the cage as it stands (the handoff classifies every
// row by execution):
//
// - RED: the valid folds and the named refusals. A tagged registration or
//   termination is no member of the legacy fold, so the state refuses it as
//   `empty-fold`; `request.spend` stops at `expect Some(RequestDatum(_))`.
// - Guards: each refusal row also asserts the handler's own False. That holds
//   today because the fold refuses every tagged request; it is a guard
//   against an accepting GREEN, not RED evidence. The `fail` rows of the
//   request boundary pass today because the datum shape is not a
//   `RequestDatum`; at GREEN they are the witnesses that a correct state
//   with an unconditional `request.spend` cannot hide.
// - Preserved: the last section holds today and must keep holding.
//
// Limits: Aiken evaluation of constructed transactions. The mint handlers of
// the active, request and application policies are not run here (the active
// policy is bound to the compiled state identity, derived once after the
// accepted GREEN), and nothing says a ledger accepts the transactions.

// ----------------------------------------------------------------------------
// The case: one complete fold
// ----------------------------------------------------------------------------

/// A pending request as the transaction observes it: the output it rides in
/// and the datum that output carries, one value so the two cannot disagree.
type Member {
  input: Input,
  datum: CageDatum,
}

type Case {
  root: ByteArray,
  next: ByteArray,
  members: List<Member>,
  extra_inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  actions: List<RequestAction>,
  range: Interval<Int>,
  donation: Option<Int>,
  fee: Int,
}

fn txOf(c: Case) -> Transaction {
  let modify: Data = Modify(c.actions)
  Transaction {
    ..fx.foldTx(
      c.root,
      c.next,
      list.map(c.members, fn(m) { m.input }),
      c.extra_inputs,
      c.outputs,
      c.mint,
    ),
    validity_range: c.range,
    treasury_donation: c.donation,
    fee: c.fee,
    redeemers: [Pair(Spend(fx.stateRef), modify)],
  }
}

// ---- the state boundary ----------------------------------------------------

/// The real typed spend of the registry's state.
fn foldSpend(c: Case) -> Bool {
  foldSpendTx(c, txOf(c))
}

fn foldSpendTx(c: Case, tx: Transaction) -> Bool {
  state.state.spend(
    Some(StateDatum(fx.stateOf(c.root))),
    Modify(c.actions),
    fx.stateRef,
    tx,
  )
}

/// The named reason of the same judgement.
fn foldReason(c: Case) -> Option<String> {
  foldReasonTx(c, txOf(c))
}

fn foldReasonTx(c: Case, tx: Transaction) -> Option<String> {
  state.modifyRefusal(fx.stateOf(c.root), c.actions, fx.stateInput(c.root), tx)
}

/// The state folds it: the handler accepts and there is no reason.
fn stateFolds(c: Case) -> Bool {
  foldSpend(c) && foldReason(c) == None
}

/// The state spend refuses and names `why`.
fn refusedAs(c: Case, why: String) -> Bool {
  foldSpend(c) == False && foldReason(c) == Some(why)
}

/// The same, for a reason the cage constructs in one place (`lib`).
fn refusedAsConstructed(c: Case, why: Option<String>) -> Bool {
  foldSpend(c) == False && foldReason(c) == why
}

/// The same, for a transaction the row built from the case by hand (the
/// continuation tampered with).
fn refusedTxAs(c: Case, tx: Transaction, why: String) -> Bool {
  foldSpendTx(c, tx) == False && foldReasonTx(c, tx) == Some(why)
}

/// The state refuses, and for a reason other than the absence of a member:
/// the case has authentic members, so the refusal belongs to what the row
/// changed.
fn refusedForWhatChanged(c: Case) -> Bool {
  foldSpend(c) == False && when foldReason(c) is {
    Some(why) -> why != @"empty-fold"
    None -> False
  }
}

// ---- the request boundary --------------------------------------------------

/// The real typed spend of one member's request output, `Contribute` naming
/// `stateRef`, in transaction `tx`.
fn contributesAt(m: Member, stateRef: OutputReference, tx: Transaction) -> Bool {
  request_validator.request.spend(
    fx.cagePolicy,
    fx.cageToken.assetName,
    Some(m.datum),
    Contribute(stateRef),
    m.input.output_reference,
    tx,
  )
}

/// The spend of a member in the case's own transaction.
fn contributes(c: Case, m: Member) -> Bool {
  contributesAt(m, fx.stateRef, txOf(c))
}

fn onlyMember(c: Case) -> Member {
  expect [m] = c.members
  m
}

// ----------------------------------------------------------------------------
// The pending requests a booking leaves
// ----------------------------------------------------------------------------

fn regRequest() -> RegistrationRequest {
  RegistrationRequest {
    registry: fx.cageToken,
    key: fx.keyA,
    refund_address: fx.bookerKey,
    destination: fx.bookerAddress,
    datum: None,
    submitted_at: 0,
    registration_cost: fx.registrationCost,
    declared_tip: fx.tip,
    carrier_ada: 1_500_000,
    nonce: 1,
  }
}

fn regDeclared(r: RegistrationRequest) -> Int {
  r.registration_cost + r.declared_tip + r.carrier_ada
}

fn regTrieTag(r: RegistrationRequest, quantity: Int) -> Value {
  from_asset(fx.bookingRequestPolicy, trieReadyTagName(r), quantity)
}

fn regApplicationTag(r: RegistrationRequest, quantity: Int) -> Value {
  from_asset(
    fx.appPolicy,
    applicationTagName(r.key, r.refund_address, r.destination, r.nonce),
    quantity,
  )
}

fn requestAddress() -> address.Address {
  address.from_script(fx.bookingRequestPolicy)
}

fn regInput(r: RegistrationRequest, index: Int) -> Input {
  Input {
    output_reference: fx.requestRef(index),
    output: Output {
      address: requestAddress(),
      value: from_lovelace(regDeclared(r))
        |> merge(regTrieTag(r, 1))
        |> merge(regApplicationTag(r, 1)),
      datum: InlineDatum(RegistrationDatum(r)),
      reference_script: None,
    },
  }
}

/// The Lean preimage `[1, 1, key, destination, nonce]` of a termination's
/// trie-ready tag, hashed here independently of the production helper.
fn termTagName(r: TerminationRequest) -> ByteArray {
  blake2b_256(
    builtin.serialise_data(
      builtin.list_data(
        [
          builtin.i_data(1),
          builtin.i_data(1),
          builtin.b_data(r.key),
          builtin.b_data(r.destination),
          builtin.i_data(r.nonce),
        ],
      ),
    ),
  )
}

/// A termination booked at 4 ADA held: the tip plus the carrier.
fn termRequestFor(key: ByteArray) -> TerminationRequest {
  TerminationRequest {
    registry: fx.cageToken,
    key,
    destination: #"",
    declared_tip: fx.tip,
    carrier_ada: 4_000_000 - fx.tip,
    nonce: 1,
  }
}

fn termRequest() -> TerminationRequest {
  termRequestFor(fx.keyA)
}

fn termHeld(r: TerminationRequest) -> Int {
  r.declared_tip + r.carrier_ada
}

fn termTrieTag(r: TerminationRequest, quantity: Int) -> Value {
  from_asset(fx.bookingRequestPolicy, termTagName(r), quantity)
}

fn singular(key: ByteArray, quantity: Int) -> Value {
  from_asset(fx.activePolicy, key, quantity)
}

fn termInput(r: TerminationRequest, index: Int) -> Input {
  Input {
    output_reference: fx.requestRef(index),
    output: Output {
      address: requestAddress(),
      value: from_lovelace(termHeld(r))
        |> merge(singular(r.key, 1))
        |> merge(termTrieTag(r, 1)),
      datum: InlineDatum(TerminationDatum(r)),
      reference_script: None,
    },
  }
}

fn regMember(r: RegistrationRequest, index: Int) -> Member {
  Member { input: regInput(r, index), datum: RegistrationDatum(r) }
}

fn termMember(r: TerminationRequest, index: Int) -> Member {
  Member { input: termInput(r, index), datum: TerminationDatum(r) }
}

/// The folder's own ordinary value: a wallet output with no tag and no datum.
fn ordinaryInput() -> Input {
  ordinaryInputOf(from_lovelace(10_000_000))
}

fn ordinaryInputOf(value: Value) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"4f524446",
      output_index: 0,
    },
    output: Output {
      address: address.from_verification_key(fx.inserterKey),
      value,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn change(lovelace: Int) -> Output {
  fx.paymentOutput(fx.inserterAddress, lovelace)
}

fn carrierOf(r: RegistrationRequest) -> Output {
  fx.deliveryOutput(
    fx.activePolicy,
    r.key,
    r.destination,
    NoDatum,
    r.carrier_ada,
  )
}

// ----------------------------------------------------------------------------
// The valid folds
// ----------------------------------------------------------------------------

/// A registration folded inside its window: the key goes into the trie, its
/// singular tag is minted and delivered with the declared carrier, both
/// request tags are burned, the registration cost is the donation and the
/// tip stays in the folder's ordinary value.
fn regCase() -> Case {
  let r = regRequest()
  Case {
    root: fx.emptyRoot(),
    next: fx.oneLeaf(r.key, fx.activeLeaf),
    members: [regMember(r, 0)],
    extra_inputs: [ordinaryInput()],
    outputs: [carrierOf(r), change(10_000_000 + r.declared_tip)],
    mint: singular(r.key, 1)
      |> merge(regTrieTag(r, -1))
      |> merge(regApplicationTag(r, -1)),
    actions: [UpdateAction([])],
    range: fx.phase1(),
    donation: Some(r.registration_cost),
    fee: 0,
  }
}

/// A termination folded after both windows: its custody moved at booking, so
/// the fold burns the singular tag the request holds and the trie-ready tag,
/// delivers nothing, and donates held minus tip.
fn termCase() -> Case {
  let t = termRequest()
  Case {
    root: fx.oneLeaf(t.key, fx.activeLeaf),
    next: fx.oneLeaf(t.key, fx.terminalLeaf),
    members: [termMember(t, 0)],
    extra_inputs: [ordinaryInput()],
    outputs: [change(10_000_000 + t.declared_tip)],
    mint: singular(t.key, -1) |> merge(termTrieTag(t, -1)),
    actions: [UpdateAction([])],
    range: fx.phase3(),
    donation: Some(termHeld(t) - t.declared_tip),
    fee: 0,
  }
}

/// Two terminations in one fold: the donation and the tips aggregate.
fn batchCase() -> Case {
  let a = termRequestFor(fx.keyA)
  let b = termRequestFor(fx.keyB)
  Case {
    root: fx.twoLeaves(fx.keyA, fx.activeLeaf, fx.keyB, fx.activeLeaf),
    next: fx.twoLeaves(fx.keyA, fx.terminalLeaf, fx.keyB, fx.terminalLeaf),
    members: [termMember(a, 0), termMember(b, 1)],
    extra_inputs: [ordinaryInput()],
    outputs: [change(10_000_000 + a.declared_tip + b.declared_tip)],
    mint: singular(a.key, -1)
      |> merge(singular(b.key, -1))
      |> merge(termTrieTag(a, -1))
      |> merge(termTrieTag(b, -1)),
    actions: [
      UpdateAction(fx.siblingProof(fx.keyB, fx.activeLeaf, fx.keyA)),
      UpdateAction(fx.siblingProof(fx.keyA, fx.terminalLeaf, fx.keyB)),
    ],
    range: fx.phase3(),
    donation: Some(termHeld(a) - a.declared_tip + termHeld(b) - b.declared_tip),
    fee: 0,
  }
}

// ---- the state boundary: each valid fold lands -----------------------------

test tagged_fold_state_folds_a_registration_inside_its_window() {
  stateFolds(regCase())
}

test tagged_fold_state_folds_a_termination_after_both_windows() {
  stateFolds(termCase())
}

test tagged_fold_state_folds_a_termination_inside_the_processing_window_too() {
  stateFolds(Case { ..termCase(), range: fx.phase1() })
}

test tagged_fold_state_folds_two_terminations_with_aggregate_donation() {
  stateFolds(batchCase())
}

// ---- the request boundary: each member's own spend, executed apart ---------

test tagged_fold_request_spend_contributes_a_registration() {
  let c = regCase()
  contributes(c, onlyMember(c))
}

test tagged_fold_request_spend_contributes_a_termination() {
  let c = termCase()
  contributes(c, onlyMember(c))
}

test tagged_fold_request_spend_contributes_both_terminations_of_a_batch() {
  let c = batchCase()
  list.all(c.members, fn(m) { contributes(c, m) })
}

// ----------------------------------------------------------------------------
// The request boundary refuses on its own
// ----------------------------------------------------------------------------
//
// A request output is spendable only inside a fold of the registry it names:
// the state of that registry is spent in the same transaction with `Modify`.
// Each row removes or alters exactly one of those and runs the real
// `request.spend`, so a correct state validator beside an `request.spend`
// that accepts unconditionally fails these rows. They are `fail` rows, the
// repository's idiom for a spend that refuses by `expect`; their valid twins
// are the rows above.

fn withoutState(tx: Transaction) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.filter(tx.inputs, fn(i) { i.output_reference != fx.stateRef }),
    redeemers: [],
  }
}

fn stateSpentAs(tx: Transaction, redeemer: Data) -> Transaction {
  Transaction { ..tx, redeemers: [Pair(Spend(fx.stateRef), redeemer)] }
}

/// The state input holds another registry's token.
fn stateOfAnotherRegistry(tx: Transaction) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.map(
      tx.inputs,
      fn(i) {
        if i.output_reference == fx.stateRef {
          Input {
            ..i,
            output: Output {
              ..i.output,
              value: from_asset(fx.cagePolicy, fx.foreignCageToken.assetName, 1)
                |> merge(from_lovelace(fx.stateLovelace)),
            },
          }
        } else {
          i
        }
      },
    ),
  }
}

test tagged_fold_request_spend_refuses_a_registration_without_the_state() fail {
  let c = regCase()
  contributesAt(onlyMember(c), fx.stateRef, withoutState(txOf(c)))
}

test tagged_fold_request_spend_refuses_a_termination_without_the_state() fail {
  let c = termCase()
  contributesAt(onlyMember(c), fx.stateRef, withoutState(txOf(c)))
}

test tagged_fold_request_spend_refuses_a_registration_when_the_state_does_not_modify() fail {
  let c = regCase()
  let retract: Data = Retract(fx.stateRef)
  contributesAt(onlyMember(c), fx.stateRef, stateSpentAs(txOf(c), retract))
}

test tagged_fold_request_spend_refuses_a_termination_when_the_state_does_not_modify() fail {
  let c = termCase()
  let retract: Data = Retract(fx.stateRef)
  contributesAt(onlyMember(c), fx.stateRef, stateSpentAs(txOf(c), retract))
}

test tagged_fold_request_spend_refuses_a_registration_naming_another_input_as_the_state() fail {
  let c = regCase()
  contributesAt(onlyMember(c), fx.requestRef(9), txOf(c))
}

test tagged_fold_request_spend_refuses_a_termination_naming_another_input_as_the_state() fail {
  let c = termCase()
  contributesAt(onlyMember(c), fx.requestRef(9), txOf(c))
}

test tagged_fold_request_spend_refuses_a_registration_beside_another_registrys_state() fail {
  let c = regCase()
  contributesAt(onlyMember(c), fx.stateRef, stateOfAnotherRegistry(txOf(c)))
}

test tagged_fold_request_spend_refuses_a_termination_beside_another_registrys_state() fail {
  let c = termCase()
  contributesAt(onlyMember(c), fx.stateRef, stateOfAnotherRegistry(txOf(c)))
}

test tagged_fold_request_spend_refuses_a_registration_of_another_registry() fail {
  let c = regCase()
  let r = RegistrationRequest { ..regRequest(), registry: fx.foreignCageToken }
  contributesAt(
    Member { ..onlyMember(c), datum: RegistrationDatum(r) },
    fx.stateRef,
    txOf(c),
  )
}

test tagged_fold_request_spend_refuses_a_termination_of_another_registry() fail {
  let c = termCase()
  let t = TerminationRequest { ..termRequest(), registry: fx.foreignCageToken }
  contributesAt(
    Member { ..onlyMember(c), datum: TerminationDatum(t) },
    fx.stateRef,
    txOf(c),
  )
}

// ----------------------------------------------------------------------------
// Registration: timing, observation, routing, donation, burns
// ----------------------------------------------------------------------------

test tagged_fold_registration_refuses_after_its_window() {
  refusedAs(Case { ..regCase(), range: fx.phase3() }, @"not-phase1")
}

test tagged_fold_registration_refuses_a_fold_interval_before_its_booking() {
  let r = RegistrationRequest { ..regRequest(), submitted_at: 3_000 }
  refusedAs(Case { ..regCase(), members: [regMember(r, 0)] }, @"not-phase1")
}

test tagged_fold_registration_refuses_a_tampered_donation() {
  let r = regRequest()
  refusedAs(
    Case { ..regCase(), donation: Some(r.registration_cost + 1) },
    @"fold-donation-mismatch",
  )
}

test tagged_fold_registration_refuses_a_missing_donation() {
  refusedAs(Case { ..regCase(), donation: None }, @"fold-donation-mismatch")
}

test tagged_fold_registration_refuses_a_short_carrier() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      outputs: [
        fx.deliveryOutput(
          fx.activePolicy,
          r.key,
          r.destination,
          NoDatum,
          r.carrier_ada - 1,
        ),
        change(10_000_000 + r.declared_tip),
      ],
    },
    @"destination-carrier-mismatch",
  )
}

test tagged_fold_registration_refuses_a_carrier_at_another_address() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      outputs: [
        fx.deliveryOutput(
          fx.activePolicy,
          r.key,
          fx.inserterAddress,
          NoDatum,
          r.carrier_ada,
        ),
        change(10_000_000 + r.declared_tip),
      ],
    },
    @"fold-destination-mismatch",
  )
}

test tagged_fold_registration_refuses_a_carrier_with_another_datum() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      outputs: [
        fx.deliveryOutput(
          fx.activePolicy,
          r.key,
          r.destination,
          InlineDatum(fx.recordDatum()),
          r.carrier_ada,
        ),
        change(10_000_000 + r.declared_tip),
      ],
    },
    @"fold-destination-mismatch",
  )
}

test tagged_fold_registration_refuses_a_missing_carrier() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      outputs: [change(10_000_000 + r.declared_tip + r.carrier_ada)],
    },
    @"fold-destination-mismatch",
  )
}

/// Two outputs hold the key's singular tag: the carrier is not exactly one.
test tagged_fold_registration_refuses_a_carrier_delivered_twice() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      outputs: [carrierOf(r), carrierOf(r), change(10_000_000 + r.declared_tip)],
    },
    @"fold-destination-mismatch",
  )
}

test tagged_fold_registration_refuses_a_foreign_asset_in_the_carrier() {
  let r = regRequest()
  let carrier = carrierOf(r)
  refusedAs(
    Case {
      ..regCase(),
      outputs: [
        Output {
          ..carrier,
          value: merge(carrier.value, from_asset(fx.foreignPolicy, "extra", 1)),
        },
        change(10_000_000 + r.declared_tip),
      ],
    },
    @"fold-destination-mismatch",
  )
}

test tagged_fold_registration_refuses_an_unburned_trie_ready_tag() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      mint: singular(r.key, 1) |> merge(regApplicationTag(r, -1)),
    },
    @"fold-tag-not-burned",
  )
}

test tagged_fold_registration_refuses_an_unburned_application_tag() {
  let r = regRequest()
  refusedAs(
    Case { ..regCase(), mint: singular(r.key, 1) |> merge(regTrieTag(r, -1)) },
    @"fold-tag-not-burned",
  )
}

test tagged_fold_registration_refuses_a_tag_burned_twice() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      mint: singular(r.key, 1)
        |> merge(regTrieTag(r, -2))
        |> merge(regApplicationTag(r, -1)),
    },
    @"fold-tag-not-burned",
  )
}

/// The burn names another tag of the request policy: the held one is not
/// burned and the mint holds a unit nobody spent.
test tagged_fold_registration_refuses_a_burn_of_another_tag() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      mint: singular(r.key, 1)
        |> merge(from_asset(fx.bookingRequestPolicy, #"6f74686572", -1))
        |> merge(regApplicationTag(r, -1)),
    },
    @"fold-tag-not-burned",
  )
}

test tagged_fold_registration_refuses_a_missing_singular_mint() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      mint: regTrieTag(r, -1) |> merge(regApplicationTag(r, -1)),
    },
    @"fold-singular-mismatch",
  )
}

test tagged_fold_registration_refuses_a_doubled_singular_mint() {
  let r = regRequest()
  refusedAs(
    Case {
      ..regCase(),
      mint: singular(r.key, 2)
        |> merge(regTrieTag(r, -1))
        |> merge(regApplicationTag(r, -1)),
    },
    @"fold-singular-mismatch",
  )
}

test tagged_fold_registration_refuses_an_occupied_key() {
  let r = regRequest()
  refusedAsConstructed(
    Case {
      ..regCase(),
      root: fx.oneLeaf(r.key, fx.activeLeaf),
      next: fx.oneLeaf(r.key, fx.activeLeaf),
    },
    lib.occupiedRefusal(),
  )
}

// ----------------------------------------------------------------------------
// Termination: no window, custody burned, donation held minus tip
// ----------------------------------------------------------------------------

test tagged_fold_termination_refuses_a_tampered_donation() {
  let t = termRequest()
  refusedAs(
    Case { ..termCase(), donation: Some(termHeld(t) - t.declared_tip + 1) },
    @"fold-donation-mismatch",
  )
}

test tagged_fold_termination_refuses_the_tip_in_the_donation() {
  let t = termRequest()
  refusedAs(
    Case { ..termCase(), donation: Some(termHeld(t)) },
    @"fold-donation-mismatch",
  )
}

/// The retired route: the held value less the tip goes back to the booker as a
/// payment, with no donation.
test tagged_fold_termination_refuses_a_refund_in_place_of_the_donation() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      outputs: [
        fx.paymentOutput(fx.bookerAddress, termHeld(t) - t.declared_tip),
        change(10_000_000 + t.declared_tip),
      ],
      donation: None,
    },
    @"fold-donation-mismatch",
  )
}

test tagged_fold_termination_refuses_an_unburned_trie_ready_tag() {
  let t = termRequest()
  refusedAs(
    Case { ..termCase(), mint: singular(t.key, -1) },
    @"fold-tag-not-burned",
  )
}

test tagged_fold_termination_refuses_an_unburned_singular_tag() {
  let t = termRequest()
  refusedAs(
    Case { ..termCase(), mint: termTrieTag(t, -1) },
    @"fold-singular-mismatch",
  )
}

/// The singular tag survives in an output instead of being burned: a pending
/// request is not a custody a later request can use.
test tagged_fold_termination_refuses_a_singular_tag_that_survives() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      outputs: [
        fx.deliveryOutput(
          fx.activePolicy,
          t.key,
          fx.bookerAddress,
          NoDatum,
          2_000_000,
        ),
        change(10_000_000 + t.declared_tip - 2_000_000),
      ],
      mint: termTrieTag(t, -1),
    },
    @"fold-singular-mismatch",
  )
}

test tagged_fold_termination_refuses_a_key_the_trie_does_not_bind() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      root: fx.emptyRoot(),
      next: fx.oneLeaf(t.key, fx.terminalLeaf),
    },
    @"key-unknown",
  )
}

test tagged_fold_termination_refuses_a_key_never_booked() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      root: fx.oneLeaf(t.key, fx.absentLeaf),
      next: fx.oneLeaf(t.key, fx.terminalLeaf),
    },
    @"not-booked",
  )
}

test tagged_fold_termination_refuses_a_key_already_terminal() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      root: fx.oneLeaf(t.key, fx.terminalLeaf),
      next: fx.oneLeaf(t.key, fx.terminalLeaf),
    },
    @"terminal-immutable",
  )
}

test tagged_fold_batch_refuses_the_donation_of_one_member_only() {
  let a = termRequestFor(fx.keyA)
  refusedAs(
    Case { ..batchCase(), donation: Some(termHeld(a) - a.declared_tip) },
    @"fold-donation-mismatch",
  )
}

test tagged_fold_batch_refuses_when_one_member_keeps_its_tags() {
  let a = termRequestFor(fx.keyA)
  let b = termRequestFor(fx.keyB)
  refusedAs(
    Case {
      ..batchCase(),
      mint: singular(a.key, -1)
        |> merge(singular(b.key, -1))
        |> merge(termTrieTag(a, -1)),
    },
    @"fold-tag-not-burned",
  )
}

// ----------------------------------------------------------------------------
// The fold's own prerequisites and routing stay
// ----------------------------------------------------------------------------

test tagged_fold_refuses_an_unbounded_fold_interval() {
  refusedAs(
    Case { ..termCase(), range: interval.everything },
    @"fold-interval-missing",
  )
}

test tagged_fold_refuses_a_wrong_next_root() {
  refusedAs(
    Case { ..termCase(), next: fx.oneLeaf(fx.keyB, fx.terminalLeaf) },
    @"root",
  )
}

/// The continuation keeps the folder's tip: the state's lovelace must equal
/// the spent state's exactly, the tip stays in ordinary value.
test tagged_fold_refuses_a_continuation_that_keeps_the_tip() {
  let c = termCase()
  let grown =
    Output {
      ..fx.stateOutput(c.next),
      value: from_asset(fx.cagePolicy, fx.cageToken.assetName, 1)
        |> merge(from_lovelace(fx.stateLovelace + fx.tip)),
    }
  let tx = Transaction { ..txOf(c), outputs: [grown, change(10_000_000)] }
  refusedTxAs(c, tx, @"fold-state-value-mismatch")
}

test tagged_fold_refuses_a_foreign_mint() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      mint: singular(t.key, -1)
        |> merge(termTrieTag(t, -1))
        |> merge(from_asset(fx.foreignPolicy, "extra", 1)),
    },
    @"fold-foreign-asset",
  )
}

test tagged_fold_refuses_a_foreign_asset_in_the_change() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      outputs: [
        Output {
          ..change(10_000_000 + t.declared_tip),
          value: from_lovelace(10_000_000 + t.declared_tip)
            |> merge(from_asset(fx.foreignPolicy, "extra", 1)),
        },
      ],
    },
    @"fold-foreign-asset",
  )
}

test tagged_fold_refuses_a_foreign_asset_in_the_spent_ordinary_input() {
  let t = termRequest()
  refusedAs(
    Case {
      ..termCase(),
      extra_inputs: [
        ordinaryInputOf(
          from_lovelace(10_000_000)
            |> merge(from_asset(fx.foreignPolicy, "extra", 1)),
        ),
      ],
      outputs: [
        Output {
          ..change(10_000_000 + t.declared_tip),
          value: from_lovelace(10_000_000 + t.declared_tip)
            |> merge(from_asset(fx.foreignPolicy, "extra", 1)),
        },
      ],
    },
    @"fold-foreign-asset",
  )
}

test tagged_fold_refuses_a_fee_the_ordinary_inputs_cannot_fund() {
  refusedAs(Case { ..termCase(), fee: 10_000_001 }, @"fold-fee-funding-short")
}

test tagged_fold_refuses_ordinary_change_one_lovelace_short() {
  let t = termRequest()
  refusedAs(
    Case { ..termCase(), outputs: [change(10_000_000 + t.declared_tip - 1)] },
    @"fold-unbalanced",
  )
}

test tagged_fold_refuses_ordinary_change_one_lovelace_over() {
  let t = termRequest()
  refusedAs(
    Case { ..termCase(), outputs: [change(10_000_000 + t.declared_tip + 1)] },
    @"fold-unbalanced",
  )
}

// ----------------------------------------------------------------------------
// Absent and forged member observations, through the actual transaction
// ----------------------------------------------------------------------------

/// The request states a registration, but the output it rides in lacks the
/// application tag the booking minted: the datum alone does not make a member.
test tagged_fold_refuses_a_registration_without_its_application_tag() {
  let r = regRequest()
  let input = regInput(r, 0)
  let bare =
    Input {
      ..input,
      output: Output {
        ..input.output,
        value: from_lovelace(regDeclared(r)) |> merge(regTrieTag(r, 1)),
      },
    }
  refusedAs(
    Case {
      ..regCase(),
      members: [Member { input: bare, datum: RegistrationDatum(r) }],
      mint: singular(r.key, 1) |> merge(regTrieTag(r, -1)),
    },
    @"request-observation-mismatch",
  )
}

test tagged_fold_refuses_a_registration_without_its_trie_ready_tag() {
  let r = regRequest()
  let input = regInput(r, 0)
  let bare =
    Input {
      ..input,
      output: Output {
        ..input.output,
        value: from_lovelace(regDeclared(r)) |> merge(regApplicationTag(r, 1)),
      },
    }
  refusedAs(
    Case {
      ..regCase(),
      members: [Member { input: bare, datum: RegistrationDatum(r) }],
      mint: singular(r.key, 1) |> merge(regApplicationTag(r, -1)),
    },
    @"request-observation-mismatch",
  )
}

/// The datum the output carries is not the one its tags commit to: the
/// declared carrier differs by one lovelace.
test tagged_fold_refuses_a_registration_datum_that_its_tags_do_not_commit_to() {
  let r = regRequest()
  let forged = RegistrationRequest { ..r, carrier_ada: r.carrier_ada + 1 }
  let input = regInput(r, 0)
  let swapped =
    Input {
      ..input,
      output: Output {
        ..input.output,
        datum: InlineDatum(RegistrationDatum(forged)),
      },
    }
  refusedAs(
    Case {
      ..regCase(),
      members: [Member { input: swapped, datum: RegistrationDatum(forged) }],
    },
    @"request-observation-mismatch",
  )
}

/// The request states a termination, but the output does not hold the
/// singular tag the booking moved into it.
test tagged_fold_refuses_a_termination_without_its_singular_tag() {
  let t = termRequest()
  let input = termInput(t, 0)
  let bare =
    Input {
      ..input,
      output: Output {
        ..input.output,
        value: from_lovelace(termHeld(t)) |> merge(termTrieTag(t, 1)),
      },
    }
  refusedAs(
    Case {
      ..termCase(),
      members: [Member { input: bare, datum: TerminationDatum(t) }],
      mint: termTrieTag(t, -1),
    },
    @"request-observation-mismatch",
  )
}

/// The output holds less than the datum declares.
test tagged_fold_refuses_a_termination_holding_less_than_it_declares() {
  let t = termRequest()
  let input = termInput(t, 0)
  let short =
    Input {
      ..input,
      output: Output {
        ..input.output,
        value: from_lovelace(termHeld(t) - 1)
          |> merge(singular(t.key, 1))
          |> merge(termTrieTag(t, 1)),
      },
    }
  refusedAs(
    Case {
      ..termCase(),
      members: [Member { input: short, datum: TerminationDatum(t) }],
    },
    @"request-observation-mismatch",
  )
}

/// An input that holds a request tag but states no request: it is neither a
/// member nor ordinary value.
test tagged_fold_refuses_an_input_holding_a_tag_but_stating_no_request() {
  let t = termRequest()
  let stray =
    Input {
      output_reference: fx.requestRef(7),
      output: Output {
        address: requestAddress(),
        value: from_lovelace(2_000_000)
          |> merge(from_asset(fx.bookingRequestPolicy, #"73747261", 1)),
        datum: NoDatum,
        reference_script: None,
      },
    }
  refusedAs(
    Case {
      ..termCase(),
      extra_inputs: [ordinaryInput(), stray],
      outputs: [change(10_000_000 + t.declared_tip + 2_000_000)],
      mint: singular(t.key, -1)
        |> merge(termTrieTag(t, -1))
        |> merge(from_asset(fx.bookingRequestPolicy, #"73747261", -1)),
    },
    @"fold-unrecognized-input",
  )
}

// ----------------------------------------------------------------------------
// The state-spending rejection is retired for authentic tagged requests
// ----------------------------------------------------------------------------
//
// The model has no state-spending rejection and no refund to the controller.
// A later handler could refuse every legacy request and still accept
// `Rejected` for a genuine tagged one, so each row below carries authentic
// tagged members and is refused for what it changed, not for the absence of a
// member (`empty-fold`). Two shapes per kind: the valid fold with only its
// action swapped, and the old rejection context (trie unchanged, the held
// value less the tip paid back, the singular tag of a termination returned to
// the booker, no donation, after both windows). The model has no name for the
// refusal, so the rows require one, other than `empty-fold`.

fn rejectedRegistrationRefund() -> Case {
  let r = regRequest()
  Case {
    ..regCase(),
    next: fx.emptyRoot(),
    outputs: [
      fx.paymentOutput(fx.bookerAddress, regDeclared(r) - r.declared_tip),
      change(10_000_000 + r.declared_tip),
    ],
    mint: regTrieTag(r, -1) |> merge(regApplicationTag(r, -1)),
    actions: [Rejected],
    range: fx.phase3(),
    donation: None,
  }
}

fn rejectedTerminationReturn() -> Case {
  let t = termRequest()
  Case {
    ..termCase(),
    next: fx.oneLeaf(t.key, fx.activeLeaf),
    outputs: [
      fx.deliveryOutput(
        fx.activePolicy,
        t.key,
        fx.bookerAddress,
        NoDatum,
        termHeld(t) - t.declared_tip,
      ),
      change(10_000_000 + t.declared_tip),
    ],
    mint: termTrieTag(t, -1),
    actions: [Rejected],
    donation: None,
  }
}

test tagged_fold_retires_rejected_for_a_registration_that_would_fold() {
  refusedForWhatChanged(Case { ..regCase(), actions: [Rejected] })
}

test tagged_fold_retires_rejected_for_a_termination_that_would_fold() {
  refusedForWhatChanged(Case { ..termCase(), actions: [Rejected] })
}

test tagged_fold_retires_rejected_with_a_registrations_refund_context() {
  refusedForWhatChanged(rejectedRegistrationRefund())
}

test tagged_fold_retires_rejected_with_a_terminations_custody_return() {
  refusedForWhatChanged(rejectedTerminationReturn())
}

// ----------------------------------------------------------------------------
// The retired approval-admitted registration, refused as a fold
// ----------------------------------------------------------------------------
//
// The model has no approval-admitted request: a legacy edge-only request is
// not a pending request, so a fold that holds only legacy requests has no
// member (`empty-fold`). The fixture is the accepting row of the existing
// insert (`insert_active_places_one_active_token_at_the_named_output`) and
// folds today; its member is the legacy request together with the legacy
// datum that same output carries. The retired legacy `Rejected` fold and the
// retired controller-refund termination are refused in
// `deposit_exits.tests.ak`, and the old `Release` in the application's
// `open_datum.tests.ak`, each on its own accepting fixture.

fn legacyRegistrationCase() -> Case {
  let destination = fx.bookingDestination()
  Case {
    root: fx.emptyRoot(),
    next: fx.oneLeaf(fx.keyA, fx.activeLeaf),
    members: [
      Member {
        input: fx.requestInput(
          0,
          fx.keyA,
          1,
          fx.bookerKey,
          destination,
          fx.approval(1, fx.keyA, fx.bookerKey, destination),
          fx.requestLovelace,
        ),
        datum: fx.requestDatum(fx.keyA, 1, fx.bookerKey, destination),
      },
    ],
    extra_inputs: [],
    outputs: [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ],
    mint: singular(fx.keyA, 1),
    actions: [UpdateAction([])],
    range: fx.phase1(),
    donation: None,
    fee: 0,
  }
}

test tagged_fold_retires_the_approval_admitted_registration() {
  refusedAs(legacyRegistrationCase(), @"empty-fold")
}

// ----------------------------------------------------------------------------
// Preserved: refusals that hold today and must keep holding
// ----------------------------------------------------------------------------

/// A fold with no member at all is refused before anything else.
test tagged_fold_preserved_refuses_a_fold_with_no_member() {
  refusedAs(
    Case {
      ..termCase(),
      next: fx.oneLeaf(fx.keyA, fx.activeLeaf),
      members: [],
      outputs: [change(10_000_000)],
      mint: zero,
      actions: [],
      donation: None,
    },
    @"empty-fold",
  )
}

/// The continuation may not drain the state's lovelace (the cage's own name
/// for the falling direction of the model's exact-equality check).
test tagged_fold_preserved_refuses_a_continuation_that_drains_the_state() {
  let c = termCase()
  let drained =
    Output {
      ..fx.stateOutput(c.next),
      value: from_asset(fx.cagePolicy, fx.cageToken.assetName, 1)
        |> merge(from_lovelace(fx.stateLovelace - 1)),
    }
  let tx =
    Transaction { ..txOf(c), outputs: [drained, change(10_000_000 + fx.tip)] }
  refusedTxAs(c, tx, @"state-drain")
}

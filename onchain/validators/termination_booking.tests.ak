use aiken/builtin
use aiken/crypto.{blake2b_256}
use booking.{terminationBookingRefusal, terminationTrieReadyTagName}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{PolicyId, Value, from_asset, from_lovelace, merge}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use cardano/transaction as tx_mod
use registry_fixtures as fx
use request as request_validator
use types.{TerminationDatum, TerminationRequest, TokenId}

// ============================================================================
// Termination booking at the real request mint handler (CP1 RED)
// ============================================================================
//
// One valid whole-transfer booking: Alice's key, a 4 ADA custody output (the
// singular tag, a deposit and a surplus), no ordinary addition, the registry's
// minimum tip, and a request output that holds all of it (H = V + A = tip +
// carrier). The request mint handler is the subject of the handler rows; the
// `terminationBookingRefusal` rows read the named reason of the same
// judgement, one independent field changed at a time, in the root model's
// order (`Economics/Termination.lean`, `terminationBookingRefusal`).
//
// RED: the judgement and the handler's termination dispatch are absent, so
// every row that expects the model's answer fails for that absence. The tag
// derivation is representation and is real; its expected value below is
// written out from the Lean preimage, not read from the production helper.
//
// Boundary: Aiken evaluation of constructed transactions. Nothing here says
// that a ledger accepts the transaction.

// ----------------------------------------------------------------------------
// The valid booking and the plan the rows perturb one thing at a time
// ----------------------------------------------------------------------------

const custodyLovelace: Int = 4_000_000

const nonce: Int = 1

fn requestPolicyId() -> PolicyId {
  fx.bookingRequestPolicy
}

fn requestAddress() -> Address {
  Address {
    payment_credential: Script(requestPolicyId()),
    stake_credential: None,
  }
}

fn applicationAddress() -> Address {
  Address { payment_credential: Script(fx.appPolicy), stake_credential: None }
}

fn ordinaryAddress() -> Address {
  Address {
    payment_credential: VerificationKey(fx.bookerKey),
    stake_credential: None,
  }
}

/// The Lean preimage `bookingCommitment 1 ([1, key, destination] ++ [nonce])`,
/// written out field by field.
fn expectedTrieTag(key: ByteArray, destination: ByteArray, n: Int) -> ByteArray {
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

fn singular(key: ByteArray) -> Value {
  from_asset(fx.activePolicy, key, 1)
}

fn theRequest() -> TerminationRequest {
  TerminationRequest {
    registry: fx.cageToken,
    key: fx.keyA,
    destination: #"",
    declared_tip: fx.tip,
    carrier_ada: custodyLovelace - fx.tip,
    nonce,
  }
}

fn declared(r: TerminationRequest) -> Int {
  r.declared_tip + r.carrier_ada
}

fn trieTag(r: TerminationRequest) -> Value {
  from_asset(
    requestPolicyId(),
    expectedTrieTag(r.key, r.destination, r.nonce),
    1,
  )
}

fn requestOutput(r: TerminationRequest, value: Value) -> Output {
  Output {
    address: requestAddress(),
    value,
    datum: InlineDatum(TerminationDatum(r)),
    reference_script: None,
  }
}

fn validOutput(r: TerminationRequest) -> Output {
  requestOutput(
    r,
    from_lovelace(declared(r)) |> merge(singular(r.key)) |> merge(trieTag(r)),
  )
}

fn custodyRef() -> OutputReference {
  OutputReference { transaction_id: #"43555354", output_index: 0 }
}

fn custodyInputOf(key: ByteArray, index: Int) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"43555354",
      output_index: index,
    },
    output: Output {
      address: applicationAddress(),
      value: from_lovelace(custodyLovelace) |> merge(singular(key)),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn ordinaryInput() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"4f524449",
      output_index: 0,
    },
    output: Output {
      address: ordinaryAddress(),
      value: from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn theState() -> Input {
  fx.stateInput(fx.oneLeaf(fx.keyA, fx.activeLeaf))
}

type Plan {
  request: TerminationRequest,
  mint: Value,
  outputs: List<Output>,
  inputs: List<Input>,
  reference_inputs: List<Input>,
}

fn plan() -> Plan {
  let r = theRequest()
  Plan {
    request: r,
    mint: trieTag(r),
    outputs: [validOutput(r)],
    inputs: [custodyInputOf(fx.keyA, 0), ordinaryInput()],
    reference_inputs: [theState()],
  }
}

fn transactionOf(p: Plan) -> Transaction {
  Transaction {
    ..tx_mod.placeholder,
    inputs: p.inputs,
    reference_inputs: p.reference_inputs,
    outputs: p.outputs,
    mint: p.mint,
    extra_signatories: [fx.bookerKey],
  }
}

/// What the real request mint handler answers.
fn handler(p: Plan) -> Bool {
  request_validator.request.mint(
    fx.cagePolicy,
    fx.cageToken.assetName,
    builtin.constr_data(0, []),
    requestPolicyId(),
    transactionOf(p),
  )
}

/// The named reason of the same judgement.
fn reason(p: Plan) -> Option<String> {
  terminationBookingRefusal(
    fx.cagePolicy,
    fx.cageToken,
    requestPolicyId(),
    transactionOf(p),
  )
}

/// The datum states `r` and the output holds exactly its declared lovelace,
/// the singular tag and the original request's trie-ready tag.
fn restated(p: Plan, r: TerminationRequest) -> Plan {
  Plan {
    ..p,
    request: r,
    outputs: [
      requestOutput(
        r,
        from_lovelace(declared(r))
          |> merge(singular(p.request.key))
          |> merge(trieTag(p.request)),
      ),
    ],
  }
}

fn withValue(p: Plan, value: Value) -> Plan {
  Plan { ..p, outputs: [requestOutput(p.request, value)] }
}

// ----------------------------------------------------------------------------
// Representation: the tag derivation is real, the judgement is not
// ----------------------------------------------------------------------------

test termination_booking_trie_ready_tag_is_the_model_preimage() {
  let r = theRequest()
  terminationTrieReadyTagName(r) == expectedTrieTag(
    r.key,
    r.destination,
    r.nonce,
  )
}

// ----------------------------------------------------------------------------
// The valid whole-transfer witness
// ----------------------------------------------------------------------------

test termination_booking_valid_witness_is_accepted_by_the_request_mint() {
  handler(plan())
}

test termination_booking_valid_witness_names_no_refusal() {
  reason(plan()) == None
}

// ----------------------------------------------------------------------------
// The six root branches, in the model's order, one independent field each
// ----------------------------------------------------------------------------
//
// Every negative asserts the refusal of the real `request.mint` handler and,
// beside it, the model's named reason: a correct helper cannot make a row
// pass while the handler accepts. RED: the handler's refusal of a termination
// holds today only because the absent judgement refuses everything (a guard
// against an accepting GREEN, not RED evidence); the named reason is the RED
// part and fails for the absence.

/// The real handler refuses the plan and the judgement names `why`.
fn refusedAs(p: Plan, why: String) -> Bool {
  handler(p) == False && reason(p) == Some(why)
}

test termination_booking_refuses_a_tip_below_the_minimum_as_dirty() {
  let p = plan()
  let r =
    TerminationRequest {
      ..p.request,
      declared_tip: fx.tip - 1,
      carrier_ada: p.request.carrier_ada + 1,
    }
  refusedAs(restated(p, r), @"dirty-request")
}

test termination_booking_refuses_an_extra_asset_as_dirty() {
  let p = plan()
  let value =
    from_lovelace(declared(p.request))
      |> merge(singular(p.request.key))
      |> merge(trieTag(p.request))
      |> merge(from_asset(fx.foreignPolicy, "extra", 1))
  refusedAs(withValue(p, value), @"dirty-request")
}

test termination_booking_refuses_a_hidden_surplus() {
  let p = plan()
  let value =
    from_lovelace(declared(p.request) + 1)
      |> merge(singular(p.request.key))
      |> merge(trieTag(p.request))
  refusedAs(withValue(p, value), @"hidden-surplus")
}

test termination_booking_refuses_a_foreign_registry_as_forged_singular() {
  let p = plan()
  let r =
    TerminationRequest {
      ..p.request,
      registry: TokenId { assetName: #"666f726569676e" },
    }
  refusedAs(restated(p, r), @"forged-singular-tag")
}

test termination_booking_refuses_another_keys_singular_tag() {
  let p = plan()
  let value =
    from_lovelace(declared(p.request))
      |> merge(singular(fx.keyB))
      |> merge(trieTag(p.request))
  refusedAs(withValue(p, value), @"forged-singular-tag")
}

test termination_booking_refuses_a_wrongly_named_trie_ready_tag() {
  let p = plan()
  let wrong = from_asset(requestPolicyId(), #"77726f6e67", 1)
  let value =
    from_lovelace(declared(p.request))
      |> merge(singular(p.request.key))
      |> merge(wrong)
  refusedAs(
    Plan { ..withValue(p, value), mint: wrong },
    @"forged-trie-ready-tag",
  )
}

test termination_booking_refuses_an_extra_minted_trie_ready_tag() {
  let p = plan()
  let twice =
    from_asset(
      requestPolicyId(),
      expectedTrieTag(p.request.key, p.request.destination, p.request.nonce),
      2,
    )
  refusedAs(Plan { ..p, mint: twice }, @"forged-trie-ready-tag")
}

test termination_booking_refuses_a_booking_with_no_custody_input() {
  let p = plan()
  refusedAs(
    Plan { ..p, inputs: [ordinaryInput()] },
    @"singular-tag-not-in-custody",
  )
}

test termination_booking_refuses_a_second_input_claiming_the_singular_tag() {
  let p = plan()
  refusedAs(
    Plan {
      ..p,
      inputs: [
        custodyInputOf(fx.keyA, 0),
        custodyInputOf(fx.keyA, 1),
        ordinaryInput(),
      ],
    },
    @"forged-singular-tag",
  )
}

test termination_booking_precedence_puts_dirty_before_hidden_surplus() {
  let p = plan()
  let r =
    TerminationRequest {
      ..p.request,
      declared_tip: fx.tip - 1,
      carrier_ada: p.request.carrier_ada + 1,
    }
  let value =
    from_lovelace(declared(r) + 1)
      |> merge(singular(p.request.key))
      |> merge(trieTag(p.request))
  refusedAs(
    Plan { ..restated(p, r), outputs: [requestOutput(r, value)] },
    @"dirty-request",
  )
}

// ----------------------------------------------------------------------------
// The natural-number domain of the wire fields (Lean `carrierAda`, `nonce`)
// ----------------------------------------------------------------------------
//
// The model's carrier and nonce are natural numbers, so a negative one has no
// model inhabitant; the wire carries them as integers, and a request that
// states one is malformed contents (`dirty-request`). Both requests are
// otherwise consistent: the declared total equals the held lovelace, the tip
// is at least the minimum, the tags are the ones the datum commits to.

test termination_booking_refuses_a_negative_carrier() {
  let p = plan()
  let r =
    TerminationRequest {
      ..p.request,
      declared_tip: declared(p.request) + 1,
      carrier_ada: 0 - 1,
    }
  refusedAs(restated(p, r), @"dirty-request")
}

test termination_booking_refuses_a_negative_nonce() {
  let p = plan()
  let r = TerminationRequest { ..p.request, nonce: 0 - 1 }
  let value =
    from_lovelace(declared(r)) |> merge(singular(r.key)) |> merge(trieTag(r))
  refusedAs(
    Plan {
      ..p,
      request: r,
      mint: trieTag(r),
      outputs: [requestOutput(r, value)],
    },
    @"dirty-request",
  )
}

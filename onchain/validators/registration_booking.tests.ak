use aiken/builtin
use aiken/interval.{
  Finite, Interval, IntervalBound, NegativeInfinity, PositiveInfinity,
}
use booking.{applicationTagName, registrationBookingRefusal, trieReadyTagName}
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{PolicyId, Value, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{
  DatumHash, InlineDatum, Input, NoDatum, Output, Transaction,
}
use cardano/transaction as tx_mod
use open
use registry_fixtures as fx
use request as request_validator
use types.{
  AbsentCustody, ApproveRegistration, CageDatum, RegistrationDatum,
  RegistrationRequest, Request, RequestDatum, State, StateDatum,
}

// ============================================================================
// Registration booking: the real request mint handler
// ============================================================================
//
// Every row below calls `request.request.mint` with the validator's applied
// parameters (state policy, registry token name) and the policy id the ledger
// would supply: the handler's own dispatch, pure burns included, is the
// subject. The `registrationBookingRefusal` rows at the end read the named
// reason the handler traces; they add to, and never replace, the handler rows.
//
// Boundary: Aiken evaluation of constructed transactions. Nothing here says
// that a ledger accepts the transaction; the devnet booking row does that.
//
// The independent expected tag names live in `cage_vectors`, produced by the
// vector generator's own evaluation of the field-by-field preimages. The
// transactions below build their tags with the production helpers, so a
// helper that drifted from the vectors fails there, and a handler that
// ignored a field fails the one-field rows here.

// ----------------------------------------------------------------------------
// Three distinct requests (the same field values the vector generator uses)
// ----------------------------------------------------------------------------

const thirdKey: ByteArray =
  #"d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3"

/// One request and the width of the interval it books under.
type Scenario {
  request: RegistrationRequest,
  width: Int,
}

fn requestOne() -> Scenario {
  Scenario {
    request: RegistrationRequest {
      registry: fx.cageToken,
      key: fx.keyA,
      refund_address: fx.bookerKey,
      destination: fx.bookerAddress,
      datum: None,
      submitted_at: 1_000_000,
      registration_cost: fx.registrationCost,
      declared_tip: 1_000_000,
      carrier_ada: 1_500_000,
      nonce: 1,
    },
    width: 5_000,
  }
}

/// Books at exactly the registry's widest interval, with a delivered datum.
fn requestTwo() -> Scenario {
  Scenario {
    request: RegistrationRequest {
      registry: fx.cageToken,
      key: fx.keyB,
      refund_address: fx.inserterKey,
      destination: fx.inserterAddress,
      datum: Some(builtin.i_data(42)),
      submitted_at: 2_500_000,
      registration_cost: fx.registrationCost,
      declared_tip: 1_500_000,
      carrier_ada: 1_200_000,
      nonce: 2,
    },
    width: fx.bookingWidth,
  }
}

/// A script destination, a large tip and a nonce wider than a machine word.
fn requestThree() -> Scenario {
  Scenario {
    request: RegistrationRequest {
      registry: fx.cageToken,
      key: fx.keyC,
      refund_address: thirdKey,
      destination: fx.recordAddress,
      datum: None,
      submitted_at: 7_000,
      registration_cost: fx.registrationCost,
      declared_tip: 3_000_000,
      carrier_ada: 2_000_000,
      nonce: 1_000_000_000_000,
    },
    width: 6_000,
  }
}

// ----------------------------------------------------------------------------
// A transaction, as a plan the rows perturb one thing at a time
// ----------------------------------------------------------------------------

type Plan {
  request: RegistrationRequest,
  lower: IntervalBound<Int>,
  upper: IntervalBound<Int>,
  mint: Value,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  inputs: List<Input>,
  redeemer: Data,
}

fn requestPolicyId() -> PolicyId {
  fx.bookingRequestPolicy
}

fn declared(r: RegistrationRequest) -> Int {
  r.registration_cost + r.declared_tip + r.carrier_ada
}

fn applicationTag(r: RegistrationRequest) -> ByteArray {
  applicationTagName(r.key, r.refund_address, r.destination, r.nonce)
}

fn trieTag(r: RegistrationRequest) -> ByteArray {
  trieReadyTagName(r)
}

fn requestTags(r: RegistrationRequest) -> Value {
  from_asset(requestPolicyId(), trieTag(r), 1)
    |> merge(from_asset(fx.appPolicy, applicationTag(r), 1))
}

fn requestAddress() -> Address {
  Address {
    payment_credential: Script(requestPolicyId()),
    stake_credential: None,
  }
}

fn requestOutput(r: RegistrationRequest, value: Value) -> Output {
  Output {
    address: requestAddress(),
    value,
    datum: InlineDatum(RegistrationDatum(r)),
    reference_script: None,
  }
}

fn validOutput(r: RegistrationRequest) -> Output {
  requestOutput(r, from_lovelace(declared(r)) |> merge(requestTags(r)))
}

fn finite(at: Int, inclusive: Bool) -> IntervalBound<Int> {
  IntervalBound { bound_type: Finite(at), is_inclusive: inclusive }
}

/// The ledger's presentation of a finite validity interval: lower included,
/// upper excluded.
fn plan(s: Scenario) -> Plan {
  let r = s.request
  Plan {
    request: r,
    lower: finite(r.submitted_at - s.width, True),
    upper: finite(r.submitted_at, False),
    mint: requestTags(r),
    outputs: [validOutput(r)],
    reference_inputs: [fx.stateInput(#"")],
    inputs: [],
    redeemer: builtin.constr_data(0, []),
  }
}

fn transactionOf(p: Plan) -> Transaction {
  Transaction {
    ..tx_mod.placeholder,
    inputs: p.inputs,
    reference_inputs: p.reference_inputs,
    outputs: p.outputs,
    mint: p.mint,
    validity_range: Interval { lower_bound: p.lower, upper_bound: p.upper },
  }
}

/// What the real handler answers.
fn handler(p: Plan) -> Bool {
  request_validator.request.mint(
    fx.cagePolicy,
    fx.cageToken.assetName,
    p.redeemer,
    requestPolicyId(),
    transactionOf(p),
  )
}

/// The named reason the same judgement gives.
fn reason(p: Plan) -> Option<String> {
  registrationBookingRefusal(
    fx.cagePolicy,
    fx.cageToken,
    requestPolicyId(),
    transactionOf(p),
  )
}

/// The datum states `r` and the output holds exactly its declared lovelace,
/// but the tags and the mint are those of the original request.
fn restated(p: Plan, r: RegistrationRequest) -> Plan {
  Plan {
    ..p,
    outputs: [
      requestOutput(
        r,
        from_lovelace(declared(r)) |> merge(requestTags(p.request)),
      ),
    ],
  }
}

fn withOutput(p: Plan, o: Output) -> Plan {
  Plan { ..p, outputs: [o] }
}

fn outputOf(p: Plan) -> Output {
  expect [o] = p.outputs
  o
}

fn burnTx(names: List<(ByteArray, Int)>) -> Plan {
  Plan {
    ..plan(requestOne()),
    mint: burnValue(names),
    outputs: [],
    reference_inputs: [],
  }
}

fn burnValue(names: List<(ByteArray, Int)>) -> Value {
  when names is {
    [] -> zero
    [(name, quantity), ..rest] ->
      merge(from_asset(requestPolicyId(), name, quantity), burnValue(rest))
  }
}

// ----------------------------------------------------------------------------
// Accepted bookings, three distinct requests
// ----------------------------------------------------------------------------

test registration_booking_accepts_first_request() {
  handler(plan(requestOne()))
}

test registration_booking_accepts_second_request_at_the_widest_interval() {
  handler(plan(requestTwo()))
}

test registration_booking_accepts_third_request() {
  handler(plan(requestThree()))
}

test registration_booking_names_no_refusal_for_each_request() {
  reason(plan(requestOne())) == None && reason(plan(requestTwo())) == None && reason(
    plan(requestThree()),
  ) == None
}

test registration_booking_does_not_commit_to_the_delivered_datum() {
  let p = plan(requestTwo())
  let r = p.request
  handler(restated(p, RegistrationRequest { ..r, datum: None }))
}

test registration_booking_does_not_forbid_a_stake_credential() {
  let p = plan(requestOne())
  let o = outputOf(p)
  handler(
    withOutput(
      p,
      Output {
        ..o,
        address: Address {
          payment_credential: Script(requestPolicyId()),
          stake_credential: Some(Inline(VerificationKey(fx.bookerKey))),
        },
      },
    ),
  )
}

test registration_booking_leaves_untagged_junk_at_the_request_address() {
  let p = plan(requestOne())
  let junk =
    Output {
      address: requestAddress(),
      value: from_lovelace(1_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  handler(Plan { ..p, outputs: [validOutput(p.request), junk] })
}

test registration_booking_does_not_police_unrelated_policies() {
  let p = plan(requestOne())
  handler(
    Plan { ..p, mint: merge(p.mint, from_asset(fx.foreignPolicy, #"01", 5)) },
  )
}

// ----------------------------------------------------------------------------
// Pure burns: no interpretation of the redeemer, no state, no outputs
// ----------------------------------------------------------------------------

fn burning(redeemer: Data) -> Bool {
  let p = burnTx([(#"01", -1)])
  handler(Plan { ..p, redeemer })
}

test registration_booking_pure_burn_accepts_a_byte_string_redeemer() {
  burning(builtin.b_data(#"deadbeef"))
}

test registration_booking_pure_burn_accepts_an_integer_redeemer() {
  burning(builtin.i_data(-7))
}

test registration_booking_pure_burn_accepts_an_unknown_constructor_redeemer() {
  burning(builtin.constr_data(7, [builtin.i_data(1)]))
}

test registration_booking_pure_burn_accepts_a_list_redeemer() {
  burning(builtin.list_data([]))
}

test registration_booking_pure_burn_accepts_a_map_redeemer() {
  burning(builtin.map_data([]))
}

test registration_booking_pure_burn_accepts_several_names() {
  handler(burnTx([(#"01", -1), (#"02", -3), (#"03", -1)]))
}

test registration_booking_pure_burn_ignores_a_mint_under_another_policy() {
  let p = burnTx([(#"01", -1)])
  handler(Plan { ..p, mint: merge(p.mint, from_asset(fx.appPolicy, #"aa", 1)) })
}

test registration_booking_refuses_a_burn_beside_a_mint() {
  let p = plan(requestOne())
  !handler(
    Plan {
      ..p,
      mint: merge(p.mint, from_asset(requestPolicyId(), #"09", -1)),
      outputs: [],
    },
  )
}

// ----------------------------------------------------------------------------
// Refused bookings: the mint
// ----------------------------------------------------------------------------

test registration_booking_refuses_two_trie_ready_tags_minted() {
  let p = plan(requestOne())
  !handler(
    Plan {
      ..p,
      mint: merge(p.mint, from_asset(requestPolicyId(), trieTag(p.request), 1)),
    },
  )
}

test registration_booking_refuses_an_extra_name_under_the_request_policy() {
  let p = plan(requestOne())
  !handler(
    Plan { ..p, mint: merge(p.mint, from_asset(requestPolicyId(), #"09", 1)) },
  )
}

test registration_booking_refuses_an_extra_name_under_the_application_policy() {
  let p = plan(requestOne())
  !handler(
    Plan { ..p, mint: merge(p.mint, from_asset(fx.appPolicy, #"09", 1)) },
  )
}

test registration_booking_refuses_two_application_tags_minted() {
  let p = plan(requestOne())
  !handler(
    Plan {
      ..p,
      mint: merge(
        p.mint,
        from_asset(fx.appPolicy, applicationTag(p.request), 1),
      ),
    },
  )
}

test registration_booking_refuses_a_missing_application_mint() {
  let p = plan(requestOne())
  !handler(
    Plan { ..p, mint: from_asset(requestPolicyId(), trieTag(p.request), 1) },
  )
}

test registration_booking_refuses_a_missing_trie_ready_mint() {
  let p = plan(requestOne())
  !handler(
    Plan { ..p, mint: from_asset(fx.appPolicy, applicationTag(p.request), 1) },
  )
}

test registration_booking_refuses_a_trie_ready_tag_of_another_nonce() {
  let p = plan(requestOne())
  let other = RegistrationRequest { ..p.request, nonce: p.request.nonce + 1 }
  let tags =
    from_asset(requestPolicyId(), trieTag(other), 1)
      |> merge(from_asset(fx.appPolicy, applicationTag(p.request), 1))
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [
        requestOutput(
          p.request,
          from_lovelace(declared(p.request)) |> merge(tags),
        ),
      ],
    },
  )
}

// ----------------------------------------------------------------------------
// Refused bookings: the tags fixed, one declared field changed in the datum
// ----------------------------------------------------------------------------

test registration_booking_refuses_a_datum_with_another_key() {
  let p = plan(requestOne())
  !handler(restated(p, RegistrationRequest { ..p.request, key: fx.keyD }))
}

test registration_booking_refuses_a_datum_with_another_refund_address() {
  let p = plan(requestOne())
  !handler(
    restated(p, RegistrationRequest { ..p.request, refund_address: thirdKey }),
  )
}

test registration_booking_refuses_a_datum_with_another_destination() {
  let p = plan(requestOne())
  !handler(
    restated(
      p,
      RegistrationRequest { ..p.request, destination: fx.strangerAddress },
    ),
  )
}

test registration_booking_refuses_a_datum_with_another_nonce() {
  let p = plan(requestOne())
  !handler(
    restated(p, RegistrationRequest { ..p.request, nonce: p.request.nonce + 1 }),
  )
}

test registration_booking_refuses_a_datum_with_another_tip() {
  let p = plan(requestOne())
  !handler(
    restated(
      p,
      RegistrationRequest {
        ..p.request,
        declared_tip: p.request.declared_tip + 1,
      },
    ),
  )
}

test registration_booking_refuses_a_datum_with_another_carrier() {
  let p = plan(requestOne())
  !handler(
    restated(
      p,
      RegistrationRequest {
        ..p.request,
        carrier_ada: p.request.carrier_ada + 1,
      },
    ),
  )
}

test registration_booking_refuses_a_datum_for_another_registry() {
  let p = plan(requestOne())
  !handler(
    restated(
      p,
      RegistrationRequest { ..p.request, registry: fx.foreignCageToken },
    ),
  )
}

// ----------------------------------------------------------------------------
// Refused bookings: allocations and the pins
// ----------------------------------------------------------------------------

test registration_booking_refuses_another_registration_cost() {
  let p = plan(requestOne())
  let r =
    RegistrationRequest {
      ..p.request,
      registration_cost: fx.registrationCost + 1,
    }
  let tags = requestTags(r)
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [requestOutput(r, from_lovelace(declared(r)) |> merge(tags))],
    },
  )
}

test registration_booking_refuses_a_tip_below_the_minimum() {
  let p = plan(requestOne())
  let r = RegistrationRequest { ..p.request, declared_tip: fx.tip - 1 }
  let tags = requestTags(r)
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [requestOutput(r, from_lovelace(declared(r)) |> merge(tags))],
    },
  )
}

test registration_booking_refuses_a_negative_carrier() {
  let p = plan(requestOne())
  let r = RegistrationRequest { ..p.request, carrier_ada: -1 }
  let tags = requestTags(r)
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [requestOutput(r, from_lovelace(declared(r)) |> merge(tags))],
    },
  )
}

test registration_booking_refuses_a_negative_nonce() {
  let p = plan(requestOne())
  let r = RegistrationRequest { ..p.request, nonce: -1 }
  let tags = requestTags(r)
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [requestOutput(r, from_lovelace(declared(r)) |> merge(tags))],
    },
  )
}

test registration_booking_refuses_a_refund_address_of_the_wrong_length() {
  let p = plan(requestOne())
  let r = RegistrationRequest { ..p.request, refund_address: #"d1d1d1" }
  let tags = requestTags(r)
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [requestOutput(r, from_lovelace(declared(r)) |> merge(tags))],
    },
  )
}

test registration_booking_refuses_lovelace_one_short() {
  let p = plan(requestOne())
  !handler(
    withOutput(
      p,
      requestOutput(
        p.request,
        from_lovelace(declared(p.request) - 1) |> merge(requestTags(p.request)),
      ),
    ),
  )
}

test registration_booking_refuses_lovelace_one_over() {
  let p = plan(requestOne())
  !handler(
    withOutput(
      p,
      requestOutput(
        p.request,
        from_lovelace(declared(p.request) + 1) |> merge(requestTags(p.request)),
      ),
    ),
  )
}

test registration_booking_refuses_a_foreign_asset_in_the_request() {
  let p = plan(requestOne())
  let o = outputOf(p)
  !handler(
    withOutput(
      p,
      Output {
        ..o,
        value: merge(o.value, from_asset(fx.foreignPolicy, #"01", 1)),
      },
    ),
  )
}

test registration_booking_refuses_a_second_application_tag_in_the_request() {
  let p = plan(requestOne())
  let o = outputOf(p)
  !handler(
    withOutput(
      p,
      Output { ..o, value: merge(o.value, from_asset(fx.appPolicy, #"09", 1)) },
    ),
  )
}

test registration_booking_refuses_an_application_tag_under_another_policy() {
  let p = plan(requestOne())
  let r = p.request
  let tags =
    from_asset(requestPolicyId(), trieTag(r), 1)
      |> merge(from_asset(fx.foreignPolicy, applicationTag(r), 1))
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [requestOutput(r, from_lovelace(declared(r)) |> merge(tags))],
    },
  )
}

test registration_booking_refuses_an_application_tag_of_another_nonce() {
  let p = plan(requestOne())
  let r = p.request
  let wrong =
    applicationTagName(r.key, r.refund_address, r.destination, r.nonce + 1)
  let tags =
    from_asset(requestPolicyId(), trieTag(r), 1)
      |> merge(from_asset(fx.appPolicy, wrong, 1))
  !handler(
    Plan {
      ..p,
      mint: tags,
      outputs: [requestOutput(r, from_lovelace(declared(r)) |> merge(tags))],
    },
  )
}

// ----------------------------------------------------------------------------
// Refused bookings: where the request sits and what it carries
// ----------------------------------------------------------------------------

test registration_booking_refuses_a_request_at_another_script() {
  let p = plan(requestOne())
  let o = outputOf(p)
  !handler(
    withOutput(
      p,
      Output {
        ..o,
        address: Address {
          payment_credential: Script(fx.foreignPolicy),
          stake_credential: None,
        },
      },
    ),
  )
}

test registration_booking_refuses_a_request_at_a_key_address() {
  let p = plan(requestOne())
  let o = outputOf(p)
  !handler(
    withOutput(
      p,
      Output {
        ..o,
        address: Address {
          payment_credential: VerificationKey(fx.bookerKey),
          stake_credential: None,
        },
      },
    ),
  )
}

test registration_booking_refuses_a_request_without_a_datum() {
  let p = plan(requestOne())
  !handler(withOutput(p, Output { ..outputOf(p), datum: NoDatum }))
}

test registration_booking_refuses_a_request_with_a_datum_hash() {
  let p = plan(requestOne())
  !handler(withOutput(p, Output { ..outputOf(p), datum: DatumHash(#"aa") }))
}

test registration_booking_refuses_the_historical_request_datum() {
  let p = plan(requestOne())
  let historical: CageDatum =
    RequestDatum(
      Request {
        requestToken: fx.cageToken,
        requestOwner: fx.bookerKey,
        requestKey: fx.keyA,
        edge: 1,
        deposit: 0,
        submitted_at: p.request.submitted_at,
        destination: (fx.bookerAddress, None),
      },
    )
  !handler(
    withOutput(p, Output { ..outputOf(p), datum: InlineDatum(historical) }),
  )
}

test registration_booking_refuses_a_state_datum_in_the_request() {
  let p = plan(requestOne())
  !handler(
    withOutput(
      p,
      Output { ..outputOf(p), datum: InlineDatum(StateDatum(fx.stateOf(#""))) },
    ),
  )
}

test registration_booking_refuses_a_custody_datum_in_the_request() {
  let p = plan(requestOne())
  !handler(
    withOutput(
      p,
      Output {
        ..outputOf(p),
        datum: InlineDatum(AbsentCustody { refund: fx.bookerKey }),
      },
    ),
  )
}

test registration_booking_refuses_two_outputs_carrying_the_tag() {
  let p = plan(requestOne())
  !handler(Plan { ..p, outputs: [outputOf(p), outputOf(p)] })
}

test registration_booking_refuses_tags_split_across_two_outputs() {
  let p = plan(requestOne())
  let r = p.request
  let trieOnly =
    requestOutput(
      r,
      from_lovelace(declared(r))
        |> merge(from_asset(requestPolicyId(), trieTag(r), 1)),
    )
  let appOnly =
    Output {
      address: requestAddress(),
      value: from_lovelace(1_000_000)
        |> merge(from_asset(fx.appPolicy, applicationTag(r), 1)),
      datum: NoDatum,
      reference_script: None,
    }
  !handler(Plan { ..p, outputs: [trieOnly, appOnly] })
}

test registration_booking_refuses_a_minted_tag_sent_elsewhere() {
  let p = plan(requestOne())
  let elsewhere =
    Output {
      address: Address {
        payment_credential: VerificationKey(fx.bookerKey),
        stake_credential: None,
      },
      value: outputOf(p).value,
      datum: NoDatum,
      reference_script: None,
    }
  !handler(Plan { ..p, outputs: [elsewhere] })
}

// ----------------------------------------------------------------------------
// Refused bookings: the registry state it reads
// ----------------------------------------------------------------------------

fn referencing(p: Plan, input: Input) -> Plan {
  Plan { ..p, reference_inputs: [input] }
}

fn stateWith(mutate: fn(State) -> State) -> Input {
  let input = fx.stateInput(#"")
  Input {
    ..input,
    output: Output {
      ..input.output,
      datum: InlineDatum(StateDatum(mutate(fx.stateOf(#"")))),
    },
  }
}

test registration_booking_refuses_a_missing_state_reference() {
  let p = plan(requestOne())
  !handler(Plan { ..p, reference_inputs: [] })
}

test registration_booking_refuses_a_state_that_is_spent_not_referenced() {
  let p = plan(requestOne())
  !handler(Plan { ..p, reference_inputs: [], inputs: [fx.stateInput(#"")] })
}

test registration_booking_refuses_a_state_token_of_another_registry() {
  let p = plan(requestOne())
  let input = fx.stateInput(#"")
  !handler(
    referencing(
      p,
      Input {
        ..input,
        output: Output {
          ..input.output,
          value: from_asset(fx.cagePolicy, fx.foreignCageToken.assetName, 1)
            |> merge(from_lovelace(fx.stateLovelace)),
        },
      },
    ),
  )
}

test registration_booking_refuses_two_state_tokens() {
  let p = plan(requestOne())
  let input = fx.stateInput(#"")
  !handler(
    referencing(
      p,
      Input {
        ..input,
        output: Output {
          ..input.output,
          value: from_asset(fx.cagePolicy, fx.cageToken.assetName, 2)
            |> merge(from_lovelace(fx.stateLovelace)),
        },
      },
    ),
  )
}

test registration_booking_refuses_a_state_at_another_script() {
  let p = plan(requestOne())
  let input = fx.stateInput(#"")
  !handler(
    referencing(
      p,
      Input {
        ..input,
        output: Output {
          ..input.output,
          address: Address {
            payment_credential: Script(fx.foreignPolicy),
            stake_credential: None,
          },
        },
      },
    ),
  )
}

test registration_booking_refuses_a_state_without_an_inline_datum() {
  let p = plan(requestOne())
  let input = fx.stateInput(#"")
  !handler(
    referencing(
      p,
      Input { ..input, output: Output { ..input.output, datum: NoDatum } },
    ),
  )
}

test registration_booking_refuses_a_state_slot_holding_a_registration() {
  let p = plan(requestOne())
  let input = fx.stateInput(#"")
  !handler(
    referencing(
      p,
      Input {
        ..input,
        output: Output {
          ..input.output,
          datum: InlineDatum(RegistrationDatum(p.request)),
        },
      },
    ),
  )
}

test registration_booking_refuses_a_state_pinning_another_request_policy() {
  let p = plan(requestOne())
  !handler(
    referencing(
      p,
      stateWith(fn(s) { State { ..s, request_policy: fx.foreignPolicy } }),
    ),
  )
}

test registration_booking_refuses_a_state_pinning_another_cost() {
  let p = plan(requestOne())
  !handler(
    referencing(
      p,
      stateWith(
        fn(s) { State { ..s, registration_cost: fx.registrationCost + 1 } },
      ),
    ),
  )
}

test registration_booking_refuses_a_state_pinning_a_higher_minimum_tip() {
  let p = plan(requestOne())
  !handler(
    referencing(
      p,
      stateWith(fn(s) { State { ..s, tip: p.request.declared_tip + 1 } }),
    ),
  )
}

test registration_booking_refuses_a_state_pinning_another_application_policy() {
  let p = plan(requestOne())
  !handler(
    referencing(
      p,
      stateWith(fn(s) { State { ..s, application_policy: fx.foreignPolicy } }),
    ),
  )
}

// ----------------------------------------------------------------------------
// Refused bookings: the clock
// ----------------------------------------------------------------------------

test registration_booking_accepts_exactly_the_widest_interval() {
  let p = plan(requestOne())
  let r = p.request
  handler(Plan { ..p, lower: finite(r.submitted_at - fx.bookingWidth, True) })
}

test registration_booking_refuses_an_interval_one_millisecond_too_wide() {
  let p = plan(requestOne())
  let r = p.request
  !handler(
    Plan { ..p, lower: finite(r.submitted_at - fx.bookingWidth - 1, True) },
  )
}

test registration_booking_refuses_an_unbounded_lower_end() {
  let p = plan(requestOne())
  !handler(
    Plan {
      ..p,
      lower: IntervalBound { bound_type: NegativeInfinity, is_inclusive: True },
    },
  )
}

test registration_booking_refuses_an_unbounded_upper_end() {
  let p = plan(requestOne())
  !handler(
    Plan {
      ..p,
      upper: IntervalBound { bound_type: PositiveInfinity, is_inclusive: True },
    },
  )
}

test registration_booking_refuses_an_empty_interval() {
  let p = plan(requestOne())
  !handler(Plan { ..p, lower: finite(p.request.submitted_at, True) })
}

test registration_booking_refuses_an_inverted_interval() {
  let p = plan(requestOne())
  !handler(Plan { ..p, lower: finite(p.request.submitted_at + 1, True) })
}

test registration_booking_refuses_a_booked_time_before_the_upper_end() {
  let p = plan(requestOne())
  let r =
    RegistrationRequest {
      ..p.request,
      submitted_at: p.request.submitted_at - 1,
    }
  !handler(
    Plan {
      ..p,
      outputs: [
        requestOutput(r, from_lovelace(declared(r)) |> merge(requestTags(r))),
      ],
      mint: requestTags(r),
    },
  )
}

test registration_booking_refuses_a_booked_time_after_the_upper_end() {
  let p = plan(requestOne())
  let r =
    RegistrationRequest {
      ..p.request,
      submitted_at: p.request.submitted_at + 1,
    }
  !handler(
    Plan {
      ..p,
      outputs: [
        requestOutput(r, from_lovelace(declared(r)) |> merge(requestTags(r))),
      ],
      mint: requestTags(r),
    },
  )
}

// ----------------------------------------------------------------------------
// The named reasons, in the model's order
// ----------------------------------------------------------------------------

test registration_booking_names_dirty_request_for_a_foreign_asset() {
  let p = plan(requestOne())
  let o = outputOf(p)
  reason(
    withOutput(
      p,
      Output {
        ..o,
        value: merge(o.value, from_asset(fx.foreignPolicy, #"01", 1)),
      },
    ),
  ) == Some(@"dirty-request")
}

test registration_booking_names_dirty_request_for_lovelace_one_short() {
  let p = plan(requestOne())
  reason(
    withOutput(
      p,
      requestOutput(
        p.request,
        from_lovelace(declared(p.request) - 1) |> merge(requestTags(p.request)),
      ),
    ),
  ) == Some(@"dirty-request")
}

test registration_booking_names_hidden_surplus_for_lovelace_one_over() {
  let p = plan(requestOne())
  reason(
    withOutput(
      p,
      requestOutput(
        p.request,
        from_lovelace(declared(p.request) + 1) |> merge(requestTags(p.request)),
      ),
    ),
  ) == Some(@"hidden-surplus")
}

test registration_booking_names_forged_trie_ready_tag_for_a_datum_with_another_key() {
  let p = plan(requestOne())
  reason(restated(p, RegistrationRequest { ..p.request, key: fx.keyD })) == Some(
    @"forged-trie-ready-tag",
  )
}

test registration_booking_names_forged_trie_ready_tag_for_a_missing_mint() {
  let p = plan(requestOne())
  reason(
    Plan { ..p, mint: from_asset(fx.appPolicy, applicationTag(p.request), 1) },
  ) == Some(@"forged-trie-ready-tag")
}

test registration_booking_names_dirty_request_for_an_unminted_application_tag() {
  let p = plan(requestOne())
  reason(
    Plan { ..p, mint: from_asset(requestPolicyId(), trieTag(p.request), 1) },
  ) == Some(@"dirty-request")
}

test registration_booking_names_invalid_booking_interval_for_an_empty_interval() {
  let p = plan(requestOne())
  reason(Plan { ..p, lower: finite(p.request.submitted_at, True) }) == Some(
    @"invalid-booking-interval",
  )
}

test registration_booking_names_backdated_booking_for_an_earlier_booked_time() {
  let p = plan(requestOne())
  let r =
    RegistrationRequest {
      ..p.request,
      submitted_at: p.request.submitted_at - 1,
    }
  reason(
    Plan {
      ..p,
      outputs: [
        requestOutput(r, from_lovelace(declared(r)) |> merge(requestTags(r))),
      ],
      mint: requestTags(r),
    },
  ) == Some(@"backdated-booking")
}

test registration_booking_names_booking_too_wide_for_an_interval_over_the_pin() {
  let p = plan(requestOne())
  reason(
    Plan {
      ..p,
      lower: finite(p.request.submitted_at - fx.bookingWidth - 1, True),
    },
  ) == Some(@"booking-too-wide")
}

test registration_booking_names_the_surplus_before_the_clock() {
  let p = plan(requestOne())
  reason(
    Plan {
      ..withOutput(
        p,
        requestOutput(
          p.request,
          from_lovelace(declared(p.request) + 1)
            |> merge(requestTags(p.request)),
        ),
      ),
      lower: finite(p.request.submitted_at, True),
    },
  ) == Some(@"hidden-surplus")
}

test registration_booking_names_the_interval_before_the_booked_time() {
  let p = plan(requestOne())
  let r =
    RegistrationRequest {
      ..p.request,
      submitted_at: p.request.submitted_at - 1,
    }
  reason(
    Plan {
      ..p,
      outputs: [
        requestOutput(r, from_lovelace(declared(r)) |> merge(requestTags(r))),
      ],
      mint: requestTags(r),
      lower: finite(r.submitted_at + 1, True),
    },
  ) == Some(@"invalid-booking-interval")
}

// ----------------------------------------------------------------------------
// The open policy's registration arm
// ----------------------------------------------------------------------------

fn certify(r: RegistrationRequest, moved: List<(ByteArray, Int)>) -> Bool {
  open.open.mint(
    ApproveRegistration {
      key: r.key,
      refund_address: r.refund_address,
      destination: r.destination,
      nonce: r.nonce,
    },
    fx.appPolicy,
    Transaction { ..tx_mod.placeholder, mint: openValue(moved) },
  )
}

fn openValue(moved: List<(ByteArray, Int)>) -> Value {
  when moved is {
    [] -> zero
    [(name, quantity), ..rest] ->
      merge(from_asset(fx.appPolicy, name, quantity), openValue(rest))
  }
}

test registration_booking_open_policy_certifies_each_request() {
  let one = requestOne().request
  let two = requestTwo().request
  let three = requestThree().request
  certify(one, [(applicationTag(one), 1)]) && certify(
    two,
    [(applicationTag(two), 1)],
  ) && certify(three, [(applicationTag(three), 1)])
}

test registration_booking_open_policy_refuses_the_name_of_another_nonce() {
  let r = requestOne().request
  let wrong =
    applicationTagName(r.key, r.refund_address, r.destination, r.nonce + 1)
  !certify(r, [(wrong, 1)])
}

test registration_booking_open_policy_refuses_the_name_of_another_key() {
  let r = requestOne().request
  let wrong =
    applicationTagName(fx.keyD, r.refund_address, r.destination, r.nonce)
  !certify(r, [(wrong, 1)])
}

test registration_booking_open_policy_refuses_quantity_two() {
  let r = requestOne().request
  !certify(r, [(applicationTag(r), 2)])
}

test registration_booking_open_policy_refuses_a_second_name() {
  let r = requestOne().request
  !certify(r, [(applicationTag(r), 1), (#"09", 1)])
}

test registration_booking_open_policy_refuses_an_empty_mint() {
  let r = requestOne().request
  !certify(r, [])
}

test registration_booking_open_policy_lets_a_registration_approval_be_burned() {
  let r = requestOne().request
  certify(r, [(applicationTag(r), -1)])
}

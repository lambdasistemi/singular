//// The booking of a registration, against the model's `registrationBook`
//// (statements `bookRegistration_inversion` and
//// `booking_authority_and_parameters`, bound at the revision of the epic
//// branch that landed the open-datum model).
////
//// The guards are tested one function each, so a refused row names the guard
//// that refused it; the validator rows at the end run the whole mint handler.
//// Every refusal row has a passing control that differs from it in the one
//// fact under test.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval.{
  Finite, Interval, IntervalBound, NegativeInfinity, PositiveInfinity,
}
use application/clock.{Bounds, registration_clock, validity_bounds}
use application/configuration.{configuration_asset}
use application/held.{
  ApplicationParameters, Configuration, Live, ProtectedControl, Registration,
  RegistrationData, TokenId,
}
use application/mint.{ApplicationAction, BookRegistration}
use application/registration.{
  booking_signature, initial_control, registration_asset, registration_at,
  registration_book, registration_control, registration_funding,
  registration_shape,
}
use cardano/address.{
  Address, Inline, Script, from_script, from_verification_key,
}
use cardano/assets.{add, from_asset, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use open_datum_requests
use open_datum_requests_fixtures.{
  active_asset_of, application_policy, booked_at, booking_actions, booking_range,
  booking_transaction, configuration_input, configuration_output,
  configuration_reference, control_of, controller, deposit, holding_address,
  key_a, key_b, key_c, keys, live_datum, other_key, other_policy, other_script,
  parameters, payload, pending_output, range, refund_key, registration_a,
  registration_of, registries, registry_a, registry_of, seed_a, seed_b, seed_c,
  seed_d, spent, token_value,
}
use singular_state/preimage.{
  approval_name, initial_datum_hash, registration_preimage,
}

fn name_of(registration: RegistrationData) -> ByteArray {
  registration_asset(application_policy, registration).name
}

/// Every registration of every key in every registry the fixtures know.
fn registrations() -> List<RegistrationData> {
  list.flat_map(
    registries(),
    fn(registry) { list.map(keys, fn(key) { registration_of(registry, key) }) },
  )
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: the approval
// ---------------------------------------------------------------------------

test the_approval_is_under_the_application_policy() {
  list.all(
    registrations(),
    fn(registration) {
      registration_asset(application_policy, registration).policy == application_policy
    },
  )
}

test the_approval_is_named_by_the_hash_of_the_preimage_that_commits_the_fields() {
  list.all(
    registrations(),
    fn(registration) {
      name_of(registration) == approval_name(
        registration_preimage(
          registration.key,
          registration.registry,
          registration.holding_address,
          initial_datum_hash(registration.initial_datum),
          registration.deposit,
        ),
      )
    },
  )
}

/// Seven registrations that differ from the first in exactly one committed
/// field: the key, the policy and the name of the registry, the payment and the
/// stake part of the holding address, the initial datum and the deposit.
fn committed_variants() -> List<RegistrationData> {
  let base = registration_a()
  let registry = registry_a()
  let other_stake =
    Address {
      payment_credential: Script(application_policy),
      stake_credential: Some(Inline(Script(other_script))),
    }
  [
    RegistrationData { ..base, key: key_b },
    RegistrationData {
      ..base,
      registry: preimage.RegistryIdentity { ..registry, policy: other_policy },
    },
    RegistrationData {
      ..base,
      registry: preimage.RegistryIdentity { ..registry, name: #"6e616d65" },
    },
    RegistrationData { ..base, holding_address: from_script(other_script) },
    RegistrationData { ..base, holding_address: other_stake },
    RegistrationData {
      ..base,
      initial_datum: live_datum(
        control_of(registry, key_a, controller, deposit),
        #"6f74686572",
      ),
    },
    RegistrationData { ..base, deposit: deposit + 1 },
  ]
}

test the_approval_name_changes_with_each_committed_field() {
  let base = name_of(registration_a())
  list.all(committed_variants(), fn(variant) { name_of(variant) != base })
}

test the_approval_names_of_the_variants_are_pairwise_different() {
  let names = [registration_a(), ..committed_variants()] |> list.map(name_of)
  list.all(names, fn(a) { list.count(names, fn(b) { a == b }) == 1 })
}

test the_approval_name_ignores_the_fields_it_does_not_commit() {
  let base = registration_a()
  let name = name_of(base)
  list.all(
    [
      RegistrationData {
        ..base,
        refund_address: from_verification_key(other_key),
      },
      RegistrationData { ..base, booked_at: base.booked_at + 1 },
      RegistrationData { ..base, process_deadline: base.process_deadline + 1 },
      RegistrationData { ..base, reclaim_end: base.reclaim_end + 1 },
    ],
    fn(variant) { name_of(variant) == name },
  )
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: guard registrationShape
// ---------------------------------------------------------------------------

fn shaped(registration: RegistrationData, output: Output) -> Bool {
  registration_shape(application_policy, output, registration)
}

test the_shape_accepts_the_pending_registration_of_every_registration() {
  list.all(
    registrations(),
    fn(registration) { shaped(registration, pending_output(registration)) },
  )
}

test the_shape_refuses_a_pending_registration_at_another_script() {
  let registration = registration_a()
  !shaped(
    registration,
    Output {
      ..pending_output(registration),
      address: from_script(other_script),
    },
  )
}

test the_shape_refuses_a_pending_registration_at_a_wallet() {
  let registration = registration_a()
  !shaped(
    registration,
    Output {
      ..pending_output(registration),
      address: from_verification_key(other_key),
    },
  )
}

test the_shape_refuses_an_output_without_the_approval() {
  let registration = registration_a()
  !shaped(
    registration,
    Output { ..pending_output(registration), value: from_lovelace(4_000_000) },
  )
}

test the_shape_refuses_the_approval_of_any_other_change() {
  let registration = registration_a()
  list.all(
    committed_variants(),
    fn(variant) {
      !shaped(
        registration,
        Output {
          ..pending_output(registration),
          value: token_value(registration_asset(application_policy, variant), 1),
        },
      )
    },
  )
}

test the_shape_refuses_the_approval_under_another_policy() {
  let registration = registration_a()
  let asset = registration_asset(application_policy, registration)
  !shaped(
    registration,
    Output {
      ..pending_output(registration),
      value: token_value(TokenId { ..asset, policy: other_policy }, 1),
    },
  )
}

test the_shape_refuses_two_approvals() {
  let registration = registration_a()
  !shaped(
    registration,
    Output {
      ..pending_output(registration),
      value: token_value(
        registration_asset(application_policy, registration),
        2,
      ),
    },
  )
}

test the_shape_refuses_another_token_beside_the_approval() {
  let registration = registration_a()
  !shaped(
    registration,
    Output {
      ..pending_output(registration),
      value: pending_output(registration).value |> add(other_policy, #"01", 1),
    },
  )
}

test the_shape_refuses_the_configuration_token_in_place_of_the_approval() {
  let registration = registration_a()
  !shaped(
    registration,
    Output {
      ..pending_output(registration),
      value: token_value(
        configuration_asset(application_policy, registration.registry),
        1,
      ),
    },
  )
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: guard registrationFunding
// ---------------------------------------------------------------------------

fn holding_lovelace(registration: RegistrationData, lovelace: Int) -> Output {
  let asset = registration_asset(application_policy, registration)
  Output {
    ..pending_output(registration),
    value: from_lovelace(lovelace) |> add(asset.policy, asset.name, 1),
  }
}

test the_funding_accepts_exactly_the_deposit() {
  let registration = registration_a()
  registration_funding(
    holding_lovelace(registration, registration.deposit),
    registration,
  )
}

test the_funding_accepts_more_than_the_deposit() {
  let registration = registration_a()
  list.all(
    [registration.deposit + 1, registration.deposit * 2, 900_000_000_000],
    fn(lovelace) {
      registration_funding(
        holding_lovelace(registration, lovelace),
        registration,
      )
    },
  )
}

test the_funding_refuses_less_than_the_deposit() {
  let registration = registration_a()
  list.all(
    [registration.deposit - 1, 1, 0],
    fn(lovelace) {
      !registration_funding(
        holding_lovelace(registration, lovelace),
        registration,
      )
    },
  )
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: model initialControl
// ---------------------------------------------------------------------------

fn with_initial(registration: RegistrationData, datum: Data) -> RegistrationData {
  RegistrationData { ..registration, initial_datum: datum }
}

fn control_a() -> ProtectedControl {
  control_of(registry_a(), key_a, controller, deposit)
}

test the_initial_control_accepts_the_live_datum_of_every_registration() {
  list.all(registrations(), initial_control)
}

test the_initial_control_accepts_any_payload() {
  let number: Data = 0
  let bytes: Data = #""
  let items: Data = [1, 2, 3]
  let carried: Data = payload
  let payloads: List<Data> = [number, bytes, items, carried]
  list.all(
    payloads,
    fn(body) {
      initial_control(
        with_initial(registration_a(), live_datum(control_a(), body)),
      )
    },
  )
}

test the_initial_control_refuses_a_datum_that_is_not_live() {
  let registration = registration_a()
  let configuration: Data = Configuration { parameters }
  let pending: Data = Registration { registration }
  let number: Data = 42
  list.all(
    [configuration, pending, number],
    fn(datum) { !initial_control(with_initial(registration, datum)) },
  )
}

test the_initial_control_refuses_a_control_of_another_registry() {
  let control =
    ProtectedControl { ..control_a(), registry: registry_of(seed_b) }
  !initial_control(with_initial(registration_a(), live_datum(control, payload)))
}

test the_initial_control_refuses_a_control_of_another_key() {
  let control = ProtectedControl { ..control_a(), key: key_b }
  !initial_control(with_initial(registration_a(), live_datum(control, payload)))
}

test the_initial_control_refuses_a_control_of_another_controller() {
  let control = ProtectedControl { ..control_a(), controller: other_key }
  !initial_control(with_initial(registration_a(), live_datum(control, payload)))
}

test the_initial_control_refuses_a_control_of_another_deposit() {
  list.all(
    [deposit - 1, deposit + 1, 0],
    fn(other) {
      let control = ProtectedControl { ..control_a(), deposit: other }
      !initial_control(
        with_initial(registration_a(), live_datum(control, payload)),
      )
    },
  )
}

test the_initial_control_refuses_the_active_token_of_another_key() {
  let control =
    ProtectedControl {
      ..control_a(),
      active_asset: active_asset_of(registry_a(), key_b),
    }
  !initial_control(with_initial(registration_a(), live_datum(control, payload)))
}

test the_initial_control_refuses_the_active_token_of_another_registry() {
  let control =
    ProtectedControl {
      ..control_a(),
      active_asset: active_asset_of(registry_of(seed_b), key_a),
    }
  !initial_control(with_initial(registration_a(), live_datum(control, payload)))
}

test the_initial_control_refuses_an_active_token_under_another_policy() {
  let active = control_a().active_asset
  let control =
    ProtectedControl {
      ..control_a(),
      active_asset: TokenId { ..active, policy: other_policy },
    }
  !initial_control(with_initial(registration_a(), live_datum(control, payload)))
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: guard registrationControl
// ---------------------------------------------------------------------------

test the_control_accepts_a_holding_at_the_application_address() {
  list.all(
    registrations(),
    fn(registration) { registration_control(application_policy, registration) },
  )
}

test the_control_accepts_a_holding_with_any_stake_part() {
  let stake =
    Address {
      payment_credential: Script(application_policy),
      stake_credential: Some(Inline(Script(other_script))),
    }
  registration_control(
    application_policy,
    RegistrationData { ..registration_a(), holding_address: stake },
  )
}

test the_control_refuses_a_holding_at_another_script() {
  !registration_control(
    application_policy,
    RegistrationData {
      ..registration_a(),
      holding_address: from_script(other_script),
    },
  )
}

test the_control_refuses_a_holding_at_a_wallet() {
  !registration_control(
    application_policy,
    RegistrationData {
      ..registration_a(),
      holding_address: from_verification_key(other_key),
    },
  )
}

test the_control_refuses_an_initial_datum_that_is_not_the_registration_control() {
  let control = ProtectedControl { ..control_a(), key: key_b }
  !registration_control(
    application_policy,
    with_initial(registration_a(), live_datum(control, payload)),
  )
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: guard bookingSignature
// ---------------------------------------------------------------------------

test the_signature_accepts_the_controller() {
  booking_signature(registration_a(), [controller])
}

test the_signature_accepts_the_controller_among_other_signers() {
  booking_signature(registration_a(), [other_key, controller, refund_key])
}

test the_signature_refuses_no_signer() {
  !booking_signature(registration_a(), [])
}

test the_signature_refuses_other_signers() {
  !booking_signature(registration_a(), [other_key, refund_key])
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: the booked output
// ---------------------------------------------------------------------------

test the_booked_output_is_found_at_its_index_with_its_record() {
  let registration = registration_a()
  let pending = pending_output(registration)
  let wallet = spent(seed_c).output
  and {
    registration_at([pending], 0) == Some((pending, registration)),
    registration_at([wallet, pending], 1) == Some((pending, registration)),
    registration_at([wallet, pending, wallet], 1) == Some(
      (pending, registration),
    ),
  }
}

test the_booked_output_is_not_found_outside_the_outputs() {
  let pending = pending_output(registration_a())
  and {
    registration_at([pending], 1) == None,
    registration_at([pending], -1) == None,
    registration_at([], 0) == None,
  }
}

test the_booked_output_is_not_an_output_of_another_kind() {
  let registration = registration_a()
  let wallet = spent(seed_c).output
  let live =
    Output {
      ..pending_output(registration),
      datum: InlineDatum(Live { control: control_a(), payload }),
    }
  let record = configuration_output(registry_a(), parameters)
  let hash_only =
    Output {
      ..pending_output(registration),
      datum: transaction.DatumHash(blake2b_256(#"00")),
    }
  list.all(
    [wallet, live, record, hash_only],
    fn(output) { registration_at([output], 0) == None },
  )
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: the clock
// ---------------------------------------------------------------------------

fn bounded(
  lower: IntervalBoundType,
  lower_inclusive: Bool,
  upper: IntervalBoundType,
  upper_inclusive: Bool,
) -> Interval<Int> {
  Interval {
    lower_bound: IntervalBound {
      bound_type: lower,
      is_inclusive: lower_inclusive,
    },
    upper_bound: IntervalBound {
      bound_type: upper,
      is_inclusive: upper_inclusive,
    },
  }
}

type IntervalBoundType =
  interval.IntervalBoundType<Int>

test the_bounds_of_an_included_lower_and_an_excluded_upper_are_the_instants() {
  validity_bounds(bounded(Finite(10), True, Finite(20), False)) == Some(
    Bounds { lower: 10, upper: 20 },
  )
}

test the_bounds_move_an_excluded_lower_to_the_next_instant() {
  validity_bounds(bounded(Finite(10), False, Finite(20), False)) == Some(
    Bounds { lower: 11, upper: 20 },
  )
}

test the_bounds_move_an_included_upper_to_the_next_instant() {
  validity_bounds(bounded(Finite(10), True, Finite(20), True)) == Some(
    Bounds { lower: 10, upper: 21 },
  )
}

test the_bounds_of_an_excluded_lower_and_an_included_upper_are_those_of_the_included_lower_and_excluded_upper() {
  and {
    validity_bounds(bounded(Finite(9), False, Finite(19), True)) == Some(
      Bounds { lower: 10, upper: 20 },
    ),
    validity_bounds(bounded(Finite(10), True, Finite(20), False)) == Some(
      Bounds { lower: 10, upper: 20 },
    ),
  }
}

test an_interval_with_an_infinite_end_has_no_bounds() {
  and {
    validity_bounds(bounded(NegativeInfinity, False, Finite(20), False)) == None,
    validity_bounds(bounded(Finite(10), True, PositiveInfinity, False)) == None,
    validity_bounds(bounded(NegativeInfinity, False, PositiveInfinity, False)) == None,
  }
}

fn clock(registration: RegistrationData, range: Interval<Int>) -> Bool {
  registration_clock(registration, parameters, range)
}

test the_clock_accepts_the_booking_range_of_the_fixture() {
  clock(registration_a(), booking_range())
}

test the_clock_accepts_a_range_narrower_than_the_booking_width() {
  list.all(
    [1, 2, parameters.booking_width - 1, parameters.booking_width],
    fn(width) { clock(registration_a(), range(booked_at - width, booked_at)) },
  )
}

test the_clock_refuses_a_range_wider_than_the_booking_width() {
  list.all(
    [parameters.booking_width + 1, parameters.booking_width * 2],
    fn(width) { !clock(registration_a(), range(booked_at - width, booked_at)) },
  )
}

test the_clock_refuses_an_empty_range() {
  and {
    !clock(registration_a(), range(booked_at, booked_at)),
    !clock(registration_a(), range(booked_at + 1, booked_at)),
  }
}

test the_clock_refuses_a_booking_time_that_is_not_the_upper_bound() {
  let registration = registration_a()
  list.all(
    [-1, 1, -600_000, 3_600_000],
    fn(shift) {
      !clock(
        RegistrationData { ..registration, booked_at: booked_at + shift },
        booking_range(),
      )
    },
  )
}

test the_clock_refuses_a_processing_deadline_that_is_not_the_booking_time_plus_the_processing_time() {
  let registration = registration_a()
  list.all(
    [-1, 1, 3_600_000],
    fn(shift) {
      !clock(
        RegistrationData {
          ..registration,
          process_deadline: registration.process_deadline + shift,
        },
        booking_range(),
      )
    },
  )
}

test the_clock_refuses_a_reclaim_end_that_is_not_the_deadline_plus_the_reclaim_time() {
  let registration = registration_a()
  list.all(
    [-1, 1, 7_200_000],
    fn(shift) {
      !clock(
        RegistrationData {
          ..registration,
          reclaim_end: registration.reclaim_end + shift,
        },
        booking_range(),
      )
    },
  )
}

test the_clock_refuses_a_range_with_an_infinite_end() {
  and {
    !clock(
      registration_a(),
      bounded(NegativeInfinity, False, Finite(booked_at), False),
    ),
    !clock(
      registration_a(),
      bounded(Finite(booked_at - 1), True, PositiveInfinity, False),
    ),
  }
}

test the_clock_reads_an_excluded_lower_and_an_included_upper_as_instants() {
  // The same instants as the booking range of the fixture, written with the
  // other kind of ends.
  clock(
    registration_a(),
    bounded(
      Finite(booked_at - parameters.booking_width - 1),
      False,
      Finite(booked_at - 1),
      True,
    ),
  )
}

test the_clock_follows_the_parameters_of_the_registry() {
  let registration = registration_a()
  let slower =
    ApplicationParameters {
      ..parameters,
      process_time: parameters.process_time + 1,
    }
  let longer =
    ApplicationParameters {
      ..parameters,
      retract_time: parameters.retract_time + 1,
    }
  let narrower =
    ApplicationParameters {
      ..parameters,
      booking_width: parameters.booking_width - 1,
    }
  and {
    registration_clock(registration, parameters, booking_range()),
    !registration_clock(registration, slower, booking_range()),
    !registration_clock(registration, longer, booking_range()),
    !registration_clock(registration, narrower, booking_range()),
  }
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: the action
// ---------------------------------------------------------------------------

fn booked(registration: RegistrationData, tx: Transaction) -> Bool {
  registration_book(
    application_policy,
    0,
    tx,
    [registration_asset(application_policy, registration)],
  )
}

test the_booking_accepts_every_registration() {
  list.all(
    registrations(),
    fn(registration) { booked(registration, booking_transaction(registration)) },
  )
}

test the_booking_refuses_an_index_that_is_not_an_output() {
  let registration = registration_a()
  let tx = booking_transaction(registration)
  and {
    !registration_book(
      application_policy,
      1,
      tx,
      [registration_asset(application_policy, registration)],
    ),
    !registration_book(
      application_policy,
      -1,
      tx,
      [registration_asset(application_policy, registration)],
    ),
  }
}

test the_booking_refuses_an_output_that_is_not_a_pending_registration() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      outputs: [spent(seed_c).output],
    }
  !booked(registration, tx)
}

test the_booking_refuses_a_pending_registration_at_another_script() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      outputs: [
        Output {
          ..pending_output(registration),
          address: from_script(other_script),
        },
      ],
    }
  !booked(registration, tx)
}

test the_booking_refuses_an_output_without_the_approval() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      outputs: [
        Output {
          ..pending_output(registration),
          value: from_lovelace(4_000_000),
        },
      ],
    }
  !booked(registration, tx)
}

test the_booking_refuses_an_output_that_does_not_cover_the_deposit() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      outputs: [holding_lovelace(registration, registration.deposit - 1)],
    }
  !booked(registration, tx)
}

test the_booking_refuses_a_holding_at_another_script() {
  let registration =
    RegistrationData {
      ..registration_a(),
      holding_address: from_script(other_script),
    }
  !booked(registration, booking_transaction(registration))
}

test the_booking_refuses_an_initial_datum_that_is_not_the_control_of_the_registration() {
  let control = ProtectedControl { ..control_a(), controller: other_key }
  let registration =
    with_initial(registration_a(), live_datum(control, payload))
  !booked(registration, booking_transaction(registration))
}

test the_booking_refuses_a_transaction_the_controller_does_not_sign() {
  let registration = registration_a()
  list.all(
    [[], [other_key], [other_key, refund_key]],
    fn(signers) {
      !booked(
        registration,
        Transaction {
          ..booking_transaction(registration),
          extra_signatories: signers,
        },
      )
    },
  )
}

test the_booking_refuses_a_transaction_without_the_configuration_of_its_registry() {
  let registration = registration_a()
  let tx =
    Transaction { ..booking_transaction(registration), reference_inputs: [] }
  !booked(registration, tx)
}

test the_booking_refuses_the_configuration_of_another_registry() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      reference_inputs: [
        configuration_input(
          registry_of(seed_b),
          parameters,
          configuration_reference,
        ),
      ],
    }
  !booked(registration, tx)
}

test the_booking_refuses_a_configuration_that_is_spent_and_not_referenced() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      inputs: [
        configuration_input(
          registration.registry,
          parameters,
          configuration_reference,
        ),
      ],
      reference_inputs: [],
    }
  !booked(registration, tx)
}

test the_booking_refuses_a_configuration_that_is_only_an_output() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      reference_inputs: [],
      outputs: [
        pending_output(registration),
        configuration_output(registration.registry, parameters),
      ],
    }
  !booked(registration, tx)
}

test the_booking_refuses_deadlines_that_the_configuration_does_not_fix() {
  let registration = registration_a()
  let other =
    ApplicationParameters {
      ..parameters,
      process_time: parameters.process_time + 1,
    }
  let tx =
    Transaction {
      ..booking_transaction(registration),
      reference_inputs: [
        configuration_input(
          registration.registry,
          other,
          configuration_reference,
        ),
      ],
    }
  !booked(registration, tx)
}

test the_booking_takes_the_clock_from_the_configuration_of_its_registry_among_others() {
  let registration = registration_a()
  let other =
    ApplicationParameters {
      ..parameters,
      process_time: parameters.process_time + 1,
    }
  let tx =
    Transaction {
      ..booking_transaction(registration),
      reference_inputs: [
        configuration_input(
          registry_of(seed_b),
          parameters,
          configuration_reference,
        ),
        configuration_input(
          registration.registry,
          other,
          OutputReference { ..configuration_reference, output_index: 8 },
        ),
        configuration_input(
          registration.registry,
          parameters,
          OutputReference { ..configuration_reference, output_index: 9 },
        ),
      ],
    }
  booked(registration, tx)
}

test the_booking_refuses_a_range_wider_than_the_booking_width() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      validity_range: range(booked_at - parameters.booking_width - 1, booked_at),
    }
  !booked(registration, tx)
}

test the_booking_refuses_a_range_that_does_not_end_at_the_booking_time() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      validity_range: range(booked_at - 2, booked_at + 1),
    }
  !booked(registration, tx)
}

test the_booking_refuses_an_approval_that_is_not_minted() {
  let registration = registration_a()
  let tx = Transaction { ..booking_transaction(registration), mint: zero }
  !booked(registration, tx)
}

test the_booking_refuses_an_approval_minted_twice() {
  let registration = registration_a()
  let asset = registration_asset(application_policy, registration)
  let tx =
    Transaction {
      ..booking_transaction(registration),
      mint: from_asset(asset.policy, asset.name, 2),
    }
  !booked(registration, tx)
}

test the_booking_refuses_the_mint_of_another_approval() {
  let registration = registration_a()
  let other =
    registration_asset(application_policy, registration_of(registry_a(), key_b))
  let tx =
    Transaction {
      ..booking_transaction(registration),
      mint: from_asset(other.policy, other.name, 1),
    }
  !booked(registration, tx)
}

// ---------------------------------------------------------------------------
// registration-approval-commits-its-fields: the validator
// ---------------------------------------------------------------------------

fn mint(actions: List<ApplicationAction>, tx: Transaction) -> Bool {
  open_datum_requests.open_datum_requests.mint(actions, application_policy, tx)
}

test the_validator_accepts_the_booking_of_every_registration() {
  list.all(
    registrations(),
    fn(registration) {
      mint(booking_actions(), booking_transaction(registration))
    },
  )
}

test the_validator_refuses_a_booking_the_controller_does_not_sign() {
  let tx =
    Transaction {
      ..booking_transaction(registration_a()),
      extra_signatories: [],
    }
  mint(booking_actions(), tx) == False
}

test the_validator_refuses_a_booking_without_the_configuration() {
  let tx =
    Transaction {
      ..booking_transaction(registration_a()),
      reference_inputs: [],
    }
  mint(booking_actions(), tx) == False
}

test the_validator_refuses_a_booking_whose_clock_is_not_the_configuration() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..booking_transaction(registration),
      validity_range: range(booked_at - 1, booked_at + 1),
    }
  mint(booking_actions(), tx) == False
}

test the_validator_refuses_a_booking_whose_holding_is_at_another_script() {
  let registration =
    RegistrationData {
      ..registration_a(),
      holding_address: from_script(other_script),
    }
  mint(booking_actions(), booking_transaction(registration)) == False
}

test the_validator_refuses_a_booking_whose_approval_is_not_that_of_its_output() {
  let registration = registration_a()
  let other =
    registration_asset(application_policy, registration_of(registry_a(), key_b))
  let tx =
    Transaction {
      ..booking_transaction(registration),
      mint: from_asset(other.policy, other.name, 1),
    }
  mint(booking_actions(), tx) == False
}

test the_validator_refuses_a_booking_that_names_an_output_that_is_not_a_registration() {
  let tx = booking_transaction(registration_a())
  mint([BookRegistration { output_index: 1 }], tx) == False
}

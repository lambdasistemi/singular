//// Shared fixtures of the open-datum request validator tests.
////
//// Every expected token name is obtained from the producer at run time: the
//// state and active names from the Singular state library, the configuration
//// and registration approval names from `application/configuration` and
//// `application/registration`. The seeds differ in the transaction id, in the
//// output index and in the high byte of the output index, so no two of them
//// agree on any part a name could be taken from.

use aiken/interval.{Finite, Interval, IntervalBound}
use application/configuration.{configuration_asset}
use application/held.{
  ApplicationParameters, Configuration, HeldDatum, Live, ProtectedControl,
  Registration, RegistrationData, TokenId,
}
use application/mint.{
  ApplicationAction, ApprovalBurn, BookRegistration, ConfigurationCreate,
}
use application/registration.{registration_asset}
use cardano/address.{Address, from_script, from_verification_key}
use cardano/assets.{PolicyId, Value, add, from_asset, from_lovelace, merge}
use cardano/transaction.{
  Datum, InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, state_token_name,
}

/// The hash of the validator under test: its policy and its credential.
pub const application_policy: PolicyId =
  #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

pub const state_policy: PolicyId =
  #"5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"

pub const other_script: PolicyId =
  #"6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b"

pub const other_policy: PolicyId =
  #"7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c"

pub const controller: ByteArray =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

pub const other_key: ByteArray =
  #"d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"

pub const refund_key: ByteArray =
  #"e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2"

const transaction_a: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const transaction_b: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

pub const seed_a: OutputReference =
  OutputReference { transaction_id: transaction_a, output_index: 0 }

pub const seed_b: OutputReference =
  OutputReference { transaction_id: transaction_a, output_index: 1 }

pub const seed_c: OutputReference =
  OutputReference { transaction_id: transaction_b, output_index: 0 }

pub const seed_d: OutputReference =
  OutputReference { transaction_id: transaction_a, output_index: 256 }

/// Four seeds, pairwise different in every part.
pub const seeds: List<OutputReference> = [seed_a, seed_b, seed_c, seed_d]

pub const key_a: ByteArray = #"6b6579"

pub const key_b: ByteArray = #"6b657962"

pub const key_c: ByteArray = #"0000"

/// Three keys, pairwise different, none a prefix of another.
pub const keys: List<ByteArray> = [key_a, key_b, key_c]

/// The registry created by spending `seed`.
pub fn registry_of(seed: OutputReference) -> RegistryIdentity {
  RegistryIdentity { policy: state_policy, name: state_token_name(seed) }
}

pub fn registry_a() -> RegistryIdentity {
  registry_of(seed_a)
}

/// The registries of the four seeds.
pub fn registries() -> List<RegistryIdentity> {
  [
    registry_of(seed_a),
    registry_of(seed_b),
    registry_of(seed_c),
    registry_of(seed_d),
  ]
}

/// A registry's request parameters: an hour to process, two hours to reclaim,
/// ten minutes of booking width.
pub const parameters: ApplicationParameters =
  ApplicationParameters {
    registration_cost: 0,
    minimum_tip: 0,
    process_time: 3_600_000,
    retract_time: 7_200_000,
    booking_width: 600_000,
  }

/// The validity range from `lower`, included, to `upper`, excluded.
pub fn range(lower: Int, upper: Int) -> Interval<Int> {
  Interval {
    lower_bound: IntervalBound { bound_type: Finite(lower), is_inclusive: True },
    upper_bound: IntervalBound {
      bound_type: Finite(upper),
      is_inclusive: False,
    },
  }
}

/// The instant at which the fixture registration is booked: the exclusive upper
/// bound of the booking transaction.
pub const booked_at: Int = 1_000_000_000

/// The booking range of the fixture registration, as wide as the parameters
/// allow.
pub fn booking_range() -> Interval<Int> {
  range(booked_at - parameters.booking_width, booked_at)
}

// ---------------------------------------------------------------------------
// Outputs and inputs
// ---------------------------------------------------------------------------

pub fn wallet_address() -> Address {
  from_verification_key(
    #"0202020202020202020202020202020202020202020202020202020202",
  )
}

/// An input at a wallet that spends `reference`.
pub fn spent(reference: OutputReference) -> Input {
  Input {
    output_reference: reference,
    output: Output {
      address: wallet_address(),
      value: from_lovelace(50_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

pub fn token_value(asset: TokenId, quantity: Int) -> Value {
  from_lovelace(2_000_000) |> add(asset.policy, asset.name, quantity)
}

pub fn held(datum: HeldDatum) -> Datum {
  InlineDatum(datum)
}

/// The configuration record output of `registry`, as genesis creates it.
pub fn configuration_output(
  registry: RegistryIdentity,
  record: ApplicationParameters,
) -> Output {
  Output {
    address: from_script(application_policy),
    value: token_value(configuration_asset(application_policy, registry), 1),
    datum: held(Configuration { parameters: record }),
    reference_script: None,
  }
}

/// A reference input that is the configuration record of `registry`.
pub fn configuration_input(
  registry: RegistryIdentity,
  record: ApplicationParameters,
  reference: OutputReference,
) -> Input {
  Input {
    output_reference: reference,
    output: configuration_output(registry, record),
  }
}

pub const configuration_reference: OutputReference =
  OutputReference { transaction_id: transaction_b, output_index: 7 }

/// The state output genesis creates for `registry`.
pub fn state_output(registry: RegistryIdentity) -> Output {
  Output {
    address: from_script(state_policy),
    value: token_value(
      TokenId { policy: registry.policy, name: registry.name },
      1,
    ),
    datum: NoDatum,
    reference_script: None,
  }
}

/// The transaction that creates the registry of `seed` and its configuration
/// record, with the record in output 1.
pub fn creation_transaction(seed: OutputReference) -> Transaction {
  let registry = registry_of(seed)
  Transaction {
    ..transaction.placeholder,
    inputs: [spent(seed)],
    outputs: [
      state_output(registry),
      configuration_output(registry, parameters),
    ],
    mint: from_asset(registry.policy, registry.name, 1)
      |> merge(
          from_asset(
            application_policy,
            configuration_asset(application_policy, registry).name,
            1,
          ),
        ),
  }
}

pub fn creation_actions(seed: OutputReference) -> List<ApplicationAction> {
  [
    ConfigurationCreate {
      state_policy: registry_of(seed).policy,
      state_name: registry_of(seed).name,
      seed,
      output_index: 1,
    },
  ]
}

// ---------------------------------------------------------------------------
// Registrations
// ---------------------------------------------------------------------------

/// The active token of `key` in `registry`.
pub fn active_asset_of(registry: RegistryIdentity, key: ByteArray) -> TokenId {
  TokenId { policy: registry.policy, name: active_token_name(registry, key) }
}

/// The control a holding for `key` in `registry` starts with.
pub fn control_of(
  registry: RegistryIdentity,
  key: ByteArray,
  owner: ByteArray,
  amount: Int,
) -> ProtectedControl {
  ProtectedControl {
    registry,
    active_asset: active_asset_of(registry, key),
    key,
    controller: owner,
    deposit: amount,
  }
}

pub const deposit: Int = 2_000_000

pub const payload: Data = #"616c696365"

/// The datum a holding starts with.
pub fn live_datum(control: ProtectedControl, body: Data) -> Data {
  let datum: Data = Live { control, payload: body }
  datum
}

pub fn holding_address() -> Address {
  from_script(application_policy)
}

/// A registration of `key` in `registry`, booked by `controller` at
/// `booked_at` under `parameters`, whose holding is at the application address
/// and starts with a live datum for the same registry, key, controller and
/// deposit.
pub fn registration_of(
  registry: RegistryIdentity,
  key: ByteArray,
) -> RegistrationData {
  RegistrationData {
    registry,
    key,
    controller,
    refund_address: from_verification_key(refund_key),
    holding_address: holding_address(),
    initial_datum: live_datum(
      control_of(registry, key, controller, deposit),
      payload,
    ),
    deposit,
    booked_at,
    process_deadline: booked_at + parameters.process_time,
    reclaim_end: booked_at + parameters.process_time + parameters.retract_time,
  }
}

pub fn registration_a() -> RegistrationData {
  registration_of(registry_a(), key_a)
}

/// The output that holds a pending registration with the approval token it is
/// approved by, as booking creates it.
pub fn pending_output(registration: RegistrationData) -> Output {
  Output {
    address: from_script(application_policy),
    value: token_value(registration_asset(application_policy, registration), 1)
      |> merge(from_lovelace(registration.deposit)),
    datum: held(Registration { registration }),
    reference_script: None,
  }
}

/// The transaction that books `registration`, with the pending registration in
/// output 0, the configuration of its registry as a reference input, the
/// controller signing and the range of the fixture.
pub fn booking_transaction(registration: RegistrationData) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [spent(seed_d)],
    reference_inputs: [
      configuration_input(
        registration.registry,
        parameters,
        configuration_reference,
      ),
    ],
    outputs: [pending_output(registration)],
    mint: from_asset(
      application_policy,
      registration_asset(application_policy, registration).name,
      1,
    ),
    extra_signatories: [registration.controller],
    validity_range: booking_range(),
  }
}

pub fn booking_actions() -> List<ApplicationAction> {
  [BookRegistration { output_index: 0 }]
}

/// The transaction that only burns `quantity` of `asset`.
pub fn burn_transaction(asset: TokenId, quantity: Int) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [spent(seed_a)],
    mint: from_asset(asset.policy, asset.name, -quantity),
  }
}

pub fn burn_actions() -> List<ApplicationAction> {
  [ApprovalBurn]
}

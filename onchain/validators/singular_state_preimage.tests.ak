//// The roles of the hashed names are told apart by their constructor.
////
//// The vectors pin the bytes of the state, active, configuration, registration
//// approval and termination approval roles. These rows state why the roles
//// cannot be confused: every preimage is one constructor of the model's
//// `Preimage`, numbered as the model, so two roles that carry the same fields
//// still serialise differently, and a preimage with its constructor taken off
//// is another name.

use aiken/cbor
use aiken/crypto.{blake2b_256}
use aiken/fuzz
use aiken/primitive/bytearray
use cardano/address.{from_script}
use cardano/assets.{AssetName}
use cardano/transaction.{Output, OutputReference}
use singular_state/preimage.{
  Active, ApplicationConfiguration, RegistrationApproval, RegistryIdentity,
  State, TerminationApproval, active_token_name, state_token_name,
  termination_preimage,
}
use singular_state/state.{recognize_state}
use singular_state_fixtures.{
  genuine_output, root_datum, seed_fuzzer, state_policy, token_value,
}

/// Keys up to 130 bytes: past the 64-byte chunk of the byte string encoding.
fn key_fuzzer() -> Fuzzer<ByteArray> {
  fuzz.bytearray_between(0, 130)
}

fn registry_of(seed: OutputReference) -> RegistryIdentity {
  RegistryIdentity { policy: state_policy, name: state_token_name(seed) }
}

fn registry_fuzzer() -> Fuzzer<RegistryIdentity> {
  fuzz.map(seed_fuzzer(), registry_of)
}

/// The two bytes of the constructor tag that open a serialised preimage.
fn constructor_tag(preimage: ByteArray) -> ByteArray {
  bytearray.take(preimage, 2)
}

// ---------------------------------------------------------------------------
// The constructors are numbered as the model's `Preimage`
// ---------------------------------------------------------------------------

test the_constructors_are_numbered_as_the_model() {
  let seed = OutputReference { transaction_id: #"", output_index: 0 }
  let registry = registry_of(seed)
  let approval =
    RegistrationApproval {
      registry,
      key: #"",
      holding_address: from_script(state_policy),
      initial_datum: #"",
      deposit: 0,
    }
  and {
    constructor_tag(cbor.serialise(State { seed })) == #"d879",
    constructor_tag(cbor.serialise(Active { registry, key: #"" })) == #"d87a",
    constructor_tag(cbor.serialise(ApplicationConfiguration { registry })) == #"d87b",
    constructor_tag(cbor.serialise(approval)) == #"d87c",
    constructor_tag(cbor.serialise(TerminationApproval { registry, key: #"" })) == #"d87d",
  }
}

// ---------------------------------------------------------------------------
// A preimage without its role constructor is another name
// ---------------------------------------------------------------------------

test prop_a_state_name_is_not_the_hash_of_the_bare_seed(seed via seed_fuzzer()) {
  state_token_name(seed) != blake2b_256(cbor.serialise(seed))
}

test prop_an_active_name_is_not_the_hash_of_its_bare_fields(
  (registry, key) via fuzz.tuple(registry_fuzzer(), key_fuzzer()),
) {
  active_token_name(registry, key) != blake2b_256(
    cbor.serialise((registry, key)),
  )
}

// ---------------------------------------------------------------------------
// Roles that carry the same fields differ by the constructor alone
// ---------------------------------------------------------------------------

test prop_an_active_preimage_is_not_a_termination_preimage_of_the_same_fields(
  (registry, key) via fuzz.tuple(registry_fuzzer(), key_fuzzer()),
) {
  let active = cbor.serialise(Active { registry, key })
  let termination = termination_preimage(key, registry)
  and {
    active != termination,
    blake2b_256(active) != blake2b_256(termination),
  }
}

test prop_an_active_name_is_never_a_state_name(
  (seed, other, key) via fuzz.tuple3(seed_fuzzer(), seed_fuzzer(), key_fuzzer()),
) {
  state_token_name(seed) != active_token_name(registry_of(other), key)
}

// ---------------------------------------------------------------------------
// An active token never authenticates a state output
// ---------------------------------------------------------------------------

/// The genuine state output of `seed`, holding the token `name` instead.
fn holding(seed: OutputReference, name: AssetName) -> Output {
  Output {
    ..genuine_output(state_policy, seed),
    value: token_value(state_policy, name, 1),
    datum: root_datum(#""),
  }
}

test a_state_output_holding_the_state_token_is_recognised() {
  let seed = OutputReference { transaction_id: #"aa", output_index: 3 }
  recognize_state(state_policy, seed, holding(seed, state_token_name(seed)))
}

test prop_a_state_output_holding_an_active_token_is_not_recognised(
  (seed, key) via fuzz.tuple(seed_fuzzer(), key_fuzzer()),
) {
  let active = active_token_name(registry_of(seed), key)
  !recognize_state(state_policy, seed, holding(seed, active))
}

//// State recognition of the new Singular line, against the model's
//// `recognizeState` (statement `recognition_inversion`, bound at the revision
//// of the epic branch that landed the model).
////
//// Each row builds an output that differs from the genuine one in exactly one
//// guard and requires it not to be a state; the first rows are the passing
//// controls that show recognition can accept.

use aiken/builtin
use aiken/collection/list
use aiken/fuzz
use cardano/address.{from_script, from_verification_key}
use cardano/assets.{add, from_asset, from_lovelace}
use cardano/transaction.{DatumHash, InlineDatum, NoDatum, Output}
use singular_state/preimage.{state_token_name}
use singular_state/state.{recognize_state}
use singular_state_fixtures.{
  genuine_output, other_policy, other_script, root_datum, seed_a, seed_b,
  seed_fuzzer, seeds, state_policy, token_value,
}

fn recognised(output: Output) -> Bool {
  recognize_state(state_policy, seed_a, output)
}

fn genuine() -> Output {
  genuine_output(state_policy, seed_a)
}

// ---------------------------------------------------------------------------
// Controls: what recognition accepts
// ---------------------------------------------------------------------------

test a_genuine_state_output_is_recognised_for_every_seed() {
  list.all(
    seeds,
    fn(seed) {
      recognize_state(state_policy, seed, genuine_output(state_policy, seed))
    },
  )
}

test a_state_output_is_recognised_whatever_its_root() {
  list.all(
    [
      #"", #"aa",
      #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    ],
    fn(root) { recognised(Output { ..genuine(), datum: root_datum(root) }) },
  )
}

test a_state_output_is_recognised_whatever_its_ada() {
  let name = state_token_name(seed_a)
  list.all(
    [
      from_asset(state_policy, name, 1),
      from_lovelace(1) |> add(state_policy, name, 1),
      from_lovelace(500_000_000) |> add(state_policy, name, 1),
    ],
    fn(value) { recognised(Output { ..genuine(), value }) },
  )
}

// ---------------------------------------------------------------------------
// The name comes from the supplied seed
// ---------------------------------------------------------------------------

test state_token_names_are_32_bytes_and_pairwise_distinct() {
  let names = list.map(seeds, state_token_name)
  list.all(names, fn(name) { builtin.length_of_bytearray(name) == 32 }) && list.length(
    list.unique(names),
  ) == list.length(seeds)
}

test a_token_named_from_another_seed_is_not_a_state() {
  list.all(
    seeds,
    fn(seed) {
      list.all(
        seeds,
        fn(other) {
          other == seed || !recognize_state(
            state_policy,
            seed,
            genuine_output(state_policy, other),
          )
        },
      )
    },
  )
}

test the_supplied_seed_decides_not_the_token() {
  !recognize_state(state_policy, seed_b, genuine())
}

// ---------------------------------------------------------------------------
// One guard at a time
// ---------------------------------------------------------------------------

test an_output_at_another_script_is_not_a_state() {
  !recognised(Output { ..genuine(), address: from_script(other_script) })
}

test an_output_at_a_key_address_is_not_a_state() {
  !recognised(
    Output {
      ..genuine(),
      address: from_verification_key(
        #"0303030303030303030303030303030303030303030303030303030303",
      ),
    },
  )
}

test a_token_under_another_policy_is_not_a_state() {
  !recognised(
    Output {
      ..genuine(),
      value: token_value(other_policy, state_token_name(seed_a), 1),
    },
  )
}

test a_state_token_of_quantity_other_than_one_is_not_a_state() {
  let name = state_token_name(seed_a)
  list.all(
    [2, 3, 1_000_000],
    fn(quantity) {
      !recognised(
        Output { ..genuine(), value: token_value(state_policy, name, quantity) },
      )
    },
  )
}

test an_output_that_holds_only_ada_is_not_a_state() {
  !recognised(Output { ..genuine(), value: from_lovelace(2_000_000) })
}

test an_output_with_an_extra_token_under_another_policy_is_not_a_state() {
  let value =
    token_value(state_policy, state_token_name(seed_a), 1)
      |> add(other_policy, #"01", 1)
  !recognised(Output { ..genuine(), value })
}

test an_output_with_a_second_name_under_the_state_policy_is_not_a_state() {
  let value =
    token_value(state_policy, state_token_name(seed_a), 1)
      |> add(state_policy, state_token_name(seed_b), 1)
  !recognised(Output { ..genuine(), value })
}

test an_output_without_a_datum_is_not_a_state() {
  !recognised(Output { ..genuine(), datum: NoDatum })
}

test an_output_with_a_datum_hash_is_not_a_state() {
  !recognised(
    Output {
      ..genuine(),
      datum: DatumHash(
        #"0404040404040404040404040404040404040404040404040404040404040404",
      ),
    },
  )
}

test an_output_with_a_datum_that_is_not_a_root_is_not_a_state() {
  list.all(
    [
      // the root alone, not wrapped
      InlineDatum(#"aa"),
      // a root under another constructor
      InlineDatum(builtin.constr_data(1, [builtin.b_data(#"aa")])),
      // the constructor of a root datum with a field that is not a root
      InlineDatum(builtin.constr_data(0, [builtin.i_data(5)])),
      // a root datum with a second field
      InlineDatum(
        builtin.constr_data(0, [builtin.b_data(#"aa"), builtin.b_data(#"bb")]),
      ),
      // a root datum with no field
      InlineDatum(builtin.constr_data(0, [])),
      // the root in a list
      InlineDatum(builtin.list_data([builtin.b_data(#"aa")])),
    ],
    fn(datum) { !recognised(Output { ..genuine(), datum }) },
  )
}

// ---------------------------------------------------------------------------
// Properties over every seed
// ---------------------------------------------------------------------------

test prop_a_genuine_state_is_recognised_for_its_own_seed(seed via seed_fuzzer()) {
  recognize_state(state_policy, seed, genuine_output(state_policy, seed))
}

test prop_a_token_named_from_another_seed_is_never_recognised(
  pair via fuzz.tuple(seed_fuzzer(), seed_fuzzer()),
) {
  let (seed, other) = pair
  seed == other || !recognize_state(
    state_policy,
    seed,
    genuine_output(state_policy, other),
  )
}

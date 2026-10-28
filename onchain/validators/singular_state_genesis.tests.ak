//// Genesis of the new Singular line, against the model's `genesis`
//// (statement `genesis_inversion`, bound at the revision of the epic branch
//// that landed the model).
////
//// The guards are tested one function each, so a refused row names the guard
//// that refused it; the validator rows at the end run the whole mint handler.
//// Every refusal row has a passing control that differs from it in the one
//// guard under test.

use aiken/builtin
use aiken/collection/list
use aiken/fuzz
use cardano/address.{from_script}
use cardano/assets.{add, from_asset, zero}
use cardano/transaction.{
  DatumHash, InlineDatum, NoDatum, Output, OutputReference, Transaction,
}
use singular_state
use singular_state/genesis.{
  Genesis, genesis_empty, genesis_invocation, genesis_mint, genesis_output,
  genesis_seed, state_candidates,
}
use singular_state/preimage.{state_token_name}
use singular_state/state.{policy_delta}
use singular_state_fixtures.{
  application_policy, genesis_transaction, genuine_output, ordinary_output,
  other_policy, other_script, root_datum, seed_a, seed_b, seed_c, seed_d,
  seed_fuzzer, seeds, spent, state_policy, token_value,
}

fn genuine() -> Output {
  genuine_output(state_policy, seed_a)
}

fn minted(seed: OutputReference, quantity: Int) -> assets.Value {
  from_asset(state_policy, state_token_name(seed), quantity)
}

// ---------------------------------------------------------------------------
// genesis-spends-its-seed-once: guard genesisSeed
// ---------------------------------------------------------------------------

test the_seed_is_spent_when_exactly_one_input_spends_it() {
  let inputs = list.map(seeds, spent)
  list.all(seeds, fn(seed) { genesis_seed(seed, inputs) })
}

test the_seed_is_not_spent_when_no_input_spends_it() {
  !genesis_seed(seed_a, [])
}

test the_seed_is_not_spent_by_inputs_that_differ_from_it_in_any_part() {
  // seed_b: the next index of the same transaction; seed_c: the same index of
  // another transaction; seed_d: an index that differs in the high byte only.
  !genesis_seed(seed_a, [spent(seed_b), spent(seed_c), spent(seed_d)])
}

test the_seed_is_not_spent_once_when_two_inputs_spend_it() {
  !genesis_seed(seed_a, [spent(seed_a), spent(seed_a)])
}

test the_seed_is_not_spent_once_when_two_of_three_inputs_spend_it() {
  !genesis_seed(seed_a, [spent(seed_a), spent(seed_b), spent(seed_a)])
}

// ---------------------------------------------------------------------------
// genesis-spends-its-seed-once: guard genesisInvocation
// ---------------------------------------------------------------------------

test the_state_policy_is_invoked_when_it_is_minted() {
  genesis_invocation(state_policy, minted(seed_a, 1))
}

test the_state_policy_is_invoked_when_other_policies_are_minted_too() {
  genesis_invocation(
    state_policy,
    minted(seed_a, 1) |> add(other_policy, #"01", 1),
  )
}

test the_state_policy_is_not_invoked_by_an_empty_mint() {
  !genesis_invocation(state_policy, zero)
}

test the_state_policy_is_not_invoked_by_the_mint_of_another_policy() {
  !genesis_invocation(
    state_policy,
    from_asset(other_policy, state_token_name(seed_a), 1),
  )
}

// ---------------------------------------------------------------------------
// genesis-mints-exactly-one-state-token: guard genesisMint, and the whole-
// policy comparison it is built on
// ---------------------------------------------------------------------------

test the_mint_is_one_state_token_named_from_each_seed() {
  list.all(
    seeds,
    fn(seed) { genesis_mint(state_policy, seed, minted(seed, 1)) },
  )
}

test other_policies_may_mint_beside_the_state_token() {
  genesis_mint(
    state_policy,
    seed_a,
    minted(seed_a, 1) |> add(other_policy, #"01", 5),
  )
}

test no_mint_is_not_the_genesis_mint() {
  !genesis_mint(state_policy, seed_a, zero)
}

test two_state_tokens_are_not_the_genesis_mint() {
  !genesis_mint(state_policy, seed_a, minted(seed_a, 2))
}

test burning_the_state_token_is_not_the_genesis_mint() {
  !genesis_mint(state_policy, seed_a, minted(seed_a, -1))
}

test a_token_named_from_another_seed_is_not_the_genesis_mint() {
  list.all(
    seeds,
    fn(seed) {
      list.all(
        seeds,
        fn(other) {
          other == seed || !genesis_mint(state_policy, seed, minted(other, 1))
        },
      )
    },
  )
}

test the_name_under_another_policy_is_not_the_genesis_mint() {
  !genesis_mint(
    state_policy,
    seed_a,
    from_asset(other_policy, state_token_name(seed_a), 1),
  )
}

test a_second_name_minted_under_the_state_policy_is_not_the_genesis_mint() {
  !genesis_mint(
    state_policy,
    seed_a,
    minted(seed_a, 1) |> add(state_policy, state_token_name(seed_b), 1),
  )
}

test a_second_name_burned_under_the_state_policy_is_not_the_genesis_mint() {
  !genesis_mint(
    state_policy,
    seed_a,
    minted(seed_a, 1) |> add(state_policy, state_token_name(seed_b), -1),
  )
}

test a_second_name_that_is_not_a_state_name_is_not_the_genesis_mint() {
  !genesis_mint(
    state_policy,
    seed_a,
    minted(seed_a, 1) |> add(state_policy, #"", 1),
  )
}

test the_policy_delta_of_nothing_is_nothing() {
  policy_delta(zero, state_policy, [])
}

test the_policy_delta_of_nothing_is_not_a_mint() {
  !policy_delta(minted(seed_a, 1), state_policy, [])
}

test the_policy_delta_sums_the_expected_quantities_of_one_name() {
  let name = state_token_name(seed_a)
  let expected: Pairs<assets.AssetName, Int> = [Pair(name, 1), Pair(name, 2)]
  policy_delta(minted(seed_a, 3), state_policy, expected) && !policy_delta(
    minted(seed_a, 1),
    state_policy,
    expected,
  )
}

test the_policy_delta_requires_every_expected_name() {
  let a = state_token_name(seed_a)
  let b = state_token_name(seed_b)
  let expected: Pairs<assets.AssetName, Int> = [Pair(a, 1), Pair(b, -1)]
  policy_delta(
    minted(seed_a, 1) |> add(state_policy, b, -1),
    state_policy,
    expected,
  ) && !policy_delta(minted(seed_a, 1), state_policy, expected)
}

// ---------------------------------------------------------------------------
// genesis-has-one-recognised-state-output: the candidates and guard
// genesisOutput
// ---------------------------------------------------------------------------

test the_candidates_are_the_outputs_that_carry_the_state_token() {
  state_candidates(
    state_policy,
    seed_a,
    [ordinary_output, genuine(), ordinary_output],
  ) == [genuine()]
}

test an_output_with_the_name_under_another_policy_is_not_a_candidate() {
  let other =
    Output {
      ..genuine(),
      value: token_value(other_policy, state_token_name(seed_a), 1),
    }
  state_candidates(state_policy, seed_a, [other]) == []
}

test an_output_with_the_token_of_another_seed_is_not_a_candidate() {
  state_candidates(state_policy, seed_a, [genuine_output(state_policy, seed_b)]) == []
}

test an_output_with_the_token_at_any_quantity_is_a_candidate() {
  let heavy =
    Output {
      ..genuine(),
      value: token_value(state_policy, state_token_name(seed_a), 2),
    }
  state_candidates(state_policy, seed_a, [heavy]) == [heavy]
}

test one_recognised_candidate_is_the_genesis_output() {
  list.all(
    seeds,
    fn(seed) {
      genesis_output(state_policy, seed, [genuine_output(state_policy, seed)])
    },
  )
}

test no_candidate_is_not_the_genesis_output() {
  !genesis_output(state_policy, seed_a, [])
}

test two_candidates_are_not_the_genesis_output() {
  !genesis_output(state_policy, seed_a, [genuine(), genuine()])
}

test a_candidate_that_is_not_recognised_is_not_the_genesis_output() {
  list.all(
    [
      Output { ..genuine(), address: from_script(other_script) },
      Output { ..genuine(), datum: NoDatum },
      Output {
        ..genuine(),
        value: token_value(state_policy, state_token_name(seed_a), 2),
      },
      Output {
        ..genuine(),
        value: token_value(state_policy, state_token_name(seed_a), 1)
          |> add(other_policy, #"01", 1),
      },
    ],
    fn(candidate) { !genesis_output(state_policy, seed_a, [candidate]) },
  )
}

test a_recognised_candidate_beside_an_unrecognised_one_is_not_the_genesis_output() {
  !genesis_output(
    state_policy,
    seed_a,
    [genuine(), Output { ..genuine(), datum: NoDatum }],
  )
}

// ---------------------------------------------------------------------------
// genesis-root-is-empty: guard genesisEmpty
// ---------------------------------------------------------------------------

test the_candidate_with_the_empty_root_is_empty() {
  genesis_empty([genuine()])
}

test a_candidate_with_another_root_is_not_empty() {
  list.all(
    [
      #"", #"00",
      #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      // the empty root with a byte appended
      #"000000000000000000000000000000000000000000000000000000000000000000",
    ],
    fn(root) {
      !genesis_empty([Output { ..genuine(), datum: root_datum(root) }])
    },
  )
}

test a_candidate_without_a_root_datum_is_not_empty() {
  list.all(
    [
      NoDatum,
      DatumHash(
        #"0404040404040404040404040404040404040404040404040404040404040404",
      ),
      InlineDatum(
        builtin.b_data(
          #"0000000000000000000000000000000000000000000000000000000000000000",
        ),
      ),
    ],
    fn(datum) { !genesis_empty([Output { ..genuine(), datum }]) },
  )
}

test one_candidate_with_a_root_among_empty_ones_is_not_empty() {
  !genesis_empty([genuine(), Output { ..genuine(), datum: root_datum(#"aa") }])
}

// ---------------------------------------------------------------------------
// The mint handler of the validator
// ---------------------------------------------------------------------------

fn mint(redeemer_seed: OutputReference, tx: Transaction) -> Bool {
  singular_state.singular_state.mint(
    application_policy,
    Genesis { seed: redeemer_seed },
    state_policy,
    tx,
  )
}

fn valid() -> Transaction {
  genesis_transaction(state_policy, seed_a)
}

test the_validator_accepts_the_genesis_of_every_seed() {
  list.all(
    seeds,
    fn(seed) { mint(seed, genesis_transaction(state_policy, seed)) },
  )
}

test the_validator_accepts_genesis_beside_ordinary_inputs_outputs_and_other_mints() {
  let tx = valid()
  mint(
    seed_a,
    Transaction {
      ..tx,
      inputs: list.concat([spent(seed_b), spent(seed_c)], tx.inputs),
      outputs: [ordinary_output, ..list.concat(tx.outputs, [ordinary_output])],
      mint: tx.mint |> add(other_policy, #"01", 7),
    },
  )
}

test the_validator_refuses_a_seed_that_is_not_spent() {
  !mint(seed_a, Transaction { ..valid(), inputs: [spent(seed_b)] })
}

test the_validator_refuses_a_seed_that_is_only_a_reference_input() {
  !mint(
    seed_a,
    Transaction { ..valid(), inputs: [], reference_inputs: [spent(seed_a)] },
  )
}

test the_validator_refuses_a_seed_spent_twice() {
  !mint(
    seed_a,
    Transaction { ..valid(), inputs: [spent(seed_a), spent(seed_a)] },
  )
}

test the_validator_refuses_a_redeemer_seed_that_the_mint_and_output_do_not_name() {
  // the transaction creates the state of seed_a and spends seed_a; the
  // redeemer claims seed_b, which is spent as well
  !mint(
    seed_b,
    Transaction { ..valid(), inputs: [spent(seed_a), spent(seed_b)] },
  )
}

test the_validator_refuses_a_second_state_token() {
  let tx = valid()
  !mint(
    seed_a,
    Transaction {
      ..tx,
      mint: tx.mint |> add(state_policy, state_token_name(seed_b), 1),
    },
  )
}

test the_validator_refuses_two_state_tokens_of_one_name() {
  !mint(seed_a, Transaction { ..valid(), mint: minted(seed_a, 2) })
}

test the_validator_refuses_a_mint_with_no_state_token() {
  !mint(seed_a, Transaction { ..valid(), mint: zero })
}

test the_validator_refuses_a_state_token_named_from_another_seed() {
  !mint(
    seed_a,
    Transaction {
      ..valid(),
      mint: minted(seed_b, 1),
      outputs: [genuine_output(state_policy, seed_b)],
    },
  )
}

test the_validator_refuses_a_transaction_with_no_state_output() {
  !mint(seed_a, Transaction { ..valid(), outputs: [ordinary_output] })
}

test the_validator_refuses_two_outputs_with_the_state_token() {
  !mint(seed_a, Transaction { ..valid(), outputs: [genuine(), genuine()] })
}

test the_validator_refuses_a_state_output_at_another_script() {
  !mint(
    seed_a,
    Transaction {
      ..valid(),
      outputs: [Output { ..genuine(), address: from_script(other_script) }],
    },
  )
}

test the_validator_refuses_a_state_output_with_an_extra_token() {
  !mint(
    seed_a,
    Transaction {
      ..valid(),
      outputs: [
        Output {
          ..genuine(),
          value: token_value(state_policy, state_token_name(seed_a), 1)
            |> add(other_policy, #"01", 1),
        },
      ],
    },
  )
}

test the_validator_refuses_a_state_output_without_a_root_datum() {
  !mint(
    seed_a,
    Transaction { ..valid(), outputs: [Output { ..genuine(), datum: NoDatum }] },
  )
}

test the_validator_refuses_a_state_output_with_a_root_that_is_not_empty() {
  !mint(
    seed_a,
    Transaction {
      ..valid(),
      outputs: [Output { ..genuine(), datum: root_datum(#"aa") }],
    },
  )
}

// ---------------------------------------------------------------------------
// Properties over every seed
// ---------------------------------------------------------------------------

test prop_genesis_is_accepted_for_every_seed(seed via seed_fuzzer()) {
  mint(seed, genesis_transaction(state_policy, seed))
}

test prop_genesis_of_one_seed_never_creates_the_state_of_another(
  pair via fuzz.tuple(seed_fuzzer(), seed_fuzzer()),
) {
  let (seed, other) = pair
  seed == other || !mint(seed, genesis_transaction(state_policy, other))
}

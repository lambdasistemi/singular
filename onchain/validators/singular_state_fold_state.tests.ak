//// The state side of the registration fold of the new Singular line, against
//// the model's `fold` (statements `batch_inversion`, `public_fold_effects` and
//// `fold_minted_outputs`, bound at the revision of the epic branch that landed
//// the model): recognising the spent state, the shape of the batch, the
//// continuing state output, the whole state-policy mint and the holdings that
//// are not consumed.
////
//// The guards are tested one function each, so a refused row names the guard
//// that refused it. Every refusal row has a passing control that differs from
//// it in the one guard under test.

use aiken/builtin
use aiken/collection/list
use cardano/address.{Address, Script, from_script, from_verification_key}
use cardano/assets.{add, from_asset, from_lovelace, zero}
use cardano/transaction.{
  DatumHash, InlineDatum, Input, NoDatum, Output, OutputReference,
}
use singular_state/fold.{
  Change, Register, Terminate, fold_address, fold_before, fold_continuation,
  fold_distinct, fold_no_new_consumed, fold_nonempty, fold_value,
  fold_whole_policy, registry_identity,
}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, state_token_name,
}
use singular_state/state.{state_root}
use singular_state_fixtures.{
  other_policy, other_script, root_datum, seed_a, seed_b, seed_c, seed_d, seeds,
  spent, state_policy, token_value,
}
use singular_state_fold_fixtures.{
  Scenario, changes_of, first_registration, fold_transaction_id,
  funding_reference, holding_index, key_a, key_b, key_c, key_d, key_e, minted,
  registration_a, registration_b, registration_c, registry_of, root_of,
  state_input, state_lovelace, state_output, state_reference,
  three_registrations, transaction_of,
}

fn scenario() -> Scenario {
  three_registrations()
}

fn changes() -> List<Change> {
  changes_of(scenario())
}

// ---------------------------------------------------------------------------
// fold-recognises-its-state: the registry is named from the supplied seed
// ---------------------------------------------------------------------------

test the_registry_is_named_from_the_supplied_seed() {
  list.all(
    seeds,
    fn(seed) {
      registry_identity(state_policy, seed) == RegistryIdentity {
        policy: state_policy,
        name: state_token_name(seed),
      }
    },
  )
}

test registries_of_different_seeds_are_different() {
  list.all(
    seeds,
    fn(seed) {
      list.all(
        seeds,
        fn(other) {
          seed == other || registry_identity(state_policy, seed) != registry_identity(
            state_policy,
            other,
          )
        },
      )
    },
  )
}

test registries_of_different_policies_are_different() {
  registry_identity(state_policy, seed_a) != registry_identity(
    other_policy,
    seed_a,
  )
}

// ---------------------------------------------------------------------------
// fold-recognises-its-state: guard foldBefore and the root of a state datum
// ---------------------------------------------------------------------------

fn before_inputs(seed: OutputReference) -> List<Input> {
  [spent(funding_reference), state_input(seed, [key_a, key_b])]
}

fn genuine_output() -> Output {
  state_output(seed_a, [key_a])
}

fn before_with(output: Output) -> List<Input> {
  [
    spent(funding_reference),
    Input { output_reference: state_reference, output },
  ]
}

fn is_before(inputs: List<Input>) -> Bool {
  fold_before(state_policy, seed_a, state_reference, inputs)
}

test the_genuine_state_is_the_state_before_for_every_seed() {
  list.all(
    seeds,
    fn(seed) {
      fold_before(state_policy, seed, state_reference, before_inputs(seed))
    },
  )
}

test the_state_before_may_hold_any_number_of_keys() {
  list.all(
    [[], [key_a], [key_a, key_b], [key_a, key_b, key_c, key_d]],
    fn(keys) {
      is_before([spent(funding_reference), state_input(seed_a, keys)])
    },
  )
}

test the_state_before_may_hold_any_ada() {
  list.all(
    [1, 2_000_000, 500_000_000],
    fn(lovelace) {
      let output = genuine_output()
      is_before(
        before_with(
          Output {
            ..output,
            value: from_lovelace(lovelace)
              |> add(state_policy, state_token_name(seed_a), 1),
          },
        ),
      )
    },
  )
}

test a_state_that_is_not_among_the_inputs_is_not_the_state_before() {
  !is_before([spent(funding_reference)])
}

test a_state_that_is_spent_twice_is_not_the_state_before() {
  let input = state_input(seed_a, [])
  !is_before([input, spent(funding_reference), input])
}

test the_state_before_is_the_input_the_reference_names() {
  // a genuine state sits at another reference; the reference spent here
  // names an ordinary input
  let elsewhere =
    Input {
      output_reference: OutputReference {
        transaction_id: #"77",
        output_index: 1,
      },
      output: genuine_output(),
    }
  !is_before([elsewhere, spent(state_reference)])
}

test a_state_of_another_seed_is_not_the_state_before() {
  list.all(
    seeds,
    fn(seed) {
      list.all(
        seeds,
        fn(supplied) {
          seed == supplied || !fold_before(
            state_policy,
            supplied,
            state_reference,
            before_inputs(seed),
          )
        },
      )
    },
  )
}

test a_state_is_not_the_state_before_under_another_policy() {
  !fold_before(other_policy, seed_a, state_reference, before_inputs(seed_a))
}

test a_state_at_another_script_is_not_the_state_before() {
  !is_before(
    before_with(
      Output { ..genuine_output(), address: from_script(other_script) },
    ),
  )
}

test a_state_at_a_key_address_is_not_the_state_before() {
  !is_before(
    before_with(
      Output {
        ..genuine_output(),
        address: from_verification_key(
          #"0404040404040404040404040404040404040404040404040404040404",
        ),
      },
    ),
  )
}

test a_state_with_an_extra_token_is_not_the_state_before() {
  !is_before(
    before_with(
      Output {
        ..genuine_output(),
        value: token_value(state_policy, state_token_name(seed_a), 1)
          |> add(other_policy, #"01", 1),
      },
    ),
  )
}

test a_state_token_of_another_quantity_is_not_the_state_before() {
  list.all(
    [0, 2],
    fn(quantity) {
      !is_before(
        before_with(
          Output {
            ..genuine_output(),
            value: token_value(state_policy, state_token_name(seed_a), quantity),
          },
        ),
      )
    },
  )
}

test a_state_with_a_datum_that_carries_no_root_is_not_the_state_before() {
  list.all(
    [
      NoDatum,
      DatumHash(
        #"00000000000000000000000000000000000000000000000000000000000000aa",
      ),
      InlineDatum(#"aa"),
      InlineDatum(builtin.constr_data(1, [builtin.b_data(#"aa")])),
      InlineDatum(builtin.constr_data(0, [builtin.i_data(5)])),
      InlineDatum(
        builtin.constr_data(0, [builtin.b_data(#"aa"), builtin.b_data(#"bb")]),
      ),
      InlineDatum(builtin.constr_data(0, [])),
    ],
    fn(datum) { !is_before(before_with(Output { ..genuine_output(), datum })) },
  )
}

test a_state_whose_root_is_not_a_trie_root_is_not_the_state_before() {
  list.all(
    [
      #"", #"aa",
      #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd",
    ],
    fn(root) {
      !is_before(
        before_with(Output { ..genuine_output(), datum: root_datum(root) }),
      )
    },
  )
}

test a_token_parked_at_the_state_address_is_not_the_state_before() {
  // the active token of a key, sitting at the state script with a root datum
  let registry = registry_of(seed_a)
  !is_before(
    before_with(
      Output {
        ..genuine_output(),
        value: token_value(state_policy, active_token_name(registry, key_a), 1),
      },
    ),
  )
}

test the_root_of_a_state_datum_is_the_root_it_carries() {
  list.all(
    [#"", #"aa", root_of([]), root_of([key_a, key_b, key_c])],
    fn(root) { state_root(root_datum(root)) == Some(root) },
  )
}

test a_datum_that_is_not_a_state_datum_has_no_root() {
  list.all(
    [
      NoDatum,
      DatumHash(
        #"00000000000000000000000000000000000000000000000000000000000000aa",
      ),
      InlineDatum(#"aa"),
      InlineDatum(builtin.constr_data(1, [builtin.b_data(#"aa")])),
      InlineDatum(builtin.constr_data(0, [builtin.i_data(5)])),
      InlineDatum(
        builtin.constr_data(0, [builtin.b_data(#"aa"), builtin.b_data(#"bb")]),
      ),
      InlineDatum(builtin.constr_data(0, [])),
      InlineDatum(builtin.list_data([builtin.b_data(#"aa")])),
    ],
    fn(datum) { state_root(datum) == None },
  )
}

// ---------------------------------------------------------------------------
// fold-batch-nonempty-and-distinct: guards foldNonempty and foldDistinct
// ---------------------------------------------------------------------------

test a_fold_with_changes_is_nonempty() {
  fold_nonempty(changes()) && fold_nonempty(changes_of(first_registration()))
}

test a_fold_with_no_change_is_not_nonempty() {
  !fold_nonempty([])
}

test changes_that_consume_different_requests_are_distinct() {
  fold_distinct(changes()) && fold_distinct([]) && fold_distinct(
    changes_of(first_registration()),
  )
}

fn request_change(request: OutputReference) -> Change {
  Register { request, key: key_a, holding: 2, deposit: 0, proof: [] }
}

test requests_that_differ_in_one_part_are_distinct() {
  fold_distinct(
    [
      request_change(OutputReference { transaction_id: #"aa", output_index: 0 }),
      request_change(OutputReference { transaction_id: #"aa", output_index: 1 }),
      request_change(OutputReference { transaction_id: #"bb", output_index: 0 }),
    ],
  )
}

test two_changes_that_consume_one_request_are_not_distinct() {
  let same = OutputReference { transaction_id: #"aa", output_index: 0 }
  let other = OutputReference { transaction_id: #"bb", output_index: 0 }
  list.all(
    [
      [request_change(same), request_change(same)],
      [request_change(same), request_change(other), request_change(same)],
      [request_change(other), request_change(same), request_change(same)],
    ],
    fn(batch) { !fold_distinct(batch) },
  )
}

test a_registration_and_a_termination_of_one_request_are_not_distinct() {
  let same = OutputReference { transaction_id: #"aa", output_index: 0 }
  !fold_distinct(
    [request_change(same), Terminate { request: same, key: key_b, proof: [] }],
  )
}

// ---------------------------------------------------------------------------
// continuation-is-bare-at-the-same-script: guards foldContinuation,
// foldAddress and foldValue
// ---------------------------------------------------------------------------

test the_continuing_state_is_the_one_output_that_carries_the_token() {
  list.all(
    seeds,
    fn(seed) {
      fold_continuation(
        state_policy,
        seed,
        [
          singular_state_fixtures.ordinary_output,
          state_output(seed, [key_a, key_b]),
          singular_state_fixtures.ordinary_output,
        ],
      )
    },
  )
}

test the_continuing_state_may_hold_any_ada() {
  list.all(
    [1, 5_000_000, 900_000_000],
    fn(lovelace) {
      fold_continuation(
        state_policy,
        seed_a,
        [
          Output {
            ..genuine_output(),
            value: from_lovelace(lovelace)
              |> add(state_policy, state_token_name(seed_a), 1),
          },
        ],
      )
    },
  )
}

test no_output_that_carries_the_token_is_not_a_continuation() {
  !fold_continuation(
    state_policy,
    seed_a,
    [singular_state_fixtures.ordinary_output],
  ) && !fold_continuation(state_policy, seed_a, [])
}

test two_outputs_that_carry_the_token_are_not_a_continuation() {
  !fold_continuation(
    state_policy,
    seed_a,
    [
      genuine_output(),
      singular_state_fixtures.ordinary_output,
      genuine_output(),
    ],
  )
}

test the_token_of_another_seed_is_not_the_continuation() {
  list.all(
    seeds,
    fn(seed) {
      list.all(
        seeds,
        fn(supplied) {
          seed == supplied || !fold_continuation(
            state_policy,
            supplied,
            [state_output(seed, [])],
          )
        },
      )
    },
  )
}

test a_state_token_of_another_quantity_is_not_a_continuation() {
  list.all(
    [2, 3],
    fn(quantity) {
      !fold_continuation(
        state_policy,
        seed_a,
        [
          Output {
            ..genuine_output(),
            value: token_value(state_policy, state_token_name(seed_a), quantity),
          },
        ],
      )
    },
  )
}

test a_continuation_with_another_token_is_not_bare() {
  let name = state_token_name(seed_a)
  list.all(
    [
      token_value(state_policy, name, 1) |> add(other_policy, #"01", 1),
      token_value(state_policy, name, 1) |> add(state_policy, #"", 1),
      token_value(state_policy, name, 1)
        |> add(state_policy, state_token_name(seed_b), 1),
      token_value(state_policy, name, 1) |> add(other_policy, name, 4),
    ],
    fn(value) {
      !fold_continuation(
        state_policy,
        seed_a,
        [Output { ..genuine_output(), value }],
      )
    },
  )
}

test the_continuing_state_may_carry_any_datum() {
  // the datum is the business of foldTrie
  list.all(
    [NoDatum, root_datum(#"aa"), InlineDatum(builtin.i_data(1))],
    fn(datum) {
      fold_continuation(
        state_policy,
        seed_a,
        [Output { ..genuine_output(), datum }],
      )
    },
  )
}

test the_continuing_state_at_the_same_payment_credential_keeps_the_address() {
  let before = genuine_output()
  list.all(
    [
      before,
      Output {
        ..before,
        address: Address {
          payment_credential: Script(state_policy),
          stake_credential: Some(address.Inline(Script(other_script))),
        },
      },
    ],
    fn(after) { fold_address(before, after) },
  )
}

test the_continuing_state_at_another_payment_credential_moves_the_address() {
  let before = genuine_output()
  list.all(
    [
      from_script(other_script),
      from_verification_key(
        #"0404040404040404040404040404040404040404040404040404040404",
      ),
    ],
    fn(address) { !fold_address(before, Output { ..before, address }) },
  )
}

fn with_lovelace(output: Output, lovelace: Int) -> Output {
  Output {
    ..output,
    value: from_lovelace(lovelace)
      |> add(state_policy, state_token_name(seed_a), 1),
  }
}

test the_continuing_state_does_not_hold_less_ada() {
  let before = with_lovelace(genuine_output(), state_lovelace)
  fold_value(before, with_lovelace(before, state_lovelace)) && fold_value(
    before,
    with_lovelace(before, state_lovelace + 1),
  ) && fold_value(before, with_lovelace(before, 900_000_000))
}

test the_continuing_state_holding_less_ada_is_refused() {
  let before = with_lovelace(genuine_output(), state_lovelace)
  !fold_value(before, with_lovelace(before, state_lovelace - 1)) && !fold_value(
    before,
    with_lovelace(before, 1),
  )
}

// ---------------------------------------------------------------------------
// nothing-else-under-the-state-policy: guard foldWholePolicy
// ---------------------------------------------------------------------------

fn registry() -> RegistryIdentity {
  registry_of(seed_a)
}

fn actives(keys: List<ByteArray>, quantity: Int) -> assets.Value {
  list.foldl(
    keys,
    zero,
    fn(key, mint) {
      mint |> add(state_policy, active_token_name(registry(), key), quantity)
    },
  )
}

test the_whole_policy_mint_is_one_token_for_each_registered_key() {
  fold_whole_policy(registry(), changes(), minted(scenario())) && fold_whole_policy(
    registry(),
    changes_of(first_registration()),
    minted(first_registration()),
  )
}

test the_approvals_burned_under_other_policies_are_not_the_state_policy_mint() {
  fold_whole_policy(
    registry(),
    changes(),
    actives([key_a, key_b, key_c], 1) |> add(other_policy, #"01", -9),
  )
}

test the_state_policy_mint_misses_a_registered_key() {
  list.all(
    [[key_a, key_b], [key_b, key_c], [key_a, key_c], [key_a], []],
    fn(keys) { !fold_whole_policy(registry(), changes(), actives(keys, 1)) },
  )
}

test the_state_policy_mint_carries_a_key_nobody_registered() {
  !fold_whole_policy(
    registry(),
    changes(),
    actives([key_a, key_b, key_c, key_e], 1),
  )
}

test the_state_policy_mint_carries_the_state_token() {
  !fold_whole_policy(
    registry(),
    changes(),
    actives([key_a, key_b, key_c], 1)
      |> add(state_policy, state_token_name(seed_a), 1),
  )
}

test the_state_policy_mint_carries_another_name() {
  list.all(
    [#"", state_token_name(seed_b), #"aa"],
    fn(name) {
      !fold_whole_policy(
        registry(),
        changes(),
        actives([key_a, key_b, key_c], 1) |> add(state_policy, name, 1),
      ) && !fold_whole_policy(
        registry(),
        changes(),
        actives([key_a, key_b, key_c], 1) |> add(state_policy, name, -1),
      )
    },
  )
}

test the_state_policy_mint_of_a_key_is_not_two() {
  !fold_whole_policy(
    registry(),
    changes(),
    actives([key_a, key_b, key_c], 1)
      |> add(state_policy, active_token_name(registry(), key_b), 1),
  )
}

test the_state_policy_burn_of_a_key_is_not_a_registration() {
  !fold_whole_policy(
    registry(),
    changes(),
    actives([key_a, key_b], 1)
      |> add(state_policy, active_token_name(registry(), key_c), -1),
  )
}

test the_token_of_a_registry_of_another_seed_is_not_in_the_mint() {
  let other = registry_of(seed_b)
  !fold_whole_policy(
    registry(),
    changes(),
    zero
      |> add(state_policy, active_token_name(other, key_a), 1)
      |> add(state_policy, active_token_name(other, key_b), 1)
      |> add(state_policy, active_token_name(other, key_c), 1),
  )
}

test a_termination_expects_the_burn_of_its_token() {
  let terminate =
    Terminate { request: registration_a().request, key: key_a, proof: [] }
  fold_whole_policy(
    registry(),
    [terminate],
    zero |> add(state_policy, active_token_name(registry(), key_a), -1),
  ) && !fold_whole_policy(
    registry(),
    [terminate],
    zero |> add(state_policy, active_token_name(registry(), key_a), 1),
  )
}

// ---------------------------------------------------------------------------
// new-holdings-are-not-consumed: guard foldNoNewConsumed
// ---------------------------------------------------------------------------

fn consumes(transaction_id: ByteArray, index: Int) -> Input {
  spent(OutputReference { transaction_id, output_index: index })
}

test no_new_holding_is_consumed_by_a_fold_that_spends_other_outputs() {
  let tx = transaction_of(scenario())
  fold_no_new_consumed(fold_transaction_id, changes(), tx.inputs)
}

test an_output_of_the_same_transaction_that_is_no_holding_is_not_a_new_holding() {
  fold_no_new_consumed(
    fold_transaction_id,
    changes(),
    [consumes(fold_transaction_id, 0), consumes(fold_transaction_id, 1)],
  )
}

test an_output_of_another_transaction_at_a_holding_index_is_not_a_new_holding() {
  fold_no_new_consumed(
    fold_transaction_id,
    changes(),
    list.map([0, 1, 2, 3, 4], fn(index) { consumes(#"0badc0de", index) }),
  )
}

test a_new_holding_that_is_consumed_is_refused() {
  list.all(
    [0, 1, 2],
    fn(n) {
      !fold_no_new_consumed(
        fold_transaction_id,
        changes(),
        [
          spent(funding_reference),
          consumes(fold_transaction_id, holding_index(n)),
        ],
      )
    },
  )
}

test a_new_holding_that_is_consumed_among_other_inputs_is_refused() {
  let tx = transaction_of(scenario())
  !fold_no_new_consumed(
    fold_transaction_id,
    changes(),
    list.concat(tx.inputs, [consumes(fold_transaction_id, holding_index(1))]),
  )
}

test a_fold_without_changes_consumes_no_new_holding() {
  fold_no_new_consumed(
    fold_transaction_id,
    [],
    [consumes(fold_transaction_id, 2)],
  )
}

test a_termination_creates_no_new_holding() {
  fold_no_new_consumed(
    fold_transaction_id,
    [Terminate { request: registration_a().request, key: key_a, proof: [] }],
    [consumes(fold_transaction_id, 2)],
  )
}

test a_registration_names_the_holding_it_creates_even_when_an_input_spends_it_unnoticed() {
  // two registrations name the same holding index: consuming it is refused
  // through either
  let first =
    Register {
      request: registration_a().request,
      key: key_a,
      holding: 3,
      deposit: 0,
      proof: [],
    }
  let second =
    Register {
      request: registration_b().request,
      key: key_b,
      holding: 5,
      deposit: 0,
      proof: [],
    }
  !fold_no_new_consumed(
    fold_transaction_id,
    [first, second],
    [consumes(fold_transaction_id, 5)],
  ) && !fold_no_new_consumed(
    fold_transaction_id,
    [first, second],
    [consumes(fold_transaction_id, 3)],
  ) && fold_no_new_consumed(
    fold_transaction_id,
    [first, second],
    [consumes(fold_transaction_id, 4)],
  )
}

//// The Singular state validator folds registrations, against the model's
//// `fold` (statements `batch_inversion`, `publicFold_inversion`,
//// `registration_effects`, `fold_minted_outputs` and `fold_untouched_keys`,
//// bound at the revision of the epic branch that landed the model): the
//// guards of `singular_state/fold` composed through the spend handler, and the
//// mint handler that lets the tokens of a fold be minted.
////
//// Every refusal row differs from the accepted fold in one part and names the
//// attempt it stands for. A fold with the termination of a key is refused in
//// this version of the validator, whatever else it carries.

use aiken/builtin
use aiken/collection/list
use aiken/fuzz
use cardano/address.{from_script}
use cardano/assets.{add, from_asset, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use singular_state
use singular_state/fold.{Fold, StateSpend, Terminate}
use singular_state/genesis.{Folded}
use singular_state/preimage.{active_token_name, state_token_name}
use singular_state_fixtures.{
  application_policy, ordinary_output, other_policy, other_script, root_datum,
  seed_a, seed_b, seed_fuzzer, seeds, spent, state_policy,
}
use singular_state_fold_fixtures.{
  Registration, Scenario, approval_of, changes_of, first_registration,
  fold_transaction_id, funding_reference, holding_index, key_a, key_b, key_c,
  key_d, minted, redeemer_of, registration_a, registration_b, registration_c,
  registry_of, request_input, root_of, state_input, state_output,
  state_reference, three_registrations, transaction_of,
}

fn spend(redeemer: StateSpend, tx: Transaction) -> Bool {
  singular_state.singular_state.spend(
    application_policy,
    Some(builtin.i_data(0)),
    redeemer,
    state_reference,
    tx,
  )
}

fn folds(scenario: Scenario) -> Bool {
  spend(redeemer_of(scenario), transaction_of(scenario))
}

fn scenario() -> Scenario {
  three_registrations()
}

fn valid() -> Transaction {
  transaction_of(scenario())
}

fn outputs_with(tx: Transaction, index: Int, output: Output) -> Transaction {
  Transaction {
    ..tx,
    outputs: list.indexed_map(
      tx.outputs,
      fn(at, kept) {
        if at == index {
          output
        } else {
          kept
        }
      },
    ),
  }
}

fn output_at(tx: Transaction, index: Int) -> Output {
  expect Some(output) = list.at(tx.outputs, index)
  output
}

// ---------------------------------------------------------------------------
// What the validator accepts
// ---------------------------------------------------------------------------

test the_validator_folds_one_registration_into_an_empty_registry() {
  folds(first_registration())
}

test the_validator_folds_three_registrations_into_a_registry_that_holds_a_key() {
  folds(scenario())
}

test the_validator_folds_into_the_registry_of_every_seed() {
  list.all(seeds, fn(seed) { folds(Scenario { ..scenario(), seed }) })
}

test the_validator_folds_beside_ordinary_inputs_outputs_and_other_mints() {
  let tx = valid()
  spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      inputs: list.concat(
        [spent(OutputReference { transaction_id: #"0b", output_index: 0 })],
        tx.inputs,
      ),
      outputs: list.concat(tx.outputs, [ordinary_output, ordinary_output]),
      mint: tx.mint |> add(other_policy, #"01", 7),
    },
  )
}

test the_validator_folds_registrations_in_any_order() {
  folds(
    Scenario {
      ..scenario(),
      registrations: [registration_c(), registration_a(), registration_b()],
    },
  )
}

test the_validator_folds_a_registration_whose_holding_holds_exactly_the_deposit() {
  // registration b: its holding holds exactly its deposit
  folds(Scenario { ..scenario(), registrations: [registration_b()] })
}

// ---------------------------------------------------------------------------
// The attempts the validator refuses
// ---------------------------------------------------------------------------

test a_fold_with_no_change_is_refused() {
  let tx =
    Transaction {
      ..valid(),
      inputs: [spent(funding_reference), state_input(seed_a, [key_d])],
      outputs: [state_output(seed_a, [key_d])],
      mint: zero,
    }
  !spend(Fold { seed: seed_a, changes: [] }, tx)
}

test a_fold_without_the_approval_is_refused() {
  let registry = registry_of(seed_a)
  let tx = valid()
  let request = request_input(registry, registration_a())
  !spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      inputs: list.map(
        tx.inputs,
        fn(input) {
          if input.output_reference == request.output_reference {
            Input {
              ..input,
              output: Output { ..input.output, value: from_lovelace(4_000_000) },
            }
          } else {
            input
          }
        },
      ),
    },
  )
}

test a_fold_with_the_approval_of_another_registration_is_refused() {
  let registry = registry_of(seed_a)
  let tx = valid()
  let first = request_input(registry, registration_a())
  let second = request_input(registry, registration_b())
  // the requests carry each other's approval
  !spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      inputs: list.map(
        tx.inputs,
        fn(input) {
          if input.output_reference == first.output_reference {
            Input { ..input, output: second.output }
          } else if input.output_reference == second.output_reference {
            Input { ..input, output: first.output }
          } else {
            input
          }
        },
      ),
    },
  )
}

test a_fold_that_does_not_burn_the_approval_is_refused() {
  let tx = valid()
  let registry = registry_of(seed_a)
  !spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      mint: tx.mint
        |> add(application_policy, approval_of(registry, registration_b()), 1),
    },
  )
}

test a_fold_that_leaves_an_approval_unconsumed_is_refused() {
  // the redeemer folds only two of the three requests; the third approval
  // stays in an input of the transaction
  let two =
    Scenario {
      ..scenario(),
      registrations: [registration_a(), registration_b()],
    }
  let tx = valid()
  !spend(
    redeemer_of(two),
    Transaction { ..transaction_of(two), inputs: tx.inputs },
  )
}

test a_token_delivered_to_another_address_is_refused() {
  let tx = valid()
  list.all(
    [
      from_script(other_script),
      address.Address {
        payment_credential: output_at(tx, holding_index(0)).address.payment_credential,
        stake_credential: Some(address.Inline(address.Script(other_script))),
      },
    ],
    fn(address) {
      !spend(
        redeemer_of(scenario()),
        outputs_with(
          tx,
          holding_index(0),
          Output { ..output_at(tx, holding_index(0)), address },
        ),
      )
    },
  )
}

test a_token_delivered_with_another_datum_is_refused() {
  let tx = valid()
  !spend(
    redeemer_of(scenario()),
    outputs_with(
      tx,
      holding_index(1),
      Output {
        ..output_at(tx, holding_index(1)),
        datum: InlineDatum(builtin.i_data(99)),
      },
    ),
  )
}

test a_token_delivered_with_less_than_the_deposit_is_refused() {
  let short =
    Registration {
      ..registration_a(),
      deposit: 6_000_000,
      holding_lovelace: 5_999_999,
    }
  let enough = Registration { ..short, holding_lovelace: 6_000_000 }
  folds(Scenario { ..scenario(), registrations: [enough, registration_b()] }) && !folds(
    Scenario { ..scenario(), registrations: [short, registration_b()] },
  )
}

test a_second_registration_of_the_same_key_is_refused() {
  list.all(
    [[key_a], [key_d, key_a], [key_a, key_b, key_c, key_d]],
    fn(before) { !folds(Scenario { ..first_registration(), before }) },
  )
}

test the_same_key_registered_twice_in_one_fold_is_refused() {
  let again =
    Registration {
      ..registration_a(),
      request: OutputReference { transaction_id: #"aa", output_index: 9 },
    }
  !folds(
    Scenario {
      ..first_registration(),
      registrations: [registration_a(), again],
    },
  )
}

test an_extra_token_in_the_state_output_is_refused() {
  let tx = valid()
  let state = output_at(tx, 1)
  list.all(
    [
      state.value |> add(other_policy, #"01", 1),
      state.value
        |> add(state_policy, active_token_name(registry_of(seed_a), key_a), 1),
      state.value |> add(application_policy, #"02", 1),
    ],
    fn(value) {
      !spend(
        redeemer_of(scenario()),
        outputs_with(tx, 1, Output { ..state, value }),
      )
    },
  )
}

test a_state_output_that_carries_the_wrong_root_is_refused() {
  let tx = valid()
  let state = output_at(tx, 1)
  list.all(
    [
      root_datum(root_of([key_d])),
      root_datum(root_of([key_d, key_a, key_b])),
      root_datum(root_of([key_d, key_a, key_b, key_c, key_a])),
      NoDatum,
    ],
    fn(datum) {
      !spend(
        redeemer_of(scenario()),
        outputs_with(tx, 1, Output { ..state, datum }),
      )
    },
  )
}

test a_state_output_at_another_address_is_refused() {
  let tx = valid()
  !spend(
    redeemer_of(scenario()),
    outputs_with(
      tx,
      1,
      Output { ..output_at(tx, 1), address: from_script(other_script) },
    ),
  )
}

test a_state_output_that_holds_less_ada_is_refused() {
  let tx = valid()
  !spend(
    redeemer_of(scenario()),
    outputs_with(
      tx,
      1,
      Output {
        ..output_at(tx, 1),
        value: from_lovelace(4_999_999)
          |> add(state_policy, state_token_name(seed_a), 1),
      },
    ),
  )
}

test a_fold_without_a_continuing_state_output_is_refused() {
  let tx = valid()
  !spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      outputs: list.filter(
        tx.outputs,
        fn(output) { output != output_at(tx, 1) },
      ),
    },
  )
}

test a_fold_with_two_state_outputs_is_refused() {
  let tx = valid()
  !spend(
    redeemer_of(scenario()),
    Transaction { ..tx, outputs: list.concat(tx.outputs, [output_at(tx, 1)]) },
  )
}

test a_fold_that_mints_another_token_of_the_state_policy_is_refused() {
  let tx = valid()
  list.all(
    [
      state_token_name(seed_b),
      state_token_name(seed_a),
      active_token_name(registry_of(seed_a), key_d),
      active_token_name(registry_of(seed_b), key_a),
      #"",
    ],
    fn(name) {
      !spend(
        redeemer_of(scenario()),
        Transaction { ..tx, mint: tx.mint |> add(state_policy, name, 1) },
      )
    },
  )
}

test a_fold_that_does_not_mint_the_token_of_a_key_is_refused() {
  let tx = valid()
  let registry = registry_of(seed_a)
  !spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      mint: tx.mint |> add(state_policy, active_token_name(registry, key_b), -1),
    },
  )
}

test a_fold_that_places_a_token_in_two_outputs_is_refused() {
  let tx = valid()
  let holding = output_at(tx, holding_index(0))
  !spend(
    redeemer_of(scenario()),
    Transaction { ..tx, outputs: list.concat(tx.outputs, [holding]) },
  )
}

test a_fold_that_places_two_tokens_in_one_holding_is_refused() {
  let tx = valid()
  let first = output_at(tx, holding_index(0))
  !spend(
    redeemer_of(scenario()),
    outputs_with(
      tx,
      holding_index(0),
      Output {
        ..first,
        value: first.value
          |> add(state_policy, active_token_name(registry_of(seed_a), key_b), 1),
      },
    ),
  )
}

test a_fold_that_consumes_one_of_its_new_holdings_is_refused() {
  let tx = valid()
  !spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      inputs: list.concat(
        tx.inputs,
        [
          spent(
            OutputReference {
              transaction_id: fold_transaction_id,
              output_index: holding_index(2),
            },
          ),
        ],
      ),
    },
  )
}

test a_fold_whose_request_is_only_a_reference_input_is_refused() {
  let registry = registry_of(seed_a)
  let tx = valid()
  let request = request_input(registry, registration_b())
  !spend(
    redeemer_of(scenario()),
    Transaction {
      ..tx,
      inputs: list.filter(
        tx.inputs,
        fn(input) { input.output_reference != request.output_reference },
      ),
      reference_inputs: [request],
    },
  )
}

test a_fold_that_carries_a_termination_is_refused() {
  let tx = valid()
  let terminate =
    Terminate { request: registration_a().request, key: key_d, proof: [] }
  !spend(
    Fold {
      seed: seed_a,
      changes: list.concat(changes_of(scenario()), [terminate]),
    },
    tx,
  ) && !spend(Fold { seed: seed_a, changes: [terminate] }, tx)
}

test a_fold_that_names_a_request_twice_is_refused() {
  let tx = valid()
  expect Some(first) = list.head(changes_of(scenario()))
  !spend(
    Fold { seed: seed_a, changes: list.concat(changes_of(scenario()), [first]) },
    tx,
  )
}

test a_state_of_another_registry_is_refused() {
  let tx = valid()
  list.all(
    [seed_b, singular_state_fixtures.seed_c],
    fn(seed) { !spend(Fold { seed, changes: changes_of(scenario()) }, tx) },
  )
}

test a_token_parked_at_the_state_address_is_refused_as_a_state() {
  // an active token of the registry, parked at the state script with a root
  // datum, spent as if it were the state: for no seed is it one
  let tx = valid()
  let parked =
    Output {
      ..state_input(seed_a, [key_d]).output,
      value: from_lovelace(5_000_000)
        |> add(state_policy, active_token_name(registry_of(seed_a), key_d), 1),
    }
  list.all(
    seeds,
    fn(seed) {
      !spend(
        Fold { seed, changes: changes_of(scenario()) },
        Transaction {
          ..tx,
          inputs: list.map(
            tx.inputs,
            fn(input) {
              if input.output_reference == state_reference {
                Input { ..input, output: parked }
              } else {
                input
              }
            },
          ),
        },
      )
    },
  )
}

test a_state_whose_datum_is_not_the_root_of_the_trie_is_refused() {
  // the proofs describe the trie of [d]; the spent state claims another root
  let tx = valid()
  list.all(
    [root_of([]), root_of([key_a]), root_of([key_d, key_b])],
    fn(root) {
      let state = state_input(seed_a, [key_d])
      !spend(
        redeemer_of(scenario()),
        Transaction {
          ..tx,
          inputs: list.map(
            tx.inputs,
            fn(input) {
              if input.output_reference == state_reference {
                Input {
                  ..state,
                  output: Output { ..state.output, datum: root_datum(root) },
                }
              } else {
                input
              }
            },
          ),
        },
      )
    },
  )
}

// ---------------------------------------------------------------------------
// The mint handler of a fold
// ---------------------------------------------------------------------------

fn mint_folded(tx: Transaction) -> Bool {
  singular_state.singular_state.mint(
    application_policy,
    Folded,
    state_policy,
    tx,
  )
}

test the_mint_of_a_fold_is_allowed_when_a_state_input_is_spent() {
  mint_folded(valid()) && mint_folded(transaction_of(first_registration()))
}

test the_mint_of_a_fold_is_refused_when_no_input_is_at_the_state_script() {
  let tx = valid()
  !mint_folded(Transaction { ..tx, inputs: [spent(funding_reference)] }) && !mint_folded(
    Transaction { ..tx, inputs: [] },
  )
}

test the_mint_of_a_fold_is_refused_when_the_inputs_are_at_other_scripts() {
  let tx = valid()
  let elsewhere =
    Input {
      output_reference: state_reference,
      output: Output {
        ..state_input(seed_a, []).output,
        address: from_script(other_script),
      },
    }
  !mint_folded(
    Transaction { ..tx, inputs: [spent(funding_reference), elsewhere] },
  )
}

test the_mint_of_a_fold_is_refused_when_the_state_is_only_a_reference_input() {
  let tx = valid()
  !mint_folded(
    Transaction {
      ..tx,
      inputs: [spent(funding_reference)],
      reference_inputs: [state_input(seed_a, [key_d])],
    },
  )
}

test the_mint_of_a_fold_leaves_the_decision_to_the_spend_handler() {
  // the mint handler allows this mint; the spend handler refuses the fold
  let tx =
    Transaction {
      ..valid(),
      mint: minted(scenario()) |> add(state_policy, #"aa", 5),
    }
  mint_folded(tx) && !spend(redeemer_of(scenario()), tx)
}

// ---------------------------------------------------------------------------
// Properties over every seed
// ---------------------------------------------------------------------------

test prop_a_fold_is_accepted_for_every_seed(seed via seed_fuzzer()) {
  folds(Scenario { ..scenario(), seed })
}

test prop_a_fold_of_one_registry_is_refused_under_the_seed_of_another(
  pair via fuzz.tuple(seed_fuzzer(), seed_fuzzer()),
) {
  let (seed, other) = pair
  seed == other || !spend(
    Fold { seed: other, changes: changes_of(Scenario { ..scenario(), seed }) },
    transaction_of(Scenario { ..scenario(), seed }),
  )
}

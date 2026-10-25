//// The registration of a key in the fold of the new Singular line, against the
//// model's `change` for a registration (statements `registration_inversion`,
//// `registration_effects`, `registration_separate_holdings` and
//// `batch_effects`, bound at the revision of the epic branch that landed the
//// model): the key was unknown, one token for it is minted and placed once,
//// the holding holds the deposit, and the new root is the root of the trie the
//// batch produced.
////
//// The guards are tested one function each. Every refusal row has a passing
//// control that differs from it in the one guard under test; every root and
//// proof is obtained from the library at run time.

use aiken/builtin
use aiken/collection/list
use aiken/merkle_patricia_forestry as mpf
use cardano/assets.{add, from_lovelace, zero}
use cardano/transaction.{
  DatumHash, InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use registry_fixtures.{leafStep}
use singular_state/fold.{
  Change, Register, Terminate, apply_change, change_batch, change_leaf,
  fold_trie, leaf_active, one_new_token, registration_deposit, registration_mint,
  registration_placement, separate_holding,
}
use singular_state/preimage.{RegistryIdentity, active_token_name}
use singular_state_fixtures.{
  application_policy, other_policy, root_datum, seed_a, seed_b, state_policy,
}
use singular_state_fold_fixtures.{
  Registration, Scenario, changes_of, first_registration, holding_index, key_a,
  key_b, key_c, key_d, key_e, key_f, minted, proof_into, registration_a,
  registration_b, registration_c, registry_of, request_input, root_of,
  three_registrations, transaction_of, trie_of,
}

fn registry() -> RegistryIdentity {
  registry_of(seed_a)
}

fn scenario() -> Scenario {
  three_registrations()
}

fn changes() -> List<Change> {
  changes_of(scenario())
}

fn outputs() -> List<Output> {
  transaction_of(scenario()).outputs
}

fn output_at(index: Int) -> Output {
  expect Some(output) = list.at(outputs(), index)
  output
}

fn token(
  registry: RegistryIdentity,
  key: ByteArray,
  quantity: Int,
) -> assets.Value {
  zero |> add(registry.policy, active_token_name(registry, key), quantity)
}

const absent_keys: List<ByteArray> = [key_a, key_b, key_c, key_d, key_e, key_f]

const existing_tries: List<List<ByteArray>> =
  [
    [],
    [key_d],
    [key_d, key_a],
    [key_d, key_a, key_b],
    [key_d, key_a, key_b, key_c],
  ]

test a_key_the_trie_does_not_bind_is_unknown_with_its_proof() {
  list.all(
    existing_tries,
    fn(existing) {
      list.all(
        absent_keys,
        fn(key) {
          list.has(existing, key) || change_leaf(
            trie_of(existing),
            key,
            proof_into(existing, key),
          )
        },
      )
    },
  )
}

test the_proof_of_another_key_does_not_show_a_key_unknown() {
  let existing = [key_d, key_a]
  change_leaf(trie_of(existing), key_b, proof_into(existing, key_b)) && !change_leaf(
    trie_of(existing),
    key_c,
    proof_into(existing, key_b),
  ) && !change_leaf(trie_of(existing), key_b, proof_into(existing, key_c))
}

test no_proof_shows_a_key_unknown_in_a_trie_that_is_not_empty() {
  !change_leaf(trie_of([key_d]), key_a, []) && !change_leaf(
    trie_of([key_d, key_a]),
    key_b,
    [],
  ) && change_leaf(trie_of([]), key_a, [])
}

test a_key_the_trie_binds_to_any_leaf_is_not_unknown() {
  let terminal = #"02"
  let trie = mpf.insert(mpf.empty, key_a, terminal, [])
  !change_leaf(trie, key_a, []) && !change_leaf(
    trie,
    key_a,
    [leafStep(key_b, terminal, key_a)],
  ) && change_leaf(trie, key_b, [leafStep(key_a, terminal, key_b)])
}

fn register_at(registration: Registration, holding: Int) -> Change {
  Register {
    request: registration.request,
    key: registration.key,
    holding,
    deposit: registration.deposit,
    proof: [],
  }
}

test each_registration_of_a_fold_names_its_own_holding() {
  let batch = changes()
  list.all(
    [0, 1, 2],
    fn(n) {
      expect Some(Register { request, .. }) = list.at(batch, n)
      separate_holding(batch, request, holding_index(n))
    },
  )
}

test two_registrations_that_name_one_holding_do_not_have_separate_holdings() {
  let a = registration_a()
  let b = registration_b()
  let batch = [register_at(a, 3), register_at(b, 3)]
  !separate_holding(batch, a.request, 3) && !separate_holding(
    batch,
    b.request,
    3,
  )
}

test a_registration_may_be_listed_twice_for_its_own_holding() {
  let a = registration_a()
  separate_holding([register_at(a, 3), register_at(a, 3)], a.request, 3)
}

test registrations_that_differ_in_holding_are_separate() {
  let a = registration_a()
  let b = registration_b()
  separate_holding([register_at(a, 3), register_at(b, 4)], a.request, 3)
}

test a_termination_never_shares_a_holding() {
  let a = registration_a()
  separate_holding(
    [
      register_at(a, 3),
      Terminate { request: registration_b().request, key: key_b, proof: [] },
    ],
    a.request,
    3,
  )
}

fn holding_with(value: assets.Value) -> Output {
  Output { ..output_at(holding_index(0)), value }
}

test a_holding_with_the_token_of_one_key_holds_one_new_token() {
  one_new_token(registry(), changes(), output_at(holding_index(0))) && one_new_token(
    registry(),
    changes(),
    output_at(holding_index(1)),
  ) && one_new_token(registry(), changes(), output_at(holding_index(2)))
}

test a_holding_with_the_tokens_of_two_keys_holds_two_new_tokens() {
  !one_new_token(
    registry(),
    changes(),
    holding_with(
      from_lovelace(3_000_000)
        |> add(state_policy, active_token_name(registry(), key_a), 1)
        |> add(state_policy, active_token_name(registry(), key_b), 1),
    ),
  )
}

test a_holding_with_two_tokens_of_one_key_holds_two_new_tokens() {
  !one_new_token(
    registry(),
    changes(),
    holding_with(
      from_lovelace(3_000_000)
        |> add(state_policy, active_token_name(registry(), key_a), 2),
    ),
  )
}

test a_holding_without_a_token_holds_no_new_token() {
  !one_new_token(registry(), changes(), holding_with(from_lovelace(3_000_000)))
}

test a_holding_counts_only_the_tokens_of_the_keys_of_the_fold() {
  one_new_token(
    registry(),
    changes(),
    holding_with(
      from_lovelace(3_000_000)
        |> add(state_policy, active_token_name(registry(), key_a), 1)
        |> add(state_policy, active_token_name(registry(), key_e), 3),
    ),
  )
}

test the_token_of_another_registry_is_not_a_new_token() {
  !one_new_token(
    registry(),
    changes(),
    holding_with(
      from_lovelace(3_000_000)
        |> add(state_policy, active_token_name(registry_of(seed_b), key_a), 1),
    ),
  ) && !one_new_token(
    registry(),
    changes(),
    holding_with(
      from_lovelace(3_000_000)
        |> add(other_policy, active_token_name(registry(), key_a), 1),
    ),
  )
}

fn placed(outputs: List<Output>, changes: List<Change>, n: Int) -> Bool {
  expect Some(Register { request, key, holding, .. }) = list.at(changes, n)
  registration_placement(registry(), outputs, changes, request, key, holding)
}

fn replace_output(index: Int, output: Output) -> List<Output> {
  list.indexed_map(
    outputs(),
    fn(at, kept) {
      if at == index {
        output
      } else {
        kept
      }
    },
  )
}

test every_registration_of_a_fold_places_its_token_once() {
  list.all([0, 1, 2], fn(n) { placed(outputs(), changes(), n) })
}

test a_token_that_is_not_in_the_holding_is_not_placed() {
  // the token of the first key sits in the second holding instead
  let second = output_at(holding_index(1))
  let outputs =
    replace_output(holding_index(0), holding_with(from_lovelace(3_000_000)))
      |> list.indexed_map(
          fn(at, kept) {
            if at == holding_index(1) {
              Output {
                ..second,
                value: second.value
                  |> add(state_policy, active_token_name(registry(), key_a), 1),
              }
            } else {
              kept
            }
          },
        )
  !placed(outputs, changes(), 0)
}

test a_token_that_is_in_two_outputs_is_not_placed_once() {
  list.all(
    [0, 1, holding_index(1)],
    fn(other) {
      let extra = output_at(other)
      !placed(
        replace_output(
          other,
          Output {
            ..extra,
            value: extra.value
              |> add(state_policy, active_token_name(registry(), key_a), 1),
          },
        ),
        changes(),
        0,
      )
    },
  )
}

test two_tokens_in_the_holding_are_not_placed_once() {
  !placed(
    replace_output(
      holding_index(0),
      holding_with(
        output_at(holding_index(0)).value
          |> add(state_policy, active_token_name(registry(), key_a), 1),
      ),
    ),
    changes(),
    0,
  )
}

test a_holding_that_does_not_exist_is_not_a_placement() {
  expect Some(Register { request, key, deposit, proof, .. }) =
    list.at(changes(), 0)
  list.all(
    [list.length(outputs()), list.length(outputs()) + 3, -1],
    fn(holding) {
      !registration_placement(
        registry(),
        outputs(),
        [Register { request, key, holding, deposit, proof }],
        request,
        key,
        holding,
      )
    },
  )
}

test two_registrations_in_one_holding_are_not_placed() {
  let a = registration_a()
  let b = registration_b()
  let batch =
    [register_at(a, holding_index(0)), register_at(b, holding_index(0))]
  let shared =
    replace_output(
      holding_index(0),
      holding_with(
        from_lovelace(9_000_000)
          |> add(state_policy, active_token_name(registry(), key_a), 1),
      ),
    )
  placed(shared, [register_at(a, holding_index(0))], 0) && !placed(
    shared,
    batch,
    0,
  ) && !placed(shared, batch, 1)
}

test a_holding_with_another_new_token_beside_the_token_is_not_placed() {
  !placed(
    replace_output(
      holding_index(0),
      holding_with(
        output_at(holding_index(0)).value
          |> add(state_policy, active_token_name(registry(), key_b), 1),
      ),
    ),
    changes(),
    0,
  )
}

test the_token_under_another_policy_is_not_a_placement() {
  !placed(
    replace_output(
      holding_index(0),
      holding_with(
        from_lovelace(3_000_000)
          |> add(other_policy, active_token_name(registry(), key_a), 1),
      ),
    ),
    changes(),
    0,
  )
}

test other_assets_beside_the_token_do_not_stop_the_placement() {
  placed(
    replace_output(
      holding_index(0),
      holding_with(
        output_at(holding_index(0)).value
          |> add(other_policy, #"01", 7)
          |> add(application_policy, #"02", 1),
      ),
    ),
    changes(),
    0,
  )
}

test one_token_of_each_key_is_minted_by_the_fold() {
  list.all(
    [key_a, key_b, key_c],
    fn(key) { registration_mint(registry(), key, minted(scenario())) },
  )
}

test the_mint_of_a_key_is_not_zero_two_or_a_burn() {
  list.all(
    [0, 2, -1],
    fn(quantity) {
      !registration_mint(registry(), key_a, token(registry(), key_a, quantity))
    },
  )
}

test the_mint_of_another_key_registry_or_policy_is_not_the_mint_of_the_key() {
  list.all(
    [
      token(registry(), key_b, 1),
      token(registry_of(seed_b), key_a, 1),
      zero |> add(other_policy, active_token_name(registry(), key_a), 1),
      zero,
    ],
    fn(mint) { !registration_mint(registry(), key_a, mint) },
  )
}

test the_mint_of_the_key_may_stand_beside_other_mints() {
  registration_mint(
    registry(),
    key_a,
    token(registry(), key_a, 1)
      |> add(other_policy, #"01", 4)
      |> add(state_policy, active_token_name(registry(), key_b), 1),
  )
}

fn holding_of(lovelace: Int) -> Output {
  holding_with(from_lovelace(lovelace))
}

test a_holding_that_holds_at_least_the_deposit_is_enough() {
  registration_deposit(2_000_000, holding_of(2_000_000)) && registration_deposit(
    2_000_000,
    holding_of(2_000_001),
  ) && registration_deposit(0, holding_of(0)) && registration_deposit(
    1,
    holding_of(900_000_000),
  )
}

test a_holding_that_holds_less_than_the_deposit_is_not_enough() {
  !registration_deposit(2_000_000, holding_of(1_999_999)) && !registration_deposit(
    1,
    holding_of(0),
  ) && !registration_deposit(2_000_000, holding_of(1))
}

test the_deposit_is_counted_in_ada_alone() {
  !registration_deposit(
    2_000_000,
    holding_with(
      from_lovelace(1_999_999)
        |> add(other_policy, #"01", 5_000_000)
        |> add(state_policy, active_token_name(registry(), key_a), 1),
    ),
  )
}

fn apply_first(
  tx: Transaction,
  trie: mpf.MerklePatriciaForestry,
) -> Option<mpf.MerklePatriciaForestry> {
  expect Some(change) = list.head(changes_of(first_registration()))
  apply_change(
    application_policy,
    registry(),
    tx,
    changes_of(first_registration()),
    trie,
    change,
  )
}

fn first_transaction() -> Transaction {
  transaction_of(first_registration())
}

fn root_after(result: Option<mpf.MerklePatriciaForestry>) -> Option<ByteArray> {
  when result is {
    Some(trie) -> Some(mpf.root(trie))
    None -> None
  }
}

test a_change_that_holds_in_every_guard_adds_its_key_to_the_trie() {
  root_after(apply_first(first_transaction(), mpf.empty)) == Some(
    root_of([key_a]),
  )
}

test a_change_adds_its_key_to_a_trie_that_holds_others() {
  let tx = transaction_of(scenario())
  list.all(
    [0, 1, 2],
    fn(n) {
      expect Some(change) = list.at(changes(), n)
      expect Some(key) = list.at([key_a, key_b, key_c], n)
      let before = list.concat([key_d], list.take([key_a, key_b, key_c], n))
      root_after(
        apply_change(
          application_policy,
          registry(),
          tx,
          changes(),
          trie_of(before),
          change,
        ),
      ) == Some(root_of(list.concat(before, [key])))
    },
  )
}

fn without_input(tx: Transaction, request: OutputReference) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.filter(
      tx.inputs,
      fn(input) { input.output_reference != request },
    ),
  }
}

test a_change_whose_request_is_not_spent_is_refused() {
  apply_first(
    without_input(first_transaction(), registration_a().request),
    mpf.empty,
  ) == None
}

test a_change_whose_request_carries_another_approval_is_refused() {
  // the same request input, the approval of another registration
  let other = request_input(registry(), registration_b())
  let tx = first_transaction()
  apply_first(
    Transaction {
      ..tx,
      inputs: list.map(
        tx.inputs,
        fn(input) {
          if input.output_reference == registration_a().request {
            Input { ..input, output: other.output }
          } else {
            input
          }
        },
      ),
    },
    mpf.empty,
  ) == None
}

test a_change_whose_approval_is_not_burned_is_refused() {
  let tx = first_transaction()
  apply_first(
    Transaction { ..tx, mint: token(registry(), key_a, 1) },
    mpf.empty,
  ) == None
}

test a_change_whose_key_is_bound_is_refused() {
  apply_first(first_transaction(), trie_of([key_a])) == None
}

test a_change_whose_token_is_not_placed_is_refused() {
  let tx = first_transaction()
  apply_first(
    Transaction {
      ..tx,
      outputs: list.indexed_map(
        tx.outputs,
        fn(at, output) {
          if at == holding_index(0) {
            Output { ..output, value: from_lovelace(3_000_000) }
          } else {
            output
          }
        },
      ),
    },
    mpf.empty,
  ) == None
}

test a_change_whose_token_is_not_minted_is_refused() {
  let tx = first_transaction()
  apply_first(
    Transaction {
      ..tx,
      mint: zero
        |> add(
            application_policy,
            singular_state_fold_fixtures.approval_of(
              registry(),
              registration_a(),
            ),
            -1,
          ),
    },
    mpf.empty,
  ) == None
}

test a_change_whose_holding_is_short_of_the_deposit_is_refused() {
  let short =
    Registration {
      ..registration_a(),
      deposit: 6_000_000,
      holding_lovelace: 5_999_999,
    }
  let enough = Registration { ..short, holding_lovelace: 6_000_000 }
  let refused = Scenario { ..first_registration(), registrations: [short] }
  let accepted = Scenario { ..first_registration(), registrations: [enough] }
  expect Some(change_short) = list.head(changes_of(refused))
  expect Some(change_enough) = list.head(changes_of(accepted))
  apply_change(
    application_policy,
    registry(),
    transaction_of(refused),
    changes_of(refused),
    mpf.empty,
    change_short,
  ) == None && root_after(
    apply_change(
      application_policy,
      registry(),
      transaction_of(accepted),
      changes_of(accepted),
      mpf.empty,
      change_enough,
    ),
  ) == Some(root_of([key_a]))
}

test a_termination_is_refused() {
  let tx = first_transaction()
  let terminate =
    Terminate { request: registration_a().request, key: key_a, proof: [] }
  apply_change(
    application_policy,
    registry(),
    tx,
    [terminate],
    trie_of([key_a]),
    terminate,
  ) == None
}

fn batch(scenario: Scenario) -> Option<mpf.MerklePatriciaForestry> {
  change_batch(
    application_policy,
    registry_of(scenario.seed),
    transaction_of(scenario),
    trie_of(scenario.before),
    changes_of(scenario),
  )
}

test the_batch_adds_every_key_to_the_trie_in_order() {
  root_after(batch(scenario())) == Some(root_of([key_d, key_a, key_b, key_c])) && root_after(
    batch(first_registration()),
  ) == Some(root_of([key_a]))
}

test the_batch_root_does_not_depend_on_the_order_of_the_registrations() {
  let reversed =
    Scenario {
      ..scenario(),
      registrations: [registration_c(), registration_b(), registration_a()],
    }
  root_after(batch(reversed)) == Some(root_of([key_d, key_c, key_b, key_a])) && root_after(
    batch(reversed),
  ) == root_after(batch(scenario()))
}

test an_empty_batch_leaves_the_trie_as_it_was() {
  root_after(
    change_batch(
      application_policy,
      registry(),
      transaction_of(scenario()),
      trie_of([key_d]),
      [],
    ),
  ) == Some(root_of([key_d]))
}

test a_batch_with_one_change_that_is_refused_is_refused() {
  let tx = transaction_of(scenario())
  list.all(
    [0, 1, 2],
    fn(n) {
      let victim =
        when n is {
          0 -> registration_a().request
          1 -> registration_b().request
          _ -> registration_c().request
        }
      change_batch(
        application_policy,
        registry(),
        without_input(tx, victim),
        trie_of([key_d]),
        changes(),
      ) == None
    },
  )
}

test a_batch_with_a_stale_proof_is_refused() {
  // the proofs were built for the order a, b, c; applied in the order c, b, a
  // they describe tries the batch never reaches
  change_batch(
    application_policy,
    registry(),
    transaction_of(scenario()),
    trie_of([key_d]),
    list.reverse(changes()),
  ) == None
}

test a_batch_that_registers_one_key_twice_is_refused() {
  let again =
    Registration {
      ..registration_a(),
      request: OutputReference { transaction_id: #"aa", output_index: 9 },
    }
  batch(
    Scenario {
      ..first_registration(),
      registrations: [registration_a(), again],
    },
  ) == None
}

test a_batch_that_registers_a_key_the_trie_binds_is_refused() {
  batch(Scenario { ..scenario(), before: [key_a] }) == None
}

test the_continuing_state_must_carry_the_root_of_the_trie_the_batch_produced() {
  let trie = trie_of([key_d, key_a])
  fold_trie(
    Some(trie),
    Output { ..output_at(1), datum: root_datum(mpf.root(trie)) },
  ) && !fold_trie(
    Some(trie),
    Output { ..output_at(1), datum: root_datum(root_of([key_d])) },
  ) && !fold_trie(
    Some(trie),
    Output { ..output_at(1), datum: root_datum(root_of([key_d, key_a, key_b])) },
  )
}

test the_continuing_state_must_carry_a_root_datum() {
  let trie = trie_of([key_d, key_a])
  list.all(
    [
      NoDatum,
      DatumHash(
        #"00000000000000000000000000000000000000000000000000000000000000aa",
      ),
      InlineDatum(builtin.b_data(mpf.root(trie))),
      InlineDatum(builtin.constr_data(1, [builtin.b_data(mpf.root(trie))])),
      InlineDatum(
        builtin.constr_data(
          0,
          [builtin.b_data(mpf.root(trie)), builtin.b_data(#"")],
        ),
      ),
    ],
    fn(datum) { !fold_trie(Some(trie), Output { ..output_at(1), datum }) },
  )
}

test a_batch_that_was_refused_leaves_no_root_to_carry() {
  !fold_trie(None, output_at(1)) && !fold_trie(
    None,
    Output { ..output_at(1), datum: root_datum(mpf.root(mpf.empty)) },
  )
}

test the_leaf_of_a_registered_key_is_the_active_leaf() {
  // the byte the off-chain trie binds to an active key
  leaf_active == #"01" && root_after(
    apply_first(first_transaction(), mpf.empty),
  ) == Some(mpf.root(mpf.insert(mpf.empty, key_a, #"01", [])))
}

test a_termination_in_the_batch_is_not_a_new_token() {
  let terminate =
    Terminate { request: registration_c().request, key: key_c, proof: [] }
  let batch = list.concat(changes(), [terminate])
  one_new_token(registry(), batch, output_at(holding_index(0))) && !one_new_token(
    registry(),
    batch,
    holding_with(from_lovelace(3_000_000)),
  )
}

test a_holding_with_the_token_of_another_registration_does_not_place_this_one() {
  // the first two holdings swap their tokens: each holding holds exactly one
  // new token and each token is in exactly one output, but not in the holding
  // its change names
  let first = output_at(holding_index(0))
  let second = output_at(holding_index(1))
  let swapped =
    replace_output(holding_index(0), Output { ..first, value: second.value })
      |> list.indexed_map(
          fn(at, kept) {
            if at == holding_index(1) {
              Output { ..second, value: first.value }
            } else {
              kept
            }
          },
        )
  placed(outputs(), changes(), 0) && !placed(swapped, changes(), 0) && !placed(
    swapped,
    changes(),
    1,
  )
}

test a_change_whose_request_is_spent_twice_is_refused() {
  let tx = first_transaction()
  let request = request_input(registry(), registration_a())
  apply_first(tx, mpf.empty) != None && apply_first(
    Transaction { ..tx, inputs: list.concat(tx.inputs, [request]) },
    mpf.empty,
  ) == None
}

test a_change_whose_request_carries_a_second_application_token_is_refused() {
  // the approval is the first token the request carries; a second one sorts after it
  let tx = first_transaction()
  let request = request_input(registry(), registration_a())
  let extra =
    Input {
      ..request,
      output: Output {
        ..request.output,
        value: request.output.value
          |> add(
              application_policy,
              #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
              1,
            ),
      },
    }
  apply_first(
    Transaction {
      ..tx,
      inputs: list.map(
        tx.inputs,
        fn(input) {
          if input.output_reference == request.output_reference {
            extra
          } else {
            input
          }
        },
      ),
    },
    mpf.empty,
  ) == None
}

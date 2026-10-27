//// The termination of a key in the fold of the new Singular line, against the
//// model's `change` for `Change.terminate` (statements `termination_inversion`,
//// `termination_effects` and `batch_inversion`, bound at the revision of the
//// epic branch that landed the model): the request is spent once and carries
//// the one approval named by the registry and the key, the approval is burned,
//// the key is active in the trie, the request holds its active token once, and
//// that token is burned.
////
//// Every refusal row differs from the accepted termination in one part and
//// names the attempt it stands for; the accepted termination is asserted
//// beside it. Every token name, root and proof is obtained from the producers
//// at run time.

use aiken/builtin
use aiken/collection/list
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry}
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{Address}
use cardano/assets.{AssetName, PolicyId, Value, add, from_lovelace, zero}
use cardano/transaction.{
  Input, NoDatum, Output, OutputReference, Transaction, find_input,
}
use singular_state
use singular_state/fold.{Change, Fold, StateSpend, apply_change}
use singular_state/preimage.{RegistryIdentity, active_token_name}
use singular_state_fixtures.{
  application_policy, other_policy, root_datum, seed_a, seed_b, state_policy,
}
use singular_state_fold_fixtures.{
  approval_of, key_a, key_b, key_c, key_d, registration_a, registry_of,
  state_reference,
}
use singular_state_termination_fixtures.{
  Held, Mixed, Terminating, Termination, active, after_termination,
  changes_of_mixed, held_after, redeemer_mixed, root_of_held, terminal,
  termination_a, termination_approval_of, termination_b, termination_c,
  termination_d, transaction_mixed, trie_of_held,
}

fn registry() -> RegistryIdentity {
  registry_of(seed_a)
}

fn before() -> List<Held> {
  [active(key_a), active(key_b), active(key_d)]
}

fn scenario() -> Mixed {
  Mixed {
    seed: seed_a,
    before: before(),
    steps: [Terminating(termination_a())],
  }
}

fn valid() -> Transaction {
  transaction_mixed(scenario())
}

fn the_change() -> Change {
  expect [change] = changes_of_mixed(scenario())
  change
}

fn request() -> OutputReference {
  termination_a().request
}

fn approval() -> AssetName {
  termination_approval_of(registry(), key_a)
}

fn active_name() -> AssetName {
  active_token_name(registry(), key_a)
}

fn applied(tx: Transaction, held: List<Held>) -> Option<MerklePatriciaForestry> {
  apply_change(
    application_policy,
    registry(),
    tx,
    [the_change()],
    trie_of_held(held),
    the_change(),
  )
}

/// The change applies, and the trie after it is the trie before with the one
/// leaf terminal.
fn accepted(tx: Transaction, held: List<Held>) -> Bool {
  when applied(tx, held) is {
    Some(trie) ->
      mpf.root(trie) == root_of_held(after_termination(before(), key_a))
    None -> False
  }
}

fn refused(tx: Transaction, held: List<Held>) -> Bool {
  applied(tx, held) == None
}

/// The valid termination is accepted, and the changed one is refused.
fn refused_beside_control(tx: Transaction) -> Bool {
  accepted(valid(), before()) && refused(tx, before())
}

fn without_request(tx: Transaction) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.filter(
      tx.inputs,
      fn(input) { input.output_reference != request() },
    ),
  }
}

fn with_request_value(tx: Transaction, value: Value) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.map(
      tx.inputs,
      fn(input) {
        if input.output_reference == request() {
          Input { ..input, output: Output { ..input.output, value } }
        } else {
          input
        }
      },
    ),
  }
}

fn request_holding(tokens: List<(PolicyId, AssetName, Int)>) -> Value {
  list.foldl(
    tokens,
    from_lovelace(4_000_000),
    fn(token, value) {
      let (policy, name, quantity) = token
      add(value, policy, name, quantity)
    },
  )
}

fn minting(
  tx: Transaction,
  policy: PolicyId,
  name: AssetName,
  quantity: Int,
) -> Transaction {
  Transaction { ..tx, mint: add(tx.mint, policy, name, quantity) }
}

fn with_mint(tx: Transaction, mint: Value) -> Transaction {
  Transaction { ..tx, mint }
}

fn burning(tokens: List<(PolicyId, AssetName, Int)>) -> Value {
  list.foldl(
    tokens,
    zero,
    fn(token, value) {
      let (policy, name, quantity) = token
      add(value, policy, name, quantity)
    },
  )
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

fn folds(mixed: Mixed) -> Bool {
  spend(redeemer_mixed(mixed), transaction_mixed(mixed))
}

// ---------------------------------------------------------------------------
// termination-change-guards: the accepted termination
// ---------------------------------------------------------------------------

fn tries() -> List<List<Held>> {
  [
    [active(key_a)],
    [active(key_a), active(key_b)],
    [active(key_a), active(key_b), active(key_d)],
    [active(key_a), active(key_b), active(key_c), active(key_d)],
  ]
}

fn termination_of(key: ByteArray) -> Termination {
  expect Some(termination) =
    list.find(
      [termination_a(), termination_b(), termination_c(), termination_d()],
      fn(termination) { termination.key == key },
    )
  termination
}

test a_termination_with_every_guard_holding_is_applied() {
  accepted(valid(), before())
}

test every_active_key_of_a_trie_is_terminated_by_its_own_termination() {
  list.all(
    tries(),
    fn(held) {
      list.all(
        held,
        fn(each) {
          let mixed =
            Mixed {
              seed: seed_a,
              before: held,
              steps: [Terminating(termination_of(each.key))],
            }
          let tx = transaction_mixed(mixed)
          expect [change] = changes_of_mixed(mixed)
          when
            apply_change(
              application_policy,
              registry(),
              tx,
              [change],
              trie_of_held(held),
              change,
            )
          is {
            Some(trie) ->
              mpf.root(trie) == root_of_held(held_after(held, mixed.steps)) && folds(
                mixed,
              )
            None -> False
          }
        },
      )
    },
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: guard changeReference
// ---------------------------------------------------------------------------

test a_termination_whose_request_is_not_among_the_inputs_is_refused() {
  refused_beside_control(without_request(valid()))
}

test a_request_spent_twice_is_refused() {
  let tx = valid()
  expect Some(input) = find_input(tx.inputs, request())
  refused_beside_control(
    Transaction { ..tx, inputs: list.concat(tx.inputs, [input]) },
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: guard changeApprovalShape
// ---------------------------------------------------------------------------

test a_request_without_an_application_token_is_refused() {
  refused_beside_control(
    with_request_value(
      valid(),
      request_holding([(registry().policy, active_name(), 1)]),
    ),
  )
}

test a_request_with_two_application_tokens_is_refused() {
  refused_beside_control(
    with_request_value(
      valid(),
      request_holding(
        [
          (application_policy, approval(), 1),
          (application_policy, #"cafe", 1),
          (registry().policy, active_name(), 1),
        ],
      ),
    ),
  )
}

test a_request_with_two_of_the_approval_is_refused() {
  refused_beside_control(
    with_request_value(
      valid(),
      request_holding(
        [
          (application_policy, approval(), 2),
          (registry().policy, active_name(), 1),
        ],
      ),
    ),
  )
}

test a_request_whose_approval_sits_under_another_policy_is_refused() {
  refused_beside_control(
    with_request_value(
      valid(),
      request_holding(
        [(other_policy, approval(), 1), (registry().policy, active_name(), 1)],
      ),
    ),
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: guard changeApproval
//
// The approval the request carries is burned in each row, and so is the one the
// change recomputes, so that only the name differs from the accepted
// termination.
// ---------------------------------------------------------------------------

fn carrying_approval(name: AssetName) -> Transaction {
  valid()
    |> with_request_value(
        request_holding(
          [(application_policy, name, 1), (registry().policy, active_name(), 1)],
        ),
      )
    |> minting(application_policy, name, -1)
}

test a_request_with_the_approval_of_another_key_is_refused() {
  refused_beside_control(
    carrying_approval(termination_approval_of(registry(), key_b)),
  )
}

test a_request_with_the_approval_of_another_registry_policy_is_refused() {
  refused_beside_control(
    carrying_approval(
      termination_approval_of(
        RegistryIdentity { policy: other_policy, name: registry().name },
        key_a,
      ),
    ),
  )
}

test a_request_with_the_approval_of_another_registry_name_is_refused() {
  refused_beside_control(
    carrying_approval(termination_approval_of(registry_of(seed_b), key_a)),
  )
}

test a_request_with_the_registration_approval_of_the_key_is_refused() {
  refused_beside_control(
    carrying_approval(approval_of(registry(), registration_a())),
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: guard changeApprovalBurn
// ---------------------------------------------------------------------------

test an_approval_that_is_not_burned_is_refused() {
  refused_beside_control(
    with_mint(valid(), burning([(registry().policy, active_name(), -1)])),
  )
}

test an_approval_burned_twice_is_refused() {
  refused_beside_control(minting(valid(), application_policy, approval(), -1))
}

test an_approval_that_is_minted_is_refused() {
  refused_beside_control(
    with_mint(
      valid(),
      burning(
        [
          (registry().policy, active_name(), -1),
          (application_policy, approval(), 1),
        ],
      ),
    ),
  )
}

test the_burn_of_another_approval_is_not_the_burn_of_this_one() {
  refused_beside_control(
    with_mint(
      valid(),
      burning(
        [
          (registry().policy, active_name(), -1),
          (application_policy, termination_approval_of(registry(), key_b), -1),
        ],
      ),
    ),
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: guard changeLeaf
// ---------------------------------------------------------------------------

test a_key_the_trie_does_not_bind_is_not_terminated() {
  accepted(valid(), before()) && refused(
    valid(),
    [active(key_b), active(key_d)],
  )
}

test a_key_that_is_already_terminal_is_not_terminated_again() {
  accepted(valid(), before()) && refused(
    valid(),
    [terminal(key_a), active(key_b), active(key_d)],
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: guard terminationHeld
// ---------------------------------------------------------------------------

fn holding_active(tokens: List<(PolicyId, AssetName, Int)>) -> Transaction {
  with_request_value(
    valid(),
    request_holding(list.concat([(application_policy, approval(), 1)], tokens)),
  )
}

test a_request_that_holds_no_active_token_is_refused() {
  refused_beside_control(holding_active([]))
}

test a_request_that_holds_the_active_token_twice_is_refused() {
  refused_beside_control(
    holding_active([(registry().policy, active_name(), 2)]),
  )
}

test a_request_that_holds_the_active_token_of_another_key_is_refused() {
  refused_beside_control(
    holding_active(
      [(registry().policy, active_token_name(registry(), key_b), 1)],
    ),
  )
}

test a_request_that_holds_the_active_token_under_another_policy_is_refused() {
  refused_beside_control(holding_active([(other_policy, active_name(), 1)]))
}

test a_request_that_holds_the_active_token_of_another_registry_is_refused() {
  refused_beside_control(
    holding_active(
      [(registry().policy, active_token_name(registry_of(seed_b), key_a), 1)],
    ),
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: guard terminationBurn
// ---------------------------------------------------------------------------

test an_active_token_that_is_not_burned_is_refused() {
  refused_beside_control(
    with_mint(valid(), burning([(application_policy, approval(), -1)])),
  )
}

test an_active_token_burned_twice_is_refused() {
  refused_beside_control(minting(valid(), registry().policy, active_name(), -1))
}

test an_active_token_that_is_minted_is_refused() {
  refused_beside_control(
    with_mint(
      valid(),
      burning(
        [
          (registry().policy, active_name(), 1),
          (application_policy, approval(), -1),
        ],
      ),
    ),
  )
}

test the_burn_of_the_active_token_of_another_key_is_not_the_burn_of_this_one() {
  refused_beside_control(
    with_mint(
      valid(),
      burning(
        [
          (registry().policy, active_token_name(registry(), key_b), -1),
          (application_policy, approval(), -1),
        ],
      ),
    ),
  )
}

// ---------------------------------------------------------------------------
// termination-change-guards: the guards of the fold over a termination
// ---------------------------------------------------------------------------

fn refused_by_the_fold(tx: Transaction) -> Bool {
  spend(redeemer_mixed(scenario()), valid()) && !spend(
    redeemer_mixed(scenario()),
    tx,
  )
}

test a_fold_with_one_termination_is_accepted() {
  folds(scenario())
}

test a_termination_naming_a_request_twice_is_refused() {
  let twice = [the_change(), the_change()]
  spend(redeemer_mixed(scenario()), valid()) && !spend(
    Fold { seed: seed_a, changes: twice },
    valid(),
  )
}

test an_input_that_carries_an_application_token_no_change_names_is_refused() {
  let other = termination_b()
  let extra =
    Input {
      output_reference: other.request,
      output: Output {
        address: valid_request_address(),
        value: request_holding(
          [
            (application_policy, termination_approval_of(registry(), key_b), 1),
            (registry().policy, active_token_name(registry(), key_b), 1),
          ],
        ),
        datum: NoDatum,
        reference_script: None,
      },
    }
  refused_by_the_fold(
    Transaction { ..valid(), inputs: list.concat(valid().inputs, [extra]) },
  )
}

fn valid_request_address() -> Address {
  expect Some(input) = find_input(valid().inputs, request())
  input.output.address
}

test a_mint_of_another_token_under_the_state_policy_is_refused() {
  refused_by_the_fold(
    minting(valid(), state_policy, active_token_name(registry(), key_b), -1),
  )
}

test a_fold_that_leaves_the_root_unchanged_is_refused() {
  refused_by_the_fold(with_state_root(root_of_held(before())))
}

test a_fold_whose_root_drops_the_key_instead_of_terminating_it_is_refused() {
  refused_by_the_fold(
    with_state_root(root_of_held([active(key_b), active(key_d)])),
  )
}

test a_fold_whose_root_terminates_another_key_as_well_is_refused() {
  refused_by_the_fold(
    with_state_root(
      root_of_held([terminal(key_a), terminal(key_b), active(key_d)]),
    ),
  )
}

fn with_state_root(root: ByteArray) -> Transaction {
  let tx = valid()
  Transaction {
    ..tx,
    outputs: list.indexed_map(
      tx.outputs,
      fn(at, output) {
        if at == 1 {
          Output { ..output, datum: root_datum(root) }
        } else {
          output
        }
      },
    ),
  }
}

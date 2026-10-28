//// Termination proofs and roots computed from the model fixtures.
//// Honest proofs change the active leaf to terminal and preserve other leaves.
//// The proof builder covers branch, fork and leaf steps and shared prefixes.

use aiken/builtin
use aiken/collection/list
use aiken/merkle_patricia_forestry.{
  Branch, Fork, Leaf, MerklePatriciaForestry, Proof, ProofStep,
}
use aiken/merkle_patricia_forestry as mpf
use cardano/transaction.{Transaction}
use registry_fixtures.{absentLeaf, terminalLeaf}
use singular_state
use singular_state/fold.{
  Change, StateSpend, Terminate, apply_change, leaf_active, leaf_terminal,
}
use singular_state/genesis.{Folded}
use singular_state/preimage.{RegistryIdentity}
use singular_state_fixtures.{application_policy, seed_a, state_policy}
use singular_state_fold_fixtures.{
  key_a, key_b, key_c, key_d, registry_of, state_reference,
}
use singular_state_termination_fixtures.{
  Held, Mixed, Terminating, Termination, active, after_termination,
  built_root_of, changes_of_mixed, deep_tries, dense_proof_for, proof_for,
  redeemer_mixed, root_of_held, terminating, termination_a, termination_b,
  termination_c, termination_d, transaction_mixed, trie_of_held,
}

fn registry() -> RegistryIdentity {
  registry_of(seed_a)
}

fn tries() -> List<List<Held>> {
  [
    [active(key_d)],
    [active(key_d), active(key_a)],
    [active(key_a), active(key_d), active(key_b)],
    [active(key_a), active(key_b), active(key_c), active(key_d)],
  ]
}

fn termination_of(key: ByteArray) -> Termination {
  when
    list.find(
      [termination_a(), termination_b(), termination_c(), termination_d()],
      fn(termination) { termination.key == key },
    )
  is {
    Some(termination) -> termination
    None -> terminating(key, 0)
  }
}

fn scenario(held: List<Held>, key: ByteArray) -> Mixed {
  Mixed {
    seed: seed_a,
    before: held,
    steps: [Terminating(termination_of(key))],
  }
}

fn the_change(held: List<Held>, key: ByteArray) -> Change {
  expect [change] = changes_of_mixed(scenario(held, key))
  change
}

/// The termination of `key` in the trie that holds `held`, with `proof` in
/// place of the proof the folder builds.
fn applied_with(
  held: List<Held>,
  key: ByteArray,
  proof: Proof,
) -> Option<MerklePatriciaForestry> {
  let mixed = scenario(held, key)
  expect Terminate { request, key, .. } = the_change(held, key)
  let change = Terminate { request, key, proof }
  apply_change(
    application_policy,
    registry(),
    transaction_mixed(mixed),
    [change],
    trie_of_held(held),
    change,
  )
}

fn applied(held: List<Held>, key: ByteArray) -> Option<MerklePatriciaForestry> {
  expect Terminate { proof, .. } = the_change(held, key)
  applied_with(held, key, proof)
}

/// The honest termination of `key` is applied, and each of `proofs` in its
/// place is refused. The transaction and the trie are built once.
fn refuses_beside_control(
  held: List<Held>,
  key: ByteArray,
  proofs: List<Proof>,
) -> Bool {
  let tx = transaction_mixed(scenario(held, key))
  let trie = trie_of_held(held)
  expect Terminate { request, key, proof: honest } = the_change(held, key)
  let attempt =
    fn(proof) {
      let change = Terminate { request, key, proof }
      apply_change(application_policy, registry(), tx, [change], trie, change)
    }
  attempt(honest) != None && list.all(
    proofs,
    fn(proof) { attempt(proof) == None },
  )
}

/// The honest termination of `key` is applied, and `proof` in its place is not.
fn refused_beside_control(
  held: List<Held>,
  key: ByteArray,
  proof: Proof,
) -> Bool {
  refuses_beside_control(held, key, [proof])
}

test the_leaf_a_terminated_key_is_bound_to_is_the_terminal_byte_of_the_fixtures() {
  leaf_terminal == terminalLeaf && leaf_terminal != leaf_active && leaf_terminal != absentLeaf
}

test the_root_after_a_termination_is_the_root_before_with_the_one_leaf_terminal() {
  list.all(
    tries(),
    fn(held) {
      list.all(
        held,
        fn(each) {
          when applied(held, each.key) is {
            Some(after) ->
              mpf.root(after) == root_of_held(after_termination(held, each.key)) && mpf.root(
                after,
              ) != root_of_held(held)
            None -> False
          }
        },
      )
    },
  )
}

test the_leaf_of_the_key_is_terminal_and_every_other_leaf_is_as_it_was() {
  list.all(
    tries(),
    fn(held) {
      list.all(
        held,
        fn(each) {
          when applied(held, each.key) is {
            Some(after) -> {
              let leaves = after_termination(held, each.key)
              list.all(
                leaves,
                fn(leaf) {
                  mpf.has(
                    after,
                    leaf.key,
                    leaf.leaf,
                    proof_for(leaves, leaf.key),
                  )
                },
              ) && !mpf.has(
                after,
                each.key,
                leaf_active,
                proof_for(leaves, each.key),
              )
            }
            None -> False
          }
        },
      )
    },
  )
}

test a_proof_of_the_key_against_another_trie_is_refused() {
  let held = [active(key_a), active(key_b), active(key_d)]
  list.all(
    [
      proof_for([active(key_a)], key_d),
      proof_for([], key_d),
      proof_for([active(key_a), active(key_b), active(key_c)], key_d),
    ],
    fn(proof) { refused_beside_control(held, key_d, proof) },
  )
}

test a_proof_of_the_key_bound_to_another_leaf_is_refused() {
  let held = [active(key_a), active(key_b), active(key_d)]
  list.all(
    [#"00", #"02", #"03", #"0101", #""],
    fn(leaf) {
      applied(held, key_d) != None && applied(
        [active(key_a), active(key_b), Held { key: key_d, leaf }],
        key_d,
      ) == None
    },
  )
}

test an_empty_proof_is_refused_beside_the_proof_that_shows_the_key() {
  list.all(
    tries(),
    fn(held) {
      list.length(held) == 1 || refused_beside_control(held, key_d, [])
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

fn all_tries() -> List<List<Held>> {
  list.concat(tries(), deep_tries())
}

fn proofs_of_deep_tries() -> List<Proof> {
  list.flat_map(
    deep_tries(),
    fn(held) { list.map(held, fn(each) { proof_for(held, each.key) }) },
  )
}

test the_proof_builder_computes_the_root_the_library_computes() {
  list.all(all_tries(), fn(held) { built_root_of(held) == root_of_held(held) })
}

test the_proof_builder_shows_every_leaf_to_the_library() {
  list.all(
    all_tries(),
    fn(held) {
      list.all(
        held,
        fn(each) {
          mpf.has(
            trie_of_held(held),
            each.key,
            each.leaf,
            proof_for(held, each.key),
          )
        },
      )
    },
  )
}

test the_proof_builder_agrees_with_the_dense_builders_where_they_apply() {
  list.all(
    tries(),
    fn(held) {
      list.all(
        held,
        fn(each) {
          proof_for(held, each.key) == dense_proof_for(held, each.key)
        },
      )
    },
  )
}

fn is_branch(step: ProofStep) -> Bool {
  when step is {
    Branch { .. } -> True
    _ -> False
  }
}

fn is_fork_below_a_prefix(step: ProofStep) -> Bool {
  when step is {
    Fork { neighbor, .. } -> neighbor.prefix != #""
    _ -> False
  }
}

fn skips_over_a_prefix(step: ProofStep) -> Bool {
  when step is {
    Branch { skip, .. } -> skip > 0
    Fork { skip, .. } -> skip > 0
    Leaf { skip, .. } -> skip > 0
  }
}

fn is_leaf(step: ProofStep) -> Bool {
  when step is {
    Leaf { .. } -> True
    _ -> False
  }
}

fn leaf_that_steps_follow(proof: Proof) -> Bool {
  when proof is {
    [step, next, ..rest] ->
      is_leaf(step) || leaf_that_steps_follow([next, ..rest])
    _ -> False
  }
}

fn deep_steps() -> List<ProofStep> {
  list.flat_map(proofs_of_deep_tries(), fn(proof) { proof })
}

test the_deep_tries_give_honest_proofs_with_a_branch_step_that_skips_a_prefix() {
  list.any(list.filter(deep_steps(), is_branch), skips_over_a_prefix)
}

test the_deep_tries_give_honest_proofs_with_a_branch_step_at_a_prefix_of_nothing() {
  list.any(
    list.filter(deep_steps(), is_branch),
    fn(step) { !skips_over_a_prefix(step) },
  )
}

test the_deep_tries_give_honest_proofs_with_a_fork_step_whose_neighbour_has_a_prefix() {
  list.any(deep_steps(), is_fork_below_a_prefix)
}

test the_deep_tries_give_honest_proofs_with_a_leaf_step_that_skips_a_prefix() {
  list.any(list.filter(deep_steps(), is_leaf), skips_over_a_prefix)
}

test the_deep_tries_give_honest_proofs_with_a_leaf_step_that_other_steps_follow() {
  list.any(proofs_of_deep_tries(), leaf_that_steps_follow)
}

test the_deep_tries_give_honest_proofs_of_three_steps_or_more() {
  list.any(proofs_of_deep_tries(), fn(proof) { list.length(proof) >= 3 })
}

test every_key_of_a_deep_trie_that_is_active_is_terminated_with_its_honest_proof() {
  list.all(
    deep_tries(),
    fn(held) {
      list.all(
        list.filter(held, fn(each) { each.leaf == leaf_active }),
        fn(each) {
          let mixed = scenario(held, each.key)
          when applied(held, each.key) is {
            Some(after) ->
              mpf.root(after) == root_of_held(after_termination(held, each.key)) && spend(
                redeemer_mixed(mixed),
                transaction_mixed(mixed),
              ) && singular_state.singular_state.mint(
                application_policy,
                Folded,
                state_policy,
                transaction_mixed(mixed),
              )
            None -> False
          }
        },
      )
    },
  )
}

test every_leaf_of_a_deep_trie_is_read_back_after_a_termination() {
  list.all(
    deep_tries(),
    fn(held) {
      list.all(
        list.filter(held, fn(each) { each.leaf == leaf_active }),
        fn(each) {
          when applied(held, each.key) is {
            Some(after) -> {
              let leaves = after_termination(held, each.key)
              list.all(
                leaves,
                fn(leaf) {
                  mpf.has(
                    after,
                    leaf.key,
                    leaf.leaf,
                    proof_for(leaves, leaf.key),
                  )
                },
              )
            }
            None -> False
          }
        },
      )
    },
  )
}

/// The proofs of `key` in the other deep tries that differ from the proof in
/// `held`: a trie whose siblings along the path are the same gives the same
/// proof, and that proof shows the key in both.
fn proofs_from_other_tries(held: List<Held>, key: ByteArray) -> List<Proof> {
  let honest = proof_for(held, key)
  list.filter(
    list.map(
      list.filter(deep_tries(), fn(other) { other != held }),
      fn(other) { proof_for(other, key) },
    ),
    fn(proof) { proof != honest },
  )
}

test a_proof_of_the_key_against_another_deep_trie_is_refused() {
  let cases =
    list.flat_map(
      deep_tries(),
      fn(held) {
        list.map(
          list.filter(held, fn(each) { each.leaf == leaf_active }),
          fn(each) { (held, each.key) },
        )
      },
    )
  cases != [] && list.all(
    cases,
    fn(case) {
      let (held, key) = case
      let proofs = proofs_from_other_tries(held, key)
      proofs != [] && refuses_beside_control(held, key, proofs)
    },
  )
}

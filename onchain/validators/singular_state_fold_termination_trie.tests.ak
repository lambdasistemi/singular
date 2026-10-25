//// Termination proofs and roots computed from the model fixtures.
//// Honest proofs change the active leaf to terminal and preserve other leaves.
//// The proof builder covers branch, fork and leaf steps and shared prefixes.

use aiken/collection/list
use aiken/merkle_patricia_forestry.{
  MerklePatriciaForestry, Proof,
}
use aiken/merkle_patricia_forestry as mpf
use singular_state/fold.{Change, Terminate, apply_change, leaf_active}
use singular_state/preimage.{RegistryIdentity}
use singular_state_fixtures.{application_policy, seed_a}
use singular_state_fold_fixtures.{key_a, key_b, key_c, key_d, registry_of}
use singular_state_termination_fixtures.{
  Held, Mixed, Terminating, Termination, active, after_termination,
  changes_of_mixed, proof_for, root_of_held, termination_a, termination_b,
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
  expect Some(termination) =
    list.find(
      [termination_a(), termination_b(), termination_c(), termination_d()],
      fn(termination) { termination.key == key },
    )
  termination
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

fn refused_beside_control(
  held: List<Held>,
  key: ByteArray,
  proof: Proof,
) -> Bool {
  applied(held, key) != None && applied_with(held, key, proof) == None
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

//// Shared fixtures of the termination and mixed fold tests.
////
//// A fold scenario names the registry's seed, the leaves its trie holds
//// before and the changes folded now, registrations and terminations in any
//// order. The transaction, the redeemer, the proofs and the continuing state
//// are derived from it: every token name from the role functions of
//// `singular_state/preimage`, every root and proof from the Merkle Patricia
//// Forestry library through the proof builders of `registry_fixtures`, as the
//// earlier changes of the batch advanced the trie. A test changes one part of
//// a valid fold and nothing else.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, Proof}
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{from_script, from_verification_key}
use cardano/assets.{AssetName, Value, add, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use registry_fixtures.{branchStep, leafStep, slotOf, terminalLeaf}
use singular_state/fold.{
  Change, Fold, Register, StateSpend, Terminate, leaf_active,
}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, approval_name, state_token_name,
  termination_preimage,
}
use singular_state_fixtures.{
  application_policy, ordinary_output, root_datum, spent, state_policy,
}
use singular_state_fold_fixtures.{
  Registration, approval_of, fold_transaction_id, funding_reference,
  holding_index, holding_output, key_a, key_b, key_c, key_d, key_e, key_f,
  registry_of, request_input, request_reference, request_script, state_lovelace,
  state_reference,
}
use singular_state_proof_builder.{entry_of, proof_in, root_of_entries}

// ---------------------------------------------------------------------------
// Leaves and tries
// ---------------------------------------------------------------------------

/// A key and the leaf the trie binds to it.
pub type Held {
  key: ByteArray,
  leaf: ByteArray,
}

pub fn active(key: ByteArray) -> Held {
  Held { key, leaf: leaf_active }
}

pub fn terminal(key: ByteArray) -> Held {
  Held { key, leaf: terminalLeaf }
}

/// The proof that shows `key` in the trie that holds `held` and `key`: the
/// siblings on its path, whatever the shape of the trie. It is also the proof
/// that shows `key` absent from the trie that holds exactly `held`.
pub fn proof_for(held: List<Held>, key: ByteArray) -> Proof {
  let others = list.filter(held, fn(each) { each.key != key })
  proof_in(
    list.concat(
      list.map(others, fn(each) { entry_of(each.key, each.leaf) }),
      [entry_of(key, leaf_active)],
    ),
    0,
    blake2b_256(key),
  )
}

/// The same proof from the proof builders of `registry_fixtures`, which describe
/// a trie with one leaf per first nibble and nothing else.
pub fn dense_proof_for(held: List<Held>, key: ByteArray) -> Proof {
  let others = list.filter(held, fn(each) { each.key != key })
  when others is {
    [] -> []
    [one] -> [leafStep(one.key, one.leaf, key)]
    _ ->
      [
        branchStep(
          list.map(others, fn(each) { slotOf(each.key, each.leaf) }),
          key,
        ),
      ]
  }
}

/// The root of the trie that holds exactly `held`, from the digests the proof
/// builder computes, not from the library.
pub fn built_root_of(held: List<Held>) -> ByteArray {
  root_of_entries(list.map(held, fn(each) { entry_of(each.key, each.leaf) }))
}

fn insert_each(
  trie: MerklePatriciaForestry,
  done: List<Held>,
  rest: List<Held>,
) -> MerklePatriciaForestry {
  when rest is {
    [] -> trie
    [each, ..tail] ->
      insert_each(
        mpf.insert(trie, each.key, each.leaf, proof_for(done, each.key)),
        list.concat(done, [each]),
        tail,
      )
  }
}

/// The trie that holds exactly `held`.
pub fn trie_of_held(held: List<Held>) -> MerklePatriciaForestry {
  insert_each(mpf.empty, [], held)
}

/// The root of the trie that holds exactly `held`.
pub fn root_of_held(held: List<Held>) -> ByteArray {
  mpf.root(trie_of_held(held))
}

/// `held` with `key` registered. A key that is held already keeps its place and
/// takes the active leaf, so a scenario that names a key twice still has a
/// trie to build: the one a fold that accepted both changes would write.
pub fn after_registration(held: List<Held>, key: ByteArray) -> List<Held> {
  if list.any(held, fn(each) { each.key == key }) {
    list.map(
      held,
      fn(each) {
        if each.key == key {
          active(key)
        } else {
          each
        }
      },
    )
  } else {
    list.concat(held, [active(key)])
  }
}

/// `held` with the leaf of `key` terminal and every other leaf as it was.
pub fn after_termination(held: List<Held>, key: ByteArray) -> List<Held> {
  list.map(
    held,
    fn(each) {
      if each.key == key {
        terminal(key)
      } else {
        each
      }
    },
  )
}

// ---------------------------------------------------------------------------
// Terminations and registrations
// ---------------------------------------------------------------------------

/// One termination as the folder builds it from chain data: the key and the
/// request input that holds the termination approval and the active token.
pub type Termination {
  key: ByteArray,
  request: OutputReference,
  request_lovelace: Int,
}

pub fn termination_a() -> Termination {
  Termination {
    key: key_a,
    request: request_reference(10),
    request_lovelace: 4_000_000,
  }
}

pub fn termination_b() -> Termination {
  Termination {
    key: key_b,
    request: request_reference(11),
    request_lovelace: 5_000_000,
  }
}

pub fn termination_c() -> Termination {
  Termination {
    key: key_c,
    request: request_reference(12),
    request_lovelace: 3_000_000,
  }
}

pub fn termination_d() -> Termination {
  Termination {
    key: key_d,
    request: request_reference(13),
    request_lovelace: 6_000_000,
  }
}

pub fn termination_e() -> Termination {
  Termination {
    key: key_e,
    request: request_reference(14),
    request_lovelace: 3_500_000,
  }
}

pub fn termination_f() -> Termination {
  Termination {
    key: key_f,
    request: request_reference(15),
    request_lovelace: 4_500_000,
  }
}

/// A termination of `key` whose request is the `n`th of the scenario.
pub fn terminating(key: ByteArray, n: Int) -> Termination {
  Termination {
    key,
    request: request_reference(100 + n),
    request_lovelace: 3_000_000 + n * 100_000,
  }
}

// ---------------------------------------------------------------------------
// Keys that share prefixes
// ---------------------------------------------------------------------------

/// Keys whose hashes share leading nibbles, so that the tries built from them
/// have nodes below the first nibble. `deep_tries` says which share what; the
/// rows that use them check the shape of the proofs they get.
pub const key_t: ByteArray = "node676"

pub const key_v: ByteArray = "node2035"

pub const key_w: ByteArray = "node457"

pub const key_x: ByteArray = "node3647"

pub const key_u: ByteArray = "node60"

pub const key_y: ByteArray = "node1"

pub const key_z: ByteArray = "node31"

/// Two keys whose hashes begin with the nibble f and share the next two, so a
/// trie with one of the keys above and these two has a branch at the last
/// branch number as the neighbour of that key.
pub const key_f1: ByteArray = "node379"

pub const key_f2: ByteArray = "node1390"

/// Keys to register into the deep tries: their hashes begin with the nibbles
/// 6 and f, so they share the first nibble with the keys above and the second
/// with each other.
pub const key_n: ByteArray = "node42"

pub const key_o: ByteArray = "node255"

/// A registration of `key` whose request is the `n`th of the scenario.
pub fn registering(key: ByteArray, n: Int) -> Registration {
  Registration {
    key,
    request: request_reference(200 + n),
    holding_address: from_script(
      #"d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7",
    ),
    datum: builtin_datum(70 + n),
    deposit: 1_000_000 + n * 50_000,
    holding_lovelace: 2_000_000 + n * 70_000,
  }
}

/// Tries whose honest proofs are not one step: a leaf neighbour that follows a
/// shared prefix, a neighbour that is a branch with a prefix of its own, three
/// children or more at a node, and a leaf step that other steps follow.
pub fn deep_tries() -> List<List<Held>> {
  [
    [active(key_t), active(key_v)],
    [active(key_t), active(key_v), active(key_u)],
    [active(key_t), active(key_v), active(key_w), active(key_x)],
    [active(key_t), active(key_v), active(key_w), active(key_x), active(key_u)],
    [
      active(key_t),
      active(key_v),
      active(key_w),
      active(key_x),
      active(key_u),
      active(key_y),
      active(key_z),
    ],
    [active(key_t), active(key_y)],
    [active(key_t), active(key_v), active(key_y)],
    [active(key_t), active(key_v), active(key_w), active(key_x), active(key_y)],
    [
      active(key_t),
      terminal(key_v),
      active(key_w),
      terminal(key_x),
      active(key_u),
      active(key_y),
      active(key_z),
    ],
  ]
}

pub fn registration_e() -> Registration {
  Registration {
    key: key_e,
    request: request_reference(20),
    holding_address: from_script(
      #"d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5",
    ),
    datum: builtin_datum(5),
    deposit: 2_000_000,
    holding_lovelace: 2_600_000,
  }
}

pub fn registration_f() -> Registration {
  Registration {
    key: key_f,
    request: request_reference(21),
    holding_address: from_verification_key(
      #"0606060606060606060606060606060606060606060606060606060606",
    ),
    datum: builtin_datum(6),
    deposit: 1_500_000,
    holding_lovelace: 3_100_000,
  }
}

fn builtin_datum(number: Int) -> Data {
  let datum: Data = number
  datum
}

/// The name of the termination approval token of `key` in `registry`, from the
/// producer.
pub fn termination_approval_of(
  registry: RegistryIdentity,
  key: ByteArray,
) -> AssetName {
  approval_name(termination_preimage(key, registry))
}

/// The request input of `termination`: the termination approval, the active
/// token of the key, and an empty datum.
pub fn termination_input(
  registry: RegistryIdentity,
  termination: Termination,
) -> Input {
  Input {
    output_reference: termination.request,
    output: Output {
      address: from_script(request_script),
      value: from_lovelace(termination.request_lovelace)
        |> add(
            application_policy,
            termination_approval_of(registry, termination.key),
            1,
          )
        |> add(registry.policy, active_token_name(registry, termination.key), 1),
      datum: InlineDatum(empty_datum()),
      reference_script: None,
    },
  }
}

fn empty_datum() -> Data {
  let datum: Data = Void
  datum
}

// ---------------------------------------------------------------------------
// The fold
// ---------------------------------------------------------------------------

/// One change of a fold.
pub type Step {
  Registering(Registration)
  Terminating(Termination)
}

/// A fold: the registry's seed, the leaves its trie holds before, and the
/// changes folded now, in order.
pub type Mixed {
  seed: OutputReference,
  before: List<Held>,
  steps: List<Step>,
}

/// The leaves the trie holds after the changes.
pub fn held_after(held: List<Held>, steps: List<Step>) -> List<Held> {
  when steps is {
    [] -> held
    [Registering(registration), ..rest] ->
      held_after(after_registration(held, registration.key), rest)
    [Terminating(termination), ..rest] ->
      held_after(after_termination(held, termination.key), rest)
  }
}

fn changes_from(
  held: List<Held>,
  steps: List<Step>,
  registered: Int,
) -> List<Change> {
  when steps is {
    [] -> []
    [Registering(registration), ..rest] ->
      [
        Register {
          request: registration.request,
          key: registration.key,
          holding: holding_index(registered),
          deposit: registration.deposit,
          proof: proof_for(held, registration.key),
        },
        ..changes_from(
          after_registration(held, registration.key),
          rest,
          registered + 1,
        )
      ]
    [Terminating(termination), ..rest] ->
      [
        Terminate {
          request: termination.request,
          key: termination.key,
          proof: proof_for(held, termination.key),
        },
        ..changes_from(
          after_termination(held, termination.key),
          rest,
          registered,
        )
      ]
  }
}

/// The changes of the fold, each with the proof against the trie as the earlier
/// changes advanced it.
pub fn changes_of_mixed(mixed: Mixed) -> List<Change> {
  changes_from(mixed.before, mixed.steps, 0)
}

/// The state output of the registry created from `seed` whose trie holds `held`.
pub fn state_output_of(seed: OutputReference, held: List<Held>) -> Output {
  Output {
    address: from_script(state_policy),
    value: from_lovelace(state_lovelace)
      |> add(state_policy, state_token_name(seed), 1),
    datum: root_datum(root_of_held(held)),
    reference_script: None,
  }
}

fn request_of_step(registry: RegistryIdentity, step: Step) -> Input {
  when step is {
    Registering(registration) -> request_input(registry, registration)
    Terminating(termination) -> termination_input(registry, termination)
  }
}

fn holdings_of(registry: RegistryIdentity, steps: List<Step>) -> List<Output> {
  list.filter_map(
    steps,
    fn(step) {
      when step is {
        Registering(registration) ->
          Some(holding_output(registry, registration))
        Terminating(_) -> None
      }
    },
  )
}

/// The mint of the fold: a token for each registered key and none for a
/// terminated one, the active token of each terminated key burned, and each
/// approval burned.
pub fn minted_mixed(mixed: Mixed) -> Value {
  let registry = registry_of(mixed.seed)
  list.foldl(
    mixed.steps,
    zero,
    fn(step, mint) {
      when step is {
        Registering(registration) ->
          mint
            |> add(
                registry.policy,
                active_token_name(registry, registration.key),
                1,
              )
            |> add(application_policy, approval_of(registry, registration), -1)
        Terminating(termination) ->
          mint
            |> add(
                registry.policy,
                active_token_name(registry, termination.key),
                -1,
              )
            |> add(
                application_policy,
                termination_approval_of(registry, termination.key),
                -1,
              )
      }
    },
  )
}

/// The state input the fold spends.
pub fn state_input_of(seed: OutputReference, held: List<Held>) -> Input {
  Input {
    output_reference: state_reference,
    output: state_output_of(seed, held),
  }
}

/// The transaction of the fold.
pub fn transaction_mixed(mixed: Mixed) -> Transaction {
  let registry = registry_of(mixed.seed)
  Transaction {
    ..transaction.placeholder,
    id: fold_transaction_id,
    inputs: [
      spent(funding_reference),
      state_input_of(mixed.seed, mixed.before),
      ..list.map(mixed.steps, fn(step) { request_of_step(registry, step) })
    ],
    outputs: [
      ordinary_output,
      state_output_of(mixed.seed, held_after(mixed.before, mixed.steps)),
      ..holdings_of(registry, mixed.steps)
    ],
    mint: minted_mixed(mixed),
  }
}

/// The redeemer of the fold.
pub fn redeemer_mixed(mixed: Mixed) -> StateSpend {
  Fold { seed: mixed.seed, changes: changes_of_mixed(mixed) }
}

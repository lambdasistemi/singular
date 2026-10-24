//// Shared fixtures of the Singular fold tests.
////
//// Every token name a transaction carries, every proof and every root is
//// obtained from the producers at run time: the role names from
//// `singular_state/preimage`, the roots and proofs from the Merkle Patricia
//// Forestry library through the proof builders of `registry_fixtures`. A fold
//// scenario names the registry's seed, the keys already registered and the
//// registrations folded now; the transaction, the redeemer and the proofs
//// are derived from it, so a test changes one part of a valid fold and
//// nothing else.
////
//// The keys differ in the first nibble of their hash, so the proof builders,
//// which describe a root with one leaf per first nibble, describe every trie
//// built here.

use aiken/builtin
use aiken/collection/list
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, Proof}
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{Address, Script, from_script, from_verification_key}
use cardano/assets.{AssetName, Value, add, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, TransactionId,
}
use registry_fixtures.{branchStep, leafStep, slotOf}
use singular_state/fold.{Change, Fold, Register, StateSpend, leaf_active}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, approval_name, initial_datum_hash,
  registration_preimage, state_token_name,
}
use singular_state_fixtures.{
  application_policy, ordinary_output, root_datum, seed_a, spent, state_policy,
}

// ---------------------------------------------------------------------------
// Keys and tries
// ---------------------------------------------------------------------------

/// "keyA": the hash begins with nibble 6.
pub const key_a: ByteArray = #"6b657941"

/// "keyB": c.
pub const key_b: ByteArray = #"6b657942"

/// "keyC": 2.
pub const key_c: ByteArray = #"6b657943"

/// "keyD": f.
pub const key_d: ByteArray = #"6b657944"

/// "keyE": 8.
pub const key_e: ByteArray = #"6b657945"

/// "keyF": 7.
pub const key_f: ByteArray = #"6b657946"

/// The proof that inserts `key` into the trie that holds exactly `existing`.
pub fn proof_into(existing: List<ByteArray>, key: ByteArray) -> Proof {
  when existing is {
    [] -> []
    [one] -> [leafStep(one, leaf_active, key)]
    _ ->
      [
        branchStep(
          list.map(existing, fn(held) { slotOf(held, leaf_active) }),
          key,
        ),
      ]
  }
}

fn insert_all(
  trie: MerklePatriciaForestry,
  done: List<ByteArray>,
  keys: List<ByteArray>,
) -> MerklePatriciaForestry {
  when keys is {
    [] -> trie
    [key, ..rest] ->
      insert_all(
        mpf.insert(trie, key, leaf_active, proof_into(done, key)),
        list.concat(done, [key]),
        rest,
      )
  }
}

/// The trie that holds exactly `keys`, each bound to the active leaf.
pub fn trie_of(keys: List<ByteArray>) -> MerklePatriciaForestry {
  insert_all(mpf.empty, [], keys)
}

/// The root of the trie that holds exactly `keys`.
pub fn root_of(keys: List<ByteArray>) -> ByteArray {
  mpf.root(trie_of(keys))
}

// ---------------------------------------------------------------------------
// Registrations
// ---------------------------------------------------------------------------

/// One registration as the booker commits it: the key, the request input that
/// carries the approval, and the holding the token is delivered to.
pub type Registration {
  key: ByteArray,
  request: OutputReference,
  holding_address: Address,
  datum: Data,
  deposit: Int,
  holding_lovelace: Int,
}

pub const request_transaction: ByteArray =
  #"5245515545535400000000000000000000000000000000000000000000000000"

pub fn request_reference(index: Int) -> OutputReference {
  OutputReference { transaction_id: request_transaction, output_index: index }
}

pub const request_script: ByteArray =
  #"8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d"

pub const holding_script_a: ByteArray =
  #"d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"

pub const holding_script_b: ByteArray =
  #"d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"

pub const holding_stake: ByteArray =
  #"e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3"

/// An address with the payment credential of `holding_script_a` and a stake
/// credential.
pub fn staked_holding_a() -> Address {
  Address {
    payment_credential: Script(holding_script_a),
    stake_credential: Some(address.Inline(Script(holding_stake))),
  }
}

pub fn registration_a() -> Registration {
  Registration {
    key: key_a,
    request: request_reference(0),
    holding_address: from_script(holding_script_a),
    datum: builtin.i_data(11),
    deposit: 2_000_000,
    holding_lovelace: 3_000_000,
  }
}

/// The holding holds exactly the deposit.
pub fn registration_b() -> Registration {
  Registration {
    key: key_b,
    request: request_reference(1),
    holding_address: from_script(holding_script_b),
    datum: builtin.constr_data(1, [builtin.i_data(22)]),
    deposit: 2_500_000,
    holding_lovelace: 2_500_000,
  }
}

pub fn registration_c() -> Registration {
  Registration {
    key: key_c,
    request: request_reference(7),
    holding_address: from_verification_key(
      #"0303030303030303030303030303030303030303030303030303030303",
    ),
    datum: builtin.b_data(#"cafe"),
    deposit: 1_000_000,
    holding_lovelace: 4_000_000,
  }
}

pub fn registration_d() -> Registration {
  Registration {
    key: key_d,
    request: request_reference(300),
    holding_address: staked_holding_a(),
    datum: builtin.list_data([builtin.i_data(1), builtin.i_data(2)]),
    deposit: 3_000_000,
    holding_lovelace: 3_500_000,
  }
}

/// The registry created by spending `seed`.
pub fn registry_of(seed: OutputReference) -> RegistryIdentity {
  RegistryIdentity { policy: state_policy, name: state_token_name(seed) }
}

/// The approval name the booker commits for `registration` in `registry`.
pub fn approval_of(
  registry: RegistryIdentity,
  registration: Registration,
) -> AssetName {
  approval_name(
    registration_preimage(
      registration.key,
      registry,
      registration.holding_address,
      initial_datum_hash(registration.datum),
      registration.deposit,
    ),
  )
}

/// The request input that carries the approval of `registration`.
pub fn request_input(
  registry: RegistryIdentity,
  registration: Registration,
) -> Input {
  Input {
    output_reference: registration.request,
    output: Output {
      address: from_script(request_script),
      value: from_lovelace(registration.deposit + 1_000_000)
        |> add(application_policy, approval_of(registry, registration), 1),
      datum: InlineDatum(builtin.i_data(0)),
      reference_script: None,
    },
  }
}

/// The holding output the fold delivers the token of `registration` to.
pub fn holding_output(
  registry: RegistryIdentity,
  registration: Registration,
) -> Output {
  Output {
    address: registration.holding_address,
    value: from_lovelace(registration.holding_lovelace)
      |> add(registry.policy, active_token_name(registry, registration.key), 1),
    datum: InlineDatum(registration.datum),
    reference_script: None,
  }
}

// ---------------------------------------------------------------------------
// The state and the fold
// ---------------------------------------------------------------------------

pub const state_lovelace: Int = 5_000_000

pub const state_reference: OutputReference =
  OutputReference {
    transaction_id: #"5354415445000000000000000000000000000000000000000000000000000000",
    output_index: 3,
  }

pub const funding_reference: OutputReference =
  OutputReference {
    transaction_id: #"66554433221100000000000000000000000000000000000000000000000000ff",
    output_index: 9,
  }

pub const fold_transaction_id: TransactionId =
  #"f01df01df01df01df01df01df01df01df01df01df01df01df01df01df01df01d"

/// The state output of the registry created from `seed` that holds `keys`.
pub fn state_output(seed: OutputReference, keys: List<ByteArray>) -> Output {
  Output {
    address: from_script(state_policy),
    value: from_lovelace(state_lovelace)
      |> add(state_policy, state_token_name(seed), 1),
    datum: root_datum(root_of(keys)),
    reference_script: None,
  }
}

pub fn state_input(seed: OutputReference, keys: List<ByteArray>) -> Input {
  Input { output_reference: state_reference, output: state_output(seed, keys) }
}

/// A fold: the registry's seed, the keys already registered, and the
/// registrations folded now, in order.
pub type Scenario {
  seed: OutputReference,
  before: List<ByteArray>,
  registrations: List<Registration>,
}

/// One registration into an empty registry.
pub fn first_registration() -> Scenario {
  Scenario { seed: seed_a, before: [], registrations: [registration_a()] }
}

/// Three registrations in a registry that holds one key.
pub fn three_registrations() -> Scenario {
  Scenario {
    seed: seed_a,
    before: [key_d],
    registrations: [registration_a(), registration_b(), registration_c()],
  }
}

/// The index of the output of the `n`th registration: after an ordinary
/// output and the continuing state.
pub fn holding_index(n: Int) -> Int {
  n + 2
}

fn keys_of(registrations: List<Registration>) -> List<ByteArray> {
  list.map(registrations, fn(registration) { registration.key })
}

fn changes_from(
  registry: RegistryIdentity,
  done: List<ByteArray>,
  registrations: List<Registration>,
  n: Int,
) -> List<Change> {
  when registrations is {
    [] -> []
    [registration, ..rest] ->
      [
        Register {
          request: registration.request,
          key: registration.key,
          holding: holding_index(n),
          deposit: registration.deposit,
          proof: proof_into(done, registration.key),
        },
        ..changes_from(
          registry,
          list.concat(done, [registration.key]),
          rest,
          n + 1,
        )
      ]
  }
}

/// The changes of the fold, each with the proof against the trie as the
/// earlier changes advanced it.
pub fn changes_of(scenario: Scenario) -> List<Change> {
  changes_from(
    registry_of(scenario.seed),
    scenario.before,
    scenario.registrations,
    0,
  )
}

/// The mint of the fold: one token for each key, and each approval burned.
pub fn minted(scenario: Scenario) -> Value {
  let registry = registry_of(scenario.seed)
  list.foldl(
    scenario.registrations,
    zero,
    fn(registration, mint) {
      mint
        |> add(
            registry.policy,
            active_token_name(registry, registration.key),
            1,
          )
        |> add(application_policy, approval_of(registry, registration), -1)
    },
  )
}

/// The transaction of the fold.
pub fn transaction_of(scenario: Scenario) -> Transaction {
  let registry = registry_of(scenario.seed)
  let keys = list.concat(scenario.before, keys_of(scenario.registrations))
  Transaction {
    ..transaction.placeholder,
    id: fold_transaction_id,
    inputs: [
      spent(funding_reference),
      state_input(scenario.seed, scenario.before),
      ..list.map(
        scenario.registrations,
        fn(registration) { request_input(registry, registration) },
      )
    ],
    outputs: [
      ordinary_output,
      state_output(scenario.seed, keys),
      ..list.map(
        scenario.registrations,
        fn(registration) { holding_output(registry, registration) },
      )
    ],
    mint: minted(scenario),
  }
}

/// The redeemer of the fold.
pub fn redeemer_of(scenario: Scenario) -> StateSpend {
  Fold { seed: scenario.seed, changes: changes_of(scenario) }
}

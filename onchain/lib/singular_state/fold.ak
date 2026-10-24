//// Registration fold of a registry state.
////
//// ## Responsibility
//// The decision sites of the model's `fold` for registration changes: one
//// function per guard, and `fold`, which conjoins them for the spend handler
//// of the state script.
////
//// ## Dependencies
//// `singular_state/state` for recognition and the mint comparison;
//// `singular_state/genesis` for the outputs that carry the state token;
//// `singular_state/preimage` for the role names; the Merkle Patricia
//// Forestry library for the proof of absence and the new root.
////
//// ## Assumptions
//// The ledger runs the spend handler once for each input at the state script,
//// and the mint handler once when the state policy is minted. The state
//// policy is the hash of the state script, which is also the credential of
//// the state address.
////
//// ## Invariants
//// A fold spends the state of a registry once and writes the computed root
//// into the one bare output that continues it, at the same script. Each
//// registration consumes the one approval of exactly that change, proves its
//// key absent, and mints one token for the key into the holding the approval
//// commits to, with at least the deposit it commits to. Nothing else is
//// minted or burned under the state policy.

use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/merkle_patricia_forestry.{
  Branch, Fork, Leaf, MerklePatriciaForestry, Proof, ProofStep,
}
use aiken/merkle_patricia_forestry as mpf
use aiken/merkle_patricia_forestry/helpers.{nibble, nibbles}
use aiken/primitive/bytearray
use cardano/assets.{
  AssetName, PolicyId, Value, flatten, lovelace_of, quantity_of, tokens,
  without_lovelace,
}
use cardano/transaction.{
  Datum, InlineDatum, Input, Output, OutputReference, Transaction, TransactionId,
  find_input,
}
use singular_state/genesis.{state_candidates}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, approval_name, initial_datum_hash,
  registration_preimage, state_token_name,
}
use singular_state/state.{StateDatum, policy_delta, recognize_state, state_root}

/// The leaf the trie binds to a registered key: the model's `known active`.
pub const leaf_active: ByteArray = #"01"

/// One change of a fold, in the order of the model's `Change`. A termination
/// is declared to keep that order; a fold that carries one is refused.
pub type Change {
  Register {
    request: OutputReference,
    key: ByteArray,
    holding: Int,
    deposit: Int,
    proof: Proof,
  }
  Terminate { request: OutputReference, key: ByteArray, proof: Proof }
}

/// The redeemer of a state output: the seed that names the registry, and the
/// changes folded into it.
pub type StateSpend {
  Fold { seed: OutputReference, changes: List<Change> }
}

/// The request input a change consumes.
pub fn request_of(change: Change) -> OutputReference {
  when change is {
    Register { request, .. } -> request
    Terminate { request, .. } -> request
  }
}

/// The key a change is about.
pub fn key_of(change: Change) -> ByteArray {
  when change is {
    Register { key, .. } -> key
    Terminate { key, .. } -> key
  }
}

/// The registry created by spending `seed` under `state_policy`.
pub fn registry_identity(
  state_policy: PolicyId,
  seed: OutputReference,
) -> RegistryIdentity {
  RegistryIdentity { policy: state_policy, name: state_token_name(seed) }
}

/// The datum an application output carries, when it carries one: the data of an
/// inline datum, whatever its shape. The category of an output is its role in
/// the fold, not the shape of its datum.
pub fn application_datum(datum: Datum) -> Option<Data> {
  when datum is {
    InlineDatum(data) -> Some(data)
    _ -> None
  }
}

/// Model guard `foldBefore`: the spent state is recognised from the supplied
/// seed, its datum is the root of the trie before, and it is spent once.
pub fn fold_before(
  state_policy: PolicyId,
  seed: OutputReference,
  own_reference: OutputReference,
  inputs: List<Input>,
) -> Bool {
  when find_input(inputs, own_reference) is {
    Some(Input { output, .. }) -> and {
        recognize_state(state_policy, seed, output),
        has_trie_root(output),
        list.count(
          inputs,
          fn(input) { input.output_reference == own_reference },
        ) == 1,
      }
    None -> False
  }
}

// `from_root` stops the script on a root that is not 32 bytes.
fn has_trie_root(output: Output) -> Bool {
  when state_root(output.datum) is {
    Some(root) -> bytearray.length(root) == 32
    None -> False
  }
}

/// Model guard `foldNonempty`: the fold carries at least one change.
pub fn fold_nonempty(changes: List<Change>) -> Bool {
  when changes is {
    [] -> False
    _ -> True
  }
}

/// Model guard `foldDistinct`: no two changes consume the same request.
pub fn fold_distinct(changes: List<Change>) -> Bool {
  all_distinct(list.map(changes, request_of))
}

fn all_distinct(requests: List<OutputReference>) -> Bool {
  when requests is {
    [] -> True
    [first, ..rest] -> !list.has(rest, first) && all_distinct(rest)
  }
}

/// Model guard `foldPairing`: an input carries an application asset exactly
/// when a change consumes it.
pub fn fold_pairing(
  application_policy: PolicyId,
  changes: List<Change>,
  inputs: List<Input>,
) -> Bool {
  let requests = list.map(changes, request_of)
  let carriers =
    list.filter(
      inputs,
      fn(input) { carried_by(application_policy, input.output) != [] },
    )
  and {
    list.length(requests) == list.length(carriers),
    list.all(carriers, fn(input) { list.has(requests, input.output_reference) }),
  }
}

// The entries of `output` under `policy`: its name and its quantity.
fn carried_by(policy: PolicyId, output: Output) -> List<Pair<AssetName, Int>> {
  list.filter(
    dict.to_pairs(tokens(output.value, policy)),
    fn(Pair(_, quantity)) { quantity > 0 },
  )
}

/// Model guard `changeReference`: exactly one input spends the request.
pub fn change_reference(inputs: List<Input>, request: OutputReference) -> Bool {
  list.count(inputs, fn(input) { input.output_reference == request }) == 1
}

/// Model guard `changeApprovalShape`: the request input carries one token of
/// the application policy, at quantity one.
pub fn change_approval_shape(
  application_policy: PolicyId,
  request: Output,
) -> Bool {
  when carried_by(application_policy, request) is {
    [Pair(_, 1)] -> True
    _ -> False
  }
}

/// The approval a registration commits to, recomputed from the change and the
/// holding output it names. The output that carries the state token is the
/// model's `root` category and has none; any other output is an application
/// output.
pub fn approval_for(
  registry: RegistryIdentity,
  outputs: List<Output>,
  change: Change,
) -> Option<AssetName> {
  when change is {
    Register { key, holding, deposit, .. } ->
      when list.at(outputs, holding) is {
        Some(output) ->
          if quantity_of(output.value, registry.policy, registry.name) > 0 {
            None
          } else {
            when application_datum(output.datum) is {
              Some(datum) ->
                Some(
                  approval_name(
                    registration_preimage(
                      key,
                      registry,
                      output.address,
                      initial_datum_hash(datum),
                      deposit,
                    ),
                  ),
                )
              None -> None
            }
          }
        None -> None
      }
    Terminate { .. } -> None
  }
}

/// Model guard `changeApproval`: the application token the request carries is
/// the approval recomputed from the change.
pub fn change_approval(
  application_policy: PolicyId,
  request: Output,
  approval: AssetName,
) -> Bool {
  when carried_by(application_policy, request) is {
    [Pair(name, _), ..] -> name == approval
    [] -> False
  }
}

/// Model guard `changeApprovalBurn`: the approval is burned.
pub fn change_approval_burn(
  application_policy: PolicyId,
  approval: AssetName,
  mint: Value,
) -> Bool {
  quantity_of(mint, application_policy, approval) == -1
}

/// Model guard `changeLeaf`, for a registration: the trie proof shows the key
/// absent.
pub fn change_leaf(
  trie: MerklePatriciaForestry,
  key: ByteArray,
  proof: Proof,
) -> Bool {
  and {
    apart_from(key, proof),
    mpf.miss(trie, key, proof),
  }
}

/// Whether every field of every step of `proof` is in its canonical domain for
/// `key`, so the proof has one reading and the trie library is asked nothing
/// about a proof outside it. The cursor of the walk starts at nibble 0 and
/// moves forward past each step by its skip and one. A skip is not negative and
/// lands inside the hash. A branch carries four digests. A fork has a branch
/// number that is a nibble other than the key's at the landing nibble, a prefix
/// of nibbles that fits below it and a digest for its root. A leaf closes the
/// proof, carries a hash and a digest, and agrees with the key from the start of
/// the hash up to the landing nibble and differs at it, so its skip is the prefix
/// the two share beyond the cursor.
///
/// The library's `miss` ignores the skip of a last leaf, takes the digest of a
/// last leaf or fork step as the trie without the key whatever that step names,
/// and does no range check on a fork's branch number: outside this domain it can
/// be true for a key the trie binds. An honest proof is inside the domain.
pub fn apart_from(key: ByteArray, proof: Proof) -> Bool {
  in_canonical_domain(blake2b_256(key), 0, proof)
}

fn in_canonical_domain(path: ByteArray, cursor: Int, proof: Proof) -> Bool {
  when proof is {
    [] -> True
    [step, ..steps] -> {
      let skip = skip_of(step)
      let index = cursor + skip
      and {
        skip >= 0,
        index < 64,
        in_domain(path, index, step, steps == []),
        in_canonical_domain(path, index + 1, steps),
      }
    }
  }
}

fn skip_of(step: ProofStep) -> Int {
  when step is {
    Branch { skip, .. } -> skip
    Fork { skip, .. } -> skip
    Leaf { skip, .. } -> skip
  }
}

fn in_domain(path: ByteArray, index: Int, step: ProofStep, last: Bool) -> Bool {
  when step is {
    Branch { neighbors, .. } -> bytearray.length(neighbors) == 128
    Fork { neighbor, .. } -> and {
        neighbor.nibble >= 0,
        neighbor.nibble < 16,
        nibble(path, index) != neighbor.nibble,
        bytearray.length(neighbor.prefix) <= 63 - index,
        bytearray.foldl(
          neighbor.prefix,
          True,
          fn(byte, all) { all && byte < 16 },
        ),
        bytearray.length(neighbor.root) == 32,
      }
    Leaf { key, value, .. } -> and {
        last,
        bytearray.length(key) == 32,
        bytearray.length(value) == 32,
        nibbles(path, 0, index) == nibbles(key, 0, index),
        nibble(path, index) != nibble(key, index),
      }
  }
}

/// Model `separateHolding`: no other registration names the same holding.
pub fn separate_holding(
  changes: List<Change>,
  request: OutputReference,
  holding: Int,
) -> Bool {
  list.all(
    changes,
    fn(change) {
      when change is {
        Register { request: other, holding: other_holding, .. } ->
          other == request || other_holding != holding
        Terminate { .. } -> True
      }
    },
  )
}

/// Model `oneNewToken`: the holding holds one new token in total.
pub fn one_new_token(
  registry: RegistryIdentity,
  changes: List<Change>,
  holding: Output,
) -> Bool {
  list.foldl(
    changes,
    0,
    fn(change, total) {
      when change is {
        Register { key, .. } ->
          total + quantity_of(
            holding.value,
            registry.policy,
            active_token_name(registry, key),
          )
        Terminate { .. } -> total
      }
    },
  ) == 1
}

/// Model guard `registrationPlacement`: the token of the key is in the holding
/// once, and in no other output.
pub fn registration_placement(
  registry: RegistryIdentity,
  outputs: List<Output>,
  changes: List<Change>,
  request: OutputReference,
  key: ByteArray,
  holding: Int,
) -> Bool {
  let active = active_token_name(registry, key)
  when list.at(outputs, holding) is {
    Some(output) -> and {
        quantity_of(output.value, registry.policy, active) == 1,
        list.foldl(
          outputs,
          0,
          fn(each, total) {
            total + quantity_of(each.value, registry.policy, active)
          },
        ) == 1,
        separate_holding(changes, request, holding),
        one_new_token(registry, changes, output),
      }
    None -> False
  }
}

/// Model guard `registrationMint`: one token of the key is minted.
pub fn registration_mint(
  registry: RegistryIdentity,
  key: ByteArray,
  mint: Value,
) -> Bool {
  quantity_of(mint, registry.policy, active_token_name(registry, key)) == 1
}

/// Model guard `registrationDeposit`: the holding holds at least the deposit.
pub fn registration_deposit(deposit: Int, holding: Output) -> Bool {
  deposit <= lovelace_of(holding.value)
}

/// One change applied to the trie: every guard of the change holds. The trie
/// after it is `None` when one does not. A termination is refused.
pub fn apply_change(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  tx: Transaction,
  changes: List<Change>,
  trie: MerklePatriciaForestry,
  change: Change,
) -> Option<MerklePatriciaForestry> {
  when change is {
    Register { request, key, holding, deposit, proof } ->
      when
        (
          find_input(tx.inputs, request),
          list.at(tx.outputs, holding),
          approval_for(registry, tx.outputs, change),
        )
      is {
        (
          Some(Input { output: request_output, .. }),
          Some(holding_output),
          Some(approval),
        ) ->
          if and {
            change_reference(tx.inputs, request),
            change_approval_shape(application_policy, request_output),
            change_approval(application_policy, request_output, approval),
            change_approval_burn(application_policy, approval, tx.mint),
            change_leaf(trie, key, proof),
            registration_placement(
              registry,
              tx.outputs,
              changes,
              request,
              key,
              holding,
            ),
            registration_mint(registry, key, tx.mint),
            registration_deposit(deposit, holding_output),
          } {
            Some(mpf.insert(trie, key, leaf_active, proof))
          } else {
            None
          }
        _ -> None
      }
    Terminate { .. } -> None
  }
}

/// Model `changeBatch`: the changes applied in order to the trie before.
pub fn change_batch(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  tx: Transaction,
  trie: MerklePatriciaForestry,
  changes: List<Change>,
) -> Option<MerklePatriciaForestry> {
  apply_changes(application_policy, registry, tx, changes, trie, changes)
}

fn apply_changes(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  tx: Transaction,
  changes: List<Change>,
  trie: MerklePatriciaForestry,
  remaining: List<Change>,
) -> Option<MerklePatriciaForestry> {
  when remaining is {
    [] -> Some(trie)
    [change, ..rest] ->
      when
        apply_change(application_policy, registry, tx, changes, trie, change)
      is {
        Some(next) ->
          apply_changes(application_policy, registry, tx, changes, next, rest)
        None -> None
      }
  }
}

/// Model guard `foldTrie`: the batch was applied, and the continuing state
/// carries the root of the trie it produced.
pub fn fold_trie(result: Option<MerklePatriciaForestry>, after: Output) -> Bool {
  when result is {
    Some(trie) ->
      after.datum == InlineDatum(StateDatum { root: mpf.root(trie) })
    None -> False
  }
}

/// Model guard `foldContinuation`: exactly one output carries the state
/// token, and it carries nothing but ADA besides.
pub fn fold_continuation(
  state_policy: PolicyId,
  seed: OutputReference,
  outputs: List<Output>,
) -> Bool {
  when state_candidates(state_policy, seed, outputs) is {
    [after] ->
      flatten(without_lovelace(after.value)) == [
        (state_policy, state_token_name(seed), 1),
      ]
    _ -> False
  }
}

/// Model guard `foldAddress`: the continuing state is at the same payment
/// credential.
pub fn fold_address(before: Output, after: Output) -> Bool {
  after.address.payment_credential == before.address.payment_credential
}

/// Model guard `foldValue`: the continuing state holds at least the ADA the
/// spent one held.
pub fn fold_value(before: Output, after: Output) -> Bool {
  lovelace_of(before.value) <= lovelace_of(after.value)
}

/// Model guard `foldWholePolicy`: the whole state-policy mint is exactly one
/// token for each registered key.
pub fn fold_whole_policy(
  registry: RegistryIdentity,
  changes: List<Change>,
  mint: Value,
) -> Bool {
  policy_delta(
    mint,
    registry.policy,
    list.map(
      changes,
      fn(change) {
        Pair(
          active_token_name(registry, key_of(change)),
          when change is {
            Register { .. } -> 1
            Terminate { .. } -> -1
          },
        )
      },
    ),
  )
}

/// Model guard `foldNoNewConsumed`: no new holding is also an input.
pub fn fold_no_new_consumed(
  transaction_id: TransactionId,
  changes: List<Change>,
  inputs: List<Input>,
) -> Bool {
  list.all(
    changes,
    fn(change) {
      when change is {
        Register { holding, .. } ->
          !list.any(
            inputs,
            fn(input) {
              input.output_reference == OutputReference {
                transaction_id,
                output_index: holding,
              }
            },
          )
        Terminate { .. } -> True
      }
    },
  )
}

/// The mint handler of a fold: a state input is spent, and its spend handler
/// decides the fold.
pub fn fold_spends_state_script(
  _state_policy: PolicyId,
  _inputs: List<Input>,
) -> Bool {
  False
}

/// The model's `fold` for the state script of `application_policy`, spending
/// the state output `own_reference` of the registry created from `seed`.
pub fn fold(
  _application_policy: PolicyId,
  _seed: OutputReference,
  _changes: List<Change>,
  _own_reference: OutputReference,
  _tx: Transaction,
) -> Bool {
  False
}

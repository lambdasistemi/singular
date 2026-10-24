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
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, Proof}
use aiken/primitive/bytearray
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, tokens}
use cardano/transaction.{
  Datum, InlineDatum, Input, Output, OutputReference, Transaction, TransactionId,
  find_input,
}
use singular_state/preimage.{
  RegistryIdentity, approval_name, initial_datum_hash, registration_preimage,
  state_token_name,
}
use singular_state/state.{recognize_state, state_root}

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
  _trie: MerklePatriciaForestry,
  _key: ByteArray,
  _proof: Proof,
) -> Bool {
  False
}

/// Model `separateHolding`: no other registration names the same holding.
pub fn separate_holding(
  _changes: List<Change>,
  _request: OutputReference,
  _holding: Int,
) -> Bool {
  False
}

/// Model `oneNewToken`: the holding holds one new token in total.
pub fn one_new_token(
  _registry: RegistryIdentity,
  _changes: List<Change>,
  _holding: Output,
) -> Bool {
  False
}

/// Model guard `registrationPlacement`: the token of the key is in the holding
/// once, and in no other output.
pub fn registration_placement(
  _registry: RegistryIdentity,
  _outputs: List<Output>,
  _changes: List<Change>,
  _request: OutputReference,
  _key: ByteArray,
  _holding: Int,
) -> Bool {
  False
}

/// Model guard `registrationMint`: one token of the key is minted.
pub fn registration_mint(
  _registry: RegistryIdentity,
  _key: ByteArray,
  _mint: Value,
) -> Bool {
  False
}

/// Model guard `registrationDeposit`: the holding holds at least the deposit.
pub fn registration_deposit(_deposit: Int, _holding: Output) -> Bool {
  False
}

/// One change applied to the trie: every guard of the change holds. The trie
/// after it is `None` when one does not. A termination is refused.
pub fn apply_change(
  _application_policy: PolicyId,
  _registry: RegistryIdentity,
  _tx: Transaction,
  _changes: List<Change>,
  _trie: MerklePatriciaForestry,
  _change: Change,
) -> Option<MerklePatriciaForestry> {
  None
}

/// Model `changeBatch`: the changes applied in order to the trie before.
pub fn change_batch(
  _application_policy: PolicyId,
  _registry: RegistryIdentity,
  _tx: Transaction,
  _trie: MerklePatriciaForestry,
  _changes: List<Change>,
) -> Option<MerklePatriciaForestry> {
  None
}

/// Model guard `foldTrie`: the batch was applied, and the continuing state
/// carries the root of the trie it produced.
pub fn fold_trie(
  _result: Option<MerklePatriciaForestry>,
  _after: Output,
) -> Bool {
  False
}

/// Model guard `foldContinuation`: exactly one output carries the state
/// token, and it carries nothing but ADA besides.
pub fn fold_continuation(
  _state_policy: PolicyId,
  _seed: OutputReference,
  _outputs: List<Output>,
) -> Bool {
  False
}

/// Model guard `foldAddress`: the continuing state is at the same payment
/// credential.
pub fn fold_address(_before: Output, _after: Output) -> Bool {
  False
}

/// Model guard `foldValue`: the continuing state holds at least the ADA the
/// spent one held.
pub fn fold_value(_before: Output, _after: Output) -> Bool {
  False
}

/// Model guard `foldWholePolicy`: the whole state-policy mint is exactly one
/// token for each registered key.
pub fn fold_whole_policy(
  _registry: RegistryIdentity,
  _changes: List<Change>,
  _mint: Value,
) -> Bool {
  False
}

/// Model guard `foldNoNewConsumed`: no new holding is also an input.
pub fn fold_no_new_consumed(
  _transaction_id: TransactionId,
  _changes: List<Change>,
  _inputs: List<Input>,
) -> Bool {
  False
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

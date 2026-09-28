//// Genesis: minting a registry's state token (#157 C7).
////
//// ## Responsibility
////
//// `validateMint` is the rule behind the state validator's `Minting` mint
//// redeemer: a registry is booted by minting its one state token, named
//// after the seed output it consumes, into a state UTxO at the validator's
//// own script address whose datum holds the empty trie's root.
////
//// ## Dependencies
////
//// Imports `lib` (the seed-derived asset name, exact quantity), `types` and
//// the Merkle Patricia Forestry library (the empty root). Imported by
//// `state`, whose mint handler dispatches `Minting` here. It imports no
//// other registry owner: genesis runs no fold.
////
//// ## Assumptions
////
//// - The ledger guarantees an input is spent at most once, so consuming the
////   seed makes the minted token name unique to this registry.
//// - The seven non-root state fields are chosen freely at boot; a fold, not
////   genesis, keeps them fixed afterwards.
////
//// ## Invariants
////
//// - Minting succeeds only when the seed is an input, exactly one token of
////   that name is minted under this policy, and the first output is at this
////   script's address, with an inline state datum whose root is the empty
////   trie's, and holds that token at quantity exactly one.
//// - Every failing condition is an `expect`: genesis crashes rather than
////   tracing a user-defined reason.

use aiken/collection/list.{head}
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/option.{is_some}
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, OutputReference, Transaction, find_input}
use lib.{assetName, exactQuantity}
use types.{State, StateDatum, TokenId}

/// Genesis (#157 C7): the four policies are set here and preserved by
/// every fold. Boot is permissionless — there is no owner — so the mint
/// authorizes no particular choice of them; preservation is what gives
/// them their force, not mint-time approval. The consumer pin and its
/// width check are gone with `consumer.ak`.
pub fn validateMint(seed: OutputReference, policyId: PolicyId, tx: Transaction) {
  let Transaction { outputs, mint, inputs, .. } = tx
  let tokenId = TokenId { assetName: assetName(seed) }
  expect is_some(find_input(inputs, seed))
  expect exactQuantity(policyId, mint, tokenId, 1)
  expect Some(output) = head(outputs)
  expect address.Script(targetScriptHash) = output.address.payment_credential
  expect targetScriptHash == policyId
  expect InlineDatum(tokenState) = output.datum
  expect StateDatum(State { root: tokenRoot, .. }) = tokenState
  expect tokenRoot == root(empty)
  expect exactQuantity(policyId, output.value, tokenId, 1)
  True
}

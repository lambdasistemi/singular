//// Genesis: minting a registry's state token (#157 state-datum-fields).
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
//// - The ten non-root state fields are chosen at boot, except that the three
////   booking pins (minimum tip, registration cost, widest booking interval)
////   must be naturals and the request policy a 28-byte hash; a fold, not
////   genesis, keeps them fixed afterwards.
////
//// ## Invariants
////
//// - Minting succeeds only when the seed is an input, exactly one token of
////   that name is minted under this policy, and the first output is at this
////   script's address, with an inline state datum whose root is the empty
////   trie's, representable booking pins, and holds that token at quantity
////   exactly one.
//// - Every failing condition is an `expect`: genesis crashes rather than
////   tracing a user-defined reason.

use aiken/collection/list.{head}
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/option.{is_some}
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, OutputReference, Transaction, find_input}
use lib.{assetName, exactQuantity}
use types.{State, StateDatum, TokenId}

/// Genesis (#157 state-datum-fields): the four policies are set here and preserved by
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
  expect StateDatum(State {
    root: tokenRoot,
    tip,
    registration_cost,
    booking_width,
    request_policy,
    ..
  }) = tokenState
  expect tokenRoot == root(empty)
  // The booking pins must be representable: naturals, and a 28-byte policy.
  expect tip >= 0
  expect registration_cost >= 0
  expect booking_width >= 0
  expect bytearray.length(request_policy) == 28
  expect exactQuantity(policyId, output.value, tokenId, 1)
  True
}

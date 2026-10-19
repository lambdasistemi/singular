//// ## Responsibility
//// The permanent contract's admission of a fold of the registry's state: a
//// single `Modify` carries the registrations and terminations of the pending
//// requests its transaction spends, and nothing else.
////
//// ## Dependencies
//// Uses the canonical modify decision for state, requests, proofs, tags,
//// carriers and the allocation of value.
////
//// ## Assumptions
//// Missing or excess actions and malformed data are refused by the fold decision.
////
//// ## Invariants
//// Every member is a registration or a termination of this registry,
//// authenticated by the tags its booking minted; a legacy edge-only request
//// is no member. Nothing in State, a parameter or a redeemer can widen this
//// fixed admission set.

use cardano/assets.{PolicyId}
use cardano/transaction.{Input, Transaction}
use registry/modify.{validFold}
use types.{RequestAction, State, TokenId}

/// The fold decision: the continuation and pins, the members and the trie,
/// then the routing of value.
pub fn validModify(
  pins: State,
  input: Input,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
) -> Option<String> {
  validFold(pins, input, policyId, tokenId, tx, actions)
}

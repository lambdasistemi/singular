//// ## Responsibility
//// The Singular state script of one application: it creates a registry state
//// and recognises it from the seed supplied with each use.
////
//// ## Dependencies
//// `singular_state/genesis` decides the creation of a registry.
////
//// ## Assumptions
//// The application policy applied to the script makes the state policy of one
//// application distinct from that of every other.
////
//// ## Invariants
//// A state token is minted only by genesis; nothing spends a state output.

use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use singular_state/genesis.{Genesis, StateMint, genesis}

/// The state validator of an application.
///
/// - `mint`: `Genesis(seed)` creates the registry state of `seed` under the
///   rule of `singular_state/genesis`.
/// - `spend`: refused for every state output.
/// - `else`: every other purpose fails.
validator singular_state(_application_policy: PolicyId) {
  mint(redeemer: StateMint, policy_id: PolicyId, tx: Transaction) {
    let Genesis { seed } = redeemer
    genesis(seed, policy_id, tx)
  }

  spend(
    _datum: Option<Data>,
    _redeemer: Data,
    _own_reference: OutputReference,
    _tx: Transaction,
  ) {
    fail
  }

  else(_) {
    fail
  }
}

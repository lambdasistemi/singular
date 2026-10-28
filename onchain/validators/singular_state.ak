//// ## Responsibility
//// The Singular state script of one application: it creates a registry state,
//// recognises it from the seed supplied with each use, and folds registrations
//// into it.
////
//// ## Dependencies
//// `singular_state/genesis` decides the creation of a registry;
//// `singular_state/fold` decides the registration fold.
////
//// ## Assumptions
//// The application policy applied to the script makes the state policy of one
//// application distinct from that of every other.
////
//// ## Invariants
//// A state token is minted only by genesis; the tokens of registered keys are
//// minted only by a fold that spends the state; a state output is spent only
//// by a fold.

use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use singular_state/fold.{Fold, StateSpend, fold, fold_spends_state_script}
use singular_state/genesis.{Folded, Genesis, StateMint, genesis}

/// The state validator of an application.
///
/// - `mint`: `Genesis(seed)` creates the registry state of `seed` under the
///   rule of `singular_state/genesis`; `Folded` is a mint that belongs to a
///   fold, which requires a state input to be spent and leaves the decision
///   to its spend handler.
/// - `spend`: `Fold(seed, changes)` folds the changes into the registry state
///   of `seed` under the rule of `singular_state/fold`.
/// - `else`: every other purpose fails.
validator singular_state(application_policy: PolicyId) {
  mint(redeemer: StateMint, policy_id: PolicyId, tx: Transaction) {
    when redeemer is {
      Genesis { seed } -> genesis(seed, policy_id, tx)
      Folded -> fold_spends_state_script(policy_id, tx.inputs)
    }
  }

  spend(
    _datum: Option<Data>,
    redeemer: StateSpend,
    own_reference: OutputReference,
    tx: Transaction,
  ) {
    let Fold { seed, changes } = redeemer
    fold(application_policy, seed, changes, own_reference, tx)
  }

  else(_) {
    fail
  }
}

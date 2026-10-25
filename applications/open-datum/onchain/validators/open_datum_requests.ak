//// ## Responsibility
//// The open-datum request validator: it creates the configuration record of a
//// registry, approves the booking of registrations, lets anyone burn
//// approvals, and keeps the pending registrations and the configuration
//// records at its address.
////
//// ## Dependencies
//// `application/mint` decides the mint and `application/spend` the spend of a
//// pending registration.
////
//// ## Assumptions
//// The hash of this script is both the policy of its tokens and the payment
//// credential of its address, and the Singular state script of the
//// application is applied to that hash.
////
//// ## Invariants
//// A configuration record is never spent. No output at this address is spent
//// by any rule that has not been written: the spend paths of a pending
//// registration and of a live holding arrive with their own rules.

use application/mint.{ApplicationAction, application_mint}
use application/spend.{SpendAction, application_spend}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}

/// The validator of the open-datum requests.
///
/// - `mint`: the actions of the redeemer are decided by
///   `application/mint`.
/// - `spend`: every spend is refused.
/// - `else`: every other purpose fails.
validator open_datum_requests {
  mint(redeemer: List<ApplicationAction>, policy_id: PolicyId, tx: Transaction) {
    application_mint(policy_id, redeemer, tx)
  }

  spend(
    _datum: Option<Data>,
    redeemer: SpendAction,
    own_reference: OutputReference,
    tx: Transaction,
  ) {
    application_spend(redeemer, own_reference, tx)
  }

  else(_) {
    fail
  }
}

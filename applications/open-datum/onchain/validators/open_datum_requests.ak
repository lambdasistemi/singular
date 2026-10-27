//// ## Responsibility
//// The open-datum request validator: it creates the configuration record of a
//// registry, approves the booking of registrations, lets anyone burn
//// approvals, and decides the spend of registrations, live holdings and
//// termination requests at its address.
////
//// ## Dependencies
//// `application/mint` decides the mint and `application/spend` the spend of a
//// application input.
////
//// ## Assumptions
//// The hash of this script is both the policy of its tokens and the payment
//// credential of its address, and the Singular state script of the
//// application is applied to that hash.
////
//// ## Invariants
//// A configuration record is never spent. A pending registration is spent only
//// by a fold before its deadline, by its refund address inside the reclaim
//// window, or by anyone after the window. A live holding changes only with
//// its controller's signature, keeping control and tokens on an update or
//// donating the deposit on termination booking. A termination request is
//// spent only when both its active token and its approval burn.

use application/mint.{ApplicationAction, application_mint}
use application/spend.{SpendAction, application_spend}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}

/// The validator of the open-datum requests.
///
/// - `mint`: the actions of the redeemer are decided by
///   `application/mint`.
/// - `spend`: the action of the redeemer is decided by `application/spend`;
///   each input must satisfy the rule for the record it carries.
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

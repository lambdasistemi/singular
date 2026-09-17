use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}

/// The three token policies of a registry instance — RED: the rule is not
/// implemented here yet.
///
/// The parametrisation is in place so the row suite compiles and executes
/// against it, but the policy admits every movement. Co-presence with a fold
/// (the whole of its rule) is missing, the terminal kind has no burn
/// exception to be an exception to, and nothing here emits a trace — so P1's
/// three refusals and P2's two are folded, and the `no-fold` row of the trace
/// map has no executable extent.
validator witness(_kind: Int, _registry: ByteArray) {
  mint(_redeemer: Data, _policy_id: PolicyId, _tx: Transaction) {
    True
  }

  else(_) {
    fail
  }
}

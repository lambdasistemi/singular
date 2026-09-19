use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}

/// The open application (#173 I1, A-001 row 1).
///
/// Parameterless by design. The open registry is the application that
/// protects nobody: anyone may mint a fresh approval for any
/// `(edge, key, owner, destination)` at any time, so there is no
/// registry identity to apply the policy to — one policy id, one
/// blueprint, no applied hash to derive. Cross-registry separation is a
/// NAMED NON-GOAL here, not an omission: replaying an approval into a
/// second registry pinning this same policy grants nothing that registry
/// did not already grant everyone.
///
/// The admission rule is NOT YET IMPLEMENTED. This arm refuses
/// everything, so `open.tests.ak` executes the compiled validator and
/// fails on the absent admission rather than on a missing module.
validator open {
  mint(_redeemer: Data, _policy_id: PolicyId, _tx: Transaction) {
    trace @"open-unimplemented"
    False
  }

  else(_) {
    fail
  }
}

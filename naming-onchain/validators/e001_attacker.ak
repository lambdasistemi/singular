use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}

/// E-001 attack fixture (issue #77): an always-true minting policy modelling
/// an attacker's independently deployed policy.
///
/// Used ONLY by the connected foreign-policy refusal row in
/// `offchain/journey/register` — never for honest mints (honest folds mint
/// under the applied representative policy derived from this blueprint).
/// The application validator's state-anchored `representative-policy` check
/// refuses any representative moving under this policy, while this policy
/// itself imposes nothing — isolating the application refusal.
///
/// Anyone can deploy their own always-true policy on a permissionless ledger;
/// pinning this fixture changes nothing about that capability. It exists so
/// the refusal row executes a permanent, versioned foreign policy instead of
/// a transient mutant blueprint.
validator e001_attacker {
  mint(_redeemer: ByteArray, _policy_id: PolicyId, _tx: Transaction) {
    True
  }

  else(_) {
    fail
  }
}

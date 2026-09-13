use e001_attacker
use cardano/assets.{add, zero}
use cardano/transaction.{Transaction}

/// The attack fixture imposes nothing: any mint under it succeeds on its own.
/// The application validator is what refuses foreign-policy representatives
/// (state-anchored `representative-policy`, issue #77 E-001 repair).
test e001_attacker_mints_anything_accepts() {
  e001_attacker.e001_attacker.mint(
    #"00",
    "attacker_policy",
    Transaction {
      ..transaction.placeholder,
      mint: add(zero, "attacker_policy", #"526570", 1),
    },
  )
}

/// Burns likewise impose nothing at this policy.
test e001_attacker_burns_anything_accepts() {
  e001_attacker.e001_attacker.mint(
    #"00",
    "attacker_policy",
    Transaction {
      ..transaction.placeholder,
      mint: add(zero, "attacker_policy", #"526570", -1),
    },
  )
}

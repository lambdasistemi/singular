use retirement_custody
use cardano/assets.{add, zero}
use cardano/address
use cardano/transaction.{NoDatum, Input, Output}
use fixtures.{app_policy, record_value, self_ref}

/// Completion-only custody (issue #66): the representative it holds is
/// burned exactly once, by anybody. Spending it is the next child
/// (`LT04`/`LT07`); these unit tests pin the shape this slice creates.

fn custody_input(value) {
  Input {
    output_reference: self_ref,
    output: Output {
      address: address.from_script(fixtures.custody_hash),
      value,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn custody_tx(inputs, mint) {
  fixtures.tx(inputs, [], [], mint, [])
}

fn held_value() {
  add(record_value, app_policy, fixtures.representative_name, 1)
}

fn burn_held() {
  add(zero, app_policy, fixtures.representative_name, -1)
}

/// Completion burns the held representative exactly once, with no
/// signature from anybody.
test custody_completion_burns_accepts() {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_tx([custody_input(held_value())], burn_held()),
  )
}

/// Negation: no burn, no completion.
test custody_without_burn_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_tx([custody_input(held_value())], zero),
  )
}

/// Negation: a wrong quantity is not the representative leaving exactly
/// once.
test custody_double_burn_refuses() fail {
  let double =
    add(burn_held(), app_policy, fixtures.representative_name, -1)
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_tx([custody_input(held_value())], double),
  )
}

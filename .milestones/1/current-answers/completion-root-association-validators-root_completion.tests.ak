use cardano/assets.{add, zero}
use cardano/transaction.{Input, NoDatum, Output}
use fixtures.{app_policy, custody_address, representative_name, rep_policy, self_ref, tx}
use representative.{BurnRepresentative}
use retirement_custody

fn carrier() {
  Input {
    output_reference: self_ref,
    output: Output {
      address: custody_address,
      value: add(zero, rep_policy, representative_name, 1),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

// This exercises both actual handlers on one context. No registry or
// request input, reference, output, withdrawal or signature is present.
test root_both_handlers_accept_burn_without_registry_completion() {
  let context = tx([carrier()], [], [], add(zero, rep_policy, representative_name, -1), [])
  context.inputs == [carrier()]
    && context.reference_inputs == []
    && context.outputs == []
    && context.withdrawals == []
    && context.extra_signatories == []
    && representative.representative.mint(app_policy, BurnRepresentative, rep_policy, context)
    && retirement_custody.retirement_custody.spend(None, #"00", self_ref, context)
}

test root_custody_without_burn_still_refuses() fail {
  retirement_custody.retirement_custody.spend(None, #"00", self_ref, tx([carrier()], [], [], zero, []))
}

test root_burn_without_custody_still_refuses() fail {
  representative.representative.mint(app_policy, BurnRepresentative, rep_policy, tx([], [], [], add(zero, rep_policy, representative_name, -1), []))
}

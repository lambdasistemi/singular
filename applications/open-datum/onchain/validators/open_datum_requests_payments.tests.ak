//// What a transaction that spends pending registrations owes, against the
//// model's `requiredPayments`, `paidTo` and `requestValueSplit` (statement
//// `additive_payments`, bound at the revision of the epic branch that landed
//// the open-datum model).
////
//// Several payments owed to one address in one transaction are counted
//// together: one output does not satisfy two of them. The function rows pin
//// the counting; the validator rows spend several registrations in one
//// transaction and change the one fact under test of a perfect transaction.

use aiken/builtin
use aiken/collection/list
use application/held.{RegistrationData}
use application/payments.{Payment, paid_to, payments_covered}
use application/spend.{
  ExpiredCleanup, OwnerReclaim, RegistrationFold, SpendAction, required_payments,
  spend_action_of,
}
use cardano/address.{
  Address, Inline, Script, from_script, from_verification_key,
}
use cardano/assets.{add, from_lovelace, merge}
use cardano/transaction.{
  InlineDatum, Input, Mint, Output, OutputReference, Spend, Transaction,
}
use open_datum_requests
use open_datum_requests_fixtures.{
  application_policy, key_a, key_b, key_c, other_script, registration_a,
  registration_of, registry_a, state_policy,
}
use open_datum_requests_pending_fixtures.{
  Spending, active_mint_of, between, burn_of, change, funding_reference,
  holding_of, payment_to, pending_reference_n, pending_with_datum, refund_signer,
  request_lovelace, stranger, surplus, transaction_of,
}

fn address_a() -> Address {
  from_verification_key(
    #"1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a",
  )
}

fn address_b() -> Address {
  from_verification_key(
    #"1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b",
  )
}

fn address_a_with_stake() -> Address {
  Address {
    payment_credential: address.VerificationKey(
      #"1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a",
    ),
    stake_credential: Some(Inline(Script(other_script))),
  }
}

// ---------------------------------------------------------------------------
// payments-are-additive: what the outputs pay (model `paidTo`)
// ---------------------------------------------------------------------------

test nothing_is_paid_to_an_address_by_no_outputs() {
  paid_to([], address_a()) == 0
}

test an_output_pays_its_lovelace_to_its_address() {
  paid_to([payment_to(address_a(), 5_000_000)], address_a()) == 5_000_000
}

test outputs_to_one_address_pay_the_sum() {
  paid_to(
    [
      payment_to(address_a(), 5),
      payment_to(address_b(), 100),
      payment_to(address_a(), 7),
      payment_to(address_a(), 11),
    ],
    address_a(),
  ) == 23
}

test an_output_to_another_address_pays_nothing_to_this_one() {
  let outputs =
    [
      payment_to(address_b(), 9),
      payment_to(from_script(other_script), 9),
      payment_to(address_a_with_stake(), 9),
    ]
  and {
    paid_to(outputs, address_a()) == 0,
    paid_to(outputs, address_b()) == 9,
    paid_to(outputs, address_a_with_stake()) == 9,
  }
}

test an_output_pays_only_its_lovelace_whatever_it_carries() {
  let carrying =
    Output {
      address: address_a(),
      value: from_lovelace(5) |> add(state_policy, #"01", 3),
      datum: InlineDatum(0),
      reference_script: None,
    }
  paid_to([carrying, payment_to(address_a(), 2)], address_a()) == 7
}

// ---------------------------------------------------------------------------
// payments-are-additive: what the outputs cover (model `requestValueSplit`)
// ---------------------------------------------------------------------------

fn owes(address: Address, amount: Int) -> Payment {
  Payment { address, amount }
}

test no_payments_are_covered_by_any_outputs() {
  and {
    payments_covered([], []),
    payments_covered([], [payment_to(address_a(), 1)]),
  }
}

test one_payment_is_covered_by_an_output_of_at_least_its_amount() {
  and {
    payments_covered([owes(address_a(), 5)], [payment_to(address_a(), 5)]),
    payments_covered([owes(address_a(), 5)], [payment_to(address_a(), 6)]),
    !payments_covered([owes(address_a(), 5)], [payment_to(address_a(), 4)]),
    !payments_covered([owes(address_a(), 5)], []),
  }
}

test a_payment_of_nothing_is_covered_by_no_outputs() {
  payments_covered([owes(address_a(), 0)], [])
}

test two_payments_to_one_address_are_not_covered_by_one_payment_of_one() {
  let payments = [owes(address_a(), 5), owes(address_a(), 5)]
  and {
    !payments_covered(payments, [payment_to(address_a(), 5)]),
    !payments_covered(payments, [payment_to(address_a(), 9)]),
    payments_covered(payments, [payment_to(address_a(), 10)]),
    payments_covered(
      payments,
      [payment_to(address_a(), 5), payment_to(address_a(), 5)],
    ),
    !payments_covered(
      payments,
      [payment_to(address_a(), 5), payment_to(address_a(), 4)],
    ),
  }
}

test payments_to_different_addresses_are_covered_each_by_its_own_address() {
  let payments = [owes(address_a(), 5), owes(address_b(), 5)]
  and {
    payments_covered(
      payments,
      [payment_to(address_a(), 5), payment_to(address_b(), 5)],
    ),
    !payments_covered(payments, [payment_to(address_a(), 10)]),
    !payments_covered(
      payments,
      [payment_to(address_a(), 5), payment_to(address_b(), 4)],
    ),
    !payments_covered(payments, [payment_to(address_b(), 10)]),
  }
}

test interleaved_payments_are_summed_per_address() {
  let payments =
    [owes(address_a(), 3), owes(address_b(), 4), owes(address_a(), 2)]
  and {
    payments_covered(
      payments,
      [payment_to(address_a(), 5), payment_to(address_b(), 4)],
    ),
    !payments_covered(
      payments,
      [payment_to(address_a(), 4), payment_to(address_b(), 4)],
    ),
    !payments_covered(
      payments,
      [payment_to(address_a(), 5), payment_to(address_b(), 3)],
    ),
  }
}

test an_address_with_another_stake_part_is_another_address() {
  and {
    !payments_covered(
      [owes(address_a(), 5)],
      [payment_to(address_a_with_stake(), 5)],
    ),
    payments_covered(
      [owes(address_a_with_stake(), 5)],
      [payment_to(address_a_with_stake(), 5)],
    ),
  }
}

// ---------------------------------------------------------------------------
// payments-are-additive: what the actions require (model `requiredPayments`)
// ---------------------------------------------------------------------------

fn requires(tx: Transaction) -> List<Payment> {
  required_payments(application_policy, tx)
}

fn spending_of(
  n: Int,
  registration: RegistrationData,
  action: SpendAction,
) -> Spending {
  Spending(pending_reference_n(n), registration, action)
}

fn transaction_spending(spendings: List<Spending>) -> Transaction {
  transaction_of(spendings, [], assets.zero, between(0, 1), [])
}

test a_fold_requires_the_deposit_at_the_holding_address() {
  let registration = registration_a()
  requires(
    transaction_spending(
      [spending_of(0, registration, RegistrationFold { holding_index: 0 })],
    ),
  ) == [owes(registration.holding_address, registration.deposit)]
}

test a_reclaim_requires_the_whole_request_at_the_refund_address() {
  let registration = registration_a()
  requires(transaction_spending([spending_of(0, registration, OwnerReclaim)])) == [
    owes(registration.refund_address, request_lovelace(registration)),
  ]
}

test a_cleanup_requires_the_deposit_at_the_refund_address() {
  let registration = registration_a()
  requires(transaction_spending([spending_of(0, registration, ExpiredCleanup)])) == [
    owes(registration.refund_address, registration.deposit),
  ]
}

test every_spent_registration_requires_its_own_payment() {
  let first = registration_of(registry_a(), key_a)
  let second = registration_of(registry_a(), key_b)
  let third = registration_of(registry_a(), key_c)
  requires(
    transaction_spending(
      [
        spending_of(0, first, RegistrationFold { holding_index: 0 }),
        spending_of(1, second, OwnerReclaim),
        spending_of(2, third, ExpiredCleanup),
      ],
    ),
  ) == [
    owes(first.holding_address, first.deposit),
    owes(second.refund_address, request_lovelace(second)),
    owes(third.refund_address, third.deposit),
  ]
}

test a_transaction_that_spends_no_registration_requires_nothing() {
  let registration = registration_a()
  and {
    requires(transaction_spending([spending_of(0, registration, OwnerReclaim)])) != [],
    requires(transaction_spending([])) == [],
    requires(Transaction { ..transaction.placeholder, redeemers: [] }) == [],
  }
}

test the_redeemer_of_an_input_that_is_not_a_registration_requires_nothing() {
  let registration = registration_a()
  let base = transaction_spending([spending_of(0, registration, OwnerReclaim)])
  let action: Data = OwnerReclaim
  let with_wallet =
    Transaction {
      ..base,
      redeemers: [Pair(Spend(funding_reference()), action), ..base.redeemers],
    }
  let configuration_like =
    Transaction {
      ..base,
      inputs: [
        Input {
          output_reference: pending_reference_n(0),
          output: pending_with_datum(registration, InlineDatum(0)),
        },
      ],
    }
  and {
    requires(base) == [
      owes(registration.refund_address, request_lovelace(registration)),
    ],
    requires(with_wallet) == requires(base),
    requires(configuration_like) == [],
  }
}

test the_redeemer_of_an_input_at_another_script_requires_nothing() {
  let registration = registration_a()
  let base = transaction_spending([spending_of(0, registration, OwnerReclaim)])
  let elsewhere =
    Transaction {
      ..base,
      inputs: [
        Input {
          output_reference: pending_reference_n(0),
          output: Output {
            ..pending_with_datum(registration, InlineDatum(0)),
            address: from_script(other_script),
          },
        },
      ],
    }
  and {
    requires(base) == [
      owes(registration.refund_address, request_lovelace(registration)),
    ],
    requires(elsewhere) == [],
  }
}

test a_redeemer_for_an_input_the_transaction_does_not_spend_requires_nothing() {
  let registration = registration_a()
  let base = transaction_spending([spending_of(0, registration, OwnerReclaim)])
  let action: Data = OwnerReclaim
  and {
    requires(base) == [
      owes(registration.refund_address, request_lovelace(registration)),
    ],
    requires(
      Transaction {
        ..base,
        redeemers: [
          Pair(Spend(pending_reference_n(5)), action),
          ..base.redeemers
        ],
      },
    ) == requires(base),
  }
}

test a_redeemer_of_another_purpose_requires_nothing() {
  let registration = registration_a()
  let base = transaction_spending([spending_of(0, registration, OwnerReclaim)])
  let action: Data = OwnerReclaim
  and {
    requires(base) == [
      owes(registration.refund_address, request_lovelace(registration)),
    ],
    requires(
      Transaction {
        ..base,
        redeemers: [Pair(Mint(application_policy), action), ..base.redeemers],
      },
    ) == requires(base),
  }
}

test a_redeemer_that_is_no_action_requires_nothing() {
  let registration = registration_a()
  let base = transaction_spending([spending_of(0, registration, OwnerReclaim)])
  let not_an_action: Data = builtin.constr_data(3, [])
  and {
    requires(base) == [
      owes(registration.refund_address, request_lovelace(registration)),
    ],
    requires(
      Transaction {
        ..base,
        redeemers: [Pair(Spend(pending_reference_n(0)), not_an_action)],
      },
    ) == [],
  }
}

test an_action_is_read_from_its_redeemer() {
  let fold: Data = RegistrationFold { holding_index: 3 }
  let reclaim: Data = OwnerReclaim
  let cleanup: Data = ExpiredCleanup
  and {
    spend_action_of(fold) == Some(RegistrationFold { holding_index: 3 }),
    spend_action_of(reclaim) == Some(OwnerReclaim),
    spend_action_of(cleanup) == Some(ExpiredCleanup),
  }
}

test a_constructor_that_is_no_action_is_read_as_none() {
  let beyond: Data = builtin.constr_data(3, [])
  spend_action_of(beyond) == None
}

// ---------------------------------------------------------------------------
// payments-are-additive: the validator
// ---------------------------------------------------------------------------

fn run_at(
  action: SpendAction,
  reference: OutputReference,
  tx: Transaction,
) -> Bool {
  open_datum_requests.open_datum_requests.spend(None, action, reference, tx)
}

fn run_all(spendings: List<Spending>, tx: Transaction) -> Bool {
  list.all(
    spendings,
    fn(spending) { run_at(spending.action, spending.reference, tx) },
  )
}

/// Two registrations of one registry, both refunded to the fixture refund
/// address, both cleaned up after both windows.
fn two_cleanups(outputs: List<Output>) -> (List<Spending>, Transaction) {
  let first = registration_of(registry_a(), key_a)
  let second = registration_of(registry_a(), key_b)
  let spendings =
    [
      spending_of(0, first, ExpiredCleanup),
      spending_of(1, second, ExpiredCleanup),
    ]
  let tx =
    transaction_of(
      spendings,
      outputs,
      burn_of([first, second]),
      between(first.reclaim_end, first.reclaim_end + 600_000),
      [],
    )
  (spendings, tx)
}

test the_validator_accepts_two_cleanups_that_pay_both_deposits() {
  let first = registration_of(registry_a(), key_a)
  let refund = first.refund_address
  let deposit = first.deposit
  let (spendings_one, one_output) =
    two_cleanups([payment_to(refund, 2 * deposit)])
  let (spendings_two, two_outputs) =
    two_cleanups(
      [payment_to(refund, deposit), change(5), payment_to(refund, deposit)],
    )
  and {
    run_all(spendings_one, one_output),
    run_all(spendings_two, two_outputs),
  }
}

test the_validator_refuses_two_cleanups_that_pay_one_deposit_for_both() {
  let first = registration_of(registry_a(), key_a)
  let refund = first.refund_address
  let deposit = first.deposit
  let (spendings, one_payment) =
    two_cleanups([payment_to(refund, deposit), change(surplus(first))])
  let (_, short_by_one) = two_cleanups([payment_to(refund, 2 * deposit - 1)])
  let (_, none) = two_cleanups([])
  and {
    !run_all(spendings, one_payment),
    !run_all(spendings, short_by_one),
    !run_all(spendings, none),
    !run_at(ExpiredCleanup, pending_reference_n(0), one_payment),
    !run_at(ExpiredCleanup, pending_reference_n(1), one_payment),
  }
}

test the_validator_accepts_two_reclaims_that_return_both_requests() {
  let first = registration_of(registry_a(), key_a)
  let second = registration_of(registry_a(), key_b)
  let spendings =
    [spending_of(0, first, OwnerReclaim), spending_of(1, second, OwnerReclaim)]
  let whole = request_lovelace(first) + request_lovelace(second)
  let tx =
    transaction_of(
      spendings,
      [payment_to(first.refund_address, whole)],
      burn_of([first, second]),
      between(first.process_deadline, first.reclaim_end),
      [refund_signer(first)],
    )
  run_all(spendings, tx)
}

test the_validator_refuses_two_reclaims_that_return_one_request_for_both() {
  let first = registration_of(registry_a(), key_a)
  let second = registration_of(registry_a(), key_b)
  let spendings =
    [spending_of(0, first, OwnerReclaim), spending_of(1, second, OwnerReclaim)]
  let whole = request_lovelace(first) + request_lovelace(second)
  let reclaim_with =
    fn(outputs) {
      transaction_of(
        spendings,
        outputs,
        burn_of([first, second]),
        between(first.process_deadline, first.reclaim_end),
        [refund_signer(first)],
      )
    }
  and {
    !run_all(
      spendings,
      reclaim_with([payment_to(first.refund_address, request_lovelace(first))]),
    ),
    !run_all(
      spendings,
      reclaim_with([payment_to(first.refund_address, whole - 1)]),
    ),
  }
}

test the_validator_refuses_two_folds_that_claim_one_holding() {
  let registration = registration_a()
  let spendings =
    [
      spending_of(0, registration, RegistrationFold { holding_index: 0 }),
      spending_of(1, registration, RegistrationFold { holding_index: 0 }),
    ]
  let fold_with =
    fn(outputs) {
      transaction_of(
        spendings,
        outputs,
        merge(
          burn_of([registration, registration]),
          active_mint_of([registration]),
        ),
        between(
          registration.process_deadline - 600_000,
          registration.process_deadline,
        ),
        [],
      )
    }
  and {
    !run_all(spendings, fold_with([holding_of(registration), change(1)])),
    !run_at(
      RegistrationFold { holding_index: 0 },
      pending_reference_n(0),
      fold_with([holding_of(registration)]),
    ),
  }
}

test the_validator_counts_a_fold_and_a_cleanup_that_are_paid_at_one_address_together() {
  let fresh = registration_a()
  let old =
    RegistrationData {
      ..registration_of(registry_a(), key_b),
      booked_at: 5_000,
      process_deadline: 3_005_000,
      reclaim_end: 3_005_010,
      refund_address: from_script(application_policy),
    }
  let spendings =
    [
      spending_of(0, fresh, RegistrationFold { holding_index: 0 }),
      spending_of(1, old, ExpiredCleanup),
    ]
  let with_outputs =
    fn(outputs) {
      transaction_of(
        spendings,
        outputs,
        merge(burn_of([fresh, old]), active_mint_of([fresh])),
        between(old.reclaim_end, old.reclaim_end + 600_000),
        [],
      )
    }
  and {
    fresh.holding_address == old.refund_address,
    run_all(
      spendings,
      with_outputs(
        [holding_of(fresh), payment_to(old.refund_address, old.deposit)],
      ),
    ),
    !run_all(spendings, with_outputs([holding_of(fresh)])),
    !run_all(
      spendings,
      with_outputs(
        [holding_of(fresh), payment_to(old.refund_address, old.deposit - 1)],
      ),
    ),
  }
}

test the_validator_requires_each_refund_address_to_be_paid_for_its_own_registration() {
  let first = registration_of(registry_a(), key_a)
  let elsewhere =
    RegistrationData {
      ..registration_of(registry_a(), key_b),
      refund_address: address_a(),
    }
  let spendings =
    [
      spending_of(0, first, ExpiredCleanup),
      spending_of(1, elsewhere, ExpiredCleanup),
    ]
  let with_outputs =
    fn(outputs) {
      transaction_of(
        spendings,
        outputs,
        burn_of([first, elsewhere]),
        between(first.reclaim_end, first.reclaim_end + 600_000),
        [],
      )
    }
  and {
    run_all(
      spendings,
      with_outputs(
        [
          payment_to(first.refund_address, first.deposit),
          payment_to(address_a(), elsewhere.deposit),
        ],
      ),
    ),
    !run_all(
      spendings,
      with_outputs(
        [payment_to(first.refund_address, first.deposit + elsewhere.deposit)],
      ),
    ),
    !run_all(
      spendings,
      with_outputs([payment_to(address_a(), first.deposit + elsewhere.deposit)]),
    ),
    !run_all(
      spendings,
      with_outputs(
        [
          payment_to(first.refund_address, first.deposit),
          payment_to(stranger(), elsewhere.deposit),
        ],
      ),
    ),
  }
}

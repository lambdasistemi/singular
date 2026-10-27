//// The cleanup of a pending registration, against the model's
//// `registrationSpend` for the action `expiredCleanup` (statement
//// `expiredCleanup_inversion` and the money statement `cleanup_journey`, bound
//// at the revision of the epic branch that landed the open-datum model).
////
//// After the reclaim window anyone may clean a request up: the committed
//// deposit goes to the refund address and the cleaner keeps the rest. The
//// range rows quantify over the table of ranges of the fixtures; the payment
//// rows change the one fact under test of the perfect cleanup transaction.

use aiken/collection/list
use application/held.{RegistrationData}
use application/phases.{Cleanup}
use application/spend.{
  ExpiredCleanup, OwnerReclaim, RegistrationFold, SpendAction,
}
use cardano/address.{Address, Inline, Script, from_script}
use cardano/assets
use cardano/transaction.{OutputReference, Transaction}
use open_datum_requests
use open_datum_requests_fixtures.{
  key_b, other_script, refund_key, registration_a, registration_of, registry_a,
}
use open_datum_requests_pending_fixtures.{
  burn_of, case_range, cases, change, cleanup_range, cleanup_transaction,
  fold_transaction, payment_to, pending_reference, processing_range,
  reclaim_range, reclaim_transaction, refund_signer, registrations,
  registrations_over_time, stranger, surplus,
}

fn cleaned(tx: Transaction) -> Bool {
  run(ExpiredCleanup, tx)
}

// ---------------------------------------------------------------------------
// cleanup-returns-the-deposit-after-the-window: the validator accepts
// ---------------------------------------------------------------------------

test the_validator_accepts_the_cleanup_of_every_registration() {
  list.all(
    registrations(),
    fn(registration) { cleaned(cleanup_transaction(registration)) },
  )
}

test the_validator_accepts_the_cleanup_of_a_registration_booked_at_any_time() {
  list.all(
    registrations_over_time(),
    fn(registration) { cleaned(cleanup_transaction(registration)) },
  )
}

test the_validator_accepts_a_cleanup_in_every_cleanup_range_and_in_no_other() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases(),
        fn(case) {
          let tx =
            Transaction {
              ..cleanup_transaction(registration),
              validity_range: case_range(registration, case),
            }
          cleaned(tx) == ( case.expected == Cleanup )
        },
      )
    },
  )
}

test the_validator_accepts_a_cleanup_whoever_signs_it() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  and {
    cleaned(Transaction { ..tx, extra_signatories: [] }),
    cleaned(Transaction { ..tx, extra_signatories: [registration.controller] }),
    cleaned(
      Transaction { ..tx, extra_signatories: [refund_signer(registration)] },
    ),
    cleaned(Transaction { ..tx, extra_signatories: [#"0f", #"1f"] }),
  }
}

test the_validator_accepts_a_cleanup_whatever_the_cleaner_does_with_the_rest() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  let deposit_payment =
    payment_to(registration.refund_address, registration.deposit)
  and {
    cleaned(Transaction { ..tx, outputs: [deposit_payment] }),
    cleaned(
      Transaction {
        ..tx,
        outputs: [
          deposit_payment,
          payment_to(stranger(), surplus(registration)),
        ],
      },
    ),
    cleaned(
      Transaction { ..tx, outputs: [change(1), deposit_payment, change(2)] },
    ),
  }
}

test the_validator_accepts_a_cleanup_that_pays_more_than_the_deposit() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  cleaned(
    Transaction {
      ..tx,
      outputs: [
        payment_to(registration.refund_address, registration.deposit + 1),
      ],
    },
  )
}

test the_validator_accepts_a_cleanup_that_pays_the_deposit_in_several_outputs() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  cleaned(
    Transaction {
      ..tx,
      outputs: [
        payment_to(registration.refund_address, 1),
        change(7),
        payment_to(registration.refund_address, registration.deposit - 1),
      ],
    },
  )
}

test the_validator_accepts_the_cleanup_of_a_registration_whose_refund_address_is_a_script() {
  let registration =
    RegistrationData {
      ..registration_a(),
      refund_address: from_script(other_script),
    }
  cleaned(cleanup_transaction(registration))
}

test the_validator_accepts_a_cleanup_to_a_refund_address_with_a_stake_part() {
  let committed =
    Address {
      payment_credential: address.VerificationKey(refund_key),
      stake_credential: Some(Inline(Script(other_script))),
    }
  let registration =
    RegistrationData { ..registration_a(), refund_address: committed }
  cleaned(cleanup_transaction(registration))
}

// ---------------------------------------------------------------------------
// cleanup-returns-the-deposit-after-the-window: the validator refuses
// ---------------------------------------------------------------------------

test the_validator_refuses_a_cleanup_that_returns_less_than_the_deposit() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  and {
    cleaned(tx),
    !cleaned(
      Transaction {
        ..tx,
        outputs: [
          payment_to(registration.refund_address, registration.deposit - 1),
          change(surplus(registration)),
        ],
      },
    ),
    !cleaned(Transaction { ..tx, outputs: [change(surplus(registration))] }),
    !cleaned(Transaction { ..tx, outputs: [] }),
  }
}

test the_validator_refuses_a_cleanup_that_returns_the_deposit_elsewhere() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  and {
    !cleaned(
      Transaction {
        ..tx,
        outputs: [payment_to(stranger(), registration.deposit)],
      },
    ),
    !cleaned(Transaction { ..tx, outputs: [change(registration.deposit)] }),
    !cleaned(
      Transaction {
        ..tx,
        outputs: [payment_to(from_script(other_script), registration.deposit)],
      },
    ),
  }
}

test the_validator_refuses_a_cleanup_returned_to_the_key_with_another_stake_part() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  let other_stake =
    Address {
      payment_credential: address.VerificationKey(refund_key),
      stake_credential: Some(Inline(Script(other_script))),
    }
  and {
    registration.refund_address.stake_credential == None,
    !cleaned(
      Transaction {
        ..tx,
        outputs: [payment_to(other_stake, registration.deposit)],
      },
    ),
  }
}

test the_validator_refuses_a_cleanup_that_does_not_burn_the_approval() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  and {
    cleaned(tx),
    !cleaned(Transaction { ..tx, mint: assets.zero }),
    !cleaned(
      Transaction {
        ..tx,
        mint: burn_of([registration_of(registry_a(), key_b)]),
      },
    ),
  }
}

test the_validator_refuses_a_cleanup_of_an_input_that_is_not_in_the_transaction() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  !cleaned(
    Transaction {
      ..tx,
      inputs: list.filter(
        tx.inputs,
        fn(input) { input.output_reference != pending_reference() },
      ),
    },
  )
}

// ---------------------------------------------------------------------------
// cleanup-returns-the-deposit-after-the-window: no other spend after the
// window is the cleanup
// ---------------------------------------------------------------------------

test the_validator_refuses_a_cleanup_in_the_processing_phase_and_in_the_window() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  and {
    cleaned(tx),
    !cleaned(
      Transaction { ..tx, validity_range: processing_range(registration) },
    ),
    !cleaned(Transaction { ..tx, validity_range: reclaim_range(registration) }),
  }
}

test the_validator_refuses_a_reclaim_after_the_window() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  and {
    run(OwnerReclaim, tx),
    !run(
      OwnerReclaim,
      Transaction { ..tx, validity_range: cleanup_range(registration) },
    ),
  }
}

test the_validator_refuses_a_fold_after_the_window() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  !run(
    RegistrationFold { holding_index: 0 },
    Transaction { ..tx, validity_range: cleanup_range(registration) },
  )
}

// ---------------------------------------------------------------------------
// The validator
// ---------------------------------------------------------------------------

fn run_at(
  action: SpendAction,
  reference: OutputReference,
  tx: Transaction,
) -> Bool {
  open_datum_requests.open_datum_requests.spend(None, action, reference, tx)
}

fn run(action: SpendAction, tx: Transaction) -> Bool {
  run_at(action, pending_reference(), tx)
}

//// The reclaim of a pending registration, against the model's
//// `registrationSpend` for the action `ownerReclaim` (statement
//// `ownerReclaim_inversion` and the money statement `reclaim_journey`, bound
//// at the revision of the epic branch that landed the open-datum model).
////
//// The refund address signs, inside the reclaim window, and the whole value of
//// the request returns to it. The range rows quantify over the table of
//// ranges of the fixtures; the payment rows change the one fact under test of
//// the perfect reclaim transaction.

use aiken/collection/list
use application/held.{RegistrationData}
use application/phases.{Reclaim}
use application/spend.{
  ExpiredCleanup, OwnerReclaim, RegistrationFold, SpendAction, refund_signature,
}
use cardano/address.{
  Address, Inline, Script, from_script, from_verification_key,
}
use cardano/assets
use cardano/transaction.{OutputReference, Transaction}
use open_datum_requests
use open_datum_requests_fixtures.{
  controller, key_b, other_script, refund_key, registration_a, registration_of,
  registry_a,
}
use open_datum_requests_pending_fixtures.{
  burn_of, case_range, cases, change, cleanup_transaction, fold_action,
  fold_transaction, payment_to, pending_reference, processing_range,
  reclaim_range, reclaim_transaction, refund_signer, registrations,
  registrations_over_time, request_lovelace, stranger,
}

fn reclaimed(tx: Transaction) -> Bool {
  run(OwnerReclaim, tx)
}

// ---------------------------------------------------------------------------
// refund-address-reclaims-everything-in-the-window: the signature
// ---------------------------------------------------------------------------

test the_refund_address_signs_when_its_key_is_a_required_signer() {
  list.all(
    registrations(),
    fn(registration) {
      refund_signature(registration, [refund_signer(registration)])
    },
  )
}

test the_refund_address_signs_among_other_signers() {
  let registration = registration_a()
  refund_signature(
    registration,
    [registration.controller, refund_signer(registration), #"0f"],
  )
}

test the_refund_address_does_not_sign_when_nobody_signs() {
  !refund_signature(registration_a(), [])
}

test the_controller_does_not_sign_for_the_refund_address() {
  let registration = registration_a()
  and {
    registration.controller != refund_signer(registration),
    !refund_signature(registration, [registration.controller]),
    !refund_signature(registration, [controller]),
  }
}

test another_key_does_not_sign_for_the_refund_address() {
  let registration = registration_a()
  !refund_signature(registration, [#"0f", #"", #"1f1f"])
}

test the_refund_address_signs_with_any_stake_part() {
  let registration =
    RegistrationData {
      ..registration_a(),
      refund_address: Address {
        payment_credential: address.VerificationKey(refund_key),
        stake_credential: Some(Inline(Script(other_script))),
      },
    }
  refund_signature(registration, [refund_key])
}

test a_script_refund_address_cannot_sign() {
  let registration =
    RegistrationData {
      ..registration_a(),
      refund_address: from_script(other_script),
    }
  and {
    !refund_signature(registration, []),
    !refund_signature(registration, [other_script]),
  }
}

// ---------------------------------------------------------------------------
// refund-address-reclaims-everything-in-the-window: the validator accepts
// ---------------------------------------------------------------------------

test the_validator_accepts_the_reclaim_of_every_registration() {
  list.all(
    registrations(),
    fn(registration) { reclaimed(reclaim_transaction(registration)) },
  )
}

test the_validator_accepts_the_reclaim_of_a_registration_booked_at_any_time() {
  list.all(
    registrations_over_time(),
    fn(registration) { reclaimed(reclaim_transaction(registration)) },
  )
}

test the_validator_accepts_a_reclaim_in_every_reclaim_range_and_in_no_other() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases(),
        fn(case) {
          let tx =
            Transaction {
              ..reclaim_transaction(registration),
              validity_range: case_range(registration, case),
            }
          reclaimed(tx) == ( case.expected == Reclaim )
        },
      )
    },
  )
}

test the_validator_accepts_a_reclaim_that_other_keys_also_sign() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  reclaimed(
    Transaction {
      ..tx,
      extra_signatories: [
        registration.controller,
        refund_signer(registration),
        #"0f",
      ],
    },
  )
}

test the_validator_accepts_a_reclaim_that_pays_more_than_the_whole_request() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  reclaimed(
    Transaction {
      ..tx,
      outputs: [
        payment_to(
          registration.refund_address,
          request_lovelace(registration) + 1,
        ),
      ],
    },
  )
}

test the_validator_accepts_a_reclaim_that_pays_the_whole_request_in_several_outputs() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  let whole = request_lovelace(registration)
  reclaimed(
    Transaction {
      ..tx,
      outputs: [
        payment_to(registration.refund_address, whole - 3_000_000),
        change(5),
        payment_to(registration.refund_address, 1_000_000),
        payment_to(registration.refund_address, 2_000_000),
      ],
    },
  )
}

test the_validator_accepts_a_reclaim_to_a_refund_address_with_a_stake_part() {
  let committed =
    Address {
      payment_credential: address.VerificationKey(refund_key),
      stake_credential: Some(Inline(Script(other_script))),
    }
  let registration =
    RegistrationData { ..registration_a(), refund_address: committed }
  reclaimed(reclaim_transaction(registration))
}

// ---------------------------------------------------------------------------
// refund-address-reclaims-everything-in-the-window: the validator refuses
// ---------------------------------------------------------------------------

test the_validator_refuses_a_reclaim_that_nobody_signs() {
  let tx = reclaim_transaction(registration_a())
  and {
    reclaimed(tx),
    !reclaimed(Transaction { ..tx, extra_signatories: [] }),
  }
}

test the_validator_refuses_a_reclaim_signed_by_the_controller_only() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  and {
    !reclaimed(
      Transaction { ..tx, extra_signatories: [registration.controller] },
    ),
    !reclaimed(Transaction { ..tx, extra_signatories: [controller, #"0f"] }),
  }
}

test the_validator_refuses_a_reclaim_signed_by_the_refund_key_of_another_address() {
  let registration = registration_a()
  let other =
    RegistrationData {
      ..registration,
      refund_address: from_verification_key(
        #"0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a",
      ),
    }
  let tx = reclaim_transaction(registration)
  !reclaimed(Transaction { ..tx, extra_signatories: [refund_signer(other)] })
}

test the_validator_refuses_the_reclaim_of_a_registration_whose_refund_address_is_a_script() {
  let registration =
    RegistrationData {
      ..registration_a(),
      refund_address: from_script(other_script),
    }
  let tx = reclaim_transaction(registration)
  !reclaimed(
    Transaction { ..tx, extra_signatories: [other_script, controller] },
  )
}

test the_validator_refuses_a_reclaim_that_returns_less_than_the_whole_request() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  let whole = request_lovelace(registration)
  and {
    reclaimed(tx),
    !reclaimed(
      Transaction {
        ..tx,
        outputs: [payment_to(registration.refund_address, whole - 1)],
      },
    ),
    !reclaimed(
      Transaction {
        ..tx,
        outputs: [
          payment_to(registration.refund_address, registration.deposit),
          change(whole - registration.deposit),
        ],
      },
    ),
    !reclaimed(Transaction { ..tx, outputs: [] }),
  }
}

test the_validator_refuses_a_reclaim_that_returns_the_request_elsewhere() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  let whole = request_lovelace(registration)
  and {
    !reclaimed(Transaction { ..tx, outputs: [payment_to(stranger(), whole)] }),
    !reclaimed(Transaction { ..tx, outputs: [change(whole)] }),
    !reclaimed(
      Transaction {
        ..tx,
        outputs: [payment_to(from_script(other_script), whole)],
      },
    ),
  }
}

test the_validator_refuses_a_reclaim_returned_to_the_key_with_another_stake_part() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  let other_stake =
    Address {
      payment_credential: address.VerificationKey(refund_key),
      stake_credential: Some(Inline(Script(other_script))),
    }
  and {
    registration.refund_address.stake_credential == None,
    !reclaimed(
      Transaction {
        ..tx,
        outputs: [payment_to(other_stake, request_lovelace(registration))],
      },
    ),
  }
}

test the_validator_refuses_a_reclaim_that_does_not_burn_the_approval() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  and {
    reclaimed(tx),
    !reclaimed(Transaction { ..tx, mint: assets.zero }),
    !reclaimed(
      Transaction {
        ..tx,
        mint: burn_of([registration_of(registry_a(), key_b)]),
      },
    ),
  }
}

test the_validator_refuses_a_reclaim_of_an_input_that_is_not_a_registration() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  !reclaimed(
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
// refund-address-reclaims-everything-in-the-window: nobody else takes the
// request in the window
// ---------------------------------------------------------------------------

test the_validator_refuses_a_fold_in_the_reclaim_window() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  and {
    run(fold_action(), tx),
    !run(
      fold_action(),
      Transaction { ..tx, validity_range: reclaim_range(registration) },
    ),
    !run(
      RegistrationFold { holding_index: 0 },
      Transaction { ..tx, validity_range: reclaim_range(registration) },
    ),
  }
}

test the_validator_refuses_a_cleanup_in_the_reclaim_window() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  and {
    run(ExpiredCleanup, tx),
    !run(
      ExpiredCleanup,
      Transaction { ..tx, validity_range: reclaim_range(registration) },
    ),
    !run(
      ExpiredCleanup,
      Transaction {
        ..tx,
        validity_range: reclaim_range(registration),
        extra_signatories: [refund_signer(registration)],
      },
    ),
  }
}

test the_validator_refuses_a_reclaim_signed_by_the_refund_address_outside_the_window() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  and {
    reclaimed(tx),
    !reclaimed(
      Transaction { ..tx, validity_range: processing_range(registration) },
    ),
  }
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

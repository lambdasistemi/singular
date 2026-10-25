//// The fold of a pending registration, against the model's
//// `registrationSpend` for the action `registrationFold` and the
//// definitions it names: `requestInput`, `approvalBurned`, the processing
//// phase and `registrationDelivery` (statements `registrationFold_inversion`
//// and `folder_protection`, bound at the revision of the epic branch that
//// landed the open-datum model).
////
//// The guards are tested one function each, so a refused row names the guard
//// that refused it; the validator rows run the whole spend handler. Every
//// refusal row has a passing control that differs from it in the one fact
//// under test, and the range rows quantify over the table of ranges of the
//// fixtures, not over a list typed here.

use aiken/collection/list
use application/held.{Configuration, Live, RegistrationData, TokenId}
use application/phases.{Processing}
use application/spend.{
  ExpiredCleanup, OwnerReclaim, RegistrationFold, SpendAction, approval_burned,
  registration_delivery, request_input,
}
use cardano/address.{
  Address, Inline, Script, from_script, from_verification_key,
}
use cardano/assets.{add, from_asset, from_lovelace, merge}
use cardano/transaction.{
  DatumHash, InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use open_datum_requests
use open_datum_requests_fixtures.{
  active_asset_of, application_policy, control_of, controller, key_a, key_b,
  live_datum, other_policy, other_script, parameters, payload, registration_a,
  registration_of, registry_a, registry_of, seed_b, spent, state_policy,
}
use open_datum_requests_pending_fixtures.{
  Spending, active_mint_of, active_of, approval_of, burn_of, case_range, cases,
  change, cleanup_transaction, fold_action, fold_transaction, funding_reference,
  holding_of, payment_to, pending_input, pending_reference, pending_reference_n,
  pending_with_datum, pending_with_value, processing_range, reclaim_transaction,
  registrations, registrations_over_time, stranger, surplus, transaction_of,
  with_pending_output,
}

fn folded(tx: Transaction) -> Bool {
  run(fold_action(), tx)
}

// ---------------------------------------------------------------------------
// only-a-fold-spends-before-the-deadline: the input (model `requestInput`)
// ---------------------------------------------------------------------------

test the_request_input_is_found_by_its_reference() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  request_input(tx.inputs, pending_reference()) == Some(
    pending_input(registration, pending_reference()).output,
  )
}

test the_request_input_is_found_among_other_inputs() {
  let first = registration_of(registry_a(), key_a)
  let second = registration_of(registry_a(), key_b)
  let inputs =
    [
      spent(funding_reference()),
      pending_input(first, pending_reference_n(0)),
      pending_input(second, pending_reference_n(1)),
    ]
  and {
    request_input(inputs, pending_reference_n(1)) == Some(
      pending_input(second, pending_reference_n(1)).output,
    ),
    request_input(inputs, pending_reference_n(0)) == Some(
      pending_input(first, pending_reference_n(0)).output,
    ),
  }
}

test the_request_input_is_not_found_when_no_input_spends_the_reference() {
  let tx = fold_transaction(registration_a())
  and {
    request_input(tx.inputs, pending_reference_n(1)) == None,
    request_input([], pending_reference()) == None,
  }
}

test the_request_input_is_not_found_when_the_reference_is_spent_twice() {
  let registration = registration_a()
  let input = pending_input(registration, pending_reference())
  let tx = fold_transaction(registration)
  request_input([input, ..tx.inputs], pending_reference()) == None
}

// ---------------------------------------------------------------------------
// only-a-fold-spends-before-the-deadline: the burn (model `approvalBurned`)
// ---------------------------------------------------------------------------

test the_approval_is_burned_when_the_transaction_burns_the_one_it_consumes() {
  list.all(
    registrations(),
    fn(registration) {
      approval_burned(fold_transaction(registration), approval_of(registration))
    },
  )
}

test the_approval_is_not_burned_when_nothing_is_burned() {
  let registration = registration_a()
  let tx =
    Transaction {
      ..fold_transaction(registration),
      mint: active_mint_of([registration]),
    }
  !approval_burned(tx, approval_of(registration))
}

test the_approval_is_not_burned_when_it_is_minted() {
  let registration = registration_a()
  let approval = approval_of(registration)
  let tx =
    Transaction {
      ..fold_transaction(registration),
      mint: from_asset(approval.policy, approval.name, 1),
    }
  !approval_burned(tx, approval)
}

test the_approval_is_not_burned_when_another_approval_is_burned() {
  let registration = registration_a()
  let other = registration_of(registry_a(), key_b)
  let tx =
    Transaction { ..fold_transaction(registration), mint: burn_of([other]) }
  !approval_burned(tx, approval_of(registration))
}

test the_approval_is_not_burned_when_a_token_of_another_policy_with_its_name_is_burned() {
  let registration = registration_a()
  let approval = approval_of(registration)
  let tx =
    Transaction {
      ..fold_transaction(registration),
      mint: from_asset(other_policy, approval.name, -1),
    }
  !approval_burned(tx, approval)
}

test the_approvals_of_two_equal_registrations_are_burned_one_each() {
  let registration = registration_a()
  let approval = approval_of(registration)
  let input_a = pending_input(registration, pending_reference_n(0))
  let input_b = pending_input(registration, pending_reference_n(1))
  let base = fold_transaction(registration)
  let two = Transaction { ..base, inputs: [input_a, input_b] }
  let burning =
    fn(quantity) {
      Transaction {
        ..two,
        mint: from_asset(approval.policy, approval.name, -quantity),
      }
    }
  and {
    !approval_burned(burning(0), approval),
    !approval_burned(burning(1), approval),
    approval_burned(burning(2), approval),
    approval_burned(burning(3), approval),
  }
}

test an_approval_held_by_another_input_is_consumed_too() {
  let registration = registration_a()
  let approval = approval_of(registration)
  let holder =
    Input {
      output_reference: funding_reference(),
      output: Output {
        address: stranger(),
        value: from_lovelace(2_000_000)
          |> add(approval.policy, approval.name, 1),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let base = fold_transaction(registration)
  let tx = Transaction { ..base, inputs: [holder, ..base.inputs] }
  let burning =
    fn(quantity) {
      Transaction {
        ..tx,
        mint: from_asset(approval.policy, approval.name, -quantity),
      }
    }
  and {
    !approval_burned(burning(1), approval),
    approval_burned(burning(2), approval),
  }
}

// ---------------------------------------------------------------------------
// only-a-fold-spends-before-the-deadline: the delivery (model
// `registrationDelivery`)
// ---------------------------------------------------------------------------

fn delivered(
  registration: RegistrationData,
  outputs: List<Output>,
  index: Int,
) -> Bool {
  registration_delivery(
    registration,
    outputs,
    active_mint_of([registration]),
    index,
  )
}

test the_delivery_accepts_the_holding_of_every_registration() {
  list.all(
    registrations(),
    fn(registration) { delivered(registration, [holding_of(registration)], 0) },
  )
}

test the_delivery_finds_the_holding_at_its_index() {
  let registration = registration_a()
  let outputs = [change(1), change(2), holding_of(registration), change(3)]
  and {
    delivered(registration, outputs, 2),
    !delivered(registration, outputs, 0),
    !delivered(registration, outputs, 1),
    !delivered(registration, outputs, 3),
  }
}

test the_delivery_refuses_an_index_outside_the_outputs() {
  let registration = registration_a()
  let outputs = [holding_of(registration)]
  and {
    !delivered(registration, outputs, 1),
    !delivered(registration, outputs, 7),
    !delivered(registration, outputs, -1),
    !delivered(registration, [], 0),
  }
}

test the_delivery_refuses_a_holding_at_another_script() {
  let registration = registration_a()
  let holding = holding_of(registration)
  !delivered(
    registration,
    [Output { ..holding, address: from_script(other_script) }],
    0,
  )
}

test the_delivery_refuses_a_holding_at_a_wallet() {
  let registration = registration_a()
  let holding = holding_of(registration)
  !delivered(registration, [Output { ..holding, address: stranger() }], 0)
}

test the_delivery_refuses_a_holding_whose_stake_part_differs() {
  let committed =
    Address {
      payment_credential: Script(application_policy),
      stake_credential: Some(Inline(Script(other_script))),
    }
  let registration =
    RegistrationData { ..registration_a(), holding_address: committed }
  let holding = holding_of(registration)
  and {
    delivered(registration, [holding], 0),
    !delivered(
      registration,
      [
        Output {
          ..holding,
          address: Address {
            payment_credential: Script(application_policy),
            stake_credential: None,
          },
        },
      ],
      0,
    ),
    !delivered(
      registration,
      [
        Output {
          ..holding,
          address: Address {
            payment_credential: Script(application_policy),
            stake_credential: Some(Inline(Script(other_policy))),
          },
        },
      ],
      0,
    ),
  }
}

test the_delivery_refuses_a_holding_that_carries_another_datum() {
  let registration = registration_a()
  let holding = holding_of(registration)
  let other_payload: Data = #"626f62"
  let other =
    RegistrationData {
      ..registration,
      initial_datum: live_datum(
        control_of(
          registration.registry,
          registration.key,
          registration.controller,
          registration.deposit,
        ),
        other_payload,
      ),
    }
  and {
    delivered(registration, [holding], 0),
    !delivered(
      registration,
      [Output { ..holding, datum: holding_of(other).datum }],
      0,
    ),
    !delivered(registration, [Output { ..holding, datum: NoDatum }], 0),
    !delivered(
      registration,
      [
        Output {
          ..holding,
          datum: DatumHash(
            #"0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a",
          ),
        },
      ],
      0,
    ),
  }
}

test the_delivery_refuses_a_holding_whose_lovelace_is_not_the_deposit() {
  let registration = registration_a()
  let active = active_of(registration)
  let holding_with =
    fn(lovelace) {
      Output {
        ..holding_of(registration),
        value: from_lovelace(lovelace) |> add(active.policy, active.name, 1),
      }
    }
  and {
    delivered(registration, [holding_with(registration.deposit)], 0),
    !delivered(registration, [holding_with(registration.deposit - 1)], 0),
    !delivered(registration, [holding_with(registration.deposit + 1)], 0),
    !delivered(registration, [holding_with(0)], 0),
  }
}

test the_delivery_refuses_a_holding_without_the_active_token() {
  let registration = registration_a()
  let holding = holding_of(registration)
  !delivered(
    registration,
    [Output { ..holding, value: from_lovelace(registration.deposit) }],
    0,
  )
}

test the_delivery_refuses_a_holding_with_two_active_tokens() {
  let registration = registration_a()
  let active = active_of(registration)
  let holding = holding_of(registration)
  !delivered(
    registration,
    [
      Output {
        ..holding,
        value: from_lovelace(registration.deposit)
          |> add(active.policy, active.name, 2),
      },
    ],
    0,
  )
}

test the_delivery_refuses_the_active_token_of_another_key() {
  let registration = registration_a()
  let other = active_asset_of(registration.registry, key_b)
  let holding = holding_of(registration)
  !delivered(
    registration,
    [
      Output {
        ..holding,
        value: from_lovelace(registration.deposit)
          |> add(other.policy, other.name, 1),
      },
    ],
    0,
  )
}

test the_delivery_refuses_the_active_token_of_another_registry() {
  let registration = registration_a()
  let other = active_asset_of(registry_of(seed_b), registration.key)
  let holding = holding_of(registration)
  !delivered(
    registration,
    [
      Output {
        ..holding,
        value: from_lovelace(registration.deposit)
          |> add(other.policy, other.name, 1),
      },
    ],
    0,
  )
}

test the_delivery_refuses_the_name_of_the_active_token_under_another_policy() {
  let registration = registration_a()
  let active = active_of(registration)
  let holding = holding_of(registration)
  let value = from_lovelace(registration.deposit)
  and {
    !delivered(
      registration,
      [
        Output {
          ..holding,
          value: value |> add(application_policy, active.name, 1),
        },
      ],
      0,
    ),
    !delivered(
      registration,
      [Output { ..holding, value: value |> add(other_policy, active.name, 1) }],
      0,
    ),
    state_policy == active.policy,
  }
}

test the_delivery_requires_exactly_one_active_token_minted() {
  let registration = registration_a()
  let active = active_of(registration)
  let outputs = [holding_of(registration)]
  let minting =
    fn(quantity) {
      registration_delivery(
        registration,
        outputs,
        from_asset(active.policy, active.name, quantity),
        0,
      )
    }
  and {
    minting(1),
    !minting(0),
    !minting(2),
    !minting(-1),
    !registration_delivery(registration, outputs, assets.zero, 0),
  }
}

test the_delivery_refuses_an_active_token_that_is_not_minted_here() {
  let registration = registration_a()
  let other = registration_of(registry_a(), key_b)
  !registration_delivery(
    registration,
    [holding_of(registration)],
    active_mint_of([other]),
    0,
  )
}

test the_delivery_refuses_the_active_token_minted_under_another_policy() {
  let registration = registration_a()
  let active = active_of(registration)
  !registration_delivery(
    registration,
    [holding_of(registration)],
    from_asset(other_policy, active.name, 1),
    0,
  )
}

// ---------------------------------------------------------------------------
// only-a-fold-spends-before-the-deadline: the validator accepts a fold
// ---------------------------------------------------------------------------

test the_validator_accepts_the_fold_of_every_registration() {
  list.all(
    registrations(),
    fn(registration) { folded(fold_transaction(registration)) },
  )
}

test the_validator_accepts_the_fold_of_a_registration_booked_at_any_time() {
  list.all(
    registrations_over_time(),
    fn(registration) { folded(fold_transaction(registration)) },
  )
}

test the_validator_accepts_a_fold_whatever_the_folder_does_with_the_rest() {
  let registration = registration_a()
  let base = fold_transaction(registration)
  and {
    folded(Transaction { ..base, outputs: [holding_of(registration)] }),
    folded(
      Transaction {
        ..base,
        outputs: [
          holding_of(registration),
          payment_to(stranger(), surplus(registration)),
        ],
      },
    ),
    folded(
      Transaction {
        ..base,
        outputs: [holding_of(registration), change(1), change(2), change(3)],
      },
    ),
  }
}

test the_validator_accepts_a_fold_whose_holding_is_at_any_index() {
  let registration = registration_a()
  let base = fold_transaction(registration)
  let at_index =
    fn(index, outputs) {
      let tx = Transaction { ..base, outputs }
      run(RegistrationFold { holding_index: index }, tx)
    }
  and {
    at_index(0, [holding_of(registration), change(surplus(registration))]),
    at_index(1, [change(surplus(registration)), holding_of(registration)]),
    at_index(2, [change(1), change(2), holding_of(registration), change(3)]),
  }
}

test the_validator_accepts_a_fold_whose_holding_address_has_a_stake_part() {
  let committed =
    Address {
      payment_credential: Script(application_policy),
      stake_credential: Some(Inline(Script(other_script))),
    }
  let registration =
    RegistrationData { ..registration_a(), holding_address: committed }
  folded(fold_transaction(registration))
}

test the_validator_accepts_the_fold_of_two_registrations_in_one_transaction() {
  let first = registration_of(registry_a(), key_a)
  let second = registration_of(registry_a(), key_b)
  let spendings =
    [
      Spending(
        pending_reference_n(0),
        first,
        RegistrationFold { holding_index: 0 },
      ),
      Spending(
        pending_reference_n(1),
        second,
        RegistrationFold { holding_index: 1 },
      ),
    ]
  let tx =
    transaction_of(
      spendings,
      [holding_of(first), holding_of(second), change(1)],
      merge(burn_of([first, second]), active_mint_of([first, second])),
      processing_range(first),
      [],
    )
  run_all(spendings, tx)
}

test the_validator_refuses_the_fold_of_two_registrations_when_one_has_no_holding() {
  let first = registration_of(registry_a(), key_a)
  let second = registration_of(registry_a(), key_b)
  let spendings =
    [
      Spending(
        pending_reference_n(0),
        first,
        RegistrationFold { holding_index: 0 },
      ),
      Spending(
        pending_reference_n(1),
        second,
        RegistrationFold { holding_index: 1 },
      ),
    ]
  let tx =
    transaction_of(
      spendings,
      [holding_of(first), change(1)],
      merge(burn_of([first, second]), active_mint_of([first, second])),
      processing_range(first),
      [],
    )
  and {
    run_at(RegistrationFold { holding_index: 0 }, pending_reference_n(0), tx),
    !run_at(RegistrationFold { holding_index: 1 }, pending_reference_n(1), tx),
  }
}

// ---------------------------------------------------------------------------
// only-a-fold-spends-before-the-deadline: the validator refuses what is not a
// fold of this registration
// ---------------------------------------------------------------------------

test the_validator_refuses_a_spend_of_an_input_that_is_not_in_the_transaction() {
  let tx = fold_transaction(registration_a())
  !run_at(fold_action(), pending_reference_n(1), tx)
}

test the_validator_refuses_a_spend_of_an_input_at_a_wallet() {
  let tx = fold_transaction(registration_a())
  !run_at(fold_action(), funding_reference(), tx)
}

test the_validator_refuses_a_spend_of_an_input_listed_twice() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  !folded(
    Transaction {
      ..tx,
      inputs: [pending_input(registration, pending_reference()), ..tx.inputs],
    },
  )
}

test the_validator_refuses_a_pending_output_that_carries_no_registration() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  let live =
    Live {
      control: control_of(
        registration.registry,
        registration.key,
        registration.controller,
        registration.deposit,
      ),
      payload,
    }
  let configuration = Configuration { parameters }
  and {
    folded(tx),
    !folded(
      with_pending_output(
        tx,
        pending_with_datum(registration, InlineDatum(live)),
      ),
    ),
    !folded(
      with_pending_output(
        tx,
        pending_with_datum(registration, InlineDatum(configuration)),
      ),
    ),
    !folded(with_pending_output(tx, pending_with_datum(registration, NoDatum))),
    !folded(
      with_pending_output(
        tx,
        pending_with_datum(
          registration,
          DatumHash(
            #"0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a",
          ),
        ),
      ),
    ),
  }
}

test the_validator_refuses_a_pending_output_without_its_approval() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  and {
    folded(tx),
    !folded(
      with_pending_output(
        tx,
        pending_with_value(registration, from_lovelace(4_000_000)),
      ),
    ),
  }
}

test the_validator_refuses_a_pending_output_with_the_approval_of_another_registration() {
  let registration = registration_a()
  let other = approval_of(registration_of(registry_a(), key_b))
  let tx = fold_transaction(registration)
  !folded(
    with_pending_output(
      tx,
      pending_with_value(
        registration,
        from_lovelace(4_000_000) |> add(other.policy, other.name, 1),
      ),
    ),
  )
}

test the_validator_refuses_a_pending_output_with_two_approvals() {
  let registration = registration_a()
  let approval = approval_of(registration)
  let tx = fold_transaction(registration)
  !folded(
    with_pending_output(
      tx,
      pending_with_value(
        registration,
        from_lovelace(4_000_000) |> add(approval.policy, approval.name, 2),
      ),
    ),
  )
}

test the_validator_refuses_a_pending_output_with_another_token_beside_the_approval() {
  let registration = registration_a()
  let approval = approval_of(registration)
  let tx = fold_transaction(registration)
  !folded(
    with_pending_output(
      tx,
      pending_with_value(
        registration,
        from_lovelace(4_000_000)
          |> add(approval.policy, approval.name, 1)
          |> add(other_policy, #"01", 1),
      ),
    ),
  )
}

test the_validator_refuses_a_pending_output_that_holds_less_than_the_deposit() {
  let registration = registration_a()
  let approval = approval_of(registration)
  let tx = fold_transaction(registration)
  let holding =
    fn(lovelace) {
      pending_with_value(
        registration,
        from_lovelace(lovelace) |> add(approval.policy, approval.name, 1),
      )
    }
  and {
    folded(with_pending_output(tx, holding(registration.deposit))),
    !folded(with_pending_output(tx, holding(registration.deposit - 1))),
  }
}

test the_validator_refuses_a_fold_that_does_not_burn_the_approval() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  and {
    folded(tx),
    !folded(Transaction { ..tx, mint: active_mint_of([registration]) }),
    !folded(
      Transaction {
        ..tx,
        mint: merge(
          burn_of([registration_of(registry_a(), key_b)]),
          active_mint_of([registration]),
        ),
      },
    ),
    !folded(
      Transaction {
        ..tx,
        mint: merge(
          from_asset(
            approval_of(registration).policy,
            approval_of(registration).name,
            1,
          ),
          active_mint_of([registration]),
        ),
      },
    ),
  }
}

test the_validator_refuses_a_fold_that_burns_one_approval_for_two_equal_requests() {
  let registration = registration_a()
  let spendings =
    [
      Spending(
        pending_reference_n(0),
        registration,
        RegistrationFold { holding_index: 0 },
      ),
      Spending(
        pending_reference_n(1),
        registration,
        RegistrationFold { holding_index: 0 },
      ),
    ]
  let one_burn =
    transaction_of(
      spendings,
      [holding_of(registration), change(1)],
      merge(burn_of([registration]), active_mint_of([registration])),
      processing_range(registration),
      [],
    )
  !run_at(
    RegistrationFold { holding_index: 0 },
    pending_reference_n(0),
    one_burn,
  )
}

test the_validator_refuses_a_fold_that_delivers_nothing() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  and {
    folded(tx),
    !folded(Transaction { ..tx, outputs: [change(surplus(registration))] }),
    !folded(Transaction { ..tx, outputs: [] }),
  }
}

test the_validator_refuses_a_fold_that_delivers_to_another_address() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  let holding = holding_of(registration)
  and {
    folded(tx),
    !folded(
      Transaction {
        ..tx,
        outputs: [
          Output { ..holding, address: from_script(other_script) },
          change(1),
        ],
      },
    ),
    !folded(
      Transaction {
        ..tx,
        outputs: [Output { ..holding, address: stranger() }, change(1)],
      },
    ),
    !folded(
      Transaction {
        ..tx,
        outputs: [
          Output {
            ..holding,
            address: from_verification_key(
              #"0303030303030303030303030303030303030303030303030303030303",
            ),
          },
          change(1),
        ],
      },
    ),
  }
}

test the_validator_refuses_a_fold_that_delivers_less_or_more_than_the_deposit() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  let active = active_of(registration)
  let holding_with =
    fn(lovelace) {
      Output {
        ..holding_of(registration),
        value: from_lovelace(lovelace) |> add(active.policy, active.name, 1),
      }
    }
  and {
    folded(tx),
    !folded(
      Transaction {
        ..tx,
        outputs: [holding_with(registration.deposit - 1), change(1)],
      },
    ),
    !folded(
      Transaction {
        ..tx,
        outputs: [holding_with(registration.deposit + 1), change(1)],
      },
    ),
  }
}

test the_validator_refuses_a_fold_that_delivers_another_datum() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  let holding = holding_of(registration)
  and {
    folded(tx),
    !folded(
      Transaction {
        ..tx,
        outputs: [Output { ..holding, datum: NoDatum }, change(1)],
      },
    ),
    !folded(
      Transaction {
        ..tx,
        outputs: [
          Output {
            ..holding,
            datum: holding_of(registration_of(registry_a(), key_b)).datum,
          },
          change(1),
        ],
      },
    ),
  }
}

test the_validator_refuses_a_fold_whose_token_is_not_the_genuine_one() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  let holding = holding_of(registration)
  let other_key = active_asset_of(registration.registry, key_b)
  let other_registry = active_asset_of(registry_of(seed_b), registration.key)
  let delivering =
    fn(token: TokenId) {
      Transaction {
        ..tx,
        outputs: [
          Output {
            ..holding,
            value: from_lovelace(registration.deposit)
              |> add(token.policy, token.name, 1),
          },
          change(1),
        ],
        mint: merge(
          burn_of([registration]),
          from_asset(token.policy, token.name, 1),
        ),
      }
    }
  and {
    folded(delivering(active_of(registration))),
    !folded(delivering(other_key)),
    !folded(delivering(other_registry)),
    !folded(
      delivering(
        TokenId {
          policy: application_policy,
          name: active_of(registration).name,
        },
      ),
    ),
    !folded(
      delivering(
        TokenId { policy: other_policy, name: active_of(registration).name },
      ),
    ),
  }
}

test the_validator_refuses_a_fold_whose_token_is_not_minted_in_the_transaction() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  and {
    folded(tx),
    !folded(Transaction { ..tx, mint: burn_of([registration]) }),
    !folded(
      Transaction {
        ..tx,
        mint: merge(
          burn_of([registration]),
          from_asset(
            active_of(registration).policy,
            active_of(registration).name,
            2,
          ),
        ),
      },
    ),
  }
}

test the_validator_refuses_a_fold_that_names_a_holding_outside_the_outputs() {
  let registration = registration_a()
  let tx = fold_transaction(registration)
  and {
    folded(tx),
    !run(RegistrationFold { holding_index: 2 }, tx),
    !run(RegistrationFold { holding_index: 9 }, tx),
    !run(RegistrationFold { holding_index: -1 }, tx),
    !run(RegistrationFold { holding_index: 1 }, tx),
  }
}

// ---------------------------------------------------------------------------
// only-a-fold-spends-before-the-deadline: the phase
// ---------------------------------------------------------------------------

test the_validator_accepts_a_fold_in_every_processing_range_and_in_no_other() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases(),
        fn(case) {
          let tx =
            Transaction {
              ..fold_transaction(registration),
              validity_range: case_range(registration, case),
            }
          folded(tx) == ( case.expected == Processing )
        },
      )
    },
  )
}

test the_validator_refuses_a_reclaim_in_every_processing_range() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        list.filter(cases(), fn(case) { case.expected == Processing }),
        fn(case) {
          let tx =
            Transaction {
              ..reclaim_transaction(registration),
              validity_range: case_range(registration, case),
            }
          !run(OwnerReclaim, tx)
        },
      )
    },
  )
}

test the_validator_refuses_a_cleanup_in_every_processing_range() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        list.filter(cases(), fn(case) { case.expected == Processing }),
        fn(case) {
          let tx =
            Transaction {
              ..cleanup_transaction(registration),
              validity_range: case_range(registration, case),
            }
          !run(ExpiredCleanup, tx)
        },
      )
    },
  )
}

test the_validator_refuses_a_reclaim_signed_by_everyone_before_the_deadline() {
  let registration = registration_a()
  let tx = reclaim_transaction(registration)
  !run(
    OwnerReclaim,
    Transaction {
      ..tx,
      validity_range: processing_range(registration),
      extra_signatories: [registration.controller, controller],
    },
  )
}

test the_validator_refuses_a_cleanup_that_pays_everything_to_the_refund_address_before_the_deadline() {
  let registration = registration_a()
  let tx = cleanup_transaction(registration)
  !run(
    ExpiredCleanup,
    Transaction {
      ..tx,
      validity_range: processing_range(registration),
      outputs: [payment_to(registration.refund_address, 4_000_000)],
    },
  )
}

// ---------------------------------------------------------------------------
// The validator
// ---------------------------------------------------------------------------

/// The spend handler of the validator, for the input at `reference`.
fn run_at(
  action: SpendAction,
  reference: OutputReference,
  tx: Transaction,
) -> Bool {
  open_datum_requests.open_datum_requests.spend(None, action, reference, tx)
}

/// The spend handler for the single pending registration of the one-spend
/// transactions.
fn run(action: SpendAction, tx: Transaction) -> Bool {
  run_at(action, pending_reference(), tx)
}

/// Whether the handler accepts every spending of the transaction: the ledger
/// runs it once for each.
fn run_all(spendings: List<Spending>, tx: Transaction) -> Bool {
  list.all(
    spendings,
    fn(spending) { run_at(spending.action, spending.reference, tx) },
  )
}

//// The mint of the application policy, against the model's `approvalBurn`,
//// `birth` and the mint conjuncts of `applicationStep` (statements
//// `approvalBurn_inversion`, `approval_burn_open` and `burning_grants_nothing`,
//// bound at the revision of the epic branch that landed the open-datum model).
////
//// The guards are tested one function each, so a refused row names the guard
//// that refused it; the validator rows at the end run the whole handlers.
//// Every refusal row has a passing control that differs from it in the one
//// fact under test.

use aiken/collection/list
use application/births.{positive_mints_are_births}
use application/configuration.{configuration_asset}
use application/held.{Registration, TokenId}
use application/mint.{
  ApplicationAction, ApprovalBurn, BookRegistration, ConfigurationCreate,
  action_accepted, birth, birth_positions_are_distinct, births_of, donation_is,
}
use application/registration.{registration_asset}
use application/spend.{
  ExpiredCleanup, OwnerReclaim, RegistrationFold, SpendAction,
}
use cardano/address.{Script}
use cardano/assets.{add, from_asset, from_lovelace, zero}
use cardano/script_context.{ScriptContext, Withdrawing}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use open_datum_requests
use open_datum_requests_fixtures.{
  application_policy, booking_actions, booking_transaction, burn_actions,
  burn_transaction, configuration_output, configuration_reference,
  creation_actions, creation_transaction, key_b, other_policy, other_script,
  pending_output, registration_a, registration_of, registries, registry_a,
  registry_of, seed_a, seed_b, seed_c, spent,
}

fn approval_a() -> TokenId {
  registration_asset(application_policy, registration_a())
}

fn approval_b() -> TokenId {
  registration_asset(application_policy, registration_of(registry_a(), key_b))
}

fn configuration_a() -> TokenId {
  configuration_asset(application_policy, registry_a())
}

fn minted(asset: TokenId, quantity: Int) -> assets.Value {
  from_asset(asset.policy, asset.name, quantity)
}

// ---------------------------------------------------------------------------
// approvals-burn-openly: the assets the actions bring into being
// ---------------------------------------------------------------------------

fn create_at(seed: OutputReference, index: Int) -> ApplicationAction {
  ConfigurationCreate {
    state_policy: registry_of(seed).policy,
    state_name: registry_of(seed).name,
    seed,
    output_index: index,
  }
}

fn outputs_of_booking() -> List<Output> {
  booking_transaction(registration_a()).outputs
}

test a_configuration_creation_brings_its_token_into_being() {
  birth(application_policy, [], create_at(seed_a, 1)) == Some(
    configuration_asset(application_policy, registry_of(seed_a)),
  )
}

test a_booking_brings_the_approval_of_its_output_into_being() {
  birth(
    application_policy,
    outputs_of_booking(),
    BookRegistration { output_index: 0 },
  ) == Some(approval_a())
}

test a_booking_of_an_output_that_is_not_a_registration_brings_nothing_into_being() {
  and {
    birth(
      application_policy,
      outputs_of_booking(),
      BookRegistration { output_index: 1 },
    ) == None,
    birth(
      application_policy,
      [spent(seed_c).output],
      BookRegistration { output_index: 0 },
    ) == None,
    birth(
      application_policy,
      [configuration_output(registry_a(), booking_parameters())],
      BookRegistration { output_index: 0 },
    ) == None,
  }
}

fn booking_parameters() -> held.ApplicationParameters {
  open_datum_requests_fixtures.parameters
}

test a_burn_brings_nothing_into_being() {
  birth(application_policy, outputs_of_booking(), ApprovalBurn) == None
}

test the_births_follow_the_actions_in_order() {
  let outputs = outputs_of_booking()
  births_of(
    application_policy,
    outputs,
    [create_at(seed_a, 1), ApprovalBurn, BookRegistration { output_index: 0 }],
  ) == [
    configuration_asset(application_policy, registry_of(seed_a)),
    approval_a(),
  ]
}

// ---------------------------------------------------------------------------
// approvals-burn-openly: model conjunct birthCoverage
// ---------------------------------------------------------------------------

test the_positions_are_distinct_when_each_action_creates_its_own_output() {
  birth_positions_are_distinct(
    [create_at(seed_a, 1), BookRegistration { output_index: 0 }],
  )
}

test the_positions_are_distinct_when_there_is_no_action_or_only_burns() {
  and {
    birth_positions_are_distinct([]),
    birth_positions_are_distinct([ApprovalBurn, ApprovalBurn]),
  }
}

test the_positions_are_not_distinct_when_two_bookings_name_one_output() {
  !birth_positions_are_distinct(
    [BookRegistration { output_index: 0 }, BookRegistration { output_index: 0 }],
  )
}

test the_positions_are_not_distinct_when_a_creation_and_a_booking_name_one_output() {
  !birth_positions_are_distinct(
    [create_at(seed_a, 1), BookRegistration { output_index: 1 }],
  )
}

test the_positions_are_not_distinct_when_two_creations_name_one_output() {
  !birth_positions_are_distinct([create_at(seed_a, 1), create_at(seed_b, 1)])
}

test the_positions_are_not_distinct_with_burns_between_the_same_two() {
  !birth_positions_are_distinct(
    [
      BookRegistration { output_index: 2 },
      ApprovalBurn,
      BookRegistration { output_index: 2 },
    ],
  )
}

// ---------------------------------------------------------------------------
// approvals-burn-openly: the mint conjunct of applicationStep
// ---------------------------------------------------------------------------

test a_burn_of_any_quantity_of_any_asset_under_the_policy_is_open() {
  list.all(
    [1, 2, 1_000_000],
    fn(quantity) {
      and {
        positive_mints_are_births(
          application_policy,
          minted(approval_a(), -quantity),
          [],
        ),
        positive_mints_are_births(
          application_policy,
          minted(configuration_a(), -quantity),
          [],
        ),
        positive_mints_are_births(
          application_policy,
          minted(
            TokenId { policy: application_policy, name: #"6e6f7468696e67" },
            -quantity,
          ),
          [],
        ),
      }
    },
  )
}

test a_transaction_that_mints_nothing_under_the_policy_is_open() {
  and {
    positive_mints_are_births(application_policy, zero, []),
    positive_mints_are_births(
      application_policy,
      minted(TokenId { policy: other_policy, name: #"01" }, 5),
      [],
    ),
  }
}

test a_mint_that_is_a_birth_is_open() {
  positive_mints_are_births(
    application_policy,
    minted(approval_a(), 1),
    [approval_a()],
  )
}

test a_mint_beside_a_burn_is_open_when_the_mint_is_a_birth() {
  positive_mints_are_births(
    application_policy,
    minted(approval_a(), 1) |> merge_mint(minted(approval_b(), -3)),
    [approval_a()],
  )
}

fn merge_mint(a: assets.Value, b: assets.Value) -> assets.Value {
  assets.merge(a, b)
}

test a_positive_mint_that_is_no_birth_is_refused() {
  list.all(
    [approval_a(), approval_b(), configuration_a()],
    fn(asset) {
      !positive_mints_are_births(application_policy, minted(asset, 1), [])
    },
  )
}

test a_positive_mint_of_another_birth_is_refused() {
  !positive_mints_are_births(
    application_policy,
    minted(approval_a(), 1),
    [approval_b()],
  )
}

test an_extra_positive_mint_beside_a_birth_is_refused() {
  !positive_mints_are_births(
    application_policy,
    minted(approval_a(), 1) |> merge_mint(minted(approval_b(), 1)),
    [approval_a()],
  )
}

test a_positive_mint_of_a_name_no_rule_knows_is_refused() {
  !positive_mints_are_births(
    application_policy,
    minted(TokenId { policy: application_policy, name: #"" }, 1),
    [approval_a()],
  )
}

// ---------------------------------------------------------------------------
// approvals-burn-openly: the donation
// ---------------------------------------------------------------------------

test a_transaction_with_no_donation_donates_none() {
  donation_is(
    Transaction { ..transaction.placeholder, treasury_donation: None },
    0,
  )
}

test a_transaction_donates_what_it_says() {
  and {
    donation_is(
      Transaction {
        ..transaction.placeholder,
        treasury_donation: Some(5_000_000),
      },
      5_000_000,
    ),
    !donation_is(
      Transaction {
        ..transaction.placeholder,
        treasury_donation: Some(5_000_000),
      },
      0,
    ),
    !donation_is(
      Transaction { ..transaction.placeholder, treasury_donation: None },
      1,
    ),
  }
}

// ---------------------------------------------------------------------------
// approvals-burn-openly: the action
// ---------------------------------------------------------------------------

test the_burn_action_is_accepted_whatever_the_transaction_burns() {
  list.all(
    [
      burn_transaction(approval_a(), 1),
      burn_transaction(approval_a(), 3),
      burn_transaction(configuration_a(), 1),
      Transaction { ..transaction.placeholder, mint: zero },
    ],
    fn(tx) { action_accepted(application_policy, tx, [], ApprovalBurn) },
  )
}

// ---------------------------------------------------------------------------
// approvals-burn-openly: the validator
// ---------------------------------------------------------------------------

fn mint(actions: List<ApplicationAction>, tx: Transaction) -> Bool {
  open_datum_requests.open_datum_requests.mint(actions, application_policy, tx)
}

test the_validator_lets_anyone_burn_an_approval_with_no_signature() {
  let tx = burn_transaction(approval_a(), 1)
  and {
    tx.extra_signatories == [],
    mint(burn_actions(), tx),
  }
}

test the_validator_lets_anyone_burn_an_approval_with_no_action() {
  mint([], burn_transaction(approval_a(), 1))
}

test the_validator_lets_anyone_burn_many_approvals_at_once() {
  let tx =
    Transaction {
      ..transaction.placeholder,
      inputs: [spent(seed_a)],
      mint: minted(approval_a(), -2) |> merge_mint(minted(approval_b(), -7)),
    }
  mint(burn_actions(), tx)
}

test the_validator_lets_anyone_burn_the_approvals_of_every_registry() {
  list.all(
    registries(),
    fn(registry) {
      let asset =
        registration_asset(application_policy, registration_of(registry, key_b))
      mint(burn_actions(), burn_transaction(asset, 1))
    },
  )
}

test the_validator_accepts_a_booking_beside_a_burn() {
  let tx = booking_transaction(registration_a())
  let burn =
    Transaction { ..tx, mint: tx.mint |> merge_mint(minted(approval_b(), -1)) }
  mint(booking_actions(), burn)
}

test the_validator_accepts_a_creation_beside_a_burn() {
  let tx = creation_transaction(seed_a)
  let burn =
    Transaction { ..tx, mint: tx.mint |> merge_mint(minted(approval_b(), -1)) }
  mint(creation_actions(seed_a), burn)
}

test the_validator_refuses_to_mint_an_approval_with_no_action() {
  let tx = booking_transaction(registration_a())
  mint([], tx) == False
}

test the_validator_refuses_to_mint_an_approval_on_the_strength_of_a_burn_action() {
  let tx = booking_transaction(registration_a())
  mint(burn_actions(), tx) == False
}

test the_validator_refuses_to_mint_the_configuration_token_with_no_action() {
  let tx = creation_transaction(seed_a)
  mint([], tx) == False
}

test the_validator_refuses_to_mint_a_second_approval_beside_a_booking() {
  let tx = booking_transaction(registration_a())
  let extra =
    Transaction { ..tx, mint: tx.mint |> merge_mint(minted(approval_b(), 1)) }
  mint(booking_actions(), extra) == False
}

test the_validator_refuses_to_mint_the_configuration_token_beside_a_booking() {
  let tx = booking_transaction(registration_a())
  let extra =
    Transaction {
      ..tx,
      mint: tx.mint |> merge_mint(minted(configuration_a(), 1)),
    }
  mint(booking_actions(), extra) == False
}

test the_validator_refuses_to_mint_an_approval_beside_a_creation() {
  let tx = creation_transaction(seed_a)
  let extra =
    Transaction { ..tx, mint: tx.mint |> merge_mint(minted(approval_a(), 1)) }
  mint(creation_actions(seed_a), extra) == False
}

test the_validator_refuses_to_mint_an_approval_for_a_termination() {
  let termination_name = #"7465726d696e6174696f6e"
  let tx =
    Transaction {
      ..transaction.placeholder,
      inputs: [spent(seed_a)],
      mint: from_asset(application_policy, termination_name, 1),
    }
  mint(burn_actions(), tx) == False
}

test the_validator_refuses_two_bookings_of_one_output() {
  let registration = registration_a()
  let tx = booking_transaction(registration)
  let twice =
    Transaction {
      ..tx,
      mint: minted(registration_asset(application_policy, registration), 2),
    }
  and {
    mint(
      [
        BookRegistration { output_index: 0 },
        BookRegistration { output_index: 0 },
      ],
      twice,
    ) == False,
    mint(booking_actions(), twice) == False,
  }
}

test the_validator_accepts_two_bookings_of_two_outputs() {
  let first = registration_a()
  let second = registration_of(registry_a(), key_b)
  let tx = booking_transaction(first)
  let both =
    Transaction {
      ..tx,
      outputs: [pending_output(first), pending_output(second)],
      mint: minted(registration_asset(application_policy, first), 1)
        |> merge_mint(minted(registration_asset(application_policy, second), 1)),
    }
  mint(
    [BookRegistration { output_index: 0 }, BookRegistration { output_index: 1 }],
    both,
  )
}

test the_validator_refuses_a_burn_that_donates_to_the_treasury() {
  let tx = burn_transaction(approval_a(), 1)
  and {
    mint(burn_actions(), tx),
    mint(
      burn_actions(),
      Transaction { ..tx, treasury_donation: Some(1_000_000) },
    ) == False,
  }
}

test the_validator_refuses_a_booking_that_donates_to_the_treasury() {
  let tx = booking_transaction(registration_a())
  mint(
    booking_actions(),
    Transaction { ..tx, treasury_donation: Some(1_000_000) },
  ) == False
}

// ---------------------------------------------------------------------------
// approvals-burn-openly: a burn grants nothing
// ---------------------------------------------------------------------------

fn spend_with(datum: Data, action: SpendAction) -> Bool {
  let burning = burn_transaction(approval_a(), 1)
  open_datum_requests.open_datum_requests.spend(
    Some(datum),
    action,
    configuration_reference,
    Transaction {
      ..burning,
      inputs: [
        transaction.Input {
          output_reference: configuration_reference,
          output: pending_output(registration_a()),
        },
      ],
    },
  )
}

/// The refusal is a pin of the constant refusal of the spend handler until the
/// rules for the pending registration arrive; it is not a RED leg of its own.
test the_validator_does_not_let_a_burn_unlock_a_pending_registration() {
  let pending: Data = Registration { registration: registration_a() }
  list.all(
    [RegistrationFold { holding_index: 0 }, OwnerReclaim, ExpiredCleanup],
    fn(action) { spend_with(pending, action) == False },
  )
}

test the_validator_refuses_every_other_purpose() fail {
  let context =
    ScriptContext {
      transaction: transaction.placeholder,
      redeemer: 0,
      info: Withdrawing(Script(application_policy)),
    }
  open_datum_requests.open_datum_requests.else(context)
}

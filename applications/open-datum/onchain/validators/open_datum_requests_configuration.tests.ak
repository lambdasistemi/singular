//// The configuration record of a registry, against the model's
//// `configurationCreate`, `configurationShape` and `configurationRead`
//// (statements `configurationCreate_inversion` and `configuration_immutable`,
//// bound at the revision of the epic branch that landed the open-datum model).
////
//// The guards are tested one function each, so a refused row names the guard
//// that refused it; the validator rows at the end run the whole handlers.
//// Every refusal row has a passing control that differs from it in the one
//// fact under test.

use aiken/collection/list
use application/births.{fresh_asset}
use application/configuration.{
  configuration_asset, configuration_create, configuration_genesis,
  configuration_parameters, configuration_read, configuration_shape,
}
use application/held.{
  ApplicationParameters, Configuration, Live, Registration, TokenId,
}
use application/mint.{ApplicationAction, ApprovalBurn}
use application/registration.{registration_asset}
use cardano/address.{from_script, from_verification_key}
use cardano/assets.{add, from_asset, from_lovelace, zero}
use cardano/transaction.{
  DatumHash, InlineDatum, NoDatum, Output, OutputReference, Transaction,
}
use open_datum_requests
use open_datum_requests_fixtures.{
  application_policy, configuration_input, configuration_output,
  configuration_reference, control_of, controller, creation_actions,
  creation_transaction, holding_address, key_a, live_datum, other_policy,
  other_script, parameters, payload, registration_a, registries, registry_of,
  seed_a, seed_b, seed_c, seed_d, seeds, spent, state_policy, token_value,
}
use singular_state/preimage.{
  RegistryIdentity, configuration_token_name, state_token_name,
}

fn genuine(seed: OutputReference) -> Output {
  configuration_output(registry_of(seed), parameters)
}

fn asset_of(seed: OutputReference) -> TokenId {
  configuration_asset(application_policy, registry_of(seed))
}

fn shaped(seed: OutputReference, output: Output) -> Bool {
  configuration_shape(application_policy, registry_of(seed), output)
}

// ---------------------------------------------------------------------------
// configuration-created-once-with-the-registry: the name of the token
// ---------------------------------------------------------------------------

test the_token_of_a_registry_is_under_the_application_policy() {
  list.all(
    registries(),
    fn(registry) {
      configuration_asset(application_policy, registry).policy == application_policy
    },
  )
}

test the_tokens_of_two_registries_have_two_names() {
  list.all(
    registries(),
    fn(a) {
      list.all(
        registries(),
        fn(b) {
          a == b || configuration_token_name(a) != configuration_token_name(b)
        },
      )
    },
  )
}

test the_name_of_a_registry_under_another_policy_is_not_the_name_of_that_registry() {
  let registry = registry_of(seed_a)
  let other = RegistryIdentity { ..registry, policy: other_policy }
  configuration_token_name(registry) != configuration_token_name(other)
}

// ---------------------------------------------------------------------------
// configuration-created-once-with-the-registry: guard configurationShape
// ---------------------------------------------------------------------------

test the_shape_accepts_the_record_of_every_registry() {
  list.all(seeds, fn(seed) { shaped(seed, genuine(seed)) })
}

test the_shape_accepts_any_parameters() {
  let zero_parameters =
    ApplicationParameters {
      registration_cost: 0,
      minimum_tip: 0,
      process_time: 0,
      retract_time: 0,
      booking_width: 0,
    }
  let large_parameters =
    ApplicationParameters {
      registration_cost: 9_000_000_000_000,
      minimum_tip: 9_000_000_000_000,
      process_time: 9_000_000_000_000,
      retract_time: 9_000_000_000_000,
      booking_width: 9_000_000_000_000,
    }
  list.all(
    [zero_parameters, parameters, large_parameters],
    fn(record) {
      configuration_shape(
        application_policy,
        registry_of(seed_a),
        configuration_output(registry_of(seed_a), record),
      )
    },
  )
}

test the_shape_refuses_a_record_at_another_script() {
  let output = Output { ..genuine(seed_a), address: from_script(other_script) }
  !shaped(seed_a, output)
}

test the_shape_refuses_a_record_at_a_wallet() {
  let output =
    Output {
      ..genuine(seed_a),
      address: from_verification_key(
        #"0202020202020202020202020202020202020202020202020202020202",
      ),
    }
  !shaped(seed_a, output)
}

test the_shape_refuses_an_output_whose_datum_is_not_a_configuration_record() {
  let registration_datum =
    InlineDatum(Registration { registration: registration_a() })
  let live =
    InlineDatum(
      Live {
        control: control_of(registry_of(seed_a), key_a, controller, 2_000_000),
        payload,
      },
    )
  let not_a_record: Data = 42
  list.all(
    [
      registration_datum,
      live,
      NoDatum,
      DatumHash(
        #"0000000000000000000000000000000000000000000000000000000000000000",
      ),
      InlineDatum(not_a_record),
    ],
    fn(datum) { !shaped(seed_a, Output { ..genuine(seed_a), datum }) },
  )
}

test the_shape_refuses_an_output_without_the_token() {
  !shaped(seed_a, Output { ..genuine(seed_a), value: from_lovelace(2_000_000) })
}

test the_shape_refuses_the_token_of_another_registry() {
  list.all(
    seeds,
    fn(other) {
      other == seed_a || !shaped(
        seed_a,
        Output { ..genuine(seed_a), value: token_value(asset_of(other), 1) },
      )
    },
  )
}

test the_shape_refuses_the_token_of_the_name_under_another_policy() {
  let asset = asset_of(seed_a)
  !shaped(
    seed_a,
    Output {
      ..genuine(seed_a),
      value: token_value(TokenId { ..asset, policy: other_policy }, 1),
    },
  )
}

test the_shape_refuses_two_tokens() {
  !shaped(
    seed_a,
    Output { ..genuine(seed_a), value: token_value(asset_of(seed_a), 2) },
  )
}

test the_shape_refuses_another_token_beside_the_one() {
  let value = token_value(asset_of(seed_a), 1) |> add(other_policy, #"01", 1)
  !shaped(seed_a, Output { ..genuine(seed_a), value })
}

test the_shape_refuses_the_token_of_another_registry_beside_the_one() {
  let value =
    token_value(asset_of(seed_a), 1)
      |> add(application_policy, asset_of(seed_b).name, 1)
  !shaped(seed_a, Output { ..genuine(seed_a), value })
}

test the_shape_refuses_a_registration_approval_in_place_of_the_token() {
  let approval = registration_asset(application_policy, registration_a())
  !shaped(seed_a, Output { ..genuine(seed_a), value: token_value(approval, 1) })
}

// ---------------------------------------------------------------------------
// configuration-created-once-with-the-registry: guard configurationGenesis
// ---------------------------------------------------------------------------

test the_genesis_accepts_the_creation_of_every_registry() {
  list.all(
    seeds,
    fn(seed) {
      configuration_genesis(registry_of(seed), seed, creation_transaction(seed))
    },
  )
}

test the_genesis_refuses_a_registry_not_named_from_the_seed() {
  list.all(
    seeds,
    fn(other) {
      other == seed_a || !configuration_genesis(
        registry_of(other),
        seed_a,
        creation_transaction(seed_a),
      )
    },
  )
}

test the_genesis_refuses_a_registry_named_from_the_seed_under_another_policy() {
  let registry =
    RegistryIdentity { policy: other_policy, name: state_token_name(seed_a) }
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      mint: from_asset(other_policy, registry.name, 1),
    }
  !configuration_genesis(registry, seed_a, tx)
}

test the_genesis_refuses_a_seed_that_is_not_spent() {
  let tx = Transaction { ..creation_transaction(seed_a), inputs: [] }
  !configuration_genesis(registry_of(seed_a), seed_a, tx)
}

test the_genesis_refuses_a_seed_spent_by_no_input_but_named_by_others() {
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      inputs: [spent(seed_b), spent(seed_c), spent(seed_d)],
    }
  !configuration_genesis(registry_of(seed_a), seed_a, tx)
}

test the_genesis_refuses_a_seed_that_is_only_a_reference_input() {
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      inputs: [spent(seed_b)],
      reference_inputs: [spent(seed_a)],
    }
  !configuration_genesis(registry_of(seed_a), seed_a, tx)
}

test the_genesis_refuses_a_seed_spent_twice() {
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      inputs: [spent(seed_a), spent(seed_a)],
    }
  !configuration_genesis(registry_of(seed_a), seed_a, tx)
}

test the_genesis_refuses_a_transaction_that_mints_no_state_token() {
  let tx = Transaction { ..creation_transaction(seed_a), mint: zero }
  !configuration_genesis(registry_of(seed_a), seed_a, tx)
}

test the_genesis_refuses_a_state_token_minted_twice() {
  let registry = registry_of(seed_a)
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      mint: from_asset(registry.policy, registry.name, 2),
    }
  !configuration_genesis(registry, seed_a, tx)
}

test the_genesis_refuses_a_state_token_burned() {
  let registry = registry_of(seed_a)
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      mint: from_asset(registry.policy, registry.name, -1),
    }
  !configuration_genesis(registry, seed_a, tx)
}

test the_genesis_refuses_the_state_token_of_another_seed_in_its_place() {
  let other = registry_of(seed_b)
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      mint: from_asset(other.policy, other.name, 1),
    }
  !configuration_genesis(registry_of(seed_a), seed_a, tx)
}

// ---------------------------------------------------------------------------
// configuration-created-once-with-the-registry: the mint of the token
// ---------------------------------------------------------------------------

test the_mint_is_fresh_when_it_equals_the_births() {
  let asset = asset_of(seed_a)
  fresh_asset(from_asset(asset.policy, asset.name, 1), [asset], asset)
}

test the_mint_is_fresh_when_two_births_mint_two() {
  let asset = asset_of(seed_a)
  fresh_asset(from_asset(asset.policy, asset.name, 2), [asset, asset], asset)
}

test the_mint_is_fresh_beside_the_births_of_other_assets() {
  let asset = asset_of(seed_a)
  let other = asset_of(seed_b)
  fresh_asset(
    from_asset(asset.policy, asset.name, 1)
      |> add(other.policy, other.name, 1),
    [other, asset],
    asset,
  )
}

test the_mint_is_not_fresh_when_nothing_is_minted() {
  let asset = asset_of(seed_a)
  !fresh_asset(zero, [asset], asset)
}

test the_mint_is_not_fresh_without_a_birth() {
  let asset = asset_of(seed_a)
  !fresh_asset(from_asset(asset.policy, asset.name, 1), [], asset)
}

test the_mint_is_not_fresh_when_only_another_asset_is_born() {
  let asset = asset_of(seed_a)
  !fresh_asset(
    from_asset(asset.policy, asset.name, 1),
    [asset_of(seed_b)],
    asset,
  )
}

test the_mint_is_not_fresh_when_it_exceeds_the_births() {
  let asset = asset_of(seed_a)
  !fresh_asset(from_asset(asset.policy, asset.name, 2), [asset], asset)
}

test the_mint_is_not_fresh_when_it_falls_short_of_the_births() {
  let asset = asset_of(seed_a)
  !fresh_asset(from_asset(asset.policy, asset.name, 1), [asset, asset], asset)
}

test the_mint_is_not_fresh_when_the_asset_is_burned() {
  let asset = asset_of(seed_a)
  !fresh_asset(from_asset(asset.policy, asset.name, -1), [asset], asset)
}

// ---------------------------------------------------------------------------
// configuration-created-once-with-the-registry: the action
// ---------------------------------------------------------------------------

fn created(seed: OutputReference, index: Int, tx: Transaction) -> Bool {
  configuration_create(
    application_policy,
    registry_of(seed),
    seed,
    index,
    tx,
    [asset_of(seed)],
  )
}

test the_creation_accepts_the_record_in_its_output_for_every_seed() {
  list.all(seeds, fn(seed) { created(seed, 1, creation_transaction(seed)) })
}

test the_creation_refuses_an_output_index_past_the_outputs() {
  !created(seed_a, 2, creation_transaction(seed_a))
}

test the_creation_refuses_a_negative_output_index() {
  !created(seed_a, -1, creation_transaction(seed_a))
}

test the_creation_refuses_the_state_output_in_place_of_the_record() {
  !created(seed_a, 0, creation_transaction(seed_a))
}

test the_creation_refuses_a_record_of_another_registry() {
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      outputs: [genuine(seed_b), genuine(seed_b)],
    }
  !created(seed_a, 1, tx)
}

test the_creation_refuses_a_transaction_without_the_genesis_of_its_registry() {
  let tx = Transaction { ..creation_transaction(seed_a), inputs: [] }
  !created(seed_a, 1, tx)
}

test the_creation_refuses_a_record_whose_token_is_not_minted() {
  let registry = registry_of(seed_a)
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      mint: from_asset(registry.policy, registry.name, 1),
    }
  !created(seed_a, 1, tx)
}

test the_creation_refuses_a_token_minted_twice_for_one_birth() {
  let registry = registry_of(seed_a)
  let asset = asset_of(seed_a)
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      mint: from_asset(registry.policy, registry.name, 1)
        |> add(asset.policy, asset.name, 2),
    }
  !created(seed_a, 1, tx)
}

test the_creation_refuses_without_the_birth_of_its_token() {
  !configuration_create(
    application_policy,
    registry_of(seed_a),
    seed_a,
    1,
    creation_transaction(seed_a),
    [],
  )
}

// ---------------------------------------------------------------------------
// configuration-created-once-with-the-registry: the validator
// ---------------------------------------------------------------------------

fn mint(actions: List<ApplicationAction>, tx: Transaction) -> Bool {
  open_datum_requests.open_datum_requests.mint(actions, application_policy, tx)
}

test the_validator_accepts_the_creation_of_every_registry() {
  list.all(
    seeds,
    fn(seed) { mint(creation_actions(seed), creation_transaction(seed)) },
  )
}

test the_validator_refuses_a_creation_that_names_the_registry_of_another_seed() {
  mint(creation_actions(seed_b), creation_transaction(seed_a)) == False
}

test the_validator_refuses_a_creation_without_the_genesis_of_its_registry() {
  let tx = Transaction { ..creation_transaction(seed_a), inputs: [] }
  mint(creation_actions(seed_a), tx) == False
}

test the_validator_refuses_a_creation_whose_output_is_the_state() {
  let actions = [mint_action_at(seed_a, 0)]
  mint(actions, creation_transaction(seed_a)) == False
}

fn mint_action_at(seed: OutputReference, index: Int) -> ApplicationAction {
  mint.ConfigurationCreate {
    state_policy: registry_of(seed).policy,
    state_name: registry_of(seed).name,
    seed,
    output_index: index,
  }
}

test the_validator_refuses_a_creation_whose_record_is_at_another_script() {
  let registry = registry_of(seed_a)
  let tx =
    Transaction {
      ..creation_transaction(seed_a),
      outputs: [
        Output {
          ..configuration_output(registry, parameters),
          address: from_script(other_script),
        },
        Output {
          ..configuration_output(registry, parameters),
          address: from_script(other_script),
        },
      ],
    }
  mint(creation_actions(seed_a), tx) == False
}

// ---------------------------------------------------------------------------
// configuration-is-immutable-and-read-by-reference: guard configurationRead
// ---------------------------------------------------------------------------

test the_parameters_of_a_record_are_those_it_carries() {
  list.all(
    seeds,
    fn(seed) {
      configuration_parameters(
        application_policy,
        registry_of(seed),
        configuration_output(registry_of(seed), parameters),
      ) == Some(parameters)
    },
  )
}

test a_record_of_another_registry_has_no_parameters_for_this_one() {
  configuration_parameters(
    application_policy,
    registry_of(seed_a),
    genuine(seed_b),
  ) == None
}

test an_output_of_another_shape_has_no_parameters() {
  let output = Output { ..genuine(seed_a), address: from_script(other_script) }
  configuration_parameters(application_policy, registry_of(seed_a), output) == None
}

fn read_by(
  seed: OutputReference,
  reference_inputs: List<transaction.Input>,
  accepts: fn(ApplicationParameters) -> Bool,
) -> Bool {
  configuration_read(
    application_policy,
    registry_of(seed),
    reference_inputs,
    accepts,
  )
}

fn input_of(
  seed: OutputReference,
  record: ApplicationParameters,
  index: Int,
) -> transaction.Input {
  configuration_input(
    registry_of(seed),
    record,
    OutputReference { ..configuration_reference, output_index: index },
  )
}

test the_record_is_read_when_it_is_a_reference_input() {
  list.all(
    seeds,
    fn(seed) { read_by(seed, [input_of(seed, parameters, 1)], fn(_) { True }) },
  )
}

test the_record_is_read_among_other_reference_inputs() {
  read_by(
    seed_a,
    [
      spent(seed_c),
      input_of(seed_b, parameters, 2),
      input_of(seed_a, parameters, 3),
    ],
    fn(_) { True },
  )
}

test the_record_is_not_read_when_there_are_no_reference_inputs() {
  !read_by(seed_a, [], fn(_) { True })
}

test the_record_is_not_read_from_the_reference_inputs_of_another_registry() {
  !read_by(seed_a, [input_of(seed_b, parameters, 1)], fn(_) { True })
}

test the_record_is_not_read_from_a_reference_input_of_another_shape() {
  let wrong =
    configuration_input(
      registry_of(seed_a),
      parameters,
      configuration_reference,
    )
  let at_other_script =
    transaction.Input {
      ..wrong,
      output: Output { ..wrong.output, address: from_script(other_script) },
    }
  !read_by(seed_a, [at_other_script], fn(_) { True })
}

test the_parameters_read_are_the_ones_the_record_carries() {
  let other =
    ApplicationParameters {
      ..parameters,
      process_time: parameters.process_time + 1,
    }
  and {
    read_by(seed_a, [input_of(seed_a, other, 1)], fn(p) { p == other }),
    !read_by(seed_a, [input_of(seed_a, other, 1)], fn(p) { p == parameters }),
  }
}

test the_read_asks_every_record_of_the_registry() {
  let other =
    ApplicationParameters {
      ..parameters,
      process_time: parameters.process_time + 1,
    }
  let inputs = [input_of(seed_a, other, 1), input_of(seed_a, parameters, 2)]
  and {
    read_by(seed_a, inputs, fn(p) { p == other }),
    read_by(seed_a, inputs, fn(p) { p == parameters }),
    !read_by(seed_a, inputs, fn(p) { p.booking_width == 1 }),
  }
}

// ---------------------------------------------------------------------------
// configuration-is-immutable-and-read-by-reference: no spend path
// ---------------------------------------------------------------------------

fn spend_of_record(seed: OutputReference, redeemer: Data) -> Bool {
  let datum: Data = Configuration { parameters }
  open_datum_requests.open_datum_requests.spend(
    Some(datum),
    redeemer,
    configuration_reference,
    Transaction {
      ..transaction.placeholder,
      inputs: [
        transaction.Input {
          output_reference: configuration_reference,
          output: genuine(seed),
        },
      ],
    },
  )
}

/// The refusal is a pin of the constant refusal of the spend handler until the
/// rules for the other records arrive; it is not a RED leg of its own.
test the_validator_has_no_spend_path_for_a_configuration_record() {
  let approval_burn: Data = ApprovalBurn
  let number: Data = 0
  list.all(
    seeds,
    fn(seed) {
      !spend_of_record(seed, approval_burn) && !spend_of_record(seed, number)
    },
  )
}

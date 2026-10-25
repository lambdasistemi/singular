//// The configuration record of a registry.
////
//// ## Responsibility
//// The decision sites of the model's `configurationCreate`,
//// `configurationShape` and `configurationRead`: the record that holds the
//// five request parameters is created with the registry, in one output at the
//// application address holding exactly its own token, and a booking reads it
//// by reference.
////
//// ## Dependencies
//// `application/births` for the accounting of the mint; `application/held`
//// for the records; `singular_state/preimage` for the registry identity, the
//// name of the configuration token and the name of the state token; the Aiken
//// standard library.
////
//// ## Assumptions
//// The state policy of the registry is minted by its own genesis, which
//// checks that the seed is spent and that the state token is minted once.
////
//// ## Invariants
//// The token of a configuration record is named from the registry it
//// configures, so the record of one registry is never the record of another.

use aiken/collection/list
use application/births.{fresh_asset}
use application/held.{
  ApplicationParameters, Configuration, TokenId, held_datum, holds_exactly_one,
}
use cardano/address.{Script}
use cardano/assets.{PolicyId, policies, quantity_of}
use cardano/transaction.{Input, Output, OutputReference, Transaction}
use singular_state/preimage.{
  RegistryIdentity, configuration_token_name, state_token_name,
}

/// The token of the configuration record of `registry`.
pub fn configuration_asset(
  application_policy: PolicyId,
  registry: RegistryIdentity,
) -> TokenId {
  TokenId {
    policy: application_policy,
    name: configuration_token_name(registry),
  }
}

/// Model guard `configurationShape`: `output` sits at the application
/// address, carries a configuration record inline, and holds exactly the one
/// token of the configuration of `registry` besides ADA.
pub fn configuration_shape(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  output: Output,
) -> Bool {
  and {
    output.address.payment_credential == Script(application_policy),
    when held_datum(output) is {
      Some(Configuration { .. }) -> True
      _ -> False
    },
    holds_exactly_one(output, configuration_asset(application_policy, registry)),
  }
}

/// Model guard `configurationGenesis`: `registry` is the registry created by
/// spending `seed`, the seed is spent once, the state policy is invoked and
/// the state token is minted once.
pub fn configuration_genesis(
  registry: RegistryIdentity,
  seed: OutputReference,
  tx: Transaction,
) -> Bool {
  and {
    registry.name == state_token_name(seed),
    list.count(tx.inputs, fn(input) { input.output_reference == seed }) == 1,
    list.has(policies(tx.mint), registry.policy),
    quantity_of(tx.mint, registry.policy, registry.name) == 1,
  }
}

/// Model `configurationCreate`: the action that creates the configuration
/// record of `registry` in the output at `output_index`.
pub fn configuration_create(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  seed: OutputReference,
  output_index: Int,
  tx: Transaction,
  births: List<TokenId>,
) -> Bool {
  when list.at(tx.outputs, output_index) is {
    Some(output) -> and {
        configuration_shape(application_policy, registry, output),
        configuration_genesis(registry, seed, tx),
        fresh_asset(
          tx.mint,
          births,
          configuration_asset(application_policy, registry),
        ),
      }
    None -> False
  }
}

/// The parameters of the configuration record `output` is, when it is the
/// record of `registry`.
pub fn configuration_parameters(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  output: Output,
) -> Option<ApplicationParameters> {
  if configuration_shape(application_policy, registry, output) {
    when held_datum(output) is {
      Some(Configuration { parameters }) -> Some(parameters)
      _ -> None
    }
  } else {
    None
  }
}

/// Model `configurationRead`: some reference input is the configuration
/// record of `registry` and its parameters satisfy `accepts`.
pub fn configuration_read(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  reference_inputs: List<Input>,
  accepts: fn(ApplicationParameters) -> Bool,
) -> Bool {
  list.any(
    reference_inputs,
    fn(input) {
      when
        configuration_parameters(application_policy, registry, input.output)
      is {
        Some(parameters) -> accepts(parameters)
        None -> False
      }
    },
  )
}

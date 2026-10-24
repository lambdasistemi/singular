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
//// for the records; `singular_state/preimage` for the registry identity and
//// the name of the state token; the Aiken standard library.
////
//// ## Assumptions
//// The state policy of the registry is minted by its own genesis, which
//// checks that the seed is spent and that the state token is minted once.
////
//// ## Invariants
//// The token of a configuration record is named from the registry it
//// configures, so the record of one registry is never the record of another.

use application/held.{ApplicationParameters, TokenId}
use cardano/assets.{PolicyId}
use cardano/transaction.{Input, Output, OutputReference, Transaction}
use singular_state/preimage.{RegistryIdentity, configuration_token_name}

/// The token of the configuration record of `registry`.
pub fn configuration_asset(
  _application_policy: PolicyId,
  registry: RegistryIdentity,
) -> TokenId {
  TokenId { policy: #"", name: configuration_token_name(registry) }
}

/// Model guard `configurationShape`: `output` sits at the application
/// address, carries a configuration record inline, and holds exactly the one
/// token of the configuration of `registry` besides ADA.
pub fn configuration_shape(
  _application_policy: PolicyId,
  _registry: RegistryIdentity,
  _output: Output,
) -> Bool {
  False
}

/// Model guard `configurationGenesis`: `registry` is the registry created by
/// spending `seed`, the seed is spent once, the state policy is invoked and
/// the state token is minted once.
pub fn configuration_genesis(
  _registry: RegistryIdentity,
  _seed: OutputReference,
  _tx: Transaction,
) -> Bool {
  False
}

/// Model `configurationCreate`: the action that creates the configuration
/// record of `registry` in the output at `output_index`.
pub fn configuration_create(
  _application_policy: PolicyId,
  _registry: RegistryIdentity,
  _seed: OutputReference,
  _output_index: Int,
  _tx: Transaction,
  _births: List<TokenId>,
) -> Bool {
  False
}

/// The parameters of the configuration record `output` is, when it is the
/// record of `registry`.
pub fn configuration_parameters(
  _application_policy: PolicyId,
  _registry: RegistryIdentity,
  _output: Output,
) -> Option<ApplicationParameters> {
  None
}

/// Model `configurationRead`: some reference input is the configuration
/// record of `registry` and its parameters satisfy `accepts`.
pub fn configuration_read(
  _application_policy: PolicyId,
  _registry: RegistryIdentity,
  _reference_inputs: List<Input>,
  _accepts: fn(ApplicationParameters) -> Bool,
) -> Bool {
  False
}

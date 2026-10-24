//// The booking of a registration.
////
//// ## Responsibility
//// The decision sites of the model's `registrationBook`: a registration
//// approval is minted only for a pending registration booked at the
//// application address, holding exactly that approval, whose committed
//// fields are the ones the approval names, signed by the controller, with
//// the clock fixed from the configuration of its registry.
////
//// ## Dependencies
//// `application/births`, `application/clock`, `application/configuration` and
//// `application/held`; `singular_state/preimage` for the approval preimage and
//// the names; the Aiken standard library.
////
//// ## Assumptions
//// The Singular state script, not this one, decides that the key is absent and
//// that the token reaches the holding the approval commits.
////
//// ## Invariants
//// The name of a registration approval commits the registry, the key, the
//// holding address, the hash of the initial datum and the deposit, so an
//// approval is good for exactly one registration.

use aiken/crypto.{VerificationKeyHash}
use application/held.{RegistrationData, TokenId}
use cardano/assets.{PolicyId}
use cardano/transaction.{Output, Transaction}

/// The token a registration is approved by: under the application policy,
/// named by the hash of the preimage that commits its fields.
pub fn registration_asset(
  _application_policy: PolicyId,
  _registration: RegistrationData,
) -> TokenId {
  TokenId { policy: #"", name: #"" }
}

/// Model guard `registrationShape`: `output` sits at the application address
/// and holds exactly the approval of `registration` besides ADA.
pub fn registration_shape(
  _application_policy: PolicyId,
  _output: Output,
  _registration: RegistrationData,
) -> Bool {
  False
}

/// Model guard `registrationFunding`: the output holds at least the deposit.
pub fn registration_funding(
  _output: Output,
  _registration: RegistrationData,
) -> Bool {
  False
}

/// Model `initialControl`: the initial datum is a live holding whose control
/// names the registry, the key, the controller and the deposit of the
/// registration, and the active token of that registry and key.
pub fn initial_control(_registration: RegistrationData) -> Bool {
  False
}

/// Model guard `registrationControl`: the holding is at the application
/// address and the initial datum is the control the registration names.
pub fn registration_control(
  _application_policy: PolicyId,
  _registration: RegistrationData,
) -> Bool {
  False
}

/// Model guard `bookingSignature`: the controller signs the transaction.
pub fn booking_signature(
  _registration: RegistrationData,
  _signatories: List<VerificationKeyHash>,
) -> Bool {
  False
}

/// The pending registration at `index` among the outputs, with its record.
pub fn registration_at(
  _outputs: List<Output>,
  _index: Int,
) -> Option<(Output, RegistrationData)> {
  None
}

/// Model `registrationBook`: the action that books the registration held by
/// the output at `output_index`.
pub fn registration_book(
  _application_policy: PolicyId,
  _output_index: Int,
  _tx: Transaction,
  _births: List<TokenId>,
) -> Bool {
  False
}

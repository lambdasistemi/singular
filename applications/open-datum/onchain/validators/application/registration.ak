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

use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use application/births.{fresh_asset}
use application/clock.{registration_clock}
use application/configuration.{configuration_read}
use application/held.{
  Live, Registration, RegistrationData, TokenId, held_datum, held_datum_of,
  holds_exactly_one,
}
use cardano/address.{Script}
use cardano/assets.{PolicyId, lovelace_of}
use cardano/transaction.{Output, Transaction}
use singular_state/preimage.{
  active_token_name, approval_name, initial_datum_hash, registration_preimage,
}

/// The token a registration is approved by: under the application policy,
/// named by the hash of the preimage that commits its fields.
pub fn registration_asset(
  application_policy: PolicyId,
  registration: RegistrationData,
) -> TokenId {
  TokenId {
    policy: application_policy,
    name: approval_name(
      registration_preimage(
        registration.key,
        registration.registry,
        registration.holding_address,
        initial_datum_hash(registration.initial_datum),
        registration.deposit,
      ),
    ),
  }
}

/// Model guard `registrationShape`: `output` sits at the application address
/// and holds exactly the approval of `registration` besides ADA.
pub fn registration_shape(
  application_policy: PolicyId,
  output: Output,
  registration: RegistrationData,
) -> Bool {
  and {
    output.address.payment_credential == Script(application_policy),
    holds_exactly_one(
      output,
      registration_asset(application_policy, registration),
    ),
  }
}

/// Model guard `registrationFunding`: the output holds at least the deposit.
pub fn registration_funding(
  output: Output,
  registration: RegistrationData,
) -> Bool {
  lovelace_of(output.value) >= registration.deposit
}

/// Model `initialControl`: the initial datum is a live holding whose control
/// names the registry, the key, the controller and the deposit of the
/// registration, and the active token of that registry and key.
pub fn initial_control(registration: RegistrationData) -> Bool {
  when held_datum_of(registration.initial_datum) is {
    Some(Live { control, .. }) -> and {
        control.registry == registration.registry,
        control.key == registration.key,
        control.controller == registration.controller,
        control.deposit == registration.deposit,
        control.active_asset == TokenId {
          policy: registration.registry.policy,
          name: active_token_name(registration.registry, registration.key),
        },
      }
    _ -> False
  }
}

/// Model guard `registrationControl`: the holding is at the application
/// address and the initial datum is the control the registration names.
pub fn registration_control(
  application_policy: PolicyId,
  registration: RegistrationData,
) -> Bool {
  and {
    registration.holding_address.payment_credential == Script(
      application_policy,
    ),
    initial_control(registration),
  }
}

/// Model guard `bookingSignature`: the controller signs the transaction.
pub fn booking_signature(
  registration: RegistrationData,
  signatories: List<VerificationKeyHash>,
) -> Bool {
  list.has(signatories, registration.controller)
}

/// The pending registration at `index` among the outputs, with its record.
pub fn registration_at(
  outputs: List<Output>,
  index: Int,
) -> Option<(Output, RegistrationData)> {
  when list.at(outputs, index) is {
    Some(output) ->
      when held_datum(output) is {
        Some(Registration { registration }) -> Some((output, registration))
        _ -> None
      }
    None -> None
  }
}

/// Model `registrationBook`: the action that books the registration held by
/// the output at `output_index`.
pub fn registration_book(
  application_policy: PolicyId,
  output_index: Int,
  tx: Transaction,
  births: List<TokenId>,
) -> Bool {
  when registration_at(tx.outputs, output_index) is {
    Some((output, registration)) -> and {
        registration_shape(application_policy, output, registration),
        registration_funding(output, registration),
        registration_control(application_policy, registration),
        booking_signature(registration, tx.extra_signatories),
        configuration_read(
          application_policy,
          registration.registry,
          tx.reference_inputs,
          fn(parameters) {
            registration_clock(registration, parameters, tx.validity_range)
          },
        ),
        fresh_asset(
          tx.mint,
          births,
          registration_asset(application_policy, registration),
        ),
      }
    None -> False
  }
}

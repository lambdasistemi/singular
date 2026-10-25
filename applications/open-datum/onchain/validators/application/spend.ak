//// The spend of a pending registration.
////
//// ## Responsibility
//// Decides the spend of a pending registration from the action of its
//// redeemer: a fold delivers the genuine token into the new holding before
//// the processing deadline, the refund address reclaims the whole request
//// inside the reclaim window, and anyone cleans the request up after the
//// window, returning the deposit to the refund address. Every spend burns the
//// approval it consumes.
////
//// ## Dependencies
//// `application/held` for the records, `application/phases` for the phase of
//// the validity range, `application/payments` for what the transaction pays;
//// `application/registration` for the approval of a registration;
//// `singular_state/preimage` for the active token name; the Aiken standard
//// library.
////
//// ## Assumptions
//// The ledger runs the spend handler once for every input at the address of
//// the script, with that input's redeemer, so every application input has
//// exactly one action. The Singular state script decides which token is the
//// genuine active token of a registration; this script checks that exactly
//// one is minted and that the holding carries it.
////
//// ## Invariants
//// Before the processing deadline only a fold spends a pending registration.
//// Whoever spends one burns its approval, so an approval is good for one
//// spend.

use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use application/held.{Registration, RegistrationData, TokenId, held_datum}
use application/payments.{Payment}
use application/phases.{Processing, classify_phase}
use application/registration.{
  registration_asset, registration_funding, registration_shape,
}
use cardano/address.{Script}
use cardano/assets.{PolicyId, Value, lovelace_of, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use singular_state/preimage.{active_token_name}

/// The actions of the model's `ApplicationAction` that spend a pending
/// registration. The reference of the input is the one the ledger hands the
/// handler.
pub type SpendAction {
  RegistrationFold { holding_index: Int }
  OwnerReclaim
  ExpiredCleanup
}

/// Model `requestInput`: the output that `reference` spends, when exactly one
/// input spends it.
pub fn request_input(
  inputs: List<Input>,
  reference: OutputReference,
) -> Option<Output> {
  when
    list.filter(inputs, fn(input) { input.output_reference == reference })
  is {
    [input] -> Some(input.output)
    _ -> None
  }
}

/// Model `approvalBurned`: the transaction burns at least as many of
/// `approval` as its inputs hold.
pub fn approval_burned(tx: Transaction, approval: TokenId) -> Bool {
  let consumed =
    list.foldr(
      tx.inputs,
      0,
      fn(input, total) {
        total + quantity_of(input.output.value, approval.policy, approval.name)
      },
    )
  quantity_of(tx.mint, approval.policy, approval.name) <= -consumed
}

/// The genuine active token of a registration: under the state policy of its
/// registry, named from the registry and the key.
fn active_token(registration: RegistrationData) -> TokenId {
  let registry = registration.registry
  TokenId {
    policy: registry.policy,
    name: active_token_name(registry, registration.key),
  }
}

/// Model guard `registrationDelivery`: the output at `holding_index` is the
/// holding the registration committed, carries the genuine active token, and
/// the transaction mints exactly one.
pub fn registration_delivery(
  registration: RegistrationData,
  outputs: List<Output>,
  mint: Value,
  holding_index: Int,
) -> Bool {
  let active = active_token(registration)
  when list.at(outputs, holding_index) is {
    Some(holding) -> and {
        holding.address == registration.holding_address,
        holding.datum == InlineDatum(registration.initial_datum),
        lovelace_of(holding.value) == registration.deposit,
        quantity_of(holding.value, active.policy, active.name) == 1,
        quantity_of(mint, active.policy, active.name) == 1,
      }
    None -> False
  }
}

/// Model `reclaimPhase`, signature part: the refund address signs.
pub fn refund_signature(
  _registration: RegistrationData,
  _signatories: List<VerificationKeyHash>,
) -> Bool {
  False
}

/// The action a redeemer carries, when it carries one.
pub fn spend_action_of(_redeemer: Data) -> Option<SpendAction> {
  None
}

/// Model `requiredPayments`: the payments the spent registrations of the
/// transaction require, one per spent registration.
pub fn required_payments(
  _application_policy: PolicyId,
  _tx: Transaction,
) -> List<Payment> {
  []
}

/// Model `registrationSpend`: the decision on the spend of `input`, the
/// pending registration `registration`, by `action`.
pub fn registration_spend(
  application_policy: PolicyId,
  action: SpendAction,
  input: Output,
  registration: RegistrationData,
  tx: Transaction,
) -> Bool {
  and {
    registration_shape(application_policy, input, registration),
    registration_funding(input, registration),
    approval_burned(tx, registration_asset(application_policy, registration)),
    when action is {
      RegistrationFold { holding_index } -> and {
          classify_phase(registration, tx.validity_range) == Processing,
          registration_delivery(
            registration,
            tx.outputs,
            tx.mint,
            holding_index,
          ),
        }
      OwnerReclaim -> False
      ExpiredCleanup -> False
    },
  }
}

/// Model `applicationAction` for the spend of the input at `own_reference`.
pub fn application_spend(
  action: SpendAction,
  own_reference: OutputReference,
  tx: Transaction,
) -> Bool {
  when request_input(tx.inputs, own_reference) is {
    Some(input) ->
      when input.address.payment_credential is {
        Script(application_policy) ->
          when held_datum(input) is {
            Some(Registration { registration }) ->
              registration_spend(
                application_policy,
                action,
                input,
                registration,
                tx,
              )
            _ -> False
          }
        _ -> False
      }
    None -> False
  }
}

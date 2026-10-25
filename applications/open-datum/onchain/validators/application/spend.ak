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

use aiken/crypto.{VerificationKeyHash}
use application/held.{RegistrationData, TokenId}
use application/payments.{Payment}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input, Output, OutputReference, Transaction}

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
  _inputs: List<Input>,
  _reference: OutputReference,
) -> Option<Output> {
  None
}

/// Model `approvalBurned`: the transaction burns at least as many of
/// `approval` as its inputs hold.
pub fn approval_burned(_tx: Transaction, _approval: TokenId) -> Bool {
  False
}

/// Model guard `registrationDelivery`: the output at `holding_index` is the
/// holding the registration committed, carries the genuine active token, and
/// the transaction mints exactly one.
pub fn registration_delivery(
  _registration: RegistrationData,
  _outputs: List<Output>,
  _mint: Value,
  _holding_index: Int,
) -> Bool {
  False
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
  _application_policy: PolicyId,
  _action: SpendAction,
  _input: Output,
  _registration: RegistrationData,
  _tx: Transaction,
) -> Bool {
  False
}

/// Model `applicationAction` for the spend of the input at `own_reference`.
pub fn application_spend(
  _action: SpendAction,
  _own_reference: OutputReference,
  _tx: Transaction,
) -> Bool {
  False
}

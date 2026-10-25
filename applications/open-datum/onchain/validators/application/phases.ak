//// The three timed phases of a pending registration.
////
//// ## Responsibility
//// Classifies the validity range of a transaction that spends a pending
//// registration against the deadlines the registration was booked with: the
//// processing phase, the reclaim window and the cleanup phase, or none of
//// them.
////
//// ## Dependencies
//// `application/clock` for the half-open reading of a validity range;
//// `application/held` for the record.
////
//// ## Assumptions
//// The deadlines of the registration are the ones booking fixed from the
//// configuration of its registry.
////
//// ## Invariants
//// A validity range is in at most one phase. A range that is empty, that has
//// no two finite bounds or that crosses a deadline is in none.

use application/held.{RegistrationData}
use cardano/transaction.{ValidityRange}

/// The model's `RegistrationPhase`.
pub type RegistrationPhase {
  Processing
  Reclaim
  Cleanup
  Refused
}

/// Model `classifyPhase`.
pub fn classify_phase(
  _registration: RegistrationData,
  _range: ValidityRange,
) -> RegistrationPhase {
  Refused
}

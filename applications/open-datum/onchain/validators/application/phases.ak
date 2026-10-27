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

use application/clock.{Bounds, validity_bounds}
use application/held.{RegistrationData}
use cardano/transaction.{ValidityRange}

/// The model's `RegistrationPhase`.
pub type RegistrationPhase {
  Processing
  Reclaim
  Cleanup
  Refused
}

/// Model `classifyPhase`: the range ends at or before the processing
/// deadline, or lies inside the window from that deadline to the end of the
/// reclaim time, or starts at or after the end of the window. An empty range
/// is in no phase.
pub fn classify_phase(
  registration: RegistrationData,
  range: ValidityRange,
) -> RegistrationPhase {
  when validity_bounds(range) is {
    Some(Bounds { lower, upper }) ->
      if lower >= upper {
        Refused
      } else if upper <= registration.process_deadline {
        Processing
      } else if registration.process_deadline <= lower && upper <= registration.reclaim_end {
        Reclaim
      } else if registration.reclaim_end <= lower {
        Cleanup
      } else {
        Refused
      }
    None -> Refused
  }
}

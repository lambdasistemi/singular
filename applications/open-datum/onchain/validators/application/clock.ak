//// The validity interval of a transaction as the model's clock reads it.
////
//// ## Responsibility
//// Reads the validity range as the half-open interval of instants the
//// transaction can be valid at, and decides the clock of a booked
//// registration against the parameters of its registry.
////
//// ## Dependencies
//// `application/held` for the records; the Aiken standard library.
////
//// ## Assumptions
//// Time is an integer count of milliseconds, and the transaction is valid at
//// the instants from its lower bound, included, to its upper bound, excluded.
////
//// ## Invariants
//// A range without two finite bounds is no clock. Inclusive and exclusive
//// bounds are brought to the one half-open reading before any comparison.

use aiken/interval.{Finite}
use application/held.{ApplicationParameters, RegistrationData}
use cardano/transaction.{ValidityRange}

/// The first instant a transaction can be valid at and the first instant it
/// no longer can be.
pub type Bounds {
  lower: Int,
  upper: Int,
}

/// The half-open interval of a validity range, when both bounds are finite.
pub fn validity_bounds(range: ValidityRange) -> Option<Bounds> {
  when (range.lower_bound.bound_type, range.upper_bound.bound_type) is {
    (Finite(lower), Finite(upper)) ->
      Some(
        Bounds {
          lower: if range.lower_bound.is_inclusive {
            lower
          } else {
            lower + 1
          },
          upper: if range.upper_bound.is_inclusive {
            upper + 1
          } else {
            upper
          },
        },
      )
    _ -> None
  }
}

/// Model guard `registrationClock`: the interval is non-empty, the booking
/// time is its upper bound, its width is within the booking width, and the
/// deadlines are the booking time moved by the processing and the reclaim
/// times of the registry.
pub fn registration_clock(
  registration: RegistrationData,
  parameters: ApplicationParameters,
  range: ValidityRange,
) -> Bool {
  when validity_bounds(range) is {
    Some(Bounds { lower, upper }) -> and {
        lower < upper,
        registration.booked_at == upper,
        upper - lower <= parameters.booking_width,
        registration.process_deadline == registration.booked_at + parameters.process_time,
        registration.reclaim_end == registration.process_deadline + parameters.retract_time,
      }
    None -> False
  }
}

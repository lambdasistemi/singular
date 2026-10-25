//// The three timed phases of a pending registration, against the model's
//// `classifyPhase`, `nonemptyInterval` and `phasesDisjoint` (statement
//// `registration_lifecycle`, bound at the revision of the epic branch that
//// landed the open-datum model).
////
//// The expected phase of every range comes from the table of
//// `open_datum_requests_pending_fixtures.cases`, written out case by case; it
//// is not computed from the deadlines. Every case is run for registrations
//// with a window of seven million, ten and eighty-six million milliseconds
//// at three different times, so no deadline is a constant of one row.

use aiken/collection/list
use aiken/interval.{
  Finite, Interval, IntervalBound, NegativeInfinity, PositiveInfinity,
}
use application/held.{RegistrationData}
use application/phases.{
  Cleanup, Processing, Reclaim, Refused, RegistrationPhase, classify_phase,
}
use application/spend.{ExpiredCleanup, OwnerReclaim, SpendAction}
use cardano/transaction.{OutputReference, Transaction}
use open_datum_requests
use open_datum_requests_fixtures.{registration_a}
use open_datum_requests_pending_fixtures.{
  Case, bounded, case_range, cases, cleanup_transaction, fold_action,
  fold_transaction, pending_reference, reclaim_transaction,
  registrations_over_time,
}

fn phase_of(registration: RegistrationData, case: Case) -> RegistrationPhase {
  classify_phase(registration, case_range(registration, case))
}

fn cases_in(phase: RegistrationPhase) -> List<Case> {
  list.filter(cases(), fn(case) { case.expected == phase })
}

// ---------------------------------------------------------------------------
// pending-registration-phases-are-disjoint: the classification
// ---------------------------------------------------------------------------

test the_table_has_cases_of_every_phase_and_of_none() {
  and {
    list.length(cases_in(Processing)) >= 3,
    list.length(cases_in(Reclaim)) >= 3,
    list.length(cases_in(Cleanup)) >= 3,
    list.length(cases_in(Refused)) >= 10,
    list.length(registrations_over_time()) == 3,
  }
}

test a_range_wholly_before_the_processing_deadline_is_processing() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases_in(Processing),
        fn(case) { phase_of(registration, case) == Processing },
      )
    },
  )
}

test a_range_wholly_inside_the_reclaim_window_is_reclaim() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases_in(Reclaim),
        fn(case) { phase_of(registration, case) == Reclaim },
      )
    },
  )
}

test a_range_from_the_end_of_the_window_on_is_cleanup() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases_in(Cleanup),
        fn(case) { phase_of(registration, case) == Cleanup },
      )
    },
  )
}

test a_range_that_crosses_a_deadline_or_is_empty_is_in_no_phase() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases_in(Refused),
        fn(case) { phase_of(registration, case) == Refused },
      )
    },
  )
}

// ---------------------------------------------------------------------------
// pending-registration-phases-are-disjoint: how a range is read
// ---------------------------------------------------------------------------

fn phase_between(
  registration: RegistrationData,
  range: Interval<Int>,
) -> RegistrationPhase {
  classify_phase(registration, range)
}

test an_excluded_lower_bound_starts_at_the_next_instant() {
  let registration = registration_a()
  let deadline = registration.process_deadline
  let end = registration.reclaim_end
  and {
    phase_between(registration, bounded(deadline - 1, False, end, False)) == Reclaim,
    phase_between(registration, bounded(deadline, False, end, False)) == Reclaim,
    phase_between(registration, bounded(end - 1, False, end + 10, False)) == Cleanup,
    phase_between(registration, bounded(end, False, end + 10, False)) == Cleanup,
    phase_between(
      registration,
      bounded(deadline - 2, False, deadline + 10, False),
    ) == Refused,
  }
}

test an_included_upper_bound_ends_at_the_next_instant() {
  let registration = registration_a()
  let deadline = registration.process_deadline
  let end = registration.reclaim_end
  and {
    phase_between(
      registration,
      bounded(deadline - 10, True, deadline - 1, True),
    ) == Processing,
    phase_between(registration, bounded(deadline - 10, True, deadline, True)) == Refused,
    phase_between(registration, bounded(deadline, True, end - 1, True)) == Reclaim,
    phase_between(registration, bounded(deadline, True, end, True)) == Refused,
  }
}

test a_range_holding_one_instant_is_not_empty_and_one_holding_none_is() {
  let registration = registration_a()
  let deadline = registration.process_deadline
  and {
    phase_between(registration, bounded(deadline + 3, True, deadline + 3, True)) == Reclaim,
    phase_between(
      registration,
      bounded(deadline + 3, False, deadline + 4, False),
    ) == Refused,
    phase_between(
      registration,
      bounded(deadline + 3, True, deadline + 3, False),
    ) == Refused,
    phase_between(
      registration,
      bounded(deadline + 3, False, deadline + 3, True),
    ) == Refused,
  }
}

test a_range_without_two_finite_bounds_is_in_no_phase() {
  let registration = registration_a()
  let deadline = registration.process_deadline
  let end = registration.reclaim_end
  let before_deadline =
    Interval {
      lower_bound: IntervalBound {
        bound_type: NegativeInfinity,
        is_inclusive: True,
      },
      upper_bound: IntervalBound {
        bound_type: Finite(deadline),
        is_inclusive: False,
      },
    }
  let after_end =
    Interval {
      lower_bound: IntervalBound { bound_type: Finite(end), is_inclusive: True },
      upper_bound: IntervalBound {
        bound_type: PositiveInfinity,
        is_inclusive: True,
      },
    }
  let always =
    Interval {
      lower_bound: IntervalBound {
        bound_type: NegativeInfinity,
        is_inclusive: True,
      },
      upper_bound: IntervalBound {
        bound_type: PositiveInfinity,
        is_inclusive: True,
      },
    }
  and {
    phase_between(registration, before_deadline) == Refused,
    phase_between(registration, after_end) == Refused,
    phase_between(registration, always) == Refused,
  }
}

test the_phase_depends_on_the_deadlines_and_on_nothing_else_of_the_registration() {
  let registration = registration_a()
  let other =
    RegistrationData {
      ..registration,
      key: #"00",
      deposit: 1,
      controller: #"01",
    }
  list.all(
    cases(),
    fn(case) {
      and {
        phase_of(registration, case) == case.expected,
        phase_of(other, case) == case.expected,
      }
    },
  )
}

// ---------------------------------------------------------------------------
// pending-registration-phases-are-disjoint: the validator
// ---------------------------------------------------------------------------

fn in_range(tx: Transaction, range: Interval<Int>) -> Transaction {
  Transaction { ..tx, validity_range: range }
}

/// How many of the three perfect spends of `registration` the validator
/// accepts when each is given the range.
fn accepted_in(registration: RegistrationData, range: Interval<Int>) -> Int {
  list.count(
    [
      run(fold_action(), in_range(fold_transaction(registration), range)),
      run(OwnerReclaim, in_range(reclaim_transaction(registration), range)),
      run(ExpiredCleanup, in_range(cleanup_transaction(registration), range)),
    ],
    fn(accepted) { accepted },
  )
}

test no_range_is_accepted_by_two_spends_of_one_registration() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases(),
        fn(case) {
          accepted_in(registration, case_range(registration, case)) <= 1
        },
      )
    },
  )
}

test no_range_in_no_phase_is_accepted_by_any_spend() {
  list.all(
    registrations_over_time(),
    fn(registration) {
      list.all(
        cases_in(Refused),
        fn(case) {
          accepted_in(registration, case_range(registration, case)) == 0
        },
      )
    },
  )
}

test no_range_of_an_unbounded_end_is_accepted_by_any_spend() {
  let registration = registration_a()
  let end = registration.reclaim_end
  let after_end =
    Interval {
      lower_bound: IntervalBound { bound_type: Finite(end), is_inclusive: True },
      upper_bound: IntervalBound {
        bound_type: PositiveInfinity,
        is_inclusive: True,
      },
    }
  let before_deadline =
    Interval {
      lower_bound: IntervalBound {
        bound_type: NegativeInfinity,
        is_inclusive: True,
      },
      upper_bound: IntervalBound {
        bound_type: Finite(registration.process_deadline),
        is_inclusive: False,
      },
    }
  and {
    accepted_in(registration, after_end) == 0,
    accepted_in(registration, before_deadline) == 0,
  }
}

// ---------------------------------------------------------------------------
// The validator
// ---------------------------------------------------------------------------

/// The spend handler of the validator, for the input at `reference`.
fn run_at(
  action: SpendAction,
  reference: OutputReference,
  tx: Transaction,
) -> Bool {
  open_datum_requests.open_datum_requests.spend(None, action, reference, tx)
}

/// The spend handler for the single pending registration of the one-spend
/// transactions.
fn run(action: SpendAction, tx: Transaction) -> Bool {
  run_at(action, pending_reference(), tx)
}

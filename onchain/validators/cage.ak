use shared

/// Compatibility module for phase predicates used by property tests.
pub fn in_phase1(validity_range, submitted_at, process_time) -> Bool {
  shared.in_phase1(validity_range, submitted_at, process_time)
}

pub fn in_phase2(
  validity_range,
  submitted_at,
  process_time,
  retract_time,
) -> Bool {
  shared.in_phase2(validity_range, submitted_at, process_time, retract_time)
}

pub fn is_rejectable(
  validity_range,
  submitted_at,
  process_time,
  retract_time,
) -> Bool {
  shared.is_rejectable(validity_range, submitted_at, process_time, retract_time)
}

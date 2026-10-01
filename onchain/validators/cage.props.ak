////// These fuzz tests verify, for randomly generated parameters, that:

use aiken/collection/list
use aiken/fuzz
use aiken/interval.{Interval}
use cage.{in_phase1, in_phase2, is_rejectable}
use cage_fixtures.{
  feeRequestInput, feeStateDatum, feeStateInput, modifyRedeemerData,
  noDestination, refundOutput, rejectedActionData, rejectedStateOutput, request,
  stateSpendRedeemerData, testStateRef, testToken, update, updateActionData,
}
use cardano/address
use cardano/assets.{from_lovelace}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use request as request_validator
use state
use types.{Contribute, Modify, Rejected, Request, RequestDatum, TokenId}

/// Phase property tests (fuzz) for the time-gated phase system in `cage.ak`.
///
/// **Lean binding: MISSING.** The historic citations below name
/// `MpfsCage/Phases.lean`, which is absent from this repository's Lean tree
/// (`lean/` contains only `Singular.*` modules, no `MpfsCage.*`). No
/// accepted Lean declaration is bound here and no conformance is claimed;
/// these are behavioral regression properties over `cage.ak`'s phase
/// helpers alone. Historic per-property markers keep the original
/// reference names as provenance.
///
/// ```
///   submitted_at          +process_time    +retract_time
///       |--- Phase 1 ---------|--- Phase 2 ---|--- Phase 3 --->
///       Oracle processes       Requester       Any folder
///       requests (Modify)      can Retract     can Reject
/// ```
///
/// **Phase 1** (oracle processing): The oracle folds requests into the MPF.
///   Contribute is allowed (linking requests to a cage).
///
/// **Phase 2** (requester retract): Only the requester can act — they may
///   Retract their unprocessed request and reclaim their ADA.
///
/// **Phase 3** (rejectable): The retract window has expired. Any folder
///   can Reject expired requests. Additionally, any request with a dishonest
///   `submitted_at` (in the future) is rejectable in any phase.
/// 1. The phases never overlap (mutual exclusion).
/// 2. Honest requests in Phase 1 or 2 are never rejectable (safety).
/// 3. Every point in time falls into at least one phase (coverage).
///
/// Each property mirrors a machine-checked Lean 4 theorem. The Lean proofs
/// provide mathematical certainty; the fuzz tests validate the Aiken
/// implementation matches the formal specification.
///
/// **Fuzzer ranges**: `submitted_at` in [0, 100k], `process_time` in [1, 50k],
/// `retract_time` in [1, 50k], validity range start in [0, 200k] with span
/// in [1, 50k]. These cover a wide range of realistic and edge-case timing
/// configurations.
/// **Historic Lean reference `MpfsCage/Phases.lean` `phase1_phase2_exclusive` — binding MISSING (see header)**
///
/// No validity range can satisfy both `in_phase1` and `in_phase2` simultaneously.
///
/// Phase 1 requires the range to be entirely before `submitted_at + process_time`.
/// Phase 2 requires it to be entirely after `submitted_at + process_time - 1`.
/// These conditions are contradictory: a range cannot be both before and after
/// the same boundary.
///
/// If this property failed, a transaction could be valid in both phases,
/// allowing the oracle to Modify AND the requester to Retract the same
/// request — a double-spend.
test prop_phase1_phase2_exclusive(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(
      fuzz.int_between(1, 50_000),
      fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000)),
    ),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let range = interval.between(lo, lo + span)
  let p1 = in_phase1(range, submitted_at, process_time)
  let p2 = in_phase2(range, submitted_at, process_time, retract_time)
  !(p1 && p2)
}

/// **Historic Lean reference `MpfsCage/Phases.lean` `phase1_phase3_exclusive` — binding MISSING (see header)**
///
/// Phase 1 and Phase 3 (rejectable via expiry) are mutually exclusive.
///
/// Phase 1 requires the range to be entirely before `submitted_at + process_time`.
/// Phase 3 (expiry path of `is_rejectable`) requires the range to be entirely
/// after `submitted_at + process_time + retract_time - 1`.
/// Since `process_time >= 1` and `retract_time >= 1`, there is always a gap
/// (Phase 2) between them.
///
/// If this property failed, the oracle could process a request that was
/// simultaneously rejectable — a folder could reject it and pocket
/// the fee while the oracle's work was wasted.
test prop_phase1_phase3_exclusive(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(
      fuzz.int_between(1, 50_000),
      fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000)),
    ),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let range = interval.between(lo, lo + span)
  let p1 = in_phase1(range, submitted_at, process_time)
  let p3 =
    interval.is_entirely_after(
      range,
      submitted_at + process_time + retract_time - 1,
    )
  !(p1 && p3)
}

/// **Historic Lean reference `MpfsCage/Phases.lean` `phase2_phase3_exclusive` — binding MISSING (see header)**
///
/// Phases 2 and 3 are mutually exclusive.
///
/// Phase 2 requires the range to be entirely before
/// `submitted_at + process_time + retract_time`.
/// Phase 3 requires it to be entirely after
/// `submitted_at + process_time + retract_time - 1`.
/// A range cannot be both before and after the same boundary.
///
/// If this property failed, a requester could Retract their request while
/// a folder simultaneously Rejects it — a race condition that would
/// let both parties claim the same ADA.
test prop_phase2_phase3_exclusive(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(
      fuzz.int_between(1, 50_000),
      fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000)),
    ),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let range = interval.between(lo, lo + span)
  let p2 = in_phase2(range, submitted_at, process_time, retract_time)
  let p3 =
    interval.is_entirely_after(
      range,
      submitted_at + process_time + retract_time - 1,
    )
  !(p2 && p3)
}

/// **Historic Lean reference `MpfsCage/Phases.lean` `phase1_honest_not_rejectable` — binding MISSING (see header)**
///
/// An honest request (submitted_at <= range_start) in Phase 1 can never
/// be rejected.
///
/// "Honest" means the requester didn't lie about their submission time —
/// `submitted_at` is at or before the validity range start. Under this
/// assumption, if the request is in Phase 1 (oracle is still processing),
/// `is_rejectable` must return false.
///
/// This is a critical safety property: it guarantees that honest requesters
/// who submitted during the processing window can never have their requests
/// prematurely rejected. The oracle has the full `process_time` window to
/// fold the request into the MPF without interference.
///
/// The fuzzer clamps `submitted_at` to `min(submitted_at, lo)` to enforce
/// the honesty precondition.
test prop_phase1_honest_not_rejectable(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(
      fuzz.int_between(1, 50_000),
      fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000)),
    ),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  // Enforce honesty: submitted_at <= lo
  let honest_submitted =
    if submitted_at <= lo {
      submitted_at
    } else {
      lo
    }
  let range = interval.between(lo, lo + span)
  let p1 = in_phase1(range, honest_submitted, process_time)
  let rej = is_rejectable(range, honest_submitted, process_time, retract_time)
  !(p1 && rej)
}

/// **Historic Lean reference `MpfsCage/Phases.lean` `phase2_honest_not_rejectable` — binding MISSING (see header)**
///
/// An honest request in Phase 2 (retract window) can never be rejected.
///
/// Same honesty assumption as above. If a request is in Phase 2, the
/// requester has the exclusive right to Retract it. No folder can
/// Reject it during this window.
///
/// This protects requesters from a race: without this property, a folder
/// could Reject a request during the retract window, stealing the
/// requester's chance to reclaim their full ADA (rejection only refunds
/// ADA minus fee, while retraction returns everything).
test prop_phase2_honest_not_rejectable(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(
      fuzz.int_between(1, 50_000),
      fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000)),
    ),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let honest_submitted =
    if submitted_at <= lo {
      submitted_at
    } else {
      lo
    }
  let range = interval.between(lo, lo + span)
  let p2 = in_phase2(range, honest_submitted, process_time, retract_time)
  let rej = is_rejectable(range, honest_submitted, process_time, retract_time)
  !(p2 && rej)
}

/// **Historic Lean reference `MpfsCage/Phases.lean` `phase_coverage_point` — binding MISSING (see header)**
///
/// For any single-slot validity range [t, t+1) with an honest timestamp
/// (submitted_at = 0), at least one of {Phase 1, Phase 2, rejectable} holds.
///
/// This is the completeness property: the three phases cover the entire
/// timeline with no gaps. At every point in time, some action is available
/// for an honest request — it's either being processed (Phase 1), retractable
/// (Phase 2), or rejectable (Phase 3).
///
/// Without this property, there could be "dead zones" where a request is
/// stuck: the oracle can't process it, the requester can't retract it, and
/// no folder can reject it — locking the ADA forever.
///
/// Uses a point range [t, t+1) rather than an arbitrary range because
/// coverage for intervals follows from coverage for points (if every point
/// is covered, every interval touching that point is in at least one phase).
test prop_phase_coverage_point(
  params via fuzz.tuple(
    fuzz.int_between(0, 100_000),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.int_between(1, 50_000)),
  ),
) {
  let (t, (process_time, retract_time)) = params
  // honest: submitted_at = 0 <= t (always true since t >= 0)
  let submitted_at = 0
  let range = interval.between(t, t + 1)
  let p1 = in_phase1(range, submitted_at, process_time)
  let p2 = in_phase2(range, submitted_at, process_time, retract_time)
  let rej = is_rejectable(range, submitted_at, process_time, retract_time)
  p1 || p2 || rej
}

// ============================================================================
// A reject carries no admission (Lean `exitAdmission .reject = none`, #320)
//
// These properties run the validators themselves, not a phase helper.
// ============================================================================

/// A validity range of any shape: finite, from a point on, up to a point, or
/// unbounded, with its points across all three windows of `feeRequestInput`
/// (processing `[0, 10_000)`, retraction `[10_000, 20_000)`, then after).
fn anyValidityRange() -> Fuzzer<Interval<Int>> {
  fuzz.either4(
    fuzz.map2(
      fuzz.int_between(0, 40_000),
      fuzz.int_between(0, 30_000),
      fn(lo, span) { interval.between(lo, lo + span) },
    ),
    fuzz.map(fuzz.int_between(0, 40_000), interval.after),
    fuzz.map(fuzz.int_between(0, 40_000), interval.before),
    fuzz.constant(interval.everything),
  )
}

/// The state purpose admits a one-request reject refunding its owner, whatever
/// the transaction's validity range.
test prop_reject_admitted_for_every_validity_range(range via anyValidityRange()) {
  state.state.spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: range,
      outputs: [rejectedStateOutput, refundOutput],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// A validity range that does not lie entirely in the processing window of
/// the `update` state and the requests below (`submitted_at` 0, processing
/// time 10_000).
fn outsideProcessing() -> Fuzzer<Interval<Int>> {
  fuzz.either3(
    fuzz.map2(
      fuzz.int_between(10_000, 30_000),
      fuzz.int_between(0, 20_000),
      fn(lo, span) { interval.between(lo, lo + span) },
    ),
    fuzz.map(fuzz.int_between(10_000, 40_000), interval.after),
    fuzz.constant(interval.everything),
  )
}

/// The `index`-th pending request of this registry.
fn pendingRequest(index: Int) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"52455155455354",
      output_index: index,
    },
    output: request.output,
  }
}

/// An input the fold does not pair with an action: a wallet's.
const walletInput =
  Input {
    output_reference: OutputReference {
      transaction_id: #"57414c4c4554",
      output_index: 0,
    },
    output: Output {
      address: address.from_verification_key(#"77616c6c6574"),
      value: from_lovelace(5_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }

/// Another input the fold does not pair: another registry's request.
const foreignRequest =
  Input {
    output_reference: OutputReference {
      transaction_id: #"464f524549474e",
      output_index: 0,
    },
    output: Output {
      ..request.output,
      datum: InlineDatum(
        RequestDatum(
          Request {
            requestToken: TokenId { assetName: "another_registry" },
            requestKey: "42",
            edge: 1,
            requestOwner: "owner",
            deposit: 0,
            submitted_at: 0,
            destination: noDestination,
          },
        ),
      ),
    },
  }

/// One to four requests of this registry, each paired with a reject or an
/// update in input order, with a wallet input and another registry's request
/// after the first; the position of one request the fold rejects; and a
/// validity range outside the processing window.
fn pairingCase() -> Fuzzer<(List<Data>, Int, List<Input>, Interval<Int>)> {
  let flags <- fuzz.and_then(fuzz.list_between(fuzz.bool(), 1, 4))
  let pick <- fuzz.and_then(fuzz.int_between(0, 3))
  let range <- fuzz.map(outsideProcessing())
  let rejected = pick % list.length(flags)
  let actions =
    list.indexed_map(
      flags,
      fn(i, flag) {
        if i == rejected || flag {
          rejectedActionData()
        } else {
          updateActionData()
        }
      },
    )
  let inputs =
    list.concat(
      [update],
      list.flat_map(
        list.indexed_map(flags, fn(i, _) { i }),
        fn(i) {
          if i == 0 {
            [pendingRequest(i), walletInput, foreignRequest]
          } else {
            [pendingRequest(i)]
          }
        },
      ),
    )
  (actions, rejected, inputs, range)
}

/// Outside the processing window the request purpose admits the request its
/// state's fold pairs with `Rejected`, wherever it sits among the requests,
/// whatever the other requests' actions (data model D-02). The refusing side,
/// a request paired with an update, is the `fail` tests of
/// `cage_contribute.tests.ak`.
test prop_request_admits_the_request_its_fold_rejects(case via pairingCase()) {
  let (actions, rejected, inputs, range) = case
  fuzz.label(
    if list.length(actions) == 1 {
      @"one request"
    } else {
      @"several requests"
    },
  )
  request_validator.request.spend(
    "policy_id",
    testToken.assetName,
    Some(
      RequestDatum(
        Request {
          requestToken: testToken,
          requestKey: "42",
          edge: 1,
          requestOwner: "owner",
          deposit: 0,
          submitted_at: 0,
          destination: noDestination,
        },
      ),
    ),
    Contribute(testStateRef),
    pendingRequest(rejected).output_reference,
    Transaction {
      ..transaction.placeholder,
      validity_range: range,
      inputs,
      redeemers: [stateSpendRedeemerData(modifyRedeemerData(actions))],
    },
  )
}

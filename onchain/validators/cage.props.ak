////// These fuzz tests verify, for randomly generated parameters, that:

use aiken/collection/list
use aiken/fuzz
use aiken/interval.{Interval}
use cage.{in_phase1, in_phase2}
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
///       |--- Phase 1 ---------|--- Phase 2 ---|--- after the windows --->
///       A folder folds         The owner
///       an update              can Retract
///   A folder can Reject in every window (#320).
/// ```
///
/// **Phase 1** (processing window): a folder folds an update into the MPF.
///   Updates are folded here only: current validator behaviour, with no
///   counterpart in Lean.
///
/// **Phase 2** (retraction window): the owner may Retract their unprocessed
///   request and reclaim their ADA.
///
/// **After the windows**: neither an update nor a retraction is admitted.
///
/// A reject reads no time (Lean `exitAdmission .reject = none`): it is
/// admitted in every window, which the validator-level properties at the end
/// of this module check against the validators themselves.
/// 1. The windows never overlap (mutual exclusion).
/// 2. Every point in time falls into one of them (coverage).
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
/// The processing window and the time after the windows are mutually
/// exclusive.
///
/// Phase 1 requires the range to be entirely before `submitted_at + process_time`.
/// After the windows requires it to be entirely after
/// `submitted_at + process_time + retract_time - 1`.
/// Since `process_time >= 1` and `retract_time >= 1`, there is always a gap
/// (Phase 2) between them.
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
/// The retraction window and the time after the windows are mutually
/// exclusive.
///
/// Phase 2 requires the range to be entirely before
/// `submitted_at + process_time + retract_time`.
/// After the windows requires it to be entirely after
/// `submitted_at + process_time + retract_time - 1`.
/// A range cannot be both before and after the same boundary.
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

/// **Historic Lean reference `MpfsCage/Phases.lean` `phase_coverage_point` — binding MISSING (see header)**
///
/// Every instant `t >= submitted_at` lies in exactly one of the processing
/// window, the retraction window or the time after them.
///
/// The range is the single instant `[t, t]`. A wider range can straddle a
/// boundary and lie in none of the three, which is why a reject must not
/// depend on them (#320): it is admitted whatever the range.
test prop_phase_coverage_point(
  params via fuzz.tuple(
    fuzz.int_between(0, 100_000),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.int_between(1, 50_000)),
  ),
) {
  let (t, (process_time, retract_time)) = params
  let submitted_at = 0
  let range = interval.between(t, t)
  let p1 = in_phase1(range, submitted_at, process_time)
  let p2 = in_phase2(range, submitted_at, process_time, retract_time)
  let p3 =
    interval.is_entirely_after(
      range,
      submitted_at + process_time + retract_time - 1,
    )
  p1 || p2 || p3
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

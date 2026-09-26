use aiken/builtin
use aiken/collection/list
use aiken/fuzz
use aiken/interval
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
// ============================================================================

use cage_fixtures.{
  aRequest, endRedeemerData, feeDelivery, legacyApproval, legacyDelivery,
  legacyDestination, legacyKey, legacyMint, legacyRoot, legacyWallet,
  modifyRedeemerData, noDestination, output, owner_fuzzer, phase1Range,
  phase2Range, phase3Range, rawStateDatum, rejectedActionData, request, state,
  stateDatum, stateSpendRedeemerData, testAbsentPolicy, testAppPolicy,
  testProcessTime, testRepPolicy, testRequestRef, testRetractTime,
  testScriptAddress, testSeed, testStakeScript, testStateRef, testTerminalPolicy,
  testToken, testValue, update, updateActionData, zfDelivery,
}
use cardano/address.{from_script}
use cardano/assets.{PolicyId, from_asset, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, ScriptPurpose, Spend,
  Transaction,
}
use lib.{assetName, valueFromToken}
use registry_fixtures as fx
use request as request_validator
use state as state_validator
use types.{
  Burning, CageDatum, Contribute, End, Migrating, Migration, MintRedeemer,
  Minting, Modify, Rejected, Request, RequestDatum, Retract, State, StateDatum,
  Sweep, TokenId, UpdateAction, UpdateRedeemer,
}

fn spend(
  maybeDatum: Option<CageDatum>,
  redeemer: UpdateRedeemer,
  self: OutputReference,
  tx: Transaction,
) -> Bool {
  when redeemer is {
    Contribute(_) | Retract(_) | Sweep(_) ->
      request_validator.request.spend(
        "policy_id",
        testToken.assetName,
        maybeDatum,
        redeemer,
        self,
        tx,
      )
    _ -> state_validator.state.spend(maybeDatum, redeemer, self, tx)
  }
}

// ============================================================================
// Retract tests
// ============================================================================

/// The request owner's key hash, as a 28-byte stand-in (Cardano ed25519
/// key hashes are 28 bytes, so this is a ledger-REPRESENTABLE signer).
/// The final byte 0x61 ('a') is what makes the generated non-owner
/// signers below structurally distinct from it.
const retractOwner: ByteArray = "the_real_owner_key_aaaaaaaaa"

/// A second, different 28-byte key hash for the paired refusal row.
const retractNotOwner: ByteArray = "the_real_owner_key_bbbbbbbbb"

fn retractRequest() -> CageDatum {
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "k",
      edge: 1,
      requestOwner: retractOwner,
      deposit: 0,
      submitted_at: 0,
      destination: noDestination,
    },
  )
}

fn signedRetractTx(signer: ByteArray) -> Transaction {
  let redeemer: Data = Retract(testStateRef)
  Transaction {
    ..transaction.placeholder,
    validity_range: phase2Range,
    extra_signatories: [signer],
    reference_inputs: [update],
    inputs: [
      Input {
        output_reference: testRequestRef,
        output: Output {
          address: testScriptAddress,
          value: from_lovelace(fx.requestLovelace),
          datum: InlineDatum(retractRequest()),
          reference_script: None,
        },
      },
    ],
    outputs: [boundPayment(testRequestRef, retractOwner, fx.requestLovelace)],
    redeemers: [Pair(Spend(testRequestRef), redeemer)],
  }
}

/// Happy path: the request owner retracts their own request during Phase 2.
/// Phase 2 is the exclusive retract window where only the requester can act.
/// The State UTxO is included as a reference input so the validator can read
/// the time params from its datum. This is the ACCEPTING control for the
/// authorization boundary below: same request, same phase, only the signer
/// differs. (Boundary note: the harness executes the script struct only —
/// a correctly sized key hash makes the shape ledger-representable, it does
/// not by itself establish a complete ledger transaction.)
test retract_happy() {
  spend(
    Some(retractRequest()),
    Retract(testStateRef),
    testRequestRef,
    signedRetractTx(retractOwner),
  )
}

/// Only the request owner can retract. A different signer must be rejected
/// to prevent theft of the request's locked ADA. Paired with `retract_happy`:
/// same request datum, same Phase 2 window, ONLY the signer changed
/// (`retractNotOwner` vs `retractOwner`, both 28-byte key hashes).
test retract_wrong_signer() fail {
  spend(
    Some(retractRequest()),
    Retract(testStateRef),
    testRequestRef,
    signedRetractTx(retractNotOwner),
  )
}

/// Before phase 2, the owner's retraction is refused with not-phase2.
/// Singular.Statements.retract_refusal_first_failing; the partner inside the
/// window is admitted by Singular.Statements.retract_admitted_iff.
test retract_in_phase1() {
  refusesPhaseRange(ledgerRange(0, fx.processTime / 2))
}

/// After phase 2, the owner's retraction is refused with not-phase2.
/// Singular.Statements.retract_refusal_first_failing; the partner inside the
/// window is admitted by Singular.Statements.retract_admitted_iff.
test retract_in_phase3() {
  refusesPhaseRange(
    ledgerRange(
      fx.processTime + fx.retractTime,
      fx.processTime + fx.retractTime + 1,
    ),
  )
}

// The script receives an included lower bound and an excluded upper bound.
fn ledgerRange(from: Int, to: Int) -> interval.Interval<Int> {
  interval.Interval {
    lower_bound: interval.IntervalBound {
      bound_type: interval.Finite(from),
      is_inclusive: True,
    },
    upper_bound: interval.IntervalBound {
      bound_type: interval.Finite(to),
      is_inclusive: False,
    },
  }
}

fn acceptsPhaseRange(range: interval.Interval<Int>) -> Bool {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let tx = retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace)])
  let accepted = Transaction { ..tx, validity_range: range }
  retractInput(input, accepted) == True && retractReason(input, accepted) == None
}

// Each refusal has a fully paid, owner-signed accepting partner. Only the
// validity interval changes; both production entry points judge both cases.
fn refusesPhaseRange(range: interval.Interval<Int>) -> Bool {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let tx = retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace)])
  let accepted =
    Transaction {
      ..tx,
      validity_range: ledgerRange(
        fx.processTime,
        fx.processTime + fx.retractTime,
      ),
    }
  let refused = Transaction { ..accepted, validity_range: range }
  retractInput(input, accepted) == True && retractReason(input, accepted) == None && retractInput(
    input,
    refused,
  ) == False && retractReason(input, refused) == Some(@"not-phase2")
}

/// The included lower bound may equal submission time plus processing time.
/// Singular.Statements.retract_admitted_iff.
test retract_at_phase2_lower_bound_accepts() {
  acceptsPhaseRange(ledgerRange(fx.processTime, fx.processTime + 1))
}

/// The excluded upper bound may reach the end of phase 2.
/// Singular.Statements.retract_admitted_iff.
test retract_at_phase2_upper_bound_accepts() {
  acceptsPhaseRange(
    ledgerRange(fx.processTime, fx.processTime + fx.retractTime),
  )
}

/// One unit before phase 2 is refused, with an otherwise identical partner.
/// Singular.Statements.retract_refusal_first_failing and
/// Singular.Statements.retract_admitted_iff.
test retract_one_unit_before_phase2_refuses() {
  refusesPhaseRange(
    ledgerRange(fx.processTime - 1, fx.processTime + fx.retractTime),
  )
}

/// One unit beyond the excluded upper bound is refused, with its partner.
/// Singular.Statements.retract_refusal_first_failing and
/// Singular.Statements.retract_admitted_iff.
test retract_one_unit_after_phase2_refuses() {
  refusesPhaseRange(
    ledgerRange(fx.processTime, fx.processTime + fx.retractTime + 1),
  )
}

/// No lower bound cannot lie inside phase 2; the finite partner is accepted.
/// Singular.Statements.retract_refusal_first_failing supplies the refusal
/// name, but its finite witness cannot express this open interval.
/// The partner instantiates Singular.Statements.retract_admitted_iff.
test retract_without_lower_bound_refuses() {
  let range = ledgerRange(fx.processTime, fx.processTime + fx.retractTime)
  refusesPhaseRange(
    interval.Interval {
      ..range,
      lower_bound: interval.IntervalBound {
        bound_type: interval.NegativeInfinity,
        is_inclusive: True,
      },
    },
  )
}

/// No upper bound cannot lie inside phase 2; the finite partner is accepted.
/// Singular.Statements.retract_refusal_first_failing supplies the refusal
/// name, but its finite witness cannot express this open interval.
/// The partner instantiates Singular.Statements.retract_admitted_iff.
test retract_without_upper_bound_refuses() {
  let range = ledgerRange(fx.processTime, fx.processTime + fx.retractTime)
  refusesPhaseRange(
    interval.Interval {
      ..range,
      upper_bound: interval.IntervalBound {
        bound_type: interval.PositiveInfinity,
        is_inclusive: False,
      },
    },
  )
}

/// **Retract refuses EVERY signer that is not the request owner — exact
/// `False` for each generated case** (historic name:
/// `prop_retract_requires_owner`, #197).
///
/// Owner and generated signers are BOTH 28-byte key hashes (Cardano
/// ed25519 key-hash size), so the property is about authorization between
/// valid representations, never about an impossible owner length. The
/// non-owner inequality is STRUCTURAL: each signer extends a fuzzed
/// 27-byte prefix with final byte 0xFF while the owner's final byte is
/// 0x61, so no generated case can be the owner and the property is
/// exclusively about non-owner authorization.
///
/// This asserts the validator's refusal EXACTLY (`== False`, the named
/// `retract-owner` refusal) for EVERY case. It replaced a `fail once`
/// existential that was satisfied by the first random refusal and so
/// kept passing while a mutated validator accepted a wrong signer whose
/// first byte was even (the #197 control evidence; the all-zero signer
/// was accepted and the old test still reported pass). The paired
/// accepting control is `retract_happy`: same request, same phase, only
/// the signer changed.
test prop_retract_refuses_every_non_owner_signer(
  prefix via fuzz.bytearray_fixed(27),
) {
  let signer = bytearray.concat(prefix, #[255])
  spend(
    Some(retractRequest()),
    Retract(testStateRef),
    testRequestRef,
    signedRetractTx(signer),
  ) == False
}

// Resolved request inputs and spending redeemers are present, as on the ledger.
// These fixtures exercise the request validator, not a connected lifecycle.
fn heldRequest(index: Int, owner: ByteArray, held: Int) -> Input {
  fx.deployedRequestInput(
    index,
    fx.keyA,
    1,
    owner,
    fx.noDestination(),
    zero,
    held,
  )
}

fn ownerPayment(owner: ByteArray, amount: Int) -> Output {
  boundPayment(heldRequest(0, owner, amount).output_reference, owner, amount)
}

fn boundPayment(ref: OutputReference, owner: ByteArray, amount: Int) -> Output {
  Output {
    address: address.from_verification_key(owner),
    value: from_lovelace(amount),
    datum: InlineDatum(ref),
    reference_script: None,
  }
}

fn retractTx(inputs: List<Input>, outputs: List<Output>) -> Transaction {
  let redeemer: Data = Retract(fx.stateRef)
  Transaction {
    ..transaction.placeholder,
    inputs,
    outputs,
    reference_inputs: [fx.stateInput(fx.emptyRoot())],
    validity_range: fx.phase2(),
    extra_signatories: [fx.bookerKey, fx.inserterKey],
    redeemers: list.map(
      inputs,
      fn(input) { Pair(Spend(input.output_reference), redeemer) },
    ),
  }
}

fn retractInput(input: Input, tx: Transaction) -> Bool {
  retractAt(input, fx.stateRef, tx)
}

fn retractAt(input: Input, stateRef: OutputReference, tx: Transaction) -> Bool {
  expect InlineDatum(raw) = input.output.datum
  expect RequestDatum(req): CageDatum = raw
  request_validator.request.spend(
    fx.cagePolicy,
    req.requestToken.assetName,
    Some(RequestDatum(req)),
    Retract(stateRef),
    input.output_reference,
    tx,
  )
}

test retract_held_exact_payment_accepts() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  retractInput(
    input,
    retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace)]),
  )
}

test retract_held_short_by_one_refuses() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  refusesHeld(
    input,
    retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace - 1)]),
  )
}

test retract_held_wrong_owner_refuses() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  refusesHeld(
    input,
    retractTx([input], [ownerPayment(fx.inserterKey, fx.requestLovelace)]),
  )
}

test retract_held_one_output_cannot_pay_two_requests() {
  let first = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let second = heldRequest(1, fx.bookerKey, fx.requestLovelace + 7)
  let tx =
    retractTx(
      [first, second],
      [ownerPayment(fx.bookerKey, fx.requestLovelace + 7)],
    )
  retractInput(first, tx) && refusesHeld(second, tx)
}

test retract_two_requests_with_bound_payments_accept() {
  let first = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let second = heldRequest(1, fx.bookerKey, fx.requestLovelace + 7)
  let tx =
    retractTx(
      [first, second],
      [
        boundPayment(first.output_reference, fx.bookerKey, fx.requestLovelace),
        boundPayment(
          second.output_reference,
          fx.bookerKey,
          fx.requestLovelace + 7,
        ),
      ],
    )
  retractInput(first, tx) && retractInput(second, tx)
}

test retract_wrong_reference_refuses() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let other = heldRequest(1, fx.bookerKey, fx.requestLovelace)
  refusesHeld(
    input,
    retractTx(
      [input],
      [boundPayment(other.output_reference, fx.bookerKey, fx.requestLovelace)],
    ),
  )
}

test retract_unbound_payment_refuses() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let payment = ownerPayment(fx.bookerKey, fx.requestLovelace)
  refusesHeld(input, retractTx([input], [Output { ..payment, datum: NoDatum }]))
}

// A-014 requires one sufficient bound output, not a sum of fragments.
test retract_split_bound_payments_refuse() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  refusesHeld(
    input,
    retractTx(
      [input],
      [
        ownerPayment(fx.bookerKey, fx.requestLovelace - 1),
        ownerPayment(fx.bookerKey, 1),
      ],
    ),
  )
}

test prop_retract_held_uses_input_lovelace(
  extra via fuzz.int_between(1, 1_000_000),
) {
  let held = fx.requestLovelace + extra
  let input = heldRequest(0, fx.bookerKey, held)
  retractInput(input, retractTx([input], [ownerPayment(fx.bookerKey, held)])) && refusesHeld(
    input,
    retractTx([input], [ownerPayment(fx.bookerKey, held - 1)]),
  )
}

fn retractReason(input: Input, tx: Transaction) -> Option<String> {
  expect InlineDatum(raw) = input.output.datum
  expect RequestDatum(req): CageDatum = raw
  request_validator.retractRefusal(
    fx.cagePolicy,
    req.requestToken,
    req,
    input.output_reference,
    fx.stateRef,
    tx,
  )
}

/// Check the complete production refusal path and the actual spend handler.
fn refusesHeld(input: Input, tx: Transaction) -> Bool {
  !retractInput(input, tx) && retractReason(input, tx) == Some(
    @"deposit-returned",
  )
}

test retract_held_does_not_replace_owner_admission() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let tx = retractTx([input], [])
  retractReason(input, Transaction { ..tx, extra_signatories: [] }) == Some(
    @"retract-owner",
  )
}

test retract_held_does_not_replace_edge_admission() {
  let input =
    fx.requestInput(
      0,
      fx.keyA,
      3,
      fx.bookerKey,
      fx.noDestination(),
      zero,
      fx.requestLovelace,
    )
  let tx = retractTx([input], [])
  retractReason(input, Transaction { ..tx, extra_signatories: [] }) == Some(
    @"withdraw-insert-only",
  )
}

/// The phase refusal precedes payment, even when no refund output exists.
/// Singular.Statements.retract_refusal_first_failing.
test retract_held_does_not_replace_phase_admission() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let tx = retractTx([input], [])
  let refused =
    Transaction { ..tx, validity_range: ledgerRange(0, fx.processTime / 2) }
  retractInput(input, refused) == False && retractReason(input, refused) == Some(
    @"not-phase2",
  ) && refusesHeld(
    input,
    Transaction {
      ..tx,
      validity_range: ledgerRange(
        fx.processTime,
        fx.processTime + fx.retractTime,
      ),
    },
  )
}

test retract_held_bound_overpayment_accepts() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  retractInput(
    input,
    retractTx(
      [input],
      [
        ownerPayment(fx.bookerKey, 1),
        ownerPayment(fx.bookerKey, fx.requestLovelace),
      ],
    ),
  )
}

test retract_held_different_owners_cannot_share_payment() {
  let first = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let second = heldRequest(1, fx.inserterKey, fx.requestLovelace + 7)
  let tx =
    retractTx(
      [first, second],
      [ownerPayment(fx.bookerKey, 2 * fx.requestLovelace + 7)],
    )
  retractInput(first, tx) && refusesHeld(second, tx)
}

test retract_held_other_redeemer_is_not_a_retraction() {
  let first = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let second = heldRequest(1, fx.bookerKey, fx.requestLovelace + 7)
  let tx =
    retractTx([first, second], [ownerPayment(fx.bookerKey, fx.requestLovelace)])
  let retract: Data = Retract(fx.stateRef)
  let contribute: Data = Contribute(fx.stateRef)
  retractInput(
    first,
    Transaction {
      ..tx,
      redeemers: [
        Pair(Spend(first.output_reference), retract),
        Pair(Spend(second.output_reference), contribute),
      ],
    },
  )
}

test retract_held_same_key_bytes_at_script_do_not_pay_owner() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let payment = ownerPayment(fx.bookerKey, fx.requestLovelace)
  refusesHeld(
    input,
    retractTx(
      [input],
      [Output { ..payment, address: from_script(fx.bookerKey) }],
    ),
  )
}

/// Distinct parameters and credentials are resolved-context fixtures, not
/// compiled hash proof. Both actual request handlers execute on the same tx.
test retract_two_registries_need_distinct_bound_payments() {
  let first = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let second = heldRequest(1, fx.bookerKey, fx.requestLovelace + 7)
  expect InlineDatum(raw) = second.output.datum
  expect RequestDatum(req): CageDatum = raw
  let other =
    Input {
      ..second,
      output: Output {
        ..second.output,
        address: from_script(fx.foreignPolicy),
        datum: InlineDatum(
          RequestDatum(Request { ..req, requestToken: fx.foreignCageToken }),
        ),
      },
    }
  let tx =
    retractTx(
      [first, other],
      [ownerPayment(fx.bookerKey, fx.requestLovelace + 7)],
    )
  let redeemer: Data = Retract(fx.foreignStateRef)
  let ownRedeemer: Data = Retract(fx.stateRef)
  let shared =
    Transaction {
      ..tx,
      reference_inputs: [
        fx.stateInput(fx.emptyRoot()),
        fx.foreignStateInput(fx.emptyRoot()),
      ],
      redeemers: [
        Pair(Spend(first.output_reference), ownRedeemer),
        Pair(Spend(other.output_reference), redeemer),
      ],
    }
  let distinct =
    Transaction {
      ..shared,
      outputs: [
        ownerPayment(fx.bookerKey, fx.requestLovelace),
        boundPayment(
          other.output_reference,
          fx.bookerKey,
          fx.requestLovelace + 7,
        ),
      ],
    }
  retractAt(first, fx.stateRef, shared) && !retractAt(
    other,
    fx.foreignStateRef,
    shared,
  ) && request_validator.retractRefusal(
    fx.cagePolicy,
    fx.foreignCageToken,
    Request { ..req, requestToken: fx.foreignCageToken },
    other.output_reference,
    fx.foreignStateRef,
    shared,
  ) == Some(@"deposit-returned") && retractAt(first, fx.stateRef, distinct) && retractAt(
    other,
    fx.foreignStateRef,
    distinct,
  )
}

fn refusesStateSpend(input: Input, tx: Transaction) -> Bool {
  !retractInput(input, tx) && retractReason(input, tx) == Some(
    @"retract-state-spent",
  )
}

test retract_other_script_purposes_do_not_count_as_spends() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let tx = retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace)])
  let modify: Data = Modify([])
  retractInput(
    input,
    Transaction {
      ..tx,
      redeemers: [
        Pair(transaction.Mint(fx.foreignPolicy), modify),
        ..tx.redeemers
      ],
    },
  )
}

// A wire encoding alone does not identify an input as a registry request or
// state. These unrelated inputs carry neither a registry datum nor its token.
fn retractBesideUnrelatedSpend(redeemer: Data) -> Bool {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let other = heldRequest(1, fx.bookerKey, fx.requestLovelace)
  let unrelated =
    Input {
      ..other,
      output: Output {
        ..other.output,
        address: from_script(fx.foreignPolicy),
        datum: NoDatum,
      },
    }
  let tx = retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace)])
  retractInput(
    input,
    Transaction {
      ..tx,
      inputs: [input, unrelated],
      redeemers: [
        Pair(Spend(unrelated.output_reference), redeemer),
        ..tx.redeemers
      ],
    },
  )
}

test retract_unrelated_spend_with_retract_bytes_is_accepted() {
  let redeemer: Data = Retract(fx.stateRef)
  retractBesideUnrelatedSpend(redeemer)
}

test retract_unrelated_spend_with_modify_bytes_is_accepted() {
  let redeemer: Data = Modify([])
  retractBesideUnrelatedSpend(redeemer)
}

test retract_beside_a_fold_refuses() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let st = fx.foreignStateInput(fx.emptyRoot())
  let tx = retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace)])
  let modify: Data = Modify([])
  refusesStateSpend(
    input,
    Transaction {
      ..tx,
      inputs: [input, st],
      redeemers: [Pair(Spend(st.output_reference), modify), ..tx.redeemers],
    },
  )
}

// The policy-token rule is independent of address, datum and redeemer.
test retract_state_policy_token_without_modify_refuses() {
  let input = heldRequest(0, fx.bookerKey, fx.requestLovelace)
  let other = heldRequest(1, fx.bookerKey, fx.requestLovelace)
  let tokenInput =
    Input {
      ..other,
      output: Output {
        ..other.output,
        address: fx.addressOf(fx.bookerAddress),
        datum: NoDatum,
        value: from_asset(fx.cagePolicy, "another_registry", 1),
      },
    }
  let tx = retractTx([input], [ownerPayment(fx.bookerKey, fx.requestLovelace)])
  refusesStateSpend(input, Transaction { ..tx, inputs: [input, tokenInput] })
}

/// Main's state-token check prevents two registry folds sharing a continuation.
/// The second state input is authentic, with a different registry token.
test retract_safety_two_registry_fold_refuses_state_token() {
  let first = fx.stateInput(fx.emptyRoot())
  let second = fx.foreignStateInput(fx.emptyRoot())
  let modify: Data = Modify([])
  let tx =
    Transaction {
      ..transaction.placeholder,
      inputs: [first, second],
      outputs: [fx.stateOutput(fx.emptyRoot())],
      redeemers: [
        Pair(Spend(first.output_reference), modify),
        Pair(Spend(second.output_reference), modify),
      ],
    }
  state_validator.modifyRefusal(fx.stateOf(fx.emptyRoot()), [], second, tx) == Some(
    @"state-token",
  ) && !state_validator.state.spend(
    Some(StateDatum(fx.stateOf(fx.emptyRoot()))),
    Modify([]),
    second.output_reference,
    tx,
  )
}

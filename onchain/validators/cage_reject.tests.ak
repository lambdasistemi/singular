use aiken/builtin
use aiken/fuzz
use aiken/interval
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{from_script}
use cardano/assets.{PolicyId, from_asset, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, ScriptPurpose, Spend,
  Transaction,
}
use lib
use lib.{assetName, valueFromToken}
use request as request_validator
use state as state_validator
use types.{
  Burning, CageDatum, Contribute, End, Migrating, Migration, MintRedeemer,
  TokenId,
  Minting, Modify, Rejected, Request, RequestDatum, Retract, State, StateDatum,
  Sweep, UpdateAction, UpdateRedeemer,
}

use cage_fixtures.{
  aRequest, burn_value, capturedMinUtxoRefundOutput, capturedRefundRequestInput,
  capturedRefundStateDatum, capturedRefundStateInput, capturedRefundStateOutput,
  capturedRefundTxFee, endRedeemerData, feeDelivery, feeRequestInput,
  feeStateDatum, feeStateInput, legacyApproval, legacyDelivery,
  legacyDestination, legacyKey, legacyMint, legacyRoot, legacyWallet,
  modifyRedeemerData, noDestination, output, owner_fuzzer, refundOutput,
  phase1Range, phase2Range, phase3Range, rawStateDatum, rejectedActionData,
  request, state, stateDatum, stateSpendRedeemerData,
  testAbsentPolicy, testAppPolicy, testFee, testProcessTime, testRepPolicy,
  testRequestRef, testScriptAddress, testSeed, testStakeScript, testStateRef,
  testRetractTime, testTerminalPolicy, testToken, testValue, update,
  topupSmallRequestInput, updateActionData, zfDelivery,
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
// Reject tests (via Modify with Rejected actions)
//
// Rejection is now expressed as Modify([Rejected, ...]). The MPF root must
// NOT change — rejected requests are never folded in. Refunds are still owed.
// ============================================================================

const rejectStateOutput =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          root: root(mpf.empty),
          tip: testFee,
          process_time: testProcessTime,
          retract_time: testRetractTime,
          application_policy: testAppPolicy,
          active_policy: testRepPolicy,
          absent_policy: testAbsentPolicy,
          terminal_policy: testTerminalPolicy
        },
      ),
    ),
    reference_script: None,
  }

/// Happy path: reject an expired request in Phase 3.
/// Root stays the same, requester gets refunded (input ADA minus fee).
test reject_happy() {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Reject is forbidden in Phase 1 — requests are still being processed.
test reject_in_phase1() fail {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Reject is forbidden in Phase 2 — the retract window belongs exclusively
/// to the requester. The cage owner must wait for Phase 3.
test reject_in_phase2() fail {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// A request with submitted_at far in the future is dishonest — rejectable
/// in ANY phase because `is_rejectable` returns true when `validity_range < submitted_at`.
test reject_future_submitted_at() {
  let future_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        edge: 1,
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        deposit: 1_500_000,
        submitted_at: 100_000,
        destination: noDestination,
      },
    )
  let future_request_input =
    Input {
      output_reference: testRequestRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(2_000_000),
        datum: InlineDatum(future_request),
        reference_script: None,
      },
    }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, future_request_input],
    },
  )
}

/// Only the state owner can End the cage (re-cut under issue #79; was
/// `reject_missing_signature`, which asserted an owner refusal for a
/// Phase-3 `Modify`). The owner-authorization obligation now lives only
/// on `End`, so the refusal moved here: a non-owner signer attempting to
/// burn the cage token is refused. (The empty-signers variant is
/// `end_missing_signature`, which still holds unchanged.)
test end_wrong_signer() fail {
  spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["someone_else"],
      inputs: [update],
      mint: burn_value,
    },
  )
}

/// The MPF root must NOT change during rejection.
test reject_root_changes() fail {
  let bad_reject_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(
          State {
            root: "different_root_aaaaaaaaaaaaa",
            tip: testFee,
            process_time: testProcessTime,
            retract_time: testRetractTime,
            application_policy: testAppPolicy,
            active_policy: testRepPolicy,
            absent_policy: testAbsentPolicy,
            terminal_policy: testTerminalPolicy
          },
        ),
      ),
      reference_script: None,
    }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [bad_reject_output, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Even rejected requests must have their ADA refunded (minus fee).
test reject_wrong_refund() fail {
  let bad_refund = Output { ..refundOutput, value: from_lovelace(500_000) }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectStateOutput, bad_refund],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

test reject_refund_owed_above_min_utxo_passes() {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Captures the live failure shape: owed is 731_158 lovelace after fee and
/// tip, but the ledger-valid refund output must carry 849_070 lovelace.
test reject_refund_min_utxo_topup_passes() {
  spend(
    capturedRefundStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      fee: capturedRefundTxFee,
      validity_range: phase3Range,
      outputs: [capturedRefundStateOutput, capturedMinUtxoRefundOutput],
      extra_signatories: ["owner"],
      inputs: [capturedRefundStateInput, topupSmallRequestInput],
    },
  )
}

test reject_refund_under_owed_fails() fail {
  let under_refund =
    Output { ..capturedMinUtxoRefundOutput, value: from_lovelace(731_157) }
  spend(
    capturedRefundStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      fee: capturedRefundTxFee,
      validity_range: phase3Range,
      outputs: [capturedRefundStateOutput, under_refund],
      extra_signatories: ["owner"],
      inputs: [capturedRefundStateInput, capturedRefundRequestInput],
    },
  )
}

test reject_refund_topup_cannot_drain_state() fail {
  let drained_state = Output { ..capturedRefundStateOutput, value: testValue }
  spend(
    capturedRefundStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      fee: capturedRefundTxFee,
      validity_range: phase3Range,
      outputs: [drained_state, capturedMinUtxoRefundOutput],
      extra_signatories: ["owner"],
      inputs: [capturedRefundStateInput, capturedRefundRequestInput],
    },
  )
}

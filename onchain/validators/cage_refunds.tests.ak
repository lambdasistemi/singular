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
  aRequest, endRedeemerData, feeApproval, feeDelivery, feeOwner,
  feeRequestInput, feeStateDatum, feeStateInput, feeStateOutput, legacyApproval,
  legacyDelivery,
  legacyDestination, legacyKey, legacyMint, legacyRoot, legacyWallet,
  modifyRedeemerData, noDestination, output, owner_fuzzer, refundOutput,
  rejectedStateOutput,
  phase1Range, phase2Range, phase3Range, rawStateDatum, rejectedActionData,
  request, state, stateDatum, stateSpendRedeemerData,
  testAbsentPolicy, testAppPolicy, testProcessTime, testRepPolicy,
  testRequestRef, testScriptAddress, testSeed, testStakeScript, testStateRef,
  testRetractTime, testTerminalPolicy, testToken, testValue, update,
  updateActionData, zfDelivery,
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
// Refund enforcement tests (NOTE-014 item A2 as corrected by NOTE-017)
//
// Only REJECTED rows are owed refunds: input lovelace less tip each, no fee
// share deducted and none invented. Processed rows carry no generic refund
// expectation: admission shapes below are permitted, never endorsed (the
// pinned consumer hook judges allocations, locking included). Per-owner
// floors catch crossed allocations aggregates cannot see; min-UTxO top-ups
// from funding inputs may only add.
// ============================================================================

/// Second rejected row for the crossed-amounts control (NOTE-014 item A2):
/// distinct key, owner and outref; 3M lovelace at the 500k fee-state tip so
/// 2.5M is owed — unequal to the first row's 1.5M, which is what makes the
/// cross detectable while credentials pass and totals match.
const crossedRequestRef =
  OutputReference { transaction_id: "2234567890abcdef", output_index: 253 }

const crossedRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "43",
      edge: 1,
      requestOwner: "requester_key_bbbbbbbbbbbbbbb",
      deposit: 2_500_000,
      submitted_at: 0,
      destination: noDestination,
    },
  )

const crossedRequestInput =
  Input {
    output_reference: crossedRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(3_000_000),
      datum: InlineDatum(crossedRequest),
      reference_script: None,
    },
  }

const crossedRefundB =
  Output {
    address: address.from_verification_key("requester_key_bbbbbbbbbbbbbbb"),
    value: from_lovelace(2_500_000),
    datum: NoDatum,
    reference_script: None,
  }

/// Processed rows carry no generic refund expectation (NOTE-017): this
/// accepted shape shows admission, not endorsement — the bond shown refunded
/// here is permitted by the generic side and judged by the pinned consumer.
/// Happy path: Modify with fee. Request has 2 ADA, fee is 0.5 ADA,
/// so refund of 1.5 ADA goes to the requester's address.
test modify_with_refund() {
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, refundOutput, feeDelivery],
      mint: legacyMint,
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// A refund output must be present for each REJECTED request, carrying at
/// least exactly what is owed (input lovelace less tip). Omitting it with
/// rejected rows present fails the output shape — nothing here can be
/// confused with a processed lock (which carries no refund at all).
test modify_missing_refund() fail {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectedStateOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Each rejected refund must carry at least its row's exact owed amount
/// (input lovelace less tip — 1.5 ADA here). Underpaying shortchanges the
/// requester even when every other row is exact.
test modify_insufficient_refund() fail {
  let bad_refund = Output { ..refundOutput, value: from_lovelace(1_000_000) }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectedStateOutput, bad_refund],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Each rejected refund must go to the request owner's address: the
/// credential check is per row, so sending an otherwise-exact refund
/// elsewhere refuses even with matching totals.
test modify_wrong_refund_address() fail {
  let wrong_addr_refund =
    Output {
      ..refundOutput,
      address: address.from_verification_key("wrong_key_aaaaaaaaaaaaaaaa"),
    }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectedStateOutput, wrong_addr_refund],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Two rejected rows paid exactly (NOTE-014 item A2): the honest twin of the
/// crossed control below — same inputs, same totals, correct positions.
/// If this does not accept, the crossed refusal proves nothing.
test modify_two_rejected_exact_accepts() {
  spend(
    feeStateDatum,
    Modify([Rejected, Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectedStateOutput, refundOutput, crossedRefundB],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput, crossedRequestInput],
    },
  )
}

/// Crossed allocations (NOTE-014 item A2 control): two rejected rows with
/// unequal oweds (1.5M and 2.5M), every credential passing and totals
/// matching, but each owner receiving the other's amount. The underpaid row
/// fails its floor — the case aggregate-only checking cannot see.
test modify_crossed_amounts_refused() fail {
  spend(
    feeStateDatum,
    Modify([Rejected, Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectedStateOutput, crossedRefundB, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput, crossedRequestInput],
    },
  )
}

/// When tip is 0 the bonded value routes visibly (NOTE-017: generic
/// admission — the consumer judges the allocation, not this test).
test modify_zero_fee() {
  let zf_state =
    State {
      root: root(mpf.empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
      application_policy: testAppPolicy,
      active_policy: testRepPolicy,
      absent_policy: testAbsentPolicy,
      terminal_policy: testTerminalPolicy
    }
  let zf_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: legacyKey,
        edge: 1,
        requestOwner: feeOwner,
        deposit: 2_000_000,
        submitted_at: 0,
        destination: legacyDestination,
      },
    )
  let zf_request_input =
    Input {
      output_reference: testRequestRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(2_000_000) |> assets.merge(feeApproval),
        datum: InlineDatum(zf_request),
        reference_script: None,
      },
    }
  let zf_state_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(zf_state)),
        reference_script: None,
      },
    }
  let zf_state_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(
          State {
            root: legacyRoot,
            tip: 0,
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
  let zf_refund =
    Output {
      address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
      value: from_lovelace(2_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  spend(
    Some(StateDatum(zf_state)),
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [zf_state_output, zf_refund, zfDelivery],
      mint: legacyMint,
      extra_signatories: ["owner"],
      inputs: [zf_state_input, zf_request_input],
    },
  )
}

/// The request's deposit must match its holding less the state's tip.
/// `tip-mismatch` retired with the tip field (#183 slice b): a request
/// created for a different fee tier is refused `deposit-mismatch` (or
/// `tip-coverage` when its holding does not even reach the tip).
test modify_deposit_mismatch() fail {
  let mismatch_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        edge: 1,
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        deposit: 100_000,
        submitted_at: 0,
        destination: noDestination,
      },
    )
  let mismatch_input =
    Input {
      output_reference: testRequestRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(2_000_000),
        datum: InlineDatum(mismatch_request),
        reference_script: None,
      },
    }
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, mismatch_input],
    },
  )
}

/// A request whose holding does not reach the state's tip is refused
/// `tip-coverage`: costless fabricated requests would otherwise fold
/// for free.
test modify_tip_coverage() fail {
  let thin_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        edge: 1,
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        deposit: 0,
        submitted_at: 0,
        destination: noDestination,
      },
    )
  let thin_input =
    Input {
      output_reference: testRequestRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(0),
        datum: InlineDatum(thin_request),
        reference_script: None,
      },
    }
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, thin_input],
    },
  )
}

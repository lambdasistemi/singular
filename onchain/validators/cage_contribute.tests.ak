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
  aRequest, endRedeemerData, feeDelivery, legacyApproval, legacyDelivery,
  legacyDestination, legacyKey, legacyMint, legacyRoot, legacyWallet,
  modifyRedeemerData, noDestination, output, owner_fuzzer,
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
// Contribute tests
// ============================================================================

/// A Contribute must reference a State UTxO whose token matches the request's
/// `requestToken`. A mismatch means the request targets a different cage.
test contribute_wrong_token() fail {
  let wrong_request =
    RequestDatum(
      Request {
        requestToken: TokenId { assetName: "different_asset" },
        requestKey: "42",
        edge: 1,
        requestOwner: "owner",
        deposit: 0,
        submitted_at: 0,
        destination: noDestination,
      },
    )
  spend(
    Some(wrong_request),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [update, request],
    },
  )
}

/// The State UTxO referenced by Contribute must actually exist in the inputs.
/// Without this, the request-token binding can't be verified.
test contribute_missing_ref() fail {
  let missing_ref =
    OutputReference { transaction_id: "nonexistent", output_index: 0 }
  spend(
    Some(aRequest),
    Contribute(missing_ref),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [update, request],
    },
  )
}

/// Contribute must consume the state UTxO in the same transaction. A reference
/// input is not enough because request consumption must be paired with state
/// Modify and its refund equation.
test contribute_reference_only_state_rejected() fail {
  spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [request],
      reference_inputs: [update],
    },
  )
}

/// The referenced state UTxO must carry the cage token under the state policy,
/// not merely a same-asset token under a foreign policy.
test contribute_rejects_foreign_policy_state_same_asset() fail {
  let fake_state_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: valueFromToken("foreign_policy", testToken),
        datum: InlineDatum(rawStateDatum),
        reference_script: None,
      },
    }
  spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [fake_state_input, request],
    },
  )
}

/// Contribute is forbidden in Phase 2 (the retract window).
/// During Phase 2, only the requester can act on their request (via Retract).
test contribute_in_phase2() fail {
  spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      inputs: [update, request],
    },
  )
}

/// Contribute IS allowed in Phase 3 (rejectable window).
/// This lets the oracle process late requests alongside a Reject operation.
test contribute_in_phase3() {
  spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      inputs: [update, request],
      redeemers: [
        stateSpendRedeemerData(modifyRedeemerData([rejectedActionData()])),
      ],
    },
  )
}

/// Contribute must be paired with state `Modify`, not merely any state spend.
/// Otherwise request UTxOs could be consumed without folding them,
/// bypassing the refund equation.
test contribute_with_state_end_rejected() fail {
  spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [update, request],
      redeemers: [stateSpendRedeemerData(endRedeemerData())],
    },
  )
}

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
  aRequest, burn_value, endRedeemerData, feeDelivery, legacyApproval, legacyDelivery,
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
// Datum-redeemer mismatch tests
//
// These verify that each redeemer can only be used with the correct datum
// type. Retract/Contribute require RequestDatum; Modify/End require StateDatum.
// Using the wrong combination must fail, preventing operations on the wrong
// kind of UTxO.
// ============================================================================

/// Retract requires a RequestDatum. Using it on a StateDatum must fail —
/// you can't retract a cage's state, only a pending request.
test retract_on_state_datum() fail {
  spend(
    stateDatum,
    Retract(testStateRef),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: ["owner"],
      reference_inputs: [update],
    },
  )
}

/// Contribute requires a RequestDatum. Using it on a StateDatum must fail —
/// you can't contribute a cage's state, only link a request to a cage.
test contribute_on_state_datum() fail {
  spend(
    stateDatum,
    Contribute(testStateRef),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [update],
    },
  )
}

/// Modify requires a StateDatum. Using it on a RequestDatum must fail —
/// you can't modify a request's MPF root (requests don't have one).
test modify_on_request_datum() fail {
  spend(
    Some(aRequest),
    Modify([]),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      extra_signatories: ["owner"],
      inputs: [request],
    },
  )
}

/// End requires a StateDatum. Using it on a RequestDatum must fail —
/// you can only burn the cage's token from a State UTxO.
test end_on_request_datum() fail {
  spend(
    Some(aRequest),
    End,
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [request],
      mint: burn_value,
    },
  )
}


// ============================================================================
// Edge cases
// ============================================================================

/// Spending a UTxO with no datum must fail immediately. All cage UTxOs
/// (both State and Request) require inline datums. This catches ADA sent
/// to the script without a datum.
test spend_no_datum() fail {
  spend(None, Retract(testStateRef), testRequestRef, transaction.placeholder)
}

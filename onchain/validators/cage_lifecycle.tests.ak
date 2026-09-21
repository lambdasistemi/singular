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
// Core happy-path test
// ============================================================================

/// End-to-end happy path: Modify a cage (fold one Insert request into the MPF)
/// and Contribute a request to a cage, both in Phase 1. Verifies both the
/// spending validator's Modify and Contribute paths accept valid transactions.
test canCage() {
  spend(
    stateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output, legacyDelivery],
      mint: legacyMint,
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  ) && spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [update, request],
      redeemers: [
        stateSpendRedeemerData(modifyRedeemerData([updateActionData()])),
      ],
    },
  )
}

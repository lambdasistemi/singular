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

fn mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) -> Bool {
  state_validator.state.mint(redeemer, policyId, tx)
}

// ============================================================================
// Per-token isolation
//
// Two distinct seeds derive distinct cage token asset names. Request validator
// instances are parameterized by the state policy id plus one cage token.
// ============================================================================

/// Two distinct seeds produce distinct token ids.
test two_seeds_distinct_tokens() {
  let seed1 =
    OutputReference { transaction_id: "aaaa567890abcdef", output_index: 1 }
  let seed2 =
    OutputReference { transaction_id: "bbbb567890abcdef", output_index: 2 }
  assetName(seed1) != assetName(seed2)
}

/// A request validator instance parameterized by a different cage token must
/// reject a request for this cage.
test wrong_request_parameter_rejects_this_cage_token() fail {
  request_validator.request.spend(
    "policy_id",
    "different_asset",
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

// ===========================================================================
// Ownerless registry (operator ruling NOTE-028/A-003, issue #77 repair)
// ===========================================================================
//
// Destructive paths executable before the repair now refuse: neither the
// registry's creator nor any other party can terminate, migrate or seize
// registry authority through any inherited operation.

/// Burning the caged token through the mint purpose — refused: it destroys
/// the registry without touching End at all. Neither the registry's
/// creator nor any other party can terminate through `Burning`.
test burning_token_refuses() fail {
  mint(
    Burning(testToken),
    "policy_id",
    Transaction {
      ..transaction.placeholder,
      mint: burn_value,
    },
  )
}

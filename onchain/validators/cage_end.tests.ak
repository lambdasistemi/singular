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
// End tests
// ============================================================================

/// Owner-signed End — refused (operator ruling NOTE-028/A-003, issue #77
/// repair): there is no registry-owner role, so no signature authorizes
/// termination. Neither the registry's creator nor any other party can
/// terminate through `End`.
test end_owner_signed_refuses() fail {
  spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [update],
      mint: burn_value,
    },
  )
}

/// Only the cage owner can End the cage. Without this, anyone could burn
/// someone else's caged token and destroy their data.
test end_missing_signature() fail {
  spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: [],
      inputs: [update],
      mint: burn_value,
    },
  )
}

/// The mint field must burn THIS token (matching asset name), not some other
/// token under the same policy. Burning the wrong token would leave the
/// cage's token in limbo.
test end_wrong_token_in_mint() fail {
  let wrong_burn = valueFromToken("policy_id", TokenId { assetName: "wrong" })
  spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [update],
      mint: wrong_burn,
    },
  )
}

/// Modify must reject a fake StateDatum carrying a foreign-policy NFT, even
/// when that NFT has the same asset name as the cage token.
test modify_rejects_foreign_policy_same_asset() fail {
  let fake_state =
    State {
      root: root(empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
      application_policy: testAppPolicy,
      active_policy: testRepPolicy,
      absent_policy: testAbsentPolicy,
      terminal_policy: testTerminalPolicy
    }
  let foreign_value = valueFromToken("foreign_policy", testToken)
  let fake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: foreign_value,
        datum: InlineDatum(StateDatum(fake_state)),
        reference_script: None,
      },
    }
  let fake_output =
    Output {
      address: testScriptAddress,
      value: foreign_value,
      datum: InlineDatum(StateDatum(fake_state)),
      reference_script: None,
    }
  spend(
    Some(StateDatum(fake_state)),
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [fake_output],
      extra_signatories: ["attacker"],
      inputs: [fake_input],
    },
  )
}

/// End must reject a fake StateDatum carrying a foreign-policy NFT, even when
/// the transaction also includes a burn under the cage policy for the same
/// asset name.
test end_rejects_foreign_policy_same_asset() fail {
  let fake_state =
    State {
      root: root(empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
      application_policy: testAppPolicy,
      active_policy: testRepPolicy,
      absent_policy: testAbsentPolicy,
      terminal_policy: testTerminalPolicy
    }
  let foreign_value = valueFromToken("foreign_policy", testToken)
  let fake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: foreign_value,
        datum: InlineDatum(StateDatum(fake_state)),
        reference_script: None,
      },
    }
  spend(
    Some(StateDatum(fake_state)),
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["attacker"],
      inputs: [fake_input],
      mint: burn_value,
    },
  )
}


/// End succeeds even when the mint field contains additional policies beyond
/// the cage's own burn. This supports atomic migration where a new token is
/// minted under a different policy in the same transaction.
test end_with_extra_mint_policy() fail {
  let extra_mint =
    from_asset("policy_id", testToken.assetName, -1)
      |> assets.merge(from_asset("other_policy", "other_asset", 1))
  spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [update],
      mint: extra_mint,
    },
  )
}

/// End must reject extra asset movements under the state policy id.
test end_with_extra_state_policy_asset() fail {
  let extra_mint =
    from_asset("policy_id", testToken.assetName, -1)
      |> assets.merge(from_asset("policy_id", "extra_asset", -1))
  spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [update],
      mint: extra_mint,
    },
  )
}

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

fn mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) -> Bool {
  state_validator.state.mint(redeemer, policyId, tx)
}

// ============================================================================
// Migration tests
//
// Migration mints a new token under the new policy while atomically burning
// the old token under the old policy. The MPF root is carried over (not
// required to be empty), preserving existing data.
// ============================================================================

const old_policy = "old_policy_id"

const new_policy = "new_policy_id"

const migrate_token = TokenId { assetName: assetName(testSeed) }

const migrate_redeemer =
  Migration { oldPolicy: old_policy, tokenId: migrate_token }

const migrate_mint =
  from_asset(old_policy, migrate_token.assetName, -1)
    |> assets.merge(from_asset(new_policy, migrate_token.assetName, 1))

// The predecessor `State`: migration must spend the UTxO carrying this
// state exactly as-is (field preservation), authorized by its own owner.
const migrate_predecessor_state =
  State {
    root: "nonempty_root_hash_aaaaaaaaa",
    tip: 0,
    process_time: testProcessTime,
    retract_time: testRetractTime,
    application_policy: testAppPolicy,
    active_policy: testRepPolicy,
    absent_policy: testAbsentPolicy,
    terminal_policy: testTerminalPolicy
  }

const migrate_predecessor_ref =
  OutputReference { transaction_id: "migrate_predecessor_tx_id", output_index: 0 }

const migrate_predecessor_input =
  Input {
    output_reference: migrate_predecessor_ref,
    output: Output {
      address: address.from_script(old_policy),
      value: from_asset(old_policy, migrate_token.assetName, 1),
      datum: InlineDatum(StateDatum(migrate_predecessor_state)),
      reference_script: None,
    },
  }

const migrate_output =
  Output {
    address: address.from_script(new_policy),
    value: from_asset(new_policy, migrate_token.assetName, 1),
    datum: InlineDatum(StateDatum(migrate_predecessor_state)),
    reference_script: None,
  }

/// Owner-signed migration — refused (operator ruling NOTE-028/A-003, issue
/// #77 repair): migration is a destructive re-policying with no ownerless
/// justification. Neither the registry's creator nor any other party can
/// migrate through `Migrating`.
test migrating_owner_signed_refuses() fail {
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [migrate_output],
      mint: migrate_mint,
    },
  )
}

/// Migration requires burning the old token. Without the burn, someone could
/// duplicate a cage by minting a new token without destroying the old one.
test migrate_no_burn() fail {
  let mint_no_burn = from_asset(new_policy, migrate_token.assetName, 1)
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [migrate_output],
      mint: mint_no_burn,
    },
  )
}

/// The migrated token must go to a script address, not a wallet.
/// Same rationale as mint_to_wallet: wallet addresses bypass the cage validator.
test migrate_to_wallet() fail {
  let wallet_output =
    Output {
      ..migrate_output,
      address: address.from_verification_key("someone"),
    }
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [wallet_output],
      mint: migrate_mint,
    },
  )
}

/// The burn must target the correct old policy. Burning a token under a
/// different policy doesn't prove ownership of the original cage.
test migrate_wrong_old_policy() fail {
  let wrong_mint =
    from_asset("wrong_old", migrate_token.assetName, -1)
      |> assets.merge(from_asset(new_policy, migrate_token.assetName, 1))
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [migrate_output],
      mint: wrong_mint,
    },
  )
}

/// Migration must not mint unrelated extra assets under the new global state
/// policy id.
test migrate_extra_state_policy_asset() fail {
  let wrong_mint =
    migrate_mint
      |> assets.merge(from_asset(new_policy, "extra_asset", 1))
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [migrate_output],
      mint: wrong_mint,
    },
  )
}

/// The State output checked by migration must actually hold the newly minted
/// cage token under the new policy.
test migrate_output_must_hold_token() fail {
  let tokenless_state_output =
    Output { ..migrate_output, value: from_lovelace(2_000_000) }
  let wallet_token_output =
    Output {
      address: address.from_verification_key("owner"),
      value: from_asset(new_policy, migrate_token.assetName, 1),
      datum: NoDatum,
      reference_script: None,
    }
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [tokenless_state_output, wallet_token_output],
      mint: migrate_mint,
    },
  )
}


// ============================================================================
// Migration provenance tests (#76): allowlist + predecessor spend + owner
// authorization + full field preservation.
// ============================================================================

/// FR1: an `oldPolicy` absent from the validator's `previousPolicies`
/// allowlist is rejected outright, before any predecessor/ownership check.
test migrate_old_policy_not_allowlisted() fail {
  let unlisted_policy = "unlisted_policy_id"
  let redeemer =
    Migration { oldPolicy: unlisted_policy, tokenId: migrate_token }
  let mint_val =
    from_asset(unlisted_policy, migrate_token.assetName, -1)
      |> assets.merge(from_asset(new_policy, migrate_token.assetName, 1))
  mint(
    Migrating(redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      outputs: [migrate_output],
      mint: mint_val,
    },
  )
}

/// FR2: burning the right quantity under the allowlisted policy is not
/// enough — migration must actually spend a UTxO carrying that token.
test migrate_no_predecessor_input() fail {
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [],
      outputs: [migrate_output],
      mint: migrate_mint,
    },
  )
}

/// Unsigned migration — refused under the wholesale `Migrating` refusal
/// (formerly FR3 owner-signature coverage; the branch refuses regardless).
test migrate_missing_owner_signature() fail {
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      inputs: [migrate_predecessor_input],
      outputs: [migrate_output],
      mint: migrate_mint,
    },
  )
}

/// FR4: changing `tip` at migration time is also rejected — parameter
/// changes belong to `Modify`, not `Migrating`.
test migrate_changes_tip() fail {
  let bad_output =
    Output {
      ..migrate_output,
      datum: InlineDatum(
        StateDatum(State { ..migrate_predecessor_state, tip: 1 }),
      ),
    }
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [bad_output],
      mint: migrate_mint,
    },
  )
}

/// Regression for the issue's exploit chain: an attacker-controlled
/// `oldPolicy` (not an audited predecessor) can never mint a genuine
/// state-policy token for a victim's asset name, since the allowlist check
/// rejects it outright. Because the forged `(statePolicyId, N)` token is
/// never produced, `Sweep` never becomes reachable against the victim cage —
/// asserting mint failure here is sufficient to close the exploit without
/// separately constructing the downstream Sweep transaction.
test migrate_forged_token_cannot_sweep() fail {
  let attacker_policy = "attacker_always_true_policy"
  let forged_redeemer =
    Migration { oldPolicy: attacker_policy, tokenId: migrate_token }
  let forged_mint =
    from_asset(attacker_policy, migrate_token.assetName, -1)
      |> assets.merge(from_asset(new_policy, migrate_token.assetName, 1))
  let forged_output =
    Output {
      ..migrate_output,
      datum: InlineDatum(StateDatum(migrate_predecessor_state)),
    }
  mint(
    Migrating(forged_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      outputs: [forged_output],
      mint: forged_mint,
    },
  )
}

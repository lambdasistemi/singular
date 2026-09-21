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
// Minting tests
// ============================================================================

const reference =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

const token = TokenId { assetName: assetName(reference) }

const minted_value = valueFromToken("policy_id", token)

const output_address = address.from_script("policy_id")

const minted =
  Output {
    address: output_address,
    value: minted_value,
    datum: InlineDatum(
      StateDatum(
        State {
          root: root(empty),
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

const paying_address = address.from_verification_key("paying_address")

const consumed_value = zero

const consumed_utxo =
  Output {
    address: paying_address,
    value: consumed_value,
    datum: NoDatum,
    reference_script: None,
  }

/// Happy path: mint a new caged token. The OutputReference is consumed,
/// exactly 1 token is minted, output goes to this script with an empty
/// MPF root. This is how a new cage is created.
test canMint() {
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction {
      ..transaction.placeholder,
      outputs: [minted],
      mint: minted_value,
      inputs: [Input { output_reference: reference, output: consumed_utxo }],
    },
  )
}


// ============================================================================
// Minting failure tests
// ============================================================================

fn mint_tx() -> Transaction {
  Transaction {
    ..transaction.placeholder,
    outputs: [minted],
    mint: minted_value,
    inputs: [Input { output_reference: reference, output: consumed_utxo }],
  }
}

/// The OutputReference used to derive the asset name must actually be consumed.
/// Without this check, anyone could mint arbitrary asset names.
test mint_missing_input() fail {
  mint(Minting(testSeed), "policy_id", Transaction { ..mint_tx(), inputs: [] })
}

/// Exactly 1 token must be minted. Minting 2 would break the NFT invariant.
test mint_quantity_two() fail {
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction {
      ..mint_tx(),
      mint: from_asset("policy_id", assetName(reference), 2),
    },
  )
}

/// The global state policy must not mint unrelated extra assets alongside a
/// valid cage NFT. Extra state-policy assets would poison policy-id discovery.
test mint_extra_state_policy_asset() fail {
  let extra_mint =
    minted_value |> assets.merge(from_asset("policy_id", "extra_asset", 1))
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction { ..mint_tx(), mint: extra_mint },
  )
}

/// The minted token must go to a script address, not a wallet.
/// Sending to a wallet would make the token unmanageable by the cage validator.
test mint_to_wallet() fail {
  let wallet_output =
    Output { ..minted, address: address.from_verification_key("someone") }
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [wallet_output] },
  )
}

/// The minted token must go to THIS script (policy_id == script hash).
/// Sending to a different script would lock the token under foreign rules.
test mint_to_wrong_script() fail {
  let wrong_output =
    Output { ..minted, address: address.from_script("other_script") }
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [wrong_output] },
  )
}

/// A freshly minted cage must start with an empty MPF root.
/// A non-empty root would mean data exists without ever being inserted.
test mint_nonempty_root() fail {
  let bad_output =
    Output {
      ..minted,
      datum: InlineDatum(
        StateDatum(
          State {
            root: "nonempty_root",
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
    }
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

/// The output datum must be a StateDatum (not a RequestDatum).
/// A RequestDatum at mint time makes no sense — there's no cage to request against yet.
test mint_request_datum() fail {
  let bad_output =
    Output {
      ..minted,
      datum: InlineDatum(
        RequestDatum(
          Request {
            requestToken: token,
            requestKey: "k",
            edge: 1,
            requestOwner: "owner",
            deposit: 0,
            submitted_at: 0,
            destination: noDestination,
          },
        ),
      ),
    }
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

/// The output must have an inline datum. Without it, the spending validator
/// would have no state to read when the cage is later spent.
test mint_no_datum() fail {
  let bad_output = Output { ..minted, datum: NoDatum }
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

/// The State output checked by minting must actually hold the newly minted
/// cage token. Otherwise the token can be minted to a wallet while a tokenless
/// StateDatum is left at the script address.
test mint_output_must_hold_token() fail {
  let tokenless_state_output =
    Output { ..minted, value: from_lovelace(2_000_000) }
  let wallet_token_output =
    Output {
      address: address.from_verification_key("owner"),
      value: minted_value,
      datum: NoDatum,
      reference_script: None,
    }
  mint(
    Minting(testSeed),
    "policy_id",
    Transaction {
      ..mint_tx(),
      outputs: [tokenless_state_output, wallet_token_output],
    },
  )
}


/// **Property: Minting works for any valid OutputReference.**
///
/// Generates random (tx_id, output_index) pairs and verifies that the full
/// minting flow succeeds: derive asset name from hash, create correct output,
/// and pass validator checks. This confirms the minting logic is robust
/// across the entire OutputReference space — not just for one hardcoded ref.
///
/// Covers: deterministic asset name derivation, quantity-1 enforcement,
/// script address check, empty root check, and inline datum check.
test prop_mint_roundtrip(
  params via fuzz.tuple(fuzz.bytearray_fixed(32), fuzz.int_between(0, 255)),
) {
  let (tx_id, idx) = params
  let ref = OutputReference { transaction_id: tx_id, output_index: idx }
  let tok = TokenId { assetName: assetName(ref) }
  let val = valueFromToken("policy_id", tok)
  let addr = address.from_script("policy_id")
  let out =
    Output {
      address: addr,
      value: val,
      datum: InlineDatum(
        StateDatum(
          State {
            root: root(empty),
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
  let utxo =
    Output {
      address: paying_address,
      value: zero,
      datum: NoDatum,
      reference_script: None,
    }
  // Parameterize the validator with the fuzzed `ref` itself — this asserts
  // that the per-token parameterization works for any seed in the OutputReference space.
  mint(
    Minting(ref),
    "policy_id",
    Transaction {
      ..transaction.placeholder,
      outputs: [out],
      mint: val,
      inputs: [Input { output_reference: ref, output: utxo }],
    },
  )
}

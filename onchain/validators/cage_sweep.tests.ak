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
  aRequest, endRedeemerData, feeDelivery, feeStateInput, legacyApproval,
  legacyDelivery,
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
// Sweep tests
//
// `Sweep(stateRef)` lets the cage owner reclaim non-legitimate UTxOs at the
// cage's address. The redeemer points at the state UTxO so the validator
// can read the owner key for the signature check; the spent UTxO at `self`
// must be neither the legitimate state nor a legitimate request for this
// cage.
// ============================================================================

// A "garbage" UTxO ref distinct from testStateRef and testRequestRef.
const sweepRef =
  OutputReference { transaction_id: "3334567890abcdef", output_index: 7 }

// A no-datum garbage UTxO at the cage address.
const sweepNoDatumInput =
  Input {
    output_reference: sweepRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(2_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }

// A wrong-token RequestDatum garbage UTxO at the cage address.
const sweepWrongTokenRequest =
  RequestDatum(
    Request {
      requestToken: TokenId { assetName: "different_asset" },
      requestKey: "k",
      edge: 1,
      requestOwner: "other_owner",
      deposit: 0,
      submitted_at: 0,
      destination: noDestination,
    },
  )

const sweepWrongTokenInput =
  Input {
    output_reference: sweepRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(2_000_000),
      datum: InlineDatum(sweepWrongTokenRequest),
      reference_script: None,
    },
  }

// A foreign-NFT StateDatum garbage UTxO at the cage address.
// The `StateDatum` shape is correct but the value carries no `cageToken`
// (just ADA) so the garbage predicate fires.
const sweepFakeStateInput =
  Input {
    output_reference: sweepRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(2_000_000),
      datum: InlineDatum(rawStateDatum),
      reference_script: None,
    },
  }

/// Owner-signed sweep — refused (operator ruling NOTE-028/A-003, issue #77
/// repair): seizing UTxOs at the cage address is an owner operation and
/// there is no owner. Neither the registry's creator nor any other party
/// can seize through `Sweep`.
test sweep_owner_signed_refuses() fail {
  spend(
    None,
    Sweep(testStateRef),
    sweepRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [sweepNoDatumInput],
      reference_inputs: [update],
    },
  )
}

/// Wrong-token sweep — refused under the same ruling (shape no longer
/// matters; every `Sweep` refuses).
test sweep_wrong_token_request() fail {
  spend(
    Some(sweepWrongTokenRequest),
    Sweep(testStateRef),
    sweepRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [sweepWrongTokenInput],
      reference_inputs: [update],
    },
  )
}

/// Fake-state sweep — refused under the same ruling.
test sweep_fake_state_no_nft() fail {
  spend(
    Some(rawStateDatum),
    Sweep(testStateRef),
    sweepRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [sweepFakeStateInput],
      reference_inputs: [update],
    },
  )
}

/// Sweep bundled with Modify — refused under the same ruling (bundling
/// changes nothing; every `Sweep` refuses).
test sweep_alongside_modify() fail {
  let bundled_state_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(rawStateDatum),
      reference_script: None,
    }
  let bundled_tx =
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [bundled_state_output],
      extra_signatories: ["owner"],
      inputs: [update, sweepNoDatumInput],
    }
  spend(None, Sweep(testStateRef), sweepRef, bundled_tx) && spend(
    stateDatum,
    Modify([]),
    testStateRef,
    bundled_tx,
  )
}

/// Negative: a non-owner cannot sweep, even if the redeemer correctly points
/// at the legitimate state UTxO.
test sweep_wrong_signer() fail {
  spend(
    None,
    Sweep(testStateRef),
    sweepRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["someone_else"],
      inputs: [sweepNoDatumInput],
      reference_inputs: [update],
    },
  )
}

/// Negative: the redeemer's `stateRef` must point at a UTxO carrying
/// `cageToken`. Pointing at a UTxO without the cage NFT (here: the garbage
/// UTxO itself) is rejected.
test sweep_fake_state_ref() fail {
  spend(
    None,
    Sweep(sweepRef),
    sweepRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [sweepNoDatumInput],
      reference_inputs: [update],
    },
  )
}

/// The state validator has no Sweep path. Garbage at the state address is
/// ignored by policy-id discovery instead of reclaimed by the protocol.
test state_sweep_rejected() fail {
  state_validator.state.spend(
        Some(rawStateDatum),
    Sweep(testStateRef),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [update],
    },
  )
}

/// Negative: a legitimate request for this cage is NOT garbage. Sweeping it
/// must fail (the request owner uses Retract; the cage owner uses Modify
/// to process or reject).
test sweep_legitimate_request() fail {
  spend(
    Some(aRequest),
    Sweep(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [request],
      reference_inputs: [update],
    },
  )
}

/// A request whose deposit does not match its holding less the state's
/// tip — 2 ADA held against a 0.5 ADA tip owes 1.5 ADA, not 0.1 — and so
/// is not processable by `Modify`. It is refused here under the wholesale
/// `Sweep` refusal (the spam-collection premise is gone with the owner).
/// `tip-mismatch` retired with the tip field (#183 slice b).
test sweep_mismatched_deposit_request() fail {
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
      output_reference: sweepRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(2_000_000),
        datum: InlineDatum(mismatch_request),
        reference_script: None,
      },
    }
  spend(
    Some(mismatch_request),
    Sweep(testStateRef),
    sweepRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [mismatch_input],
      reference_inputs: [feeStateInput],
    },
  )
}

/// An underfunded request — refused under the same wholesale refusal.
test sweep_underfunded_matching_request() fail {
  let underfunded_request =
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
  let underfunded_input =
    Input {
      output_reference: sweepRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(0),
        datum: InlineDatum(underfunded_request),
        reference_script: None,
      },
    }
  spend(
    Some(underfunded_request),
    Sweep(testStateRef),
    sweepRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [underfunded_input],
      reference_inputs: [feeStateInput],
    },
  )
}

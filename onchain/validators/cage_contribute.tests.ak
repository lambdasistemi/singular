use aiken/builtin
use aiken/crypto.{blake2b_256}
use booking.{applicationTagName, trieReadyTagName}
use cage_fixtures.{
  aRequest, endRedeemerData, feeDelivery, legacyApproval, legacyDelivery,
  legacyDestination, legacyKey, legacyMint, legacyRoot, legacyWallet,
  modifyRedeemerData, noDestination, output, owner_fuzzer, phase1Range,
  phase2Range, phase3Range, rawStateDatum, rejectedActionData, request, state,
  stateDatum, stateSpendRedeemerData, testAbsentPolicy, testAppPolicy,
  testProcessTime, testRepPolicy, testRequestPolicy, testRequestRef,
  testRetractTime, testScriptAddress, testSeed, testStakeScript, testStateRef,
  testTerminalPolicy, testToken, testValue, update, updateActionData, zfDelivery,
}
use cardano/address.{from_script}
use cardano/assets.{PolicyId, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, ScriptPurpose, Spend,
  Transaction,
}
use lib.{assetName, valueFromToken}
use request as request_validator
use state as state_validator
use types.{
  CageDatum, Contribute, RegistrationDatum, RegistrationRequest, Retract, Sweep,
  TerminationDatum, TerminationRequest, TokenId, UpdateRedeemer,
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
// Contribute: a pending request is spent only inside a fold of its registry
// ============================================================================
//
// CP2: the request output a booking leaves is a registration or a termination
// (`RegistrationDatum`, `TerminationDatum`). Its `request.spend` accepts
// `Contribute` only for a request of this registry, naming a state input that
// holds this registry's token and is spent in the same transaction with
// `Modify`; the state validator then judges every input, this one included.
// Each refusal below changes one of those and has the accepting twins first.
//
// The legacy edge-only `RequestDatum` is no longer spent by `Contribute`
// (`contribute_of_a_legacy_request_refuses`); its window, rejection and
// pairing rows are retired with the state-spending rejection and the window
// rule of the old fold (the registration window is the state's `not-phase1`,
// covered in `tagged_fold.tests.ak`).

const pendingKey: ByteArray = "42"

fn pendingRegistration() -> RegistrationRequest {
  RegistrationRequest {
    registry: testToken,
    key: pendingKey,
    refund_address: #"d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
    destination: #"60d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
    datum: None,
    submitted_at: 0,
    registration_cost: 2_000_000,
    declared_tip: 1_000_000,
    carrier_ada: 1_500_000,
    nonce: 1,
  }
}

fn pendingRequest() -> TerminationRequest {
  TerminationRequest {
    registry: testToken,
    key: pendingKey,
    destination: "",
    declared_tip: 1_000_000,
    carrier_ada: 3_000_000,
    nonce: 1,
  }
}

fn pendingTermination() -> CageDatum {
  TerminationDatum(pendingRequest())
}

fn pendingRegistrationDatum() -> CageDatum {
  RegistrationDatum(pendingRegistration())
}

/// The Lean preimage `bookingCommitment 1 ([1, key, destination] ++ [nonce])`.
fn pendingTrieName(r: TerminationRequest) -> ByteArray {
  blake2b_256(
    builtin.serialise_data(
      builtin.list_data(
        [
          builtin.i_data(1),
          builtin.i_data(1),
          builtin.b_data(r.key),
          builtin.b_data(r.destination),
          builtin.i_data(r.nonce),
        ],
      ),
    ),
  )
}

/// The genuine pending termination output: a `TerminationDatum` at the request
/// reference and at the request address of the state context (`update`, whose
/// `request_policy` is `testRequestPolicy`), holding the declared lovelace,
/// the key's singular tag under the active policy and the trie-ready tag the
/// datum commits to, minted under that same request policy.
fn pendingInput() -> Input {
  let r = pendingRequest()
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: from_script(testRequestPolicy),
      value: from_lovelace(r.declared_tip + r.carrier_ada)
        |> merge(from_asset(testRepPolicy, r.key, 1))
        |> merge(from_asset(testRequestPolicy, pendingTrieName(r), 1)),
      datum: InlineDatum(pendingTermination()),
      reference_script: None,
    },
  }
}

/// The genuine pending registration output of the same context.
fn pendingRegistrationInput() -> Input {
  let r = pendingRegistration()
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: from_script(testRequestPolicy),
      value: from_lovelace(r.registration_cost + r.declared_tip + r.carrier_ada)
        |> merge(from_asset(testRequestPolicy, trieReadyTagName(r), 1))
        |> merge(
            from_asset(
              testAppPolicy,
              applicationTagName(
                r.key,
                r.refund_address,
                r.destination,
                r.nonce,
              ),
              1,
            ),
          ),
      datum: InlineDatum(pendingRegistrationDatum()),
      reference_script: None,
    },
  }
}

/// Spend the pending output `self` by `Contribute(stateRef)`, with the datum
/// the output carries, in a transaction over `inputs` whose redeemers are
/// `redeemers`.
fn contributes(
  datum: CageDatum,
  stateRef: OutputReference,
  inputs: List<Input>,
  redeemers: Pairs<ScriptPurpose, Data>,
) -> Bool {
  spend(
    Some(datum),
    Contribute(stateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs,
      redeemers,
    },
  )
}

fn modifies() -> Pairs<ScriptPurpose, Data> {
  [stateSpendRedeemerData(modifyRedeemerData([updateActionData()]))]
}

// ---- the accepting twins ----------------------------------------------------

test contribute_a_pending_registration_beside_the_state_modify_accepts() {
  contributes(
    pendingRegistrationDatum(),
    testStateRef,
    [update, pendingRegistrationInput()],
    modifies(),
  )
}

test contribute_a_pending_termination_beside_the_state_modify_accepts() {
  contributes(
    pendingTermination(),
    testStateRef,
    [update, pendingInput()],
    modifies(),
  )
}

// ---- the request's registry and the state it names ---------------------------

/// A Contribute must name a State UTxO whose token matches the request's
/// registry. A mismatch means the request targets a different cage.
test contribute_wrong_token() fail {
  let r =
    RegistrationRequest {
      ..pendingRegistration(),
      registry: TokenId { assetName: "different_asset" },
    }
  contributes(
    RegistrationDatum(r),
    testStateRef,
    [update, pendingRegistrationInput()],
    modifies(),
  )
}

test contribute_a_termination_of_another_registry_refuses() fail {
  let r =
    TerminationRequest {
      ..pendingRequest(),
      registry: TokenId { assetName: "different_asset" },
    }
  contributes(
    TerminationDatum(r),
    testStateRef,
    [update, pendingInput()],
    modifies(),
  )
}

/// The State UTxO named by Contribute must actually exist in the inputs.
/// Without this, the registry binding can't be verified.
test contribute_missing_ref() fail {
  let missing_ref =
    OutputReference { transaction_id: "nonexistent", output_index: 0 }
  contributes(
    pendingRegistrationDatum(),
    missing_ref,
    [update, pendingRegistrationInput()],
    modifies(),
  )
}

/// Contribute must consume the state UTxO in the same transaction. A reference
/// input is not enough because request consumption must be paired with state
/// Modify.
test contribute_reference_only_state_rejected() fail {
  spend(
    Some(pendingRegistrationDatum()),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [pendingRegistrationInput()],
      reference_inputs: [update],
      redeemers: modifies(),
    },
  )
}

/// The named state UTxO must carry the cage token under the state policy,
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
  contributes(
    pendingRegistrationDatum(),
    testStateRef,
    [fake_state_input, pendingRegistrationInput()],
    modifies(),
  )
}

/// Contribute must be paired with state `Modify`, not merely any state spend.
/// Otherwise request UTxOs could be consumed without folding them.
test contribute_with_state_end_rejected() fail {
  contributes(
    pendingRegistrationDatum(),
    testStateRef,
    [update, pendingRegistrationInput()],
    [stateSpendRedeemerData(endRedeemerData())],
  )
}

test contribute_a_termination_with_state_end_rejected() fail {
  contributes(
    pendingTermination(),
    testStateRef,
    [update, pendingInput()],
    [stateSpendRedeemerData(endRedeemerData())],
  )
}

// ---- the retired legacy request -----------------------------------------------

/// The legacy edge-only request was spent by `Contribute` beside a `Modify` in
/// the processing window (`contribute_update_in_the_processing_window_accepts`
/// before CP2). It is no member of the fold, so no `Contribute` spends it:
/// the twin above, with the same state and redeemers, accepts the tagged
/// request.
test contribute_of_a_legacy_request_refuses() fail {
  contributes(aRequest, testStateRef, [update, request], modifies())
}

// ============================================================================
// A pending termination request is not custody (CP1, closed by CP2)
// ============================================================================
//
// Alice's booked termination holds the genuine singular tag while the trie
// still says the key is active. The root model's custody excludes a tag a
// pending request carries, so a second booking must not be able to spend
// that request as its custody input. The real `request.spend` refuses the
// spend outside a fold: `Contribute` only inside a state `Modify`, and
// `Retract` only for the legacy `RequestDatum`. Inside a fold the request is
// consumed and its singular tag burned (`tagged_fold.tests.ak`), so the tag
// never survives to be custody. The input is the genuine pending output of
// the accepting twin above.

test pending_termination_is_refused_as_custody_without_a_fold() fail {
  spend(
    Some(pendingTermination()),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [pendingInput()],
      reference_inputs: [update],
    },
  )
}

test pending_termination_is_refused_as_custody_by_a_retract() fail {
  spend(
    Some(pendingTermination()),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      inputs: [pendingInput(), update],
    },
  )
}

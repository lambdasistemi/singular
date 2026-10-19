use aiken/builtin
use aiken/crypto.{blake2b_256}
use aiken/fuzz
use aiken/interval.{Interval}
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/merkle_patricia_forestry as mpf
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
  Burning, CageDatum, Contribute, End, Migrating, Migration, MintRedeemer,
  Minting, Modify, Rejected, Request, RequestDatum, Retract, State, StateDatum,
  Sweep, TerminationDatum, TerminationRequest, TokenId, UpdateAction,
  UpdateRedeemer,
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

// ----------------------------------------------------------------------------
// The request's matching action (#320, data model D-02)
//
// A request spent by `Contribute` is admitted inside the processing window,
// or in any window when the state's fold pairs it with `Rejected`: the fold
// pairs actions with the transaction's requests of this registry in input
// order. Each refusal below has an accepting twin that differs only in the
// validity range or in the order of the same actions.
// ----------------------------------------------------------------------------

/// Spend `self` by `Contribute` beside a `Modify` of the state carrying
/// `actions`, over `inputs`, valid over `range`.
fn contribute(
  self: OutputReference,
  inputs: List<Input>,
  actions: List<Data>,
  range: Interval<Int>,
) -> Bool {
  spend(
    Some(aRequest),
    Contribute(testStateRef),
    self,
    Transaction {
      ..transaction.placeholder,
      validity_range: range,
      inputs,
      redeemers: [stateSpendRedeemerData(modifyRedeemerData(actions))],
    },
  )
}

const secondRequestRef =
  OutputReference { transaction_id: "3234567890abcdef", output_index: 0 }

/// The state, then two requests of this registry in input order.
fn twoRequests() -> List<Input> {
  [update, request, Input { ..request, output_reference: secondRequestRef }]
}

test contribute_rejected_in_the_processing_window_accepts() {
  contribute(
    testRequestRef,
    [update, request],
    [rejectedActionData()],
    phase1Range,
  )
}

test contribute_rejected_in_the_retraction_window_accepts() {
  contribute(
    testRequestRef,
    [update, request],
    [rejectedActionData()],
    phase2Range,
  )
}

test contribute_rejected_with_no_validity_bounds_accepts() {
  contribute(
    testRequestRef,
    [update, request],
    [rejectedActionData()],
    interval.everything,
  )
}

/// The twin of the two refusals below.
test contribute_update_in_the_processing_window_accepts() {
  contribute(
    testRequestRef,
    [update, request],
    [updateActionData()],
    phase1Range,
  )
}

/// An update is folded in the processing window only: current validator
/// behaviour, outside Lean (spec KR-01).
test contribute_update_in_the_retraction_window_refuses() fail {
  contribute(
    testRequestRef,
    [update, request],
    [updateActionData()],
    phase2Range,
  )
}

test contribute_update_after_the_windows_refuses() fail {
  contribute(
    testRequestRef,
    [update, request],
    [updateActionData()],
    phase3Range,
  )
}

/// A request the fold pairs with no action is not admitted outside the
/// processing window.
test contribute_with_no_matching_action_refuses() fail {
  contribute(testRequestRef, [update, request], [], phase2Range)
}

/// Two requests, an update then a reject: the second is the rejected one.
test contribute_second_request_rejected_after_an_update_accepts() {
  contribute(
    secondRequestRef,
    twoRequests(),
    [updateActionData(), rejectedActionData()],
    phase2Range,
  )
}

test contribute_first_request_updated_before_a_reject_refuses() fail {
  contribute(
    testRequestRef,
    twoRequests(),
    [updateActionData(), rejectedActionData()],
    phase2Range,
  )
}

/// The same two actions in the other order: now the first is the rejected one.
test contribute_first_request_rejected_before_an_update_accepts() {
  contribute(
    testRequestRef,
    twoRequests(),
    [rejectedActionData(), updateActionData()],
    phase2Range,
  )
}

test contribute_second_request_updated_after_a_reject_refuses() fail {
  contribute(
    secondRequestRef,
    twoRequests(),
    [rejectedActionData(), updateActionData()],
    phase2Range,
  )
}

/// A request rejected after the windows, as before the repair.
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

// ============================================================================
// A pending termination request is not custody (CP1)
// ============================================================================
//
// Alice's booked termination holds the genuine singular tag while the trie
// still says the key is active. The root model's custody excludes a tag a
// pending request carries, so a second booking must not be able to spend
// that request as its custody input. The real `request.spend` is what
// refuses the spend: `Contribute` only inside a state `Modify`, `Retract`
// only for the legacy `RequestDatum`. The input below is the genuine pending
// output, its datum, value and reference in agreement: a `TerminationDatum`
// at the request reference and at the request address of the state context
// (`update`, whose `request_policy` is `testRequestPolicy`), holding the
// declared lovelace, the key's singular tag under the active policy and the
// trie-ready tag the datum commits to, minted under that same request policy.
//
// These rows pin the refusals that exist today, which come from the datum's
// shape (`expect Some(RequestDatum(..))` fails), so they are guards and not
// RED evidence. A fold that does spend the request burns its tag (CP2); that
// closure is not claimed here.

const pendingKey: ByteArray = "42"

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

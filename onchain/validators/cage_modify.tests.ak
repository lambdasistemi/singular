use aiken/builtin
use aiken/fuzz
use aiken/interval
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/merkle_patricia_forestry as mpf
use cage_fixtures.{
  aRequest, burn_value, endRedeemerData, feeDelivery, feeRequestInput,
  feeStateDatum, feeStateInput, feeStateOutput, legacyApproval, legacyDelivery,
  legacyDestination, legacyKey, legacyMint, legacyRoot, legacyWallet,
  modifyRedeemerData, noDestination, output, owner_fuzzer, phase1Range,
  phase2Range, phase3Range, rawStateDatum, rejectedActionData, request, state,
  stateDatum, stateSpendRedeemerData, testAbsentPolicy, testAppPolicy,
  testBookingWidth, testProcessTime, testRegistrationCost, testRepPolicy,
  testRequestPolicy, testRequestRef, testRetractTime, testScriptAddress,
  testSeed, testStakeScript, testStateRef, testTerminalPolicy, testToken,
  testValue, update, updateActionData, zfDelivery,
}
use cardano/address.{from_script}
use cardano/assets.{PolicyId, from_asset, from_lovelace, zero}
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
  Sweep, TokenId, UpdateAction, UpdateRedeemer,
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
// Modify tests
// ============================================================================
//
// CP2 old-to-new map. The legacy edge-only requests these rows folded are no
// members of the fold, so a row whose control was such a fold could not
// establish its guard and was retired or moved to a valid tagged fold, one fact
// from it (`tagged_fold.tests.ak`):
//
// - `modify_without_owner_succeeds`, `modify_advances_root_accepts` and
//   `modify_zero_net_state_preserved_accepts`: `tagged_fold_state_folds_*`,
//   with `tagged_fold_is_permissionless` (no owner, any signer) and the funded
//   rows (the state keeps its lovelace exactly);
// - `modify_too_few_proofs`, `modify_extra_proofs`: `tagged_fold_refuses_a_missing_action`,
//   `..._a_surplus_action`, `..._a_batch_with_too_few_actions`;
// - `modify_wrong_root`: `tagged_fold_refuses_a_wrong_next_root`;
// - `modify_in_phase2`: `tagged_fold_registration_refuses_in_the_retraction_window`;
// - `modify_skip_other_token`: `tagged_fold_refuses_a_request_of_another_registry_beside_a_member`;
// - `modify_wrong_address`, `modify_output_must_hold_token`,
//   `modify_altered_representative_policy_refuses` (and the ten registry-pin rows
//   of `registry_rows.tests.ak`): `tagged_fold_refuses_a_continuation_at_another_address`,
//   `..._without_the_state_token`, `tagged_fold_pins_altered_*_refuses`, each from
//   a fold that lands;
// - `modify_zero_requests_root_changes`: its root half is `tagged_fold_refuses_a_wrong_next_root`
//   (it passed as an empty fold);
// - the rejected-request rows of `cage_reject.tests.ak` (the file is retired) and
//   of `cage.props.ak` (`prop_reject_admitted_for_every_validity_range`,
//   `prop_request_admits_the_request_its_fold_rejects`): the state-spending
//   rejection is retired (`tagged_fold_retires_rejected_*`,
//   `deposit_exits.tests.ak`); `end_wrong_signer` is `tagged_fold_end_stays_refused`
//   and `reject_refund_topup_cannot_drain_state` is
//   `tagged_fold_preserved_refuses_a_continuation_that_drains_the_state`;
// - `cage_refunds.tests.ak` (retired): the refund floors of rejected rows and the
//   tip and deposit coverage of the old request belong to the old fold; the exact
//   donation and the held value are `fold-donation-mismatch` and
//   `request-observation-mismatch`;
// - `cage_lifecycle.tests.ak` (retired): `canCage` is the pair
//   `tagged_fold_state_folds_a_registration_inside_its_window` and
//   `tagged_fold_request_spend_contributes_a_registration`.
//
// The rows that stay here refuse a state-only transaction (no member) or a
// redeemer the state never accepts (`End`), whose control is not a fold.

/// Owner-signed End with a staking withdrawal — refused: termination is
/// refused for every party under the ownerless ruling, stake or no stake.
test end_stake_withdrawal_refuses() fail {
  spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      withdrawals: [Pair(address.Script(testStakeScript), 1)],
      inputs: [update],
      mint: burn_value,
    },
  )
}

/// Owner-signed End without withdrawal — refused: same ruling, no
/// signature authorizes termination.
test end_owner_signed_no_withdrawal_refuses() fail {
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

/// Modify with no matching requests refuses (NOTE-020, A001/root 071):
/// empty processing is not a valid no-op. The root is unchanged and the
/// hook withdrawal is even present — neither manufactures nonemptiness.
test modify_no_requests() fail {
  let unchanged_output =
    Output {
      address: testScriptAddress,
      value: testValue,
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
            terminal_policy: testTerminalPolicy,
            registration_cost: testRegistrationCost,
            booking_width: testBookingWidth,
            request_policy: testRequestPolicy,
          },
        ),
      ),
      reference_script: None,
    }
  spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [unchanged_output],
      extra_signatories: ["owner"],
      inputs: [update],
    },
  )
}

/// **Property: empty Modify refuses regardless of signer (NOTE-020).**
///
/// The pre-repair defect this prop re-cut is gone; what remains is the
/// pairing rule: a `Modify` that consumes no request refuses for EVERY
/// signer, owner or not. Generates random 28-byte signers and verifies
/// the empty fold refuses no matter who signs — no signer manufactures
/// nonemptiness, and permissionlessness is about the absence of an owner
/// hypothesis, not the acceptance of empty batches.
test prop_empty_modify_refuses(signer via owner_fuzzer()) fail {
  let s =
    State {
      root: root(empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
      application_policy: testAppPolicy,
      active_policy: testRepPolicy,
      absent_policy: testAbsentPolicy,
      terminal_policy: testTerminalPolicy,
      registration_cost: testRegistrationCost,
      booking_width: testBookingWidth,
      request_policy: testRequestPolicy,
    }
  let unchanged_output =
    Output {
      address: testScriptAddress,
      value: testValue,
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
            terminal_policy: testTerminalPolicy,
            registration_cost: testRegistrationCost,
            booking_width: testBookingWidth,
            request_policy: testRequestPolicy,
          },
        ),
      ),
      reference_script: None,
    }
  let state_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(s)),
        reference_script: None,
      },
    }
  spend(
    Some(StateDatum(s)),
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [unchanged_output],
      extra_signatories: [signer],
      inputs: [state_input],
    },
  )
}

// ============================================================================
// Zero-request Modify tests
//
// A Modify with no actions and no request inputs is a steady-state Oracle
// tick — no requests to process, root unchanged, no refunds. The validator
// short-circuits the per-request conservation equation when `n == 0`.
// ============================================================================

// State output that preserves the cage state verbatim — used in zero-request
// Modify tests where the root and time params must not change.
const zeroRequestStateOutput =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(rawStateDatum),
    reference_script: None,
  }

/// Modify with no requests refuses (NOTE-020): root unchanged or not, an
/// unconsuming batch is refused. `modify_zero_requests_root_changes`
/// below keeps the root-mutation half; this one keeps the emptiness half.
test modify_zero_requests_refuses() fail {
  spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [zeroRequestStateOutput],
      extra_signatories: ["owner"],
      inputs: [update],
    },
  )
}

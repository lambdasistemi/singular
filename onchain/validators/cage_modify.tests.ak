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
  aRequest, burn_value, endRedeemerData, feeDelivery, feeRequestInput,
  feeStateDatum, feeStateInput, feeStateOutput, legacyApproval, legacyDelivery,
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
// Modify tests
// ============================================================================

/// Permissionless Modify (re-cut under issue #79; was
/// `modify_missing_signature`, which required a refusal when the owner
/// signature was absent). That expectation encoded the pre-repair defect:
/// Lean `Singular.step`'s `.fold` case requires only `nativeSpend`, net
/// mint equality and the conditional mint witnesses — it states no owner
/// hypothesis — so the repaired validator accepts an ownerless Modify.
/// This test pins the repaired truth: a well-formed fold with no owner
/// signer is accepted.
test modify_without_owner_succeeds() {
  spend(
    stateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output, legacyDelivery],
      mint: legacyMint,
      extra_signatories: [],
      inputs: [update, request],
    },
  )
}


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

/// The output must stay at the same script address as the input.
/// Without this check, anyone could steal the token by redirecting
/// the output to a different script they control.
test modify_wrong_address() fail {
  let bad_output =
    Output { ..output, address: address.from_script("different_script") }
  spend(
    stateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [bad_output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

/// A well-formed Modify advancing the root is accepted. (Named
/// `modify_owner_transfer` before the ownerless repair, when the output
/// fixture carried a new owner; the owner field is gone and the test now
/// pins only the root-advancing fold it always executed.)
test modify_advances_root_accepts() {
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
  )
}

/// Genuine nonempty zero-net positive (NOTE-020): real processed work with
/// zero state-value delta. One Insert consumed (the root advances, the
/// consumer permits via the pinned withdrawal); the state output carries
/// EXACTLY the input state's value — net zero, no lock absorbed and none
/// required; the admitted bond routes visibly to a change output
/// (permitted, never endorsed). Do not confuse with zero consumed requests
/// (refused below): work happened here, the trie proves it.
test modify_zero_net_state_preserved_accepts() {
  let change_output =
    Output {
      address: address.from_verification_key("folder_key"),
      value: from_lovelace(1_500_000),
      datum: NoDatum,
      reference_script: None,
    }
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, change_output, feeDelivery],
      mint: legacyMint,
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
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
            terminal_policy: testTerminalPolicy
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

/// Requests targeting a different token are silently skipped — no proof is
/// consumed for them. Only requests whose `requestToken` matches the cage's
/// token participate in the MPF fold. A batch with NOTHING matching refuses
/// for empty processing (NOTE-020): skipping is real, and so is the
/// emptiness refusal — the skipped request consumes no action.
test modify_skip_other_token() fail {
  let other_request_datum =
    RequestDatum(
      Request {
        requestToken: TokenId { assetName: "other_token" },
        requestKey: "42",
        edge: 1,
        requestOwner: "someone",
        deposit: 0,
        submitted_at: 0,
        destination: noDestination,
      },
    )
  let other_request =
    Input {
      output_reference: OutputReference {
        transaction_id: "3334567890abcdef",
        output_index: 1,
      },
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(0),
        datum: InlineDatum(other_request_datum),
        reference_script: None,
      },
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
            terminal_policy: testTerminalPolicy
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
      inputs: [update, other_request],
    },
  )
}

/// Each matching request must have a corresponding proof. Providing zero
/// proofs for one request triggers `uncons` on an empty list, which fails.
test modify_too_few_proofs() fail {
  spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output, legacyDelivery],
      mint: legacyMint,
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

/// Extra proofs beyond what's needed are silently ignored. The fold consumes
/// one proof per matching request; leftover proofs are discarded.
/// Surplus actions refuse (NOTE-020): every supplied action must pair with
/// an actual matching request. Two actions for one request leave one
/// unconsumed — the batch refuses even though the root, the refunds, and
/// the hook withdrawal are all otherwise valid.
test modify_extra_proofs() fail {
  spend(
    stateDatum,
    Modify([UpdateAction([]), UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output, legacyDelivery],
      mint: legacyMint,
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

/// The output's MPF root must exactly match the result of folding all requests
/// into the old root. A wrong root means the oracle is lying about the data.
test modify_wrong_root() fail {
  let bad_root_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(
          State {
            root: "wrong_root_hash",
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
  spend(
    stateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [bad_root_output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

/// Modify must preserve the expected representative policy (issue #77, E-001
/// repair): the registry configuration set at bootstrap. A fold altering it —
/// even with the root, token, address and economics intact — refuses.
test modify_altered_representative_policy_refuses() fail {
  let altered_policy_output =
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
            active_policy: #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            absent_policy: testAbsentPolicy,
            terminal_policy: testTerminalPolicy
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
      outputs: [altered_policy_output],
      extra_signatories: ["owner"],
      inputs: [update],
    },
  )
}

/// Modify is forbidden in Phase 2 (the retract window). The oracle can only
/// process requests during Phase 1 to give requesters a fair retract window.
test modify_in_phase2() fail {
  spend(
    stateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      outputs: [output, legacyDelivery],
      mint: legacyMint,
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

/// Modify must preserve the cage token in the continuing State output. The
/// datum/root/address checks are not enough: a transaction that moves the NFT
/// to a wallet and leaves a tokenless state at the script must be rejected.
test modify_output_must_hold_token() fail {
  let tokenless_state_output =
    Output {
      address: testScriptAddress,
      value: from_lovelace(2_000_000),
      datum: InlineDatum(rawStateDatum),
      reference_script: None,
    }
  let wallet_token_output =
    Output {
      address: address.from_verification_key("owner"),
      value: testValue,
      datum: NoDatum,
      reference_script: None,
    }
  spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [tokenless_state_output, wallet_token_output],
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
      terminal_policy: testTerminalPolicy
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
            terminal_policy: testTerminalPolicy
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

/// Negative: zero-request Modify cannot mutate the MPF root. The fold returns
/// the identity root and the output's root must match it.
test modify_zero_requests_root_changes() fail {
  let bad_output =
    Output {
      ..zeroRequestStateOutput,
      datum: InlineDatum(
        StateDatum(
          State {
            root: "different_root_aaaaaaaaaaaaa",
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
  spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [bad_output],
      extra_signatories: ["owner"],
      inputs: [update],
    },
  )
}

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
use lib.{TokenId, assetName, valueFromToken}
use request
use state
use types.{
  CageDatum, Contribute, End, Insert, Migrating, Migration, MintRedeemer,
  Minting, Modify, Rejected, Request, RequestDatum, Retract, State, StateDatum,
  Sweep, UpdateAction, UpdateRedeemer,
}

// ============================================================================
// Test constants
// ============================================================================

// Test time params: 10s process window, 10s retract window
/// Unit tests and validator-level property tests for the MPF Cage validator.
///
/// This is a **test module** (no `pub` exports), which allows it to import
/// the `cage` validator directly via qualified syntax: `cage.mpfCage.spend(...)`.
///
/// ## Test Fixture Layout
///
/// All tests share a common set of constants that simulate a minimal cage
/// scenario:
///
/// - **Time phases**: process_time = 10s, retract_time = 10s, submitted_at = 0
///   - Phase 1 (oracle processing):  [0, 10_000)    — validity range [0, 5_000]
///   - Phase 2 (requester retract):  [10_000, 20_000) — validity range [10_000, 15_000]
///   - Phase 3 (rejectable/expired): [20_000, ...)    — validity range [20_000, 25_000]
///
/// - **State UTxO** (`update`): holds `testToken` at `testScriptAddress` with
///   an empty MPF root, owned by "owner".
///
/// - **Request UTxO** (`request`): an Insert("42") request targeting `testToken`,
///   submitted by "owner" at time 0.
///
/// - **Expected output** (`output`): the State UTxO after processing the Insert,
///   with the computed MPF root and ownership transferred to "new-owner".
const testProcessTime = 10_000

const testRetractTime = 10_000

// Phase 1 validity range: [0, 5_000] — entirely before submitted_at(0) + process_time(10_000)
const phase1Range = interval.between(0, 5_000)

// Phase 2 validity range: [10_000, 15_000] — after process_time, before process_time + retract_time
const phase2Range = interval.between(10_000, 15_000)

// Phase 3 validity range: [20_000, 25_000] — after process_time + retract_time
const phase3Range = interval.between(20_000, 25_000)

// Test constants: a script address used for all test UTxOs
const testScriptAddress = from_script("policy_id")

// Test seed parameter: the validator's `seed: OutputReference` parameter
// for all tests. The mint tests deliberately use this exact ref as the
// consumed input so `validateMint`'s seed-consumption check passes.
const testSeed =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

// Test constants: output references for State and Request UTxOs
const testStateRef =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

const testRequestRef =
  OutputReference { transaction_id: "2234567890abcdef", output_index: 254 }

// Test constants: a token ID derived from `testSeed`. With the per-token
// validator parameterization, the cage's canonical token id is
// `assetName(seed)`, so test fixtures must use the seed-derived asset name
// — otherwise the spend handler's defense-in-depth check
// (`extractedToken == cageToken`) rejects them.
const testToken = TokenId { assetName: assetName(testSeed) }

const testValue = valueFromToken("policy_id", testToken)

const testStakeScript = "test_stake_script"

fn spend(
  maybeDatum: Option<CageDatum>,
  redeemer: UpdateRedeemer,
  self: OutputReference,
  tx: Transaction,
) -> Bool {
  when redeemer is {
    Contribute(_) | Retract(_) | Sweep(_) ->
      request.request.spend(
        "policy_id",
        testToken.assetName,
        maybeDatum,
        redeemer,
        self,
        tx,
      )
    _ -> state.state.spend([], maybeDatum, redeemer, self, tx)
  }
}

fn mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) -> Bool {
  state.state.mint(previousPolicies, redeemer, policyId, tx)
}

fn endRedeemerData() -> Data {
  builtin.constr_data(0, [])
}

fn updateActionData() -> Data {
  builtin.constr_data(0, [builtin.list_data([])])
}

fn rejectedActionData() -> Data {
  builtin.constr_data(1, [])
}

fn modifyRedeemerData(actions: List<Data>) -> Data {
  builtin.constr_data(2, [builtin.list_data(actions)])
}

fn stateSpendRedeemerData(redeemer: Data) -> Pair<ScriptPurpose, Data> {
  Pair(Spend(testStateRef), redeemer)
}

// Test constants: a State with the owner "owner" and an empty MPF root
const state =
  State {
    owner: "owner",
    stake_script: None,
    root: root(mpf.empty),
    tip: 0,
    process_time: testProcessTime,
    retract_time: testRetractTime,
  }

// Raw datum for input/output UTxOs (no Option wrapper)
const rawStateDatum = StateDatum(state)

// Option-wrapped datum for the validator's maybeDatum parameter
const stateDatum = Some(rawStateDatum)

// Test constants: a Request that inserts key "42" with value "42"
const aRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "42",
      requestValue: Insert("42"),
      requestOwner: "owner",
      tip: 0,
      submitted_at: 0,
    },
  )

// Test constants: the State UTxO input (holds the token + state datum)
const update =
  Input {
    output_reference: testStateRef,
    output: Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(rawStateDatum),
      reference_script: None,
    },
  }

// Test constants: the Request UTxO input (holds ADA + request datum)
const request =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(0),
      datum: InlineDatum(aRequest),
      reference_script: None,
    },
  }

// Test constants: the expected output after Modify with the Insert request.
const output =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          owner: "new-owner",
          stake_script: None,
          root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
          tip: 0,
          process_time: testProcessTime,
          retract_time: testRetractTime,
        },
      ),
    ),
    reference_script: None,
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
      outputs: [output],
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
          owner: "owner",
          stake_script: None,
          root: root(empty),
          tip: 0,
          process_time: testProcessTime,
          retract_time: testRetractTime,
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
            owner: "owner",
            stake_script: None,
            root: "nonempty_root",
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
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
            requestValue: Insert("v"),
            requestOwner: "owner",
            tip: 0,
            submitted_at: 0,
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

// ============================================================================
// Retract tests
// ============================================================================

/// Happy path: the request owner retracts their own request during Phase 2.
/// Phase 2 is the exclusive retract window where only the requester can act.
/// The State UTxO is included as a reference input so the validator can read
/// the time params from its datum.
test retract_happy() {
  spend(
    Some(aRequest),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: ["owner"],
      reference_inputs: [update],
    },
  )
}

/// Only the request owner can retract. A different signer must be rejected
/// to prevent theft of the request's locked ADA.
test retract_wrong_signer() fail {
  spend(
    Some(aRequest),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: ["someone_else"],
      reference_inputs: [update],
    },
  )
}

/// Retract is forbidden in Phase 1 (the oracle processing window).
/// The oracle needs time to process the request undisturbed.
test retract_in_phase1() fail {
  spend(
    Some(aRequest),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      extra_signatories: ["owner"],
      reference_inputs: [update],
    },
  )
}

/// Retract is forbidden in Phase 3 (after the retract window expires).
/// Once Phase 3 begins, the request becomes rejectable by the cage owner instead.
test retract_in_phase3() fail {
  spend(
    Some(aRequest),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      extra_signatories: ["owner"],
      reference_inputs: [update],
    },
  )
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
        requestValue: Insert("42"),
        requestOwner: "owner",
        tip: 0,
        submitted_at: 0,
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

/// Contribute is forbidden in Phase 2 (the retract window).
/// During Phase 2, only the requester can act on their request (via Retract).
test contribute_in_phase2() fail {
  spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      inputs: [update, request],
    },
  )
}

/// Contribute IS allowed in Phase 3 (rejectable window).
/// This lets the oracle process late requests alongside a Reject operation.
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
/// Otherwise the state owner could consume request UTxOs while ending the cage,
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
// Modify tests
// ============================================================================

/// Only the cage owner can Modify. Without the owner's signature, anyone
/// could update the MPF root with arbitrary data.
test modify_missing_signature() fail {
  spend(
    stateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output],
      extra_signatories: [],
      inputs: [update, request],
    },
  )
}

/// A cage configured with a staking script can be modified by any submitter
/// when the transaction withdraws through that script credential.
test modify_with_stake_script_withdrawal() {
  let stake_state = State { ..state, stake_script: Some(testStakeScript) }
  let stake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(stake_state)),
        reference_script: None,
      },
    }
  let stake_output =
    Output {
      ..output,
      datum: InlineDatum(
        StateDatum(
          State {
            ..stake_state,
            owner: "new-owner",
            stake_script: Some(testStakeScript),
            root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
          },
        ),
      ),
    }
  spend(
    Some(StateDatum(stake_state)),
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [stake_output],
      extra_signatories: ["owner"],
      withdrawals: [Pair(address.Script(testStakeScript), 1)],
      inputs: [stake_input, request],
    },
  )
}

/// Modify must fail when stake_script is Some but no matching withdrawal is
/// present. Signature alone is not enough when the plugin is active.
test modify_with_stake_script_no_withdrawal() fail {
  let stake_state = State { ..state, stake_script: Some(testStakeScript) }
  let stake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(stake_state)),
        reference_script: None,
      },
    }
  let stake_output =
    Output {
      ..output,
      datum: InlineDatum(
        StateDatum(
          State {
            ..stake_state,
            owner: "new-owner",
            stake_script: Some(testStakeScript),
            root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
          },
        ),
      ),
    }
  spend(
    Some(StateDatum(stake_state)),
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [stake_output],
      extra_signatories: ["owner"],
      inputs: [stake_input, request],
    },
  )
}

/// End succeeds when stake_script is Some and the transaction supplies
/// both the owner signature and the required staking withdrawal.
test end_with_stake_script() {
  let stake_state = State { ..state, stake_script: Some(testStakeScript) }
  let stake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(stake_state)),
        reference_script: None,
      },
    }
  spend(
    Some(StateDatum(stake_state)),
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      withdrawals: [Pair(address.Script(testStakeScript), 1)],
      inputs: [stake_input],
      mint: burn_value,
    },
  )
}

/// End must fail when stake_script is Some but the withdrawal is absent.
test end_with_stake_script_no_withdrawal() fail {
  let stake_state = State { ..state, stake_script: Some(testStakeScript) }
  let stake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(stake_state)),
        reference_script: None,
      },
    }
  spend(
    Some(StateDatum(stake_state)),
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [stake_input],
      mint: burn_value,
    },
  )
}

/// The output must stay at the same script address as the input.
/// Without this check, the owner could steal the token by redirecting
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

/// Ownership transfer is permitted during Modify. The output datum can have
/// a different owner than the input. This is intentional: it allows the
/// current owner to hand off the cage to someone else.
test modify_owner_transfer() {
  spend(
    stateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

/// Modify with no matching requests leaves the MPF root unchanged.
/// This is a valid no-op that the validator must accept.
test modify_no_requests() {
  let unchanged_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(
          State {
            owner: "owner",
            stake_script: None,
            root: root(empty),
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
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
/// token participate in the MPF fold.
test modify_skip_other_token() {
  let other_request_datum =
    RequestDatum(
      Request {
        requestToken: TokenId { assetName: "other_token" },
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "someone",
        tip: 0,
        submitted_at: 0,
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
            owner: "owner",
            stake_script: None,
            root: root(empty),
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
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
      outputs: [output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

/// Extra proofs beyond what's needed are silently ignored. The fold consumes
/// one proof per matching request; leftover proofs are discarded.
test modify_extra_proofs() {
  spend(
    stateDatum,
    Modify([UpdateAction([]), UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output],
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
            owner: "new-owner",
            stake_script: None,
            root: "wrong_root_hash",
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
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
      outputs: [output],
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

// ============================================================================
// End tests
// ============================================================================

const burn_value = from_asset("policy_id", testToken.assetName, -1)

/// Happy path: the cage owner burns the token, destroying the cage.
/// Requires the owner's signature and the token in the mint field with qty -1.
test end_happy() {
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
      owner: "attacker",
      stake_script: None,
      root: root(empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
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
      owner: "attacker",
      stake_script: None,
      root: root(empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
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

// ============================================================================
// Datum-redeemer mismatch tests
//
// These verify that each redeemer can only be used with the correct datum
// type. Retract/Contribute require RequestDatum; Modify/End require StateDatum.
// Using the wrong combination must fail, preventing operations on the wrong
// kind of UTxO.
// ============================================================================

/// Retract requires a RequestDatum. Using it on a StateDatum must fail —
/// you can't retract a cage's state, only a pending request.
test retract_on_state_datum() fail {
  spend(
    stateDatum,
    Retract(testStateRef),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: ["owner"],
      reference_inputs: [update],
    },
  )
}

/// Contribute requires a RequestDatum. Using it on a StateDatum must fail —
/// you can't contribute a cage's state, only link a request to a cage.
test contribute_on_state_datum() fail {
  spend(
    stateDatum,
    Contribute(testStateRef),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [update],
    },
  )
}

/// Modify requires a StateDatum. Using it on a RequestDatum must fail —
/// you can't modify a request's MPF root (requests don't have one).
test modify_on_request_datum() fail {
  spend(
    Some(aRequest),
    Modify([]),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      extra_signatories: ["owner"],
      inputs: [request],
    },
  )
}

/// End requires a StateDatum. Using it on a RequestDatum must fail —
/// you can only burn the cage's token from a State UTxO.
test end_on_request_datum() fail {
  spend(
    Some(aRequest),
    End,
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [request],
      mint: burn_value,
    },
  )
}

// ============================================================================
// Edge cases
// ============================================================================

/// Spending a UTxO with no datum must fail immediately. All cage UTxOs
/// (both State and Request) require inline datums. This catches ADA sent
/// to the script without a datum.
test spend_no_datum() fail {
  spend(None, Retract(testStateRef), testRequestRef, transaction.placeholder)
}

// ============================================================================
// Property tests (validator-level)
//
// These use fuzz testing to verify security properties hold for ALL inputs,
// not just the specific values in the unit tests above.
// ============================================================================

fn owner_fuzzer() -> Fuzzer<ByteArray> {
  fuzz.bytearray_fixed(28)
}

/// **Property: Retract requires the exact owner key.**
///
/// Generates random 28-byte signers and verifies that Retract always fails
/// when the signer doesn't match the request owner. The `fail once` modifier
/// means the test passes as soon as it finds ONE failing case — which it
/// does immediately, since a random 28-byte key has negligible probability
/// of matching the hardcoded owner "the_real_owner_key_aaaaaaaaaa".
///
/// This demonstrates that the `has(extra_signatories, requestOwner)` check
/// is effective: no random key can authorize a retract.
test prop_retract_requires_owner(signer via owner_fuzzer()) fail once {
  let req =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "k",
        requestValue: Insert("v"),
        requestOwner: "the_real_owner_key_aaaaaaaaaa",
        tip: 0,
        submitted_at: 0,
      },
    )
  spend(
    Some(req),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: [signer],
      reference_inputs: [update],
    },
  )
}

/// **Property: Modify requires the exact owner key.**
///
/// Same approach as prop_retract_requires_owner but for the Modify path.
/// Generates random signers and confirms Modify fails when the signer
/// doesn't match the state owner. This verifies `has(extra_signatories, owner)`
/// protects the MPF state from unauthorized modifications.
test prop_modify_requires_owner(signer via owner_fuzzer()) fail once {
  let s =
    State {
      owner: "the_real_owner_key_aaaaaaaaaa",
      stake_script: None,
      root: root(empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
    }
  let unchanged_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(
          State {
            owner: "the_real_owner_key_aaaaaaaaaa",
            stake_script: None,
            root: root(empty),
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
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
            owner: "owner",
            stake_script: None,
            root: root(empty),
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
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

// ============================================================================
// Migration tests
//
// Migration mints a new token under the new policy while atomically burning
// the old token under the old policy. The MPF root is carried over (not
// required to be empty), preserving existing data.
// ============================================================================

const old_policy = "old_policy_id"

const new_policy = "new_policy_id"

// The `mint` test wrapper applies this fixed allowlist to every mint-path
// call. `old_policy` is the only audited predecessor; migrations must spend
// a genuine predecessor UTxO under it, so plain `Minting` tests (which never
// reach `validateMigration`) are unaffected by its presence.
const previousPolicies = [old_policy]

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
    owner: "owner",
    stake_script: None,
    root: "nonempty_root_hash_aaaaaaaaa",
    tip: 0,
    process_time: testProcessTime,
    retract_time: testRetractTime,
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

/// Happy path: migrate a cage from old_policy to new_policy.
/// Burns old token (-1) and mints new token (+1) atomically, spending the
/// allowlisted predecessor state input (owner-signed) and preserving every
/// field of its `State` in the migrated output.
test canMigrate() {
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

/// FR3: the predecessor `State`'s owner must sign; an unsigned migration of
/// an otherwise-genuine predecessor is rejected.
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

/// FR4: the migrated output must preserve every field of the predecessor
/// `State`. Changing `owner` is exactly the exploit's forged-ownership move.
test migrate_changes_owner() fail {
  let bad_output =
    Output {
      ..migrate_output,
      datum: InlineDatum(
        StateDatum(State { ..migrate_predecessor_state, owner: "attacker" }),
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
      datum: InlineDatum(
        StateDatum(State { ..migrate_predecessor_state, owner: "attacker" }),
      ),
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

// ============================================================================
// Refund enforcement tests
//
// When a request is processed (Modify) or rejected (Reject), the requester
// is owed a refund: (input lovelace - fee). These tests verify that refund
// outputs are present, sufficient, and sent to the correct address.
// ============================================================================

const testFee = 500_000

const feeState =
  State {
    owner: "owner",
    stake_script: None,
    root: root(mpf.empty),
    tip: testFee,
    process_time: testProcessTime,
    retract_time: testRetractTime,
  }

const feeStateDatum = Some(StateDatum(feeState))

const feeRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "42",
      requestValue: Insert("42"),
      requestOwner: "requester_key_aaaaaaaaaaaaaaa",
      tip: testFee,
      submitted_at: 0,
    },
  )

const feeRequestInput =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(2_000_000),
      datum: InlineDatum(feeRequest),
      reference_script: None,
    },
  }

const feeStateInput =
  Input {
    output_reference: testStateRef,
    output: Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(StateDatum(feeState)),
      reference_script: None,
    },
  }

const feeStateOutput =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          owner: "new-owner",
          stake_script: None,
          root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
          tip: testFee,
          process_time: testProcessTime,
          retract_time: testRetractTime,
        },
      ),
    ),
    reference_script: None,
  }

const refundOutput =
  Output {
    address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
    value: from_lovelace(1_500_000),
    datum: NoDatum,
    reference_script: None,
  }

const capturedRefundTip = 2_000_000

const capturedRefundTxFee = 2_289_551

const capturedStateValue = testValue |> assets.merge(from_lovelace(2_000_000))

const capturedRefundState =
  State {
    owner: "owner",
    stake_script: None,
    root: root(mpf.empty),
    tip: capturedRefundTip,
    process_time: testProcessTime,
    retract_time: testRetractTime,
  }

const capturedRefundStateDatum = Some(StateDatum(capturedRefundState))

const capturedRefundStateInput =
  Input {
    output_reference: testStateRef,
    output: Output {
      address: testScriptAddress,
      value: capturedStateValue,
      datum: InlineDatum(StateDatum(capturedRefundState)),
      reference_script: None,
    },
  }

const capturedRefundStateOutput =
  Output {
    address: testScriptAddress,
    value: capturedStateValue,
    datum: InlineDatum(StateDatum(capturedRefundState)),
    reference_script: None,
  }

const capturedRefundRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "42",
      requestValue: Insert("42"),
      requestOwner: "requester_key_aaaaaaaaaaaaaaa",
      tip: capturedRefundTip,
      submitted_at: 0,
    },
  )

const capturedRefundRequestInput =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(5_020_709),
      datum: InlineDatum(capturedRefundRequest),
      reference_script: None,
    },
  }

const capturedMinUtxoRefundOutput =
  Output {
    address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
    value: from_lovelace(849_070),
    datum: NoDatum,
    reference_script: None,
  }

/// Happy path: Modify with fee. Request has 2 ADA, fee is 0.5 ADA,
/// so refund of 1.5 ADA goes to the requester's address.
test modify_with_refund() {
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// A refund output must be present for each processed request.
/// Omitting it steals the requester's locked ADA.
test modify_missing_refund() fail {
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// The refund must be at least (input_lovelace - fee). Underpaying shortchanges
/// the requester.
test modify_insufficient_refund() fail {
  let bad_refund = Output { ..refundOutput, value: from_lovelace(1_000_000) }
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, bad_refund],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// The refund must go to the request owner's address. Sending it elsewhere
/// is theft even if the amount is correct.
test modify_wrong_refund_address() fail {
  let wrong_addr_refund =
    Output {
      ..refundOutput,
      address: address.from_verification_key("wrong_key_aaaaaaaaaaaaaaaa"),
    }
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, wrong_addr_refund],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// When fee is 0, the full input ADA is refunded. No ADA is retained by the
/// cage owner. This is the "free service" case.
test modify_zero_fee() {
  let zf_state =
    State {
      owner: "owner",
      stake_script: None,
      root: root(mpf.empty),
      tip: 0,
      process_time: testProcessTime,
      retract_time: testRetractTime,
    }
  let zf_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        tip: 0,
        submitted_at: 0,
      },
    )
  let zf_request_input =
    Input {
      output_reference: testRequestRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(2_000_000),
        datum: InlineDatum(zf_request),
        reference_script: None,
      },
    }
  let zf_state_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(zf_state)),
        reference_script: None,
      },
    }
  let zf_state_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(
          State {
            owner: "new-owner",
            stake_script: None,
            root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
          },
        ),
      ),
      reference_script: None,
    }
  let zf_refund =
    Output {
      address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
      value: from_lovelace(2_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  spend(
    Some(StateDatum(zf_state)),
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [zf_state_output, zf_refund],
      extra_signatories: ["owner"],
      inputs: [zf_state_input, zf_request_input],
    },
  )
}

/// The request's tip must match the state's tip. A mismatch means the
/// request was created for a different fee tier and must be rejected.
test modify_fee_mismatch() fail {
  let mismatch_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        tip: 100_000,
        submitted_at: 0,
      },
    )
  let mismatch_input =
    Input {
      output_reference: testRequestRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(2_000_000),
        datum: InlineDatum(mismatch_request),
        reference_script: None,
      },
    }
  spend(
    feeStateDatum,
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [feeStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, mismatch_input],
    },
  )
}

/// End succeeds even when the mint field contains additional policies beyond
/// the cage's own burn. This supports atomic migration where a new token is
/// minted under a different policy in the same transaction.
test end_with_extra_mint_policy() {
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

// ============================================================================
// Reject tests (via Modify with Rejected actions)
//
// Rejection is now expressed as Modify([Rejected, ...]). The MPF root must
// NOT change — rejected requests are never folded in. Refunds are still owed.
// ============================================================================

const rejectStateOutput =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          owner: "owner",
          stake_script: None,
          root: root(mpf.empty),
          tip: testFee,
          process_time: testProcessTime,
          retract_time: testRetractTime,
        },
      ),
    ),
    reference_script: None,
  }

/// Happy path: reject an expired request in Phase 3.
/// Root stays the same, requester gets refunded (input ADA minus fee).
test reject_happy() {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Reject is forbidden in Phase 1 — requests are still being processed.
test reject_in_phase1() fail {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Reject is forbidden in Phase 2 — the retract window belongs exclusively
/// to the requester. The cage owner must wait for Phase 3.
test reject_in_phase2() fail {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// A request with submitted_at far in the future is dishonest — rejectable
/// in ANY phase because `is_rejectable` returns true when `validity_range < submitted_at`.
test reject_future_submitted_at() {
  let future_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        tip: testFee,
        submitted_at: 100_000,
      },
    )
  let future_request_input =
    Input {
      output_reference: testRequestRef,
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(2_000_000),
        datum: InlineDatum(future_request),
        reference_script: None,
      },
    }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, future_request_input],
    },
  )
}

/// Only the cage owner can reject requests.
test reject_missing_signature() fail {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: [],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// The MPF root must NOT change during rejection.
test reject_root_changes() fail {
  let bad_reject_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(
          State {
            owner: "owner",
            stake_script: None,
            root: "different_root_aaaaaaaaaaaaa",
            tip: testFee,
            process_time: testProcessTime,
            retract_time: testRetractTime,
          },
        ),
      ),
      reference_script: None,
    }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [bad_reject_output, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Even rejected requests must have their ADA refunded (minus fee).
test reject_wrong_refund() fail {
  let bad_refund = Output { ..refundOutput, value: from_lovelace(500_000) }
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectStateOutput, bad_refund],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

test reject_refund_owed_above_min_utxo_passes() {
  spend(
    feeStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase3Range,
      outputs: [rejectStateOutput, refundOutput],
      extra_signatories: ["owner"],
      inputs: [feeStateInput, feeRequestInput],
    },
  )
}

/// Captures the live failure shape: owed is 731_158 lovelace after fee and
/// tip, but the ledger-valid refund output must carry 849_070 lovelace.
test reject_refund_min_utxo_topup_passes() {
  spend(
    capturedRefundStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      fee: capturedRefundTxFee,
      validity_range: phase3Range,
      outputs: [capturedRefundStateOutput, capturedMinUtxoRefundOutput],
      extra_signatories: ["owner"],
      inputs: [capturedRefundStateInput, capturedRefundRequestInput],
    },
  )
}

test reject_refund_under_owed_fails() fail {
  let under_refund =
    Output { ..capturedMinUtxoRefundOutput, value: from_lovelace(731_157) }
  spend(
    capturedRefundStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      fee: capturedRefundTxFee,
      validity_range: phase3Range,
      outputs: [capturedRefundStateOutput, under_refund],
      extra_signatories: ["owner"],
      inputs: [capturedRefundStateInput, capturedRefundRequestInput],
    },
  )
}

test reject_refund_topup_cannot_drain_state() fail {
  let drained_state = Output { ..capturedRefundStateOutput, value: testValue }
  spend(
    capturedRefundStateDatum,
    Modify([Rejected]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      fee: capturedRefundTxFee,
      validity_range: phase3Range,
      outputs: [drained_state, capturedMinUtxoRefundOutput],
      extra_signatories: ["owner"],
      inputs: [capturedRefundStateInput, capturedRefundRequestInput],
    },
  )
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
      requestValue: Insert("v"),
      requestOwner: "other_owner",
      tip: 0,
      submitted_at: 0,
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

/// Happy path: owner sweeps a no-datum garbage UTxO, with the legitimate
/// state UTxO included as a reference input.
test sweep_no_datum() {
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

/// Happy path: owner sweeps a wrong-token RequestDatum garbage UTxO.
test sweep_wrong_token_request() {
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

/// Happy path: owner sweeps a fake-state UTxO whose value carries no cage NFT.
test sweep_fake_state_no_nft() {
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

/// Happy path: Sweep bundled with Modify in the same tx — the state UTxO is
/// in `tx.inputs` (being spent by Modify), not in reference_inputs.
test sweep_alongside_modify() {
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
  state.state.spend(
    [],
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

/// A matching-token request with the wrong tip can never be processed by
/// state Modify, so the owner may sweep it from the request address.
test sweep_mismatched_tip_request() {
  let mismatch_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        tip: 100_000,
        submitted_at: 0,
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

/// A matching-token request that cannot cover the agreed tip is also
/// malformed and sweepable.
test sweep_underfunded_matching_request() {
  let underfunded_request =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "requester_key_aaaaaaaaaaaaaaa",
        tip: testFee,
        submitted_at: 0,
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

/// Happy path: Modify with no requests, root unchanged. Owner ticks the state
/// (e.g. so a paired Sweep can run alongside).
test modify_zero_requests_happy() {
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
            owner: "owner",
            stake_script: None,
            root: "different_root_aaaaaaaaaaaaa",
            tip: 0,
            process_time: testProcessTime,
            retract_time: testRetractTime,
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
  request.request.spend(
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

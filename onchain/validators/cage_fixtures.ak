use aiken/builtin
use aiken/fuzz
use aiken/interval
use aiken/merkle_patricia_forestry.{root}
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{from_script}
use cardano/assets.{from_asset, from_lovelace}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, ScriptPurpose, Spend,
}
use lib
use lib.{assetName, valueFromToken}
use types.{
  Request, RequestDatum, State, StateDatum, TokenId,
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
///   an empty MPF root (no owner field exists).
///
/// - **Request UTxO** (`request`): an edge-1 (insertActive) request targeting `testToken`,
///   submitted at time 0.
///
/// - **Expected output** (`output`): the State UTxO after processing the Insert,
///   with the computed MPF root.
pub const testProcessTime = 10_000

pub const testRetractTime = 10_000

/// The four policies the eight-field `State` pins (#157 C7). The active
/// policy keeps the 0xaa bytes the representative policy had, so the
/// preservation rows that used 0xbb for the altered case still read the
/// same way; the application, absent and terminal policies are the three
/// the ticket adds.
pub const testRepPolicy =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

pub const testAppPolicy =
  #"a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9"

pub const testAbsentPolicy =
  #"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"

pub const testTerminalPolicy =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

/// The destination of a request that names none (#157 D-DEST): the
/// requests in this module exercise the cage's non-registry paths —
/// minting, contribute, retract, sweep, rejection — none of which moves
/// a token to a destination. The registry-mode rows build their own.
pub const noDestination: (ByteArray, ByteArray) = (#"", #"")

// Phase 1 validity range: [0, 5_000] — entirely before submitted_at(0) + process_time(10_000)
pub const phase1Range = interval.between(0, 5_000)

// Phase 2 validity range: [10_000, 15_000] — after process_time, before process_time + retract_time
pub const phase2Range = interval.between(10_000, 15_000)

// Phase 3 validity range: [20_000, 25_000] — after process_time + retract_time
pub const phase3Range = interval.between(20_000, 25_000)

// Test constants: a script address used for all test UTxOs
pub const testScriptAddress = from_script("policy_id")

// Test seed parameter: the validator's `seed: OutputReference` parameter
// for all tests. The mint tests deliberately use this exact ref as the
// consumed input so `validateMint`'s seed-consumption check passes.
pub const testSeed =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

// Test constants: output references for State and Request UTxOs
pub const testStateRef =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

pub const testRequestRef =
  OutputReference { transaction_id: "2234567890abcdef", output_index: 254 }

// Test constants: a token ID derived from `testSeed`. With the per-token
// validator parameterization, the cage's canonical token id is
// `assetName(seed)`, so test fixtures must use the seed-derived asset name
// — otherwise the spend handler's defense-in-depth check
// (`extractedToken == cageToken`) rejects them.
pub const testToken = TokenId { assetName: assetName(testSeed) }

pub const testValue = valueFromToken("policy_id", testToken)

pub const burn_value = from_asset("policy_id", testToken.assetName, -1)

pub const testStakeScript = "test_stake_script"

pub fn endRedeemerData() -> Data {
  builtin.constr_data(0, [])
}

pub fn updateActionData() -> Data {
  builtin.constr_data(0, [builtin.list_data([])])
}

pub fn rejectedActionData() -> Data {
  builtin.constr_data(1, [])
}

pub fn modifyRedeemerData(actions: List<Data>) -> Data {
  builtin.constr_data(2, [builtin.list_data(actions)])
}

pub fn stateSpendRedeemerData(redeemer: Data) -> Pair<ScriptPurpose, Data> {
  Pair(Spend(testStateRef), redeemer)
}

// Test constants: a State with an empty MPF root
pub const state =
  State {
    root: root(mpf.empty),
    tip: 0,
    process_time: testProcessTime,
    retract_time: testRetractTime,
    application_policy: testAppPolicy,
    active_policy: testRepPolicy,
    absent_policy: testAbsentPolicy,
    terminal_policy: testTerminalPolicy
  }

// Raw datum for input/output UTxOs (no Option wrapper)
pub const rawStateDatum = StateDatum(state)

// Option-wrapped datum for the validator's maybeDatum parameter
pub const stateDatum = Some(rawStateDatum)

// Test constants: a Request that inserts key "42" (edge 1, value `0x01`)
/// Registry-mode shape for this module's shared fold fixture (#157):
/// the request books `"42"` at edge 1 — so the fixture describes
/// a real edge of C2 instead of the pre-#157 "any bytes" registry. Every
/// `Modify` row below therefore refuses for ITS OWN reason rather than
/// at the leaf codec.
pub const legacyKey: ByteArray = "42"

/// An enterprise payment-key address, as `destination` carries it.
pub const legacyWallet: ByteArray =
  #"60eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

pub const legacyDestination: (ByteArray, ByteArray) = (legacyWallet, #"")

/// The approval the application minted for exactly this request.
pub const legacyApproval =
  from_asset(
    testAppPolicy,
    lib.approvalName(1, legacyKey, "owner", legacyDestination),
    1,
  )

/// The `+1 active` the booking entails, and the output it must land in.
pub const legacyMint = from_asset(testRepPolicy, legacyKey, 1)

pub const legacyDelivery =
  Output {
    address: address.from_verification_key(
      #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    ),
    value: from_asset(testRepPolicy, legacyKey, 1),
    datum: NoDatum,
    reference_script: None,
  }

/// The root after the booking folds.
pub const legacyRoot = mpf.root(mpf.insert(mpf.empty, legacyKey, #"01", []))

/// The delivery output for the fee fixture: its request carries 2 ADA
/// against a 500_000 tip, so the deposit the fold returns is the
/// difference — 2_000_000 less the 500_000 `testFee` (#157 T6).
/// The zero-tip variant: the whole 2 ADA rides back to the destination.
pub const zfDelivery =
  Output {
    address: address.from_verification_key(
      #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    ),
    value: from_asset(testRepPolicy, legacyKey, 1)
      |> assets.merge(from_lovelace(2_000_000)),
    datum: NoDatum,
    reference_script: None,
  }

pub const feeDelivery =
  Output {
    address: address.from_verification_key(
      #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    ),
    value: from_asset(testRepPolicy, legacyKey, 1)
      |> assets.merge(from_lovelace(1_500_000)),
    datum: NoDatum,
    reference_script: None,
  }

pub const testFee = 500_000

pub const feeState =
  State {
    root: root(mpf.empty),
    tip: testFee,
    process_time: testProcessTime,
    retract_time: testRetractTime,
    application_policy: testAppPolicy,
    active_policy: testRepPolicy,
    absent_policy: testAbsentPolicy,
    terminal_policy: testTerminalPolicy
  }

pub const feeStateDatum = Some(StateDatum(feeState))

pub const feeOwner: ByteArray = "requester_key_aaaaaaaaaaaaaaa"

pub const feeApproval =
  from_asset(
    testAppPolicy,
    lib.approvalName(1, legacyKey, feeOwner, legacyDestination),
    1,
  )

pub const feeRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: legacyKey,
      edge: 1,
      requestOwner: feeOwner,
      deposit: 1_500_000,
      submitted_at: 0,
      destination: legacyDestination,
    },
  )

pub const feeRequestInput =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(2_000_000) |> assets.merge(feeApproval),
      datum: InlineDatum(feeRequest),
      reference_script: None,
    },
  }

pub const feeStateInput =
  Input {
    output_reference: testStateRef,
    output: Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(StateDatum(feeState)),
      reference_script: None,
    },
  }

pub const feeStateOutput =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          root: legacyRoot,
          tip: testFee,
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

pub const refundOutput =
  Output {
    address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
    value: from_lovelace(1_500_000),
    datum: NoDatum,
    reference_script: None,
  }

pub const rejectedStateOutput =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(StateDatum(feeState)),
    reference_script: None,
  }

pub const capturedRefundTip = 2_000_000

pub const capturedRefundTxFee = 2_289_551

pub const capturedStateValue =
  testValue |> assets.merge(from_lovelace(2_000_000))

pub const capturedRefundState =
  State {
    root: root(mpf.empty),
    tip: capturedRefundTip,
    process_time: testProcessTime,
    retract_time: testRetractTime,
    application_policy: testAppPolicy,
    active_policy: testRepPolicy,
    absent_policy: testAbsentPolicy,
    terminal_policy: testTerminalPolicy
  }

pub const capturedRefundStateDatum = Some(StateDatum(capturedRefundState))

pub const capturedRefundStateInput =
  Input {
    output_reference: testStateRef,
    output: Output {
      address: testScriptAddress,
      value: capturedStateValue,
      datum: InlineDatum(StateDatum(capturedRefundState)),
      reference_script: None,
    },
  }

pub const capturedRefundStateOutput =
  Output {
    address: testScriptAddress,
    value: capturedStateValue,
    datum: InlineDatum(StateDatum(capturedRefundState)),
    reference_script: None,
  }

pub const capturedRefundRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "42",
      edge: 1,
      requestOwner: "requester_key_aaaaaaaaaaaaaaa",
      deposit: 3_020_709,
      submitted_at: 0,
      destination: noDestination,
    },
  )

pub const topupRefundRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "42",
      edge: 1,
      requestOwner: "requester_key_aaaaaaaaaaaaaaa",
      deposit: 500_000,
      submitted_at: 0,
      destination: noDestination,
    },
  )

pub const capturedRefundRequestInput =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(5_020_709),
      datum: InlineDatum(capturedRefundRequest),
      reference_script: None,
    },
  }

pub const capturedMinUtxoRefundOutput =
  Output {
    address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
    value: from_lovelace(849_070),
    datum: NoDatum,
    reference_script: None,
  }

pub const topupSmallRequestInput =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(2_500_000),
      datum: InlineDatum(topupRefundRequest),
      reference_script: None,
    },
  }

pub const aRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: legacyKey,
      edge: 1,
      requestOwner: "owner",
      deposit: 0,
      submitted_at: 0,
      destination: legacyDestination,
    },
  )

// Test constants: the State UTxO input (holds the token + state datum)
pub const update =
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
pub const request =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: legacyApproval,
      datum: InlineDatum(aRequest),
      reference_script: None,
    },
  }

// Test constants: the expected output after Modify with the Insert request.
pub const output =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          root: legacyRoot,
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


pub fn owner_fuzzer() -> Fuzzer<ByteArray> {
  fuzz.bytearray_fixed(28)
}

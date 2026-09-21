use aiken/builtin
use aiken/fuzz
use aiken/interval
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/bytearray
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

// ============================================================================

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
// Retract tests
// ============================================================================

/// The request owner's key hash, as a 28-byte stand-in (Cardano ed25519
/// key hashes are 28 bytes, so this is a ledger-REPRESENTABLE signer).
/// The final byte 0x61 ('a') is what makes the generated non-owner
/// signers below structurally distinct from it.
const retractOwner: ByteArray = "the_real_owner_key_aaaaaaaaa"

/// A second, different 28-byte key hash for the paired refusal row.
const retractNotOwner: ByteArray = "the_real_owner_key_bbbbbbbbb"

fn retractRequest() -> CageDatum {
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "k",
      edge: 1,
      requestOwner: retractOwner,
      deposit: 0,
      submitted_at: 0,
      destination: noDestination,
    },
  )
}

/// Happy path: the request owner retracts their own request during Phase 2.
/// Phase 2 is the exclusive retract window where only the requester can act.
/// The State UTxO is included as a reference input so the validator can read
/// the time params from its datum. This is the ACCEPTING control for the
/// authorization boundary below: same request, same phase, only the signer
/// differs. (Boundary note: the harness executes the script struct only —
/// a correctly sized key hash makes the shape ledger-representable, it does
/// not by itself establish a complete ledger transaction.)
test retract_happy() {
  spend(
    Some(retractRequest()),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: [retractOwner],
      reference_inputs: [update],
    },
  )
}

/// Only the request owner can retract. A different signer must be rejected
/// to prevent theft of the request's locked ADA. Paired with `retract_happy`:
/// same request datum, same Phase 2 window, ONLY the signer changed
/// (`retractNotOwner` vs `retractOwner`, both 28-byte key hashes).
test retract_wrong_signer() fail {
  spend(
    Some(retractRequest()),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: [retractNotOwner],
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
/// Once Phase 3 begins, the request becomes rejectable by any folder instead.
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

/// **Retract refuses EVERY signer that is not the request owner — exact
/// `False` for each generated case** (historic name:
/// `prop_retract_requires_owner`, #197).
///
/// Owner and generated signers are BOTH 28-byte key hashes (Cardano
/// ed25519 key-hash size), so the property is about authorization between
/// valid representations, never about an impossible owner length. The
/// non-owner inequality is STRUCTURAL: each signer extends a fuzzed
/// 27-byte prefix with final byte 0xFF while the owner's final byte is
/// 0x61, so no generated case can be the owner and the property is
/// exclusively about non-owner authorization.
///
/// This asserts the validator's refusal EXACTLY (`== False`, the named
/// `retract-owner` refusal) for EVERY case. It replaced a `fail once`
/// existential that was satisfied by the first random refusal and so
/// kept passing while a mutated validator accepted a wrong signer whose
/// first byte was even (the #197 control evidence; the all-zero signer
/// was accepted and the old test still reported pass). The paired
/// accepting control is `retract_happy`: same request, same phase, only
/// the signer changed.
test prop_retract_refuses_every_non_owner_signer(
  prefix via fuzz.bytearray_fixed(27),
) {
  let signer = bytearray.concat(prefix, #[255])
  spend(
    Some(retractRequest()),
    Retract(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase2Range,
      extra_signatories: [signer],
      reference_inputs: [update],
    },
  ) == False
}

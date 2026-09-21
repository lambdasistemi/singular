use cardano/address
use application
use application.{Maintain, Recover, Retire}
use aiken/crypto.{blake2b_256}
use aiken/primitive/bytearray
use cardano/assets.{add, from_lovelace, zero}
use cardano/transaction.{InlineDatum, NoDatum, Output}
use fixtures.{
  as_datum,
  altered_control, app_policy, burn_approval, claim_input,
  claim_value_with_approval, continuation_output, controller, custody_address,
  deposit, member2, member3,
  mock_registry_token,
  redirected_output_address,
  redirected_refund, refund_destination, refund_output_address, rep_policy,
  self_ref, state_datum,
  source_record, record_value, tampered_commitment, tx, with_commitment,
  with_quorum,

}
use naming
use naming.{RetirementQuorum, mpfs_state_hash, mpfs_state_policy}

// ===========================================================================
// Mirror contract — the registry state datum (NOTE-013, sixth field)
// ===========================================================================

/// The six-field registry state datum decodes through the mirror and
/// yields the carried representative policy. A mirror that drifts from
/// onchain `State` field order or arity refuses here instead of deep
/// inside fold/retire rows.
test mirror_decodes_registry_state() {
  expect mpfs_state_policy(state_datum()) == rep_policy
  True
}

// ===========================================================================
// Maintenance — the LM rows
// ===========================================================================

/// LM01-maintenance-accepts: the controller signs; only the payment
/// destination is maintained (Some(destination) -> none); control,
/// commitment and quorum are preserved; the record's value continues.
test lm01_maintenance_accepts() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(maintained), record_value)],
      [controller],
      zero,
      [],
    ),
  )
}

/// LM02-maintenance-unauthorized-refused: the control signature is the
/// only difference; its absence alone refuses.
test lm02_maintenance_unauthorized_refuses() fail {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(maintained), record_value)],
      [],
      zero,
      [],
    ),
  )
}

/// LM03-maintenance-field-tamper-refused: signed, but the
/// next-control commitment was tampered with.
test lm03_commitment_tamper_refuses() fail {
  let source = source_record()
  let tampered = with_commitment(
    fixtures.maintained_record(),
    tampered_commitment,
  )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(tampered), record_value)],
      [controller],
      zero,
      [],
    ),
  )
}

/// LM04-maintenance-quorum-alteration-refused: signed, but the
/// retirement quorum was altered — it is not maintainable.
test lm04_quorum_alteration_refuses() fail {
  let source = source_record()
  let altered = with_quorum(
    fixtures.maintained_record(),
    RetirementQuorum {
      threshold: 2,
      members: [fixtures.member1, fixtures.member2],
    },
  )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(altered), record_value)],
      [controller],
      zero,
      [],
    ),
  )
}

/// Negation of control preservation: a signed maintenance that swaps
/// the control address refuses.
test maintenance_control_tamper_refuses() fail {
  let source = source_record()
  let swapped =
    fixtures.with_control(fixtures.maintained_record(), altered_control)
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(swapped), record_value)],
      [controller],
      zero,
      [],
    ),
  )
}

/// Negation of the continuation requirement: no successor, no
/// maintenance.
test maintenance_without_continuation_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [],
      [controller],
      zero,
      [],
    ),
  )
}

/// Negation of exactly-one-continuation: two records at the
/// application address is not a maintenance.
test maintenance_with_two_continuations_refuses() fail {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  let continuation =
    continuation_output(fixtures.as_datum(maintained), record_value)
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation, continuation],
      [controller],
      zero,
      [],
    ),
  )
}

/// Negation of value preservation: the record's value may not shrink.
test maintenance_value_shrink_refuses() fail {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(
        as_datum(maintained),
        from_lovelace(deposit - 1),
      )],
      [controller],
      zero,
      [],
    ),
  )
}

/// A destination-preserving maintenance (no change at all) also
/// accepts: the destination is free either way.
test maintenance_identity_candidate_accepts() {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(source), record_value)],
      [controller],
      zero,
      [],
    ),
  )
}

// ===========================================================================
// Cancellation — the LC rows, via the withdraw approval bound to the
// stored refund destination
// ===========================================================================

// ===========================================================================
// Fold and retire — the claim/record transitions
// ===========================================================================

/// Negation: a retire that smuggles the record through as a
/// continuation refuses.
test retire_with_continuation_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire { key: fixtures.registry_key, revealed_control: recovery_revealed },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(source), record_value)],
      [],
      zero,
      [],
    ),
  )
}

// ===========================================================================
// The application policy's mint purpose — withdraw approvals
// ===========================================================================

// ===========================================================================
// Recovery — the LR rows (issue #62, RED: Recover does not exist yet)
// ===========================================================================

const recovery_revealed =
  #"611d1e1f202122232425262728292a2b2c2d2e2f303132333435363738"

const recovery_revealed_hash =
  #"1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738"

const recovery_rep =
  #"61aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0d1d2d3d4"

fn recovery_commitment(revealed: ByteArray) -> ByteArray {
  blake2b_256(
    bytearray.concat(
      bytearray.concat(
        bytearray.from_string(@"singular/naming/next-control/v1"),
        #"00",
      ),
      revealed,
    ),
  )
}

fn recovery_record_value() {
  add(record_value, app_policy, recovery_rep, 1)
}

fn recovery_source() {
  with_commitment(source_record(), recovery_commitment(recovery_revealed))
}

fn recovery_successor() {
  let source = recovery_source()
  let with_new_control = fixtures.with_control(source, recovery_revealed)
  with_commitment(
    with_new_control,
    recovery_commitment(
      #"61e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfc",
    ),
  )
}

test lr01_recovery_accepts() {
  let source = recovery_source()
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        recovery_record_value(),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

const recovery_wrong_revealed =
  #"61393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f5051525354"

const recovery_wrong_hash =
  #"393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f5051525354"

const recovery_rep_tampered =
  #"61aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0d1d2d3d5"

const recovery_fresh_address =
  #"61e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfc"

const recovery_fresh_address2 =
  #"61c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdc"

const recovery_script_reveal =
  #"710102030405060708090a0b0c0d0e0f101112131415161718191a1b1c"

/// `LR06`: the commitment WITHOUT its domain separation — the forged
/// digest that passes iff the separation is dropped.
fn forged_commitment(revealed: ByteArray) -> ByteArray {
  blake2b_256(revealed)
}

test lr02_wrong_reveal_refuses() fail {
  let source = recovery_source()
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_wrong_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        recovery_record_value(),
      )],
      [recovery_wrong_hash],
      zero,
      [],
    ),
  )
}

test lr03_missing_signer_refuses() fail {
  let source = recovery_source()
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        recovery_record_value(),
      )],
      [],
      zero,
      [],
    ),
  )
}

test lr04_replay_refuses() fail {
  let consumed_reveal = recovery_revealed
  let successor_as_source =
    with_commitment(
      fixtures.with_control(source_record(), consumed_reveal),
      recovery_commitment(recovery_fresh_address),
    )
  let candidate =
    with_commitment(
      fixtures.with_control(source_record(), consumed_reveal),
      recovery_commitment(recovery_fresh_address2),
    )
  let successor_value =
    add(record_value, app_policy, recovery_rep, 1)
  application.application.spend(
    Some(fixtures.as_datum(successor_as_source)),
    Recover {
      revealed_control: consumed_reveal,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(successor_as_source), successor_value)],
      [continuation_output(fixtures.as_datum(candidate), successor_value)],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

test lr05_old_controller_refuses() fail {
  let recovered =
    fixtures.with_control(source_record(), recovery_revealed)
  let maintained =
    fixtures.with_control(fixtures.maintained_record(), recovery_revealed)
  application.application.spend(
    Some(fixtures.as_datum(recovered)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(recovered), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(maintained),
        recovery_record_value(),
      )],
      [controller],
      zero,
      [],
    ),
  )
}

test lr05_recovered_controller_maintains_accepts() {
  let recovered =
    fixtures.with_control(source_record(), recovery_revealed)
  let maintained =
    fixtures.with_control(fixtures.maintained_record(), recovery_revealed)
  application.application.spend(
    Some(fixtures.as_datum(recovered)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(recovered), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(maintained),
        recovery_record_value(),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

test lr06_forged_digest_refuses() fail {
  let source =
    with_commitment(source_record(), forged_commitment(recovery_revealed))
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        recovery_record_value(),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

test lr07_wrong_signer_refuses() fail {
  let source = recovery_source()
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        recovery_record_value(),
      )],
      [controller],
      zero,
      [],
    ),
  )
}

test lr08_missing_fresh_refuses() fail {
  let source = recovery_source()
  let stale =
    with_commitment(
      fixtures.with_control(source, recovery_revealed),
      recovery_commitment(recovery_revealed),
    )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(fixtures.as_datum(stale), recovery_record_value())],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

test lr10_registry_tamper_refuses() fail {
  let source = recovery_source()
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: rep_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        recovery_record_value(),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

test lr11_quorum_tamper_refuses() fail {
  let source = recovery_source()
  let tampered =
    with_quorum(
      fixtures.with_control(source, recovery_revealed),
      RetirementQuorum {
        threshold: 2,
        members: [fixtures.member1, fixtures.member2],
      },
    )
  let tampered_successor =
    with_commitment(
      tampered,
      recovery_commitment(recovery_fresh_address),
    )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(tampered_successor),
        recovery_record_value(),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

test recovery_script_reveal_refuses() fail {
  let source =
    with_commitment(
      source_record(),
      recovery_commitment(recovery_script_reveal),
    )
  let successor =
    with_commitment(
      fixtures.with_control(source, recovery_script_reveal),
      recovery_commitment(recovery_fresh_address),
    )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_script_reveal,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        recovery_record_value(),
      )],
      [controller],
      zero,
      [],
    ),
  )
}

test recovery_destination_tamper_refuses() fail {
  let source = recovery_source()
  let maintained = fixtures.maintained_record()
  let cleared_destination = maintained.payment_destination
  let redirected =
    fixtures.with_destination(
      fixtures.with_control(source, recovery_revealed),
      cleared_destination,
    )
  let redirected_successor =
    with_commitment(
      redirected,
      recovery_commitment(recovery_fresh_address),
    )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(redirected_successor),
        recovery_record_value(),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

// ===========================================================================
// Retirement — the LT rows (issue #66, RED: Retire is a stub)
// ===========================================================================

fn retirement_tx(inputs, outputs, signers, mint, redeemers) {
  let base = tx(inputs, outputs, signers, mint, redeemers)
  transaction.Transaction {
    ..base,
    reference_inputs: [fixtures.state_input()],
    withdrawals: [Pair(address.Script(rep_policy), 0)],
  }
}

/// The retirement source: control distinct from the quorum so each route
/// is shown sufficient alone — the controller hash (member1) is not among
/// the quorum members [member2, member3], threshold 2.
fn retirement_source() {
  with_quorum(
    source_record(),
    RetirementQuorum { threshold: 2, members: [member2, member3] },
  )
}

fn retirement_claim_value() {
  // #157 D-ASSET: the record carries the ACTIVE token whose asset name
  // IS the registry key — the hashed representative name is gone.
  add(record_value, rep_policy, fixtures.registry_key, 1)
}


/// The retirement's owner: any key the approval and its request agree on.
const retirement_owner = member2

/// #157 F-003 — a retirement books the `updateTerminal` edge, so the LT
/// positives carry both co-created obligations: the bound approval, and
/// the completion request that will fold `Update(0x01, 0x02)`.
fn terminate_approval() -> ByteArray {
  application.approval_name(
    3,
    fixtures.registry_key,
    retirement_owner,
    (#"", #""),
  )
}

fn retirement_completion_output() -> Output {
  Output {
    address: address.from_script(mpfs_state_hash),
    value: add(from_lovelace(3_000_000), app_policy, terminate_approval(), 1),
    datum: InlineDatum(
      naming.MRequestDatum(
        naming.MRequest {
          requestToken: naming.MTokenId {
            assetName: fixtures.mock_registry_token,
          },
          requestOwner: retirement_owner,
          requestKey: fixtures.registry_key,
          requestValue: naming.MUpdate(#"01", #"02"),
          tip: 1_000_000,
          submitted_at: 0,
          destination: (#"", #""),
        },
      ),
    ),
    reference_script: None,
  }
}
fn retirement_custody_output(value) {
  Output {
    address: custody_address,
    value,
    datum: NoDatum,
    reference_script: None,
  }
}

/// LT02-quorum-retirement-accepts: the quorum alone retires with no
/// controller signature.
test lt02_quorum_retirement_accepts() {
  let source = retirement_source()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire { key: fixtures.registry_key, revealed_control: #"" },
    self_ref,
    retirement_tx(
      [
        claim_input(fixtures.as_datum(source), retirement_claim_value()),
        fixtures.state_input(),
      ],
      [
        retirement_custody_output(retirement_claim_value()),
        retirement_completion_output(),
      ],
      [member2, member3],
      add(zero, app_policy, terminate_approval(), 1),
      [],
    ),
  )
}

/// LT03-insufficient-quorum-refused: one distinct signature short of the
/// threshold, no controller signature.
test lt03_insufficient_quorum_refuses() fail {
  let source = retirement_source()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire { key: fixtures.registry_key, revealed_control: #"" },
    self_ref,
    retirement_tx(
      [claim_input(fixtures.as_datum(source), retirement_claim_value())],
      [retirement_custody_output(retirement_claim_value())],
      [member2],
      zero,
      [],
    ),
  )
}

/// eraseDups is load-bearing: one member signing twice does not reach a
/// threshold of two.
test lt03_duplicate_member_refuses() fail {
  let source = retirement_source()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire { key: fixtures.registry_key, revealed_control: #"" },
    self_ref,
    retirement_tx(
      [claim_input(fixtures.as_datum(source), retirement_claim_value())],
      [retirement_custody_output(retirement_claim_value())],
      [member2, member2],
      zero,
      [],
    ),
  )
}

/// The duplication that matters on a ledger is in the stored quorum,
/// which is ordinary datum content: members [member2, member2, member3]
/// at threshold 2 are well-formed (distinct 2), but the duplicated
/// member alone must not retire. A `length` in place of `distinct_count`
/// would accept this.
test lt03_duplicate_stored_member_refuses() fail {
  let source =
    with_quorum(
      source_record(),
      RetirementQuorum {
        threshold: 2,
        members: [member2, member2, member3],
      },
    )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire { key: fixtures.registry_key, revealed_control: #"" },
    self_ref,
    retirement_tx(
      [claim_input(fixtures.as_datum(source), retirement_claim_value())],
      [retirement_custody_output(retirement_claim_value())],
      [member2],
      zero,
      [],
    ),
  )
}

/// Forged reference (NOTE-014 item A1): a state-address input with NO cage
/// token is not the registry on either path and refuses.
test retire_forged_reference_refuses() fail {
  let source = retirement_source()
  let base =
    retirement_tx(
      [claim_input(fixtures.as_datum(source), retirement_claim_value())],
      [retirement_custody_output(retirement_claim_value())],
      [controller],
      zero,
      [],
    )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire { key: fixtures.registry_key, revealed_control: recovery_revealed },
    self_ref,
    fixtures.with_state_reference(base, fixtures.state_input_no_token()),
  )
}

/// Lying datum (NOTE-014 item A1): the referenced datum declares a foreign
/// expected policy while the token — and the carried value — are honest.
/// The input policy check compares value against declared policy and refuses.
test retire_foreign_datum_reference_refuses() fail {
  let source = retirement_source()
  let base =
    retirement_tx(
      [claim_input(fixtures.as_datum(source), retirement_claim_value())],
      [retirement_custody_output(retirement_claim_value())],
      [controller],
      zero,
      [],
    )
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire { key: fixtures.registry_key, revealed_control: recovery_revealed },
    self_ref,
    fixtures.with_state_reference(base, fixtures.state_input_foreign_datum()),
  )
}

// ===========================================================================
// Insert approvals and the insert fold — the real representative (issue #77)
// ===========================================================================
//
// RED: `InsertApproval` does not exist yet. These tests demand the
// appended mint arm (`step .createInsert` needs the request token to be
// `insertAsset r.proposal`) and the insert half of the fold
// (`Singular.foldOne` `.insert`: approval bound to the datum,
// `representative-identity`, certified output carrying the minted name).

// Permanent second-asset regression controls.
const extra_policy = #"ffeeddccbbaa99887766554433221100ffeeddccbbaa998877665544"

fn extra_token(value) { add(value, extra_policy, "junk", 1) }

test lr01_with_extra_token_refuses() {
  let source = recovery_source()
  let successor = recovery_successor()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), extra_token(recovery_record_value()))],
      [continuation_output(
        fixtures.as_datum(successor),
        extra_token(recovery_record_value()),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

test lm01_with_extra_token_accepts() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), extra_token(record_value))],
      [continuation_output(fixtures.as_datum(maintained), extra_token(record_value))],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_extra_token_refuses() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(maintained), extra_token(record_value))],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_lovelace_topup_accepts() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(maintained), from_lovelace(deposit + 1))],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_lovelace_reduction_refuses() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(maintained), from_lovelace(deposit - 1))],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_addition_refuses() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(fixtures.as_datum(maintained), add(recovery_record_value(), extra_policy, "junk", 1))],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_same_policy_addition_refuses() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(fixtures.as_datum(maintained), add(recovery_record_value(), app_policy, "junk", 1))],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_quantity_increase_refuses() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(fixtures.as_datum(maintained), add(recovery_record_value(), app_policy, recovery_rep, 1))],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_removal_refuses() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(fixtures.as_datum(maintained), record_value)],
      [controller],
      zero,
      [],
    ),
  )
}

test maintain_replacement_refuses() {
  let source = source_record()
  let maintained = fixtures.maintained_record()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Maintain,
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(fixtures.as_datum(maintained), add(record_value, extra_policy, recovery_rep, 1))],
      [controller],
      zero,
      [],
    ),
  )
}

test recover_extra_token_refuses() {
  let source = recovery_source()
  let successor = recovery_successor()
  !application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      registry: app_policy,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), recovery_record_value())],
      [continuation_output(
        fixtures.as_datum(successor),
        extra_token(recovery_record_value()),
      )],
      [recovery_revealed_hash],
      zero,
      [],
    ),
  )
}

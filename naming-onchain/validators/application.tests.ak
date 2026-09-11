use application.{Cancel, Fold, Maintain, Recover, Retire, WithdrawApproval}
use aiken/crypto.{blake2b_256}
use aiken/primitive/bytearray
use cardano/assets.{add, from_lovelace, zero}
use cardano/transaction.{InlineDatum, Output}
use fixtures.{
  as_datum,
  altered_control, app_policy, burn_approval, claim_input,
  claim_value_with_approval, continuation_output, controller, deposit,
  redirected_output_address,
  redirected_refund, refund_destination, refund_output_address, rep_policy,
  self_ref,
  source_record, record_value, tampered_commitment, tx, with_commitment,
  with_quorum,

}
use naming.{RetirementQuorum}

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

fn refund_output(value) {
  Output {
    address: refund_output_address,
    value,
    datum: InlineDatum(fixtures.as_datum(source_record())),
    reference_script: None,
  }
}

/// LC01-cancellation-stored-refund-accepts: cancellation presenting the
/// stored refund destination, burning its withdraw approval, refunds
/// the claim's lovelace to the bound destination.
test lc01_cancellation_stored_refund_accepts() {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(
        as_datum(source),
        claim_value_with_approval(record_value),
      )],
      [refund_output(record_value)],
      [],
      burn_approval(),
      [],
    ),
  )
}

fn redirected(value) {
  let base = refund_output(value)
  Output { ..base, address: redirected_output_address }
}

/// LC02-cancellation-redirect-refused: a presented refund address
/// differing from the stored one refuses.
test lc02_cancellation_redirect_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Cancel {
      presented_refund: redirected_refund,
    },
    self_ref,
    tx(
      [claim_input(
        fixtures.as_datum(source),
        claim_value_with_approval(record_value),
      )],
      [redirected(record_value)],
      [],
      add(zero, app_policy, redirected_refund, -1),
      [],
    ),
  )
}

/// LC03-insert-attestation-cancellation-refused: without the withdraw
/// approval riding the claim there is no stored destination to compare
/// against and nothing to burn.
test lc03_cancellation_without_approval_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [refund_output(record_value)],
      [],
      burn_approval(),
      [],
    ),
  )
}

/// Negation of the burn requirement: keeping the approval alive is not
/// a cancellation.
test cancellation_without_burn_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(
        as_datum(source),
        claim_value_with_approval(record_value),
      )],
      [refund_output(record_value)],
      [],
      zero,
      [],
    ),
  )
}

/// Negation of the refund amount: a refund output short of the claim's
/// lovelace refuses.
test cancellation_short_refund_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(
        as_datum(source),
        claim_value_with_approval(record_value),
      )],
      [refund_output(from_lovelace(deposit - 1))],
      [],
      burn_approval(),
      [],
    ),
  )
}

/// Negation of the refund destination: an output at another key does
/// not satisfy the refund.
test cancellation_misaddressed_refund_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(
        as_datum(source),
        claim_value_with_approval(record_value),
      )],
      [redirected(record_value)],
      [],
      burn_approval(),
      [],
    ),
  )
}

// ===========================================================================
// Fold and retire — the claim/record transitions
// ===========================================================================

fn representative_name() {
  #"5265700102030405060708090a0b0c0d"
}

/// The value a live claim carries: its deposit plus the withdraw
/// approval under the application policy.
fn live_claim_value() {
  claim_value_with_approval(record_value)
}

/// The burn matching a live claim's approval.
fn fold_burn() {
  burn_approval()
}

/// A fold freezes the four-field datum into the record and consumes the
/// withdraw approval.
test fold_freezes_datum_accepts() {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Fold {
      representatives: [representative_name()],
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), live_claim_value())],
      [continuation_output(fixtures.as_datum(source), record_value)],
      [],
      fold_burn(),
      [],
    ),
  )
}

/// Negation: a fold may not alter the datum it freezes.
test fold_altering_datum_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Fold {
      representatives: [representative_name()],
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), live_claim_value())],
      [continuation_output(
        fixtures.as_datum(fixtures.maintained_record()),
        record_value,
      )],
      [],
      fold_burn(),
      [],
    ),
  )
}

/// Negation: a fold without the withdraw approval riding the claim
/// refuses — there is nothing to consume.
test fold_without_approval_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Fold {
      representatives: [representative_name()],
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [continuation_output(fixtures.as_datum(source), record_value)],
      [],
      fold_burn(),
      [],
    ),
  )
}

/// Negation: a fold that keeps the approval alive (no burn) refuses.
test fold_without_burn_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Fold {
      representatives: [representative_name()],
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), live_claim_value())],
      [continuation_output(fixtures.as_datum(source), record_value)],
      [],
      zero,
      [],
    ),
  )
}

/// LC04-folded-claim-cancellation-refused: once the claim has folded,
/// the approval is consumed — the record carries no withdraw approval
/// under the application policy — and the Cancel path refuses.
test lc04_folded_claim_cancellation_refuses() fail {
  let folded = source_record()
  let record_value_with_representative =
    add(record_value, fixtures.rep_policy, fixtures.representative_name, 1)
  application.application.spend(
    Some(fixtures.as_datum(folded)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(
        fixtures.as_datum(folded),
        record_value_with_representative,
      )],
      [refund_output(record_value)],
      [],
      burn_approval(),
      [],
    ),
  )
}

/// LC06-cancellation-replay-refused: replaying a cancellation against
/// an already-consumed approval refuses — the claim no longer carries
/// it and the burn cannot be re-executed.
test lc06_cancellation_replay_refuses() fail {
  let spent_claim = source_record()
  application.application.spend(
    Some(fixtures.as_datum(spent_claim)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(spent_claim), record_value)],
      [refund_output(record_value)],
      [],
      burn_approval(),
      [],
    ),
  )
}

/// Negation of the burn's exactness: consuming the approval twice in
/// one cancellation (a double burn) refuses.
test cancel_double_burn_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Cancel {
      presented_refund: refund_destination,
    },
    self_ref,
    tx(
      [claim_input(
        fixtures.as_datum(source),
        claim_value_with_approval(record_value),
      )],
      [refund_output(record_value)],
      [],
      add(zero, app_policy, refund_destination, -2),
      [],
    ),
  )
}

/// A retire consumes the record without a continuation.
test retire_consumes_record_accepts() {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire {
      representatives: [representative_name()],
    },
    self_ref,
    tx(
      [claim_input(fixtures.as_datum(source), record_value)],
      [],
      [],
      zero,
      [],
    ),
  )
}

/// Negation: a retire that smuggles the record through as a
/// continuation refuses.
test retire_with_continuation_refuses() fail {
  let source = source_record()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Retire {
      representatives: [representative_name()],
    },
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

fn approval_mint(quantity: Int) {
  add(zero, app_policy, refund_destination, quantity)
}

/// Minting a withdraw approval binds the refund destination in the
/// asset name, on the controller's signature.
test withdraw_approval_binds_destination_accepts() {
  application.application.mint(
    WithdrawApproval {
      controller,
      destination: refund_destination,
    },
    app_policy,
    tx([], [], [controller], approval_mint(1), []),
  )
}

/// Negation: without the controller's signature no approval mints.
test withdraw_approval_without_controller_refuses() fail {
  application.application.mint(
    WithdrawApproval {
      controller,
      destination: refund_destination,
    },
    app_policy,
    tx([], [], [], approval_mint(1), []),
  )
}

/// Negation: the approval's name must be the bound destination.
test withdraw_approval_name_mismatch_refuses() fail {
  application.application.mint(
    WithdrawApproval {
      controller,
      destination: refund_destination,
    },
    app_policy,
    tx(
      [],
      [],
      [controller],
      add(zero, app_policy, redirected_refund, 1),
      [],
    ),
  )
}

/// Negation: the approval mints exactly once.
test withdraw_approval_wrong_quantity_refuses() fail {
  application.application.mint(
    WithdrawApproval {
      controller,
      destination: refund_destination,
    },
    app_policy,
    tx([], [], [controller], approval_mint(2), []),
  )
}

/// The fold/cancellation burn the spend purpose itself demands: exactly
/// -1, riding a live input at the application address that carries the
/// approval. Unsigned — the approval token is the authorization, and
/// the LC rows demand no signers.
test cancel_burn_riding_claim_accepts() {
  application.application.mint(
    WithdrawApproval {
      controller,
      destination: refund_destination,
    },
    app_policy,
    tx(
      [claim_input(
        as_datum(source_record()),
        claim_value_with_approval(record_value),
      )],
      [],
      [],
      approval_mint(-1),
      [],
    ),
  )
}

/// Negation: a burn with no claim input carrying the approval refuses —
/// the approval cannot leave the ledger without the claim it binds.
test cancel_burn_without_claim_refuses() fail {
  application.application.mint(
    WithdrawApproval {
      controller,
      destination: refund_destination,
    },
    app_policy,
    tx([], [], [], approval_mint(-1), []),
  )
}

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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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

test lr09_representative_tamper_refuses() fail {
  let source = recovery_source()
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      representatives: [recovery_rep_tampered],
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

test lr10_registry_tamper_refuses() fail {
  let source = recovery_source()
  let successor = recovery_successor()
  application.application.spend(
    Some(fixtures.as_datum(source)),
    Recover {
      revealed_control: recovery_revealed,
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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
      representatives: [recovery_rep],
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

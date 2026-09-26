# 197 — Aiken test quality: case mapping, controls, and boundaries

## Story and authority

As a validator contributor, I run the Aiken suite and observe precise failures
for wrong authorization or token identity behavior, in tests whose names and
model references explain the rule.

Everything here is test-only. The worktree base is `ba788d0fd19ed3d2388335436594d3318ff9c80d`
(the review baseline for the findings is its parent `e19ca5e`); the Lean tree
at that base is the accepted model surface (`lean/Singular.*`, last model
commit `759ceba`). No Lean file, production validator, blueprint, or lockfile
changed. The on-chain gates are `nix flake check ./onchain` and
`nix flake check ./naming-onchain`, unchanged.

## Boundary repairs and controls

Three properties had an existential shape: `fail once` around an expression
that was expected to be false, so a single unequal result satisfied the test
and a partial defect stayed invisible. Each was replaced by a property that
asserts the intended outcome EXACTLY for every generated case, with
structurally distinct identities.

| boundary | old property (existential) | new property (exact) |
|---|---|---|
| foreign policy | `prop_quantity_wrong_policy` | `prop_quantity_is_none_for_a_foreign_policy` |
| foreign asset name | `prop_quantity_wrong_asset` | `prop_quantity_is_none_for_a_foreign_asset_name` |
| retract authorization | `prop_retract_requires_owner` | `prop_retract_refuses_every_non_owner_signer` |

Controls recorded (evidence files in the worker runtime, `evidence-20260921/`):

- old miss, quantity: mutating `lib.quantity` so an absent token yields a
  wrong non-None value made BOTH old properties pass at iteration 1 —
  satisfied immediately, nothing exercised (`old-…-under-…` record and
  `/tmp/mut_lib.log` from the interrupted session).
- new detect, quantity: the same mutation makes both new properties fail at
  iteration 1 (`new-quantity-props-under-some0-mutation.json`).
- old miss, retract: under the recovered parity mutation of the owner check,
  the old property passed at iteration 3 while the validator accepted the
  all-zero wrong signer (`old-retract-prop-under-parity-mutation.json`).
- new detect, retract: the same mutation makes the new property fail with
  counterexample `c75a0f85…` — an even-first-byte signer
  (`new-retract-prop-under-parity-mutation.json`).
- accepting controls retained: `prop_quantity_present`,
  `prop_valueFromToken_roundtrip`, `prop_quantity_valueFromToken`,
  `prop_tokenFromValue_ada_only`, and the owner-signed `retract_happy`.

## Authorization fixture repair

The retract fixtures previously used a 29-byte owner literal and signer
strings of other lengths. Cardano ed25519 key hashes are 28 bytes, so owner
and generated signers are now BOTH 28 bytes and the non-owner inequality is
structural, not length-based:

- owner: `the_real_owner_key_aaaaaaaaa` (final byte `0x61`),
- generated signer: a fuzzed 27-byte prefix plus final byte `0xFF`,
- paired refusal row: `the_real_owner_key_bbbbbbbbb`.

`retract_happy` and `retract_wrong_signer` share one request datum and one
Phase-2 window and differ ONLY in the signer, so the pair isolates the
authorization change. Boundary note, stated plainly: a correctly sized key
hash makes a shape ledger-representable; the harness still executes the
script struct only, so these rows are script-level evidence, not a built
ledger transaction. The phase rows `retract_in_phase1` and
`retract_in_phase3` are no longer script-failure expectations: since the
request validator began naming the phase refusal, they assert the exact
outcome — the spend handler returns `False` and `retractRefusal` returns
`Some(@"not-phase2")` — each beside an accepting partner that differs only in
the validity interval. At this record's base they were `fail` rows at an
`expect in_phase2(...)` boundary claiming neither a named semantic refusal
nor Lean correspondence; the re-cut rows, with the window-edge and open-bound
rows beside them, cite `Singular.Statements.retract_refusal_first_failing`
for the refusals and `Singular.Statements.retract_admitted_iff` for the
accepting partners.

## Refusal classification

Classification of the affected groups; `semantic` means the validator returns
a named clean refusal (asserted through the executable spend boundary), while
`malformed` means the input itself cannot be interpreted at the script
boundary. A `script-level phase guard` is separately classified: at this
record's base the validator rejected the phase at an `expect`, so `fail`
proved script rejection but not a clean Boolean outcome or named semantic
reason; that column is now empty because the request validator names the
phase refusal.

| group | semantic refusals | malformed-context `fail` | script-level phase-guard `fail` |
|---|---|---|---|
| retract | `retract_wrong_signer`, `prop_retract_refuses_every_non_owner_signer` (exact `== False`), `retract_in_phase1`, `retract_in_phase3` (exact `not-phase2`, partner accepting) | — | — |
| token identity | `quantity_wrong_policy`, `quantity_wrong_asset` (exact `None` units); foreign-policy/foreign-asset properties (exact `None`) | — | — |
| datum shape | — | `retract_on_state_datum`, `contribute_on_state_datum`, `modify_on_request_datum`, `end_on_request_datum`, `spend_no_datum` (wrong datum TYPE for the redeemer) | — |
| duplicate registration | `duplicate_insert_active_refuses_cleanly` (`== False`), `duplicate_insert_active_reason_is_key_exists` (named construction site) | — | — |
| terminal retire | all rows `== False` with paired accepting controls | — | — |

Helper-string rows (the `…_reason_is_…` checks) assert the construction site
the validator reads; they never stand alone — each semantic refusal row in
the same group carries the executable spend result, and the reason rows are
extra bindings on top.

## Module organization

The 3,092-line `cage.tests.ak` was split into behavior modules plus a shared
fixture module; the ticket-named modules were renamed to behavior-led names
(ticket identifiers stay in the module documentation as provenance):

| before | after | content |
|---|---|---|
| `cage.tests.ak` (97 tests) | `cage_fixtures.ak` + 12 behavior modules | see inventory below |
| `t157_fixtures.ak` | `registry_fixtures.ak` | shared registry-fold fixtures |
| `t157_rows.tests.ak` (104) | `registry_rows.tests.ak` | registry fold rows |
| `t173_edge.tests.ak` (8) | `duplicate_insert.tests.ak` | duplicate-registration edge |
| `t177_edge.tests.ak` (17) | `terminal_retire.tests.ak` | terminal-retirement edge |
| naming `t157_naming.tests.ak` (26) | `naming_registry.tests.ak` | naming registry rows |

Stale "currently broken" prose was removed: the duplicate-registration module
no longer claims the fold crashes or that a key-exists path is absent (the
fold refuses cleanly through the named site today, and the `== False` row
passes); the terminal-retirement module now states the library-crash hazard
as the reason refusals happen at the validator's own named sites before the
library call.

## Name inventory

Every test of the base tree is accounted for: 97 cage rows move with exactly
one rename; every other rename is a pure ticket-prefix strip. Counts per
module are unchanged.

### Cage split inventory

```text
cage_lifecycle.tests.ak (1):
  canCage
cage_mint.tests.ak (11):
  canMint
  mint_missing_input
  mint_quantity_two
  mint_extra_state_policy_asset
  mint_to_wallet
  mint_to_wrong_script
  mint_nonempty_root
  mint_request_datum
  mint_no_datum
  mint_output_must_hold_token
  prop_mint_roundtrip
cage_retract.tests.ak (5):
  retract_happy
  retract_wrong_signer
  retract_in_phase1
  retract_in_phase3
  prop_retract_refuses_every_non_owner_signer
cage_contribute.tests.ak (7):
  contribute_wrong_token
  contribute_missing_ref
  contribute_reference_only_state_rejected
  contribute_rejects_foreign_policy_state_same_asset
  contribute_in_phase2
  contribute_in_phase3
  contribute_with_state_end_rejected
cage_modify.tests.ak (17):
  modify_without_owner_succeeds
  end_stake_withdrawal_refuses
  end_owner_signed_no_withdrawal_refuses
  modify_wrong_address
  modify_advances_root_accepts
  modify_zero_net_state_preserved_accepts
  modify_no_requests
  modify_skip_other_token
  modify_too_few_proofs
  modify_extra_proofs
  modify_wrong_root
  modify_altered_representative_policy_refuses
  modify_in_phase2
  modify_output_must_hold_token
  prop_empty_modify_refuses
  modify_zero_requests_refuses
  modify_zero_requests_root_changes
cage_end.tests.ak (7):
  end_owner_signed_refuses
  end_missing_signature
  end_wrong_token_in_mint
  modify_rejects_foreign_policy_same_asset
  end_rejects_foreign_policy_same_asset
  end_with_extra_mint_policy
  end_with_extra_state_policy_asset
cage_datum_shape.tests.ak (5):
  retract_on_state_datum
  contribute_on_state_datum
  modify_on_request_datum
  end_on_request_datum
  spend_no_datum
cage_migrate.tests.ak (11):
  migrating_owner_signed_refuses
  migrate_no_burn
  migrate_to_wallet
  migrate_wrong_old_policy
  migrate_extra_state_policy_asset
  migrate_output_must_hold_token
  migrate_old_policy_not_allowlisted
  migrate_no_predecessor_input
  migrate_missing_owner_signature
  migrate_changes_tip
  migrate_forged_token_cannot_sweep
cage_refunds.tests.ak (9):
  modify_with_refund
  modify_missing_refund
  modify_insufficient_refund
  modify_wrong_refund_address
  modify_two_rejected_exact_accepts
  modify_crossed_amounts_refused
  modify_zero_fee
  modify_deposit_mismatch
  modify_tip_coverage
cage_reject.tests.ak (11):
  reject_happy
  reject_in_phase1
  reject_in_phase2
  reject_future_submitted_at
  end_wrong_signer
  reject_root_changes
  reject_wrong_refund
  reject_refund_owed_above_min_utxo_passes
  reject_refund_min_utxo_topup_passes
  reject_refund_under_owed_fails
  reject_refund_topup_cannot_drain_state
cage_sweep.tests.ak (10):
  sweep_owner_signed_refuses
  sweep_wrong_token_request
  sweep_fake_state_no_nft
  sweep_alongside_modify
  sweep_wrong_signer
  sweep_fake_state_ref
  state_sweep_rejected
  sweep_legitimate_request
  sweep_mismatched_deposit_request
  sweep_underfunded_matching_request
cage_isolation.tests.ak (3):
  two_seeds_distinct_tokens
  wrong_request_parameter_rejects_this_cage_token
  burning_token_refuses
```

The single cage rename: `prop_retract_requires_owner` ->
`prop_retract_refuses_every_non_owner_signer`. No cage row was dropped or
merged (mechanical diff of base versus split name sets: 97 -> 97, one rename).

### Ticket-prefix strips

Ticket identifiers no longer lead any test name; lowercase row-group tags
(registry gate and row labels such as `g2_`, `a1_`, `m1_`, `t5_`, `n8_`,
`v1_`, `lr01_`) are kept as secondary provenance. All 168 renames:

```text
  t157_g2_insert_absent_accepts -> g2_insert_absent_accepts
  t157_g2_insert_active_accepts -> g2_insert_active_accepts
  t157_g2_update_absent_to_active_accepts -> g2_update_absent_to_active_accepts
  t157_g2_update_active_to_terminal_accepts -> g2_update_active_to_terminal_accepts
  t157_g2_delete_absent_accepts -> g2_delete_absent_accepts
  t157_g2_delete_active_accepts -> g2_delete_active_accepts
  t157_g2_read_terminal_accepts -> g2_read_terminal_accepts
  t157_g2_insert_absent_delta_off_refuses -> g2_insert_absent_delta_off_refuses
  t157_g2_insert_active_delta_off_refuses -> g2_insert_active_delta_off_refuses
  t157_g2_update_absent_to_active_delta_off_refuses -> g2_update_absent_to_active_delta_off_refuses
  t157_g2_update_active_to_terminal_delta_off_refuses -> g2_update_active_to_terminal_delta_off_refuses
  t157_g2_delete_absent_delta_off_refuses -> g2_delete_absent_delta_off_refuses
  t157_g2_delete_active_delta_off_refuses -> g2_delete_active_delta_off_refuses
  t157_g2_read_terminal_delta_off_refuses -> g2_read_terminal_delta_off_refuses
  t157_g2_prop_delta_reads_off_the_edge -> g2_prop_delta_reads_off_the_edge
  t157_g3_tagged_insert_absent_accepts -> g3_tagged_insert_absent_accepts
  t157_g3_edge_tag_just_above_the_table_refuses -> g3_edge_tag_just_above_the_table_refuses
  t157_g3_edge_tag_negative_refuses -> g3_edge_tag_negative_refuses
  t157_g3_edge_tag_far_outside_the_table_refuses -> g3_edge_tag_far_outside_the_table_refuses
  t157_g3_an_unadmitted_tag_never_walks_the_trie -> g3_an_unadmitted_tag_never_walks_the_trie
  t157_g4_read_verifies_against_the_middle_root -> g4_read_verifies_against_the_middle_root
  t157_g4_read_against_initial_root_refuses -> g4_read_against_initial_root_refuses
  t157_g4_read_against_final_root_refuses -> g4_read_against_final_root_refuses
  t157_g5_batch_of_only_reads_accepts -> g5_batch_of_only_reads_accepts
  t157_g5_zero_consumed_requests_refuses -> g5_zero_consumed_requests_refuses
  t157_m3_read_of_terminal_leaf_accepts -> m3_read_of_terminal_leaf_accepts
  t157_m3_read_of_active_leaf_refuses -> m3_read_of_active_leaf_refuses
  t157_m3_read_of_absent_leaf_refuses -> m3_read_of_absent_leaf_refuses
  t157_m3_read_of_an_unbound_key_refuses -> m3_read_of_an_unbound_key_refuses
  t157_m3_the_read_faults_are_distinct_names -> m3_the_read_faults_are_distinct_names
  t157_n10_update_active_on_terminal_refuses -> n10_update_active_on_terminal_refuses
  t157_n10_delete_absent_on_terminal_refuses -> n10_delete_absent_on_terminal_refuses
  t157_n10_delete_active_on_terminal_refuses -> n10_delete_active_on_terminal_refuses
  t157_n10_terminal_edge_reason_is_edge_from_terminal -> n10_terminal_edge_reason_is_edge_from_terminal
  t157_n10_read_terminal_accepts -> n10_read_terminal_accepts
  t157_a1_insert_absent_without_approval_refuses -> a1_insert_absent_without_approval_refuses
  t157_a1_insert_active_without_approval_refuses -> a1_insert_active_without_approval_refuses
  t157_a1_update_active_without_approval_refuses -> a1_update_active_without_approval_refuses
  t157_a1_update_terminal_without_approval_refuses -> a1_update_terminal_without_approval_refuses
  t157_a1_delete_absent_without_approval_refuses -> a1_delete_absent_without_approval_refuses
  t157_a1_delete_active_without_approval_refuses -> a1_delete_active_without_approval_refuses
  t157_a1_insert_absent_with_approval_accepts -> a1_insert_absent_with_approval_accepts
  t157_a1_insert_active_with_approval_accepts -> a1_insert_active_with_approval_accepts
  t157_a1_update_active_with_approval_accepts -> a1_update_active_with_approval_accepts
  t157_a1_update_terminal_with_approval_accepts -> a1_update_terminal_with_approval_accepts
  t157_a1_delete_absent_with_approval_accepts -> a1_delete_absent_with_approval_accepts
  t157_a1_delete_active_with_approval_accepts -> a1_delete_active_with_approval_accepts
  t157_a2_wrong_edge_approval_refuses -> a2_wrong_edge_approval_refuses
  t157_a2_wrong_key_approval_refuses -> a2_wrong_key_approval_refuses
  t157_a2_wrong_owner_approval_refuses -> a2_wrong_owner_approval_refuses
  t157_a2_wrong_destination_approval_refuses -> a2_wrong_destination_approval_refuses
  t157_a2_bound_approval_accepts -> a2_bound_approval_accepts
  t157_a2_prop_approval_name_binds_the_key -> a2_prop_approval_name_binds_the_key
  t157_a3_read_without_approval_accepts -> a3_read_without_approval_accepts
  t157_a3_foreign_policy_approval_refuses -> a3_foreign_policy_approval_refuses
  t157_a4_altered_tip_refuses -> a4_altered_tip_refuses
  t157_a4_altered_process_time_refuses -> a4_altered_process_time_refuses
  t157_a4_altered_retract_time_refuses -> a4_altered_retract_time_refuses
  t157_a4_altered_application_policy_refuses -> a4_altered_application_policy_refuses
  t157_a4_altered_active_policy_refuses -> a4_altered_active_policy_refuses
  t157_a4_altered_absent_policy_refuses -> a4_altered_absent_policy_refuses
  t157_a4_altered_terminal_policy_refuses -> a4_altered_terminal_policy_refuses
  t157_a4_all_seven_preserved_accepts -> a4_all_seven_preserved_accepts
  t157_m1_two_active_tokens_for_one_key_refuses -> m1_two_active_tokens_for_one_key_refuses
  t157_m1_active_token_for_another_key_refuses -> m1_active_token_for_another_key_refuses
  t157_m1_exactly_one_active_token_accepts -> m1_exactly_one_active_token_accepts
  t157_m2_absent_mint_on_active_leaf_refuses -> m2_absent_mint_on_active_leaf_refuses
  t157_m2_insert_absent_on_unknown_key_accepts -> m2_insert_absent_on_unknown_key_accepts
  t157_m4_update_active_without_absent_burn_refuses -> m4_update_active_without_absent_burn_refuses
  t157_m4_update_active_with_both_legs_accepts -> m4_update_active_with_both_legs_accepts
  t157_m5_stray_terminal_mint_refuses -> m5_stray_terminal_mint_refuses
  t157_p3_token_named_other_than_the_key_refuses -> p3_token_named_other_than_the_key_refuses
  t157_p3_key_named_token_accepts -> p3_key_named_token_accepts
  t157_t1_active_token_at_another_address_refuses -> t1_active_token_at_another_address_refuses
  t157_t1_active_token_with_another_datum_refuses -> t1_active_token_with_another_datum_refuses
  t157_t1_active_token_in_two_outputs_refuses -> t1_active_token_in_two_outputs_refuses
  t157_t1_named_output_accepts -> t1_named_output_accepts
  t157_t2_terminal_token_elsewhere_refuses -> t2_terminal_token_elsewhere_refuses
  t157_t2_read_destination_accepts -> t2_read_destination_accepts
  t157_t3_absent_token_in_a_wallet_refuses -> t3_absent_token_in_a_wallet_refuses
  t157_t3_custody_naming_another_key_refuses -> t3_custody_naming_another_key_refuses
  t157_t3_custody_with_another_refund_refuses -> t3_custody_with_another_refund_refuses
  t157_t3_custody_carrying_an_extra_asset_refuses -> t3_custody_carrying_an_extra_asset_refuses
  t157_t3_exact_custody_output_accepts -> t3_exact_custody_output_accepts
  t157_t4_booking_over_custody_refunds_the_inserter -> t4_booking_over_custody_refunds_the_inserter
  t157_t4_deleting_custody_refunds_the_inserter -> t4_deleting_custody_refunds_the_inserter
  t157_t4_refund_below_the_held_lovelace_refuses -> t4_refund_below_the_held_lovelace_refuses
  t157_t4_refund_to_the_booker_instead_refuses -> t4_refund_to_the_booker_instead_refuses
  t157_t4_custody_left_unspent_refuses -> t4_custody_left_unspent_refuses
  t157_t5_plain_custody_spend_refuses -> t5_plain_custody_spend_refuses
  t157_t5_fold_for_another_key_refuses -> t5_fold_for_another_key_refuses
  t157_t5_fold_whose_request_is_a_read_refuses -> t5_fold_whose_request_is_a_read_refuses
  t157_t5_request_without_authenticated_state_modify_refuses -> t5_request_without_authenticated_state_modify_refuses
  t157_t5_fold_consuming_this_key_accepts -> t5_fold_consuming_this_key_accepts
  t157_t6_destination_carrying_the_residual_accepts -> t6_destination_carrying_the_residual_accepts
  t157_t6_folder_keeping_the_residual_refuses -> t6_folder_keeping_the_residual_refuses
  t157_t6_underfunded_destination_refuses -> t6_underfunded_destination_refuses
  t157_v1_request_below_its_tip_refuses -> v1_request_below_its_tip_refuses
  t157_v1_funded_request_accepts -> v1_funded_request_accepts
  t157_v2_read_retracted_by_its_owner_accepts -> v2_read_retracted_by_its_owner_accepts
  t157_v2_read_retracted_by_a_stranger_refuses -> v2_read_retracted_by_a_stranger_refuses
  t157_v2_update_retract_refuses -> v2_update_retract_refuses
  t157_t5_foreign_registry_modify_does_not_authorize_custody_refuses -> t5_foreign_registry_modify_does_not_authorize_custody_refuses
  t157_t5_request_at_the_request_script_accepts -> t5_request_at_the_request_script_accepts
  t173_insert_active_places_one_active_token_at_the_named_output -> insert_active_places_one_active_token_at_the_named_output
  t173_duplicate_insert_active_refuses_cleanly -> duplicate_insert_active_refuses_cleanly
  t173_duplicate_insert_active_reason_is_key_exists -> duplicate_insert_active_reason_is_key_exists
  t173_two_key_batch_with_the_right_distribution_accepts -> two_key_batch_with_the_right_distribution_accepts
  t173_two_key_batch_with_the_wrong_distribution_refuses -> two_key_batch_with_the_wrong_distribution_refuses
  t173_the_wrong_distribution_agrees_per_kind -> the_wrong_distribution_agrees_per_kind
  t173_keyed_mint_reason_is_net_mint_mismatch -> keyed_mint_reason_is_net_mint_mismatch
  t173_the_two_refusals_are_distinct_reasons -> the_two_refusals_are_distinct_reasons
  t177_update_terminal_retires_the_active_token -> update_terminal_retires_the_active_token
  t177_unknown_key_refuses_cleanly -> unknown_key_refuses_cleanly
  t177_absent_key_refuses_cleanly -> absent_key_refuses_cleanly
  t177_terminal_key_refuses_cleanly -> terminal_key_refuses_cleanly
  t177_the_trie_fault_control_accepts -> the_trie_fault_control_accepts
  t177_without_the_active_witness_refuses_cleanly -> without_the_active_witness_refuses_cleanly
  t177_the_witness_control_accepts -> the_witness_control_accepts
  t177_a_surviving_active_carrier_refuses_cleanly -> a_surviving_active_carrier_refuses_cleanly
  t177_the_surviving_carrier_control_accepts -> the_surviving_carrier_control_accepts
  t177_another_keys_witness_refuses_cleanly -> another_keys_witness_refuses_cleanly
  t177_delete_active_still_folds -> delete_active_still_folds
  t177_unknown_key_reason_is_key_unknown -> unknown_key_reason_is_key_unknown
  t177_absent_key_reason_is_not_booked -> absent_key_reason_is_not_booked
  t177_terminal_key_reason_is_terminal_immutable -> terminal_key_reason_is_terminal_immutable
  t177_an_active_leaf_is_not_a_trie_fault -> an_active_leaf_is_not_a_trie_fault
  t177_missing_witness_reason_is_token_missing -> missing_witness_reason_is_token_missing
  t177_the_reasons_are_distinct_names -> the_reasons_are_distinct_names
  t157_n1_insert_active_with_controller_signature_accepts -> n1_insert_active_with_controller_signature_accepts
  t157_n1_insert_active_without_signature_refuses -> n1_insert_active_without_signature_refuses
  t157_n1_prop_approval_name_binds_the_edge -> n1_prop_approval_name_binds_the_edge
  t157_n2_update_active_with_controller_signature_accepts -> n2_update_active_with_controller_signature_accepts
  t157_n2_update_active_without_signature_refuses -> n2_update_active_without_signature_refuses
  t157_n3_insert_absent_without_any_signature_accepts -> n3_insert_absent_without_any_signature_accepts
  t157_n4_delete_absent_by_the_recorded_refund_accepts -> n4_delete_absent_by_the_recorded_refund_accepts
  t157_n4_delete_absent_by_another_address_refuses -> n4_delete_absent_by_another_address_refuses
  t157_n4_delete_absent_unsigned_refuses -> n4_delete_absent_unsigned_refuses
  t157_n4_delete_absent_without_custody_reference_refuses -> n4_delete_absent_without_custody_reference_refuses
  t157_n4_prop_refund_binding_reads_the_custody -> n4_prop_refund_binding_reads_the_custody
  t157_n5_delete_active_is_never_certified_refuses -> n5_delete_active_is_never_certified_refuses
  t157_n6_retire_with_the_recovery_key_accepts -> n6_retire_with_the_recovery_key_accepts
  t157_n6_retire_with_the_quorum_accepts -> n6_retire_with_the_quorum_accepts
  t157_n6_retire_below_the_quorum_refuses -> n6_retire_below_the_quorum_refuses
  t157_n6_retire_with_the_control_key_alone_refuses -> n6_retire_with_the_control_key_alone_refuses
  t157_n6_retire_with_a_wrong_reveal_refuses -> n6_retire_with_a_wrong_reveal_refuses
  t157_n6_retire_without_approval_mint_refuses -> n6_retire_without_approval_mint_refuses
  t157_n6_retire_without_completion_request_refuses -> n6_retire_without_completion_request_refuses
  t157_n6_foreign_script_retire_spoof_refuses -> n6_foreign_script_retire_spoof_refuses
  t157_n6_terminate_approval_without_a_retire_refuses -> n6_terminate_approval_without_a_retire_refuses
  t157_n7_record_with_its_single_active_token_accepts -> n7_record_with_its_single_active_token_accepts
  t157_n7_record_with_a_second_asset_refuses -> n7_record_with_a_second_asset_refuses
  t157_n9_maintain_without_the_registry_accepts -> n9_maintain_without_the_registry_accepts
  t157_n9_maintain_spending_the_registry_refuses -> n9_maintain_spending_the_registry_refuses
  t157_n9_recover_without_the_registry_accepts -> n9_recover_without_the_registry_accepts
  t146_lr01_with_extra_token_refuses -> lr01_with_extra_token_refuses
  t146_lm01_with_extra_token_accepts -> lm01_with_extra_token_accepts
  t146_maintain_extra_token_refuses -> maintain_extra_token_refuses
  t146_maintain_lovelace_topup_accepts -> maintain_lovelace_topup_accepts
  t146_maintain_lovelace_reduction_refuses -> maintain_lovelace_reduction_refuses
  t146_maintain_addition_refuses -> maintain_addition_refuses
  t146_maintain_same_policy_addition_refuses -> maintain_same_policy_addition_refuses
  t146_maintain_quantity_increase_refuses -> maintain_quantity_increase_refuses
  t146_maintain_removal_refuses -> maintain_removal_refuses
  t146_maintain_replacement_refuses -> maintain_replacement_refuses
  t146_recover_extra_token_refuses -> recover_extra_token_refuses
  t157_n8_completion_folds_the_terminal_update_accepts -> n8_completion_folds_the_terminal_update_accepts
  t157_n8_completion_burning_another_token_refuses -> n8_completion_burning_another_token_refuses
```

## Lean bindings

- The historic citations in `lib.props.ak` and `cage.props.ak` name Lean
  files that do not exist in this repository's Lean tree. Both property
  modules now record the binding as MISSING and claim no conformance; the
  tests stand as behavioral regression properties over the Aiken helpers.
- Retract timing was unbound at this record's base; the user ruled that Issue
  197 preserve the executable script-level phase guards without a
  clean-refusal or Lean-correspondence claim. The phase rows are bound since
  the request validator names the refusal: refusals cite
  `Singular.Statements.retract_refusal_first_failing` and their accepting
  partners `Singular.Statements.retract_admitted_iff`, both declared in
  `lean/Singular/Statements.lean`.
- `duplicate_insert.tests.ak` cites the keyed-mint fault; the accepted
  qualified declaration is `Singular.assetSame` (declared in
  `lean/Singular/Model.lean` under `namespace Singular`), and it exists.
- `terminal_retire.tests.ak` cites
  `Singular.Statements.update_terminal_transaction_row`; the nested
  namespace is declared in `lean/Singular/Statements.lean` and the theorem
  exists at that qualified name.

## Verification and limits

- Required gates passed on the final staged source: `nix flake check
  ./onchain` global invocation 10 exited 0 across its three checks, and `nix
  flake check ./naming-onchain` global invocation 2 exited 0 across its two
  checks. Total spend includes the predecessor run: on-chain 10 invocations
  (3 predecessor, 7 continuation) and naming-onchain 2 invocations (1 each);
  the second remaining naming allocation was not needed. Focused Aiken runs
  used for controls are listed in the worker journal and are separate from
  the flake-gate budget.
- The successful Aiken logs report 2,171 on-chain checks with 0 errors and 616
  warnings, and 307 naming-onchain checks with 0 errors and 13 warnings. The
  warnings are non-failing diagnostics (including unused imports exposed by
  the split); this record does not claim a warning-clean suite.
- Control evidence lives outside the repo in the worker runtime because the
  mutations are deliberately never committed; the journal binds each run to
  its command and result.
- Known limits: malformed-context rows bound only input shape, not a refusal
  reason. The out-of-window retract rows asserted rejection at the
  `expect in_phase2(...)` script boundary at this record's base; they now
  assert the exact outcome — `False` from the spend handler and `not-phase2`
  from the refusal helper — since the request validator names the refusal.
  The full-suite verification of the split is the candidate gate itself, and
  no focused run substitutes for it.
- Out of scope and untouched: Lean, production validators, blueprints,
  lockfiles, conformance rows, sibling tickets' scopes.

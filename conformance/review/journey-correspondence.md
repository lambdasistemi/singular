# Journey, Lean and conformance correspondence

Source inventory below: the 28 generic-registry declarations in
`lean/Singular/Statements.lean` at the branch base `d92f35bf722120369c386ce09e6c7a40d321182f`.
This is not a complete inventory of naming statements and project helper
lemmas. The operator's every-theorem coverage requirement remains unmet.

Journey names identify related subjects, not proof of equivalence. The main
journey requests `edgeInsertAbsent`; the naming `register` journey includes
application behavior outside this open-registry example.

## All statements

Names below have the prefix `Singular.Statements.`.

| Statement | Related journey subject | Conformance asset or finding |
|---|---|---|
| `readAt_true_iff` | read-back; verify-present; verify-absent | GAP: no asset binds this statement |
| `no_tree_change_without_approval` | request → apply | GAP: no asset binds this statement |
| `booked_at_most_once` | request → apply | GAP: no asset binds this statement |
| `terminal_attestation_sound` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `terminal_mint_only_by_read` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `terminal_attestation_permanent` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `biconditional_supply_sync` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `occupancy` | register (occupied-name refusal) | GAP: no asset binds this statement |
| `occupancy_free_key_succeeds` | register (free-name fold) | GAP: no asset binds this statement |
| `termination` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `active_witness_unique` | register | GAP: no asset binds this statement |
| `absent_witness_unique` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `terminal_witness_plural` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `witness_kinds_exclude` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `insert_absent_inversion` | request → apply (the main journey books insertAbsent) | GAP: no asset binds this statement |
| `insert_active_inversion` | register | GAP: no asset binds this statement |
| `update_active_inversion` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `update_terminal_inversion` | retirement / retire-verify | GAP: no asset binds this statement |
| `delete_absent_inversion` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `delete_active_inversion` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `witness_terminal_inversion` | GAP: no direct statement-bound journey step established | GAP: no asset binds this statement |
| `empty_fold_error` | apply (no dedicated empty-batch step) | GAP: no asset binds this statement |
| `fold_batch_cons` | apply (no dedicated batch-decomposition step) | GAP: no asset binds this statement |
| `read_changes_nothing` | read-back | GAP: no asset binds this statement |
| `insert_absent_transaction_row` | request → apply (the main journey books insertAbsent) | GAP: no asset binds this statement |
| `insert_active_transaction_row` | register (related naming-application journey; this asset uses the open registry) | `Edge.Register` — live delivery compared with executable Lean; remaining checks use Haskell predicates; report cases are appendix evidence |
| `update_terminal_transaction_row` | retirement / retire-verify | `Edge.Retire` — live Haskell checks with a statement binding; no executable Lean comparison yet |
| `fold_batch_claimed_mint_by_kind_key` | GAP: no dedicated journey; conformance runner produces the two-key observation | `Fold.KeyedMint` — live batch comparison using Haskell predicates; no executable Lean comparison yet |

## All journey subjects

| Journey subject | Asset or finding |
|---|---|
| `boot` | GAP: no product asset |
| `request`, `apply` | Main journey uses insertAbsent; GAP: no corresponding asset yet |
| `read-back`, state observation | GAP: no product asset |
| `identity`, `derived-applied-identity` | GAP: no product asset; receipt codec checks are appendix evidence |
| `references` | GAP: no product asset |
| `verify-absent`, `verify-present`, `verify-false-claim` | GAP: no product asset |
| `reject-request` | GAP: no product asset |
| `reject-forged-identity` | GAP: no product asset |
| `reject-tampered-output` | GAP: no product asset |
| `reject-missing-proof` | GAP: no product asset |
| `reject-end-without-owner`, `reject-control` | GAP: no product asset |
| `register` | `Edge.Register`, open-registry live execution; naming-specific approval behavior is not bound here |
| `retirement` | `Edge.Retire`, live open-registry registration then retirement; naming authorization remains outside this story |
| `recovery` | GAP: no product asset |
| `repair` | GAP: no product asset |
| `verifier` | GAP: no product asset |
| `li01` | GAP: no product asset |
| `li-refusals` | GAP: no product asset |
| `lmlc` | GAP: no product asset |
| `retire-verify` | GAP: no product asset |

`complete` is a runner summary, not a new product subject. The nine sibling
executables above are all the immediate `offchain/journey/*/Main.hs` entries.

## Product assets and binding limits

- `Edge.Register` binds `insert_active_transaction_row`; its delivery clause
  runs the model oracle and the real registration. See [the run evidence](registration-lean.md).
- `Edge.Retire` binds `update_terminal_transaction_row`; its real registration,
  retirement and refusal controls currently use Haskell checks.
- `Fold.KeyedMint` binds `fold_batch_claimed_mint_by_kind_key`; its real
  two-key allocation controls currently use Haskell checks.

The appendix still checks exactly two constants, `insertActiveRow` and
`keyedMintFold`, against the manifest. The live interpreter resolves bindings
when their program steps execute, including retirement. Neither mechanism
establishes that every project theorem has a consumer or that every conclusion
is exercised. The coverage report's `stale bindings 0` is not such a census;
[issue 213](https://github.com/lambdasistemi/singular/issues/213) tracks that gap.

The retained missing-binding control was observed failing after changing the
actual registration binding to a nonexistent declaration, then restored.
The missing-consumer requirement has not been discharged by this example.
No uncovered row is promoted by this correspondence document.

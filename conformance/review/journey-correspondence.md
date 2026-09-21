# Journey, Lean and conformance correspondence

Source inventory: all 28 `theorem` declarations in
`lean/Singular/Statements.lean` at `d92f35bf722120369c386ce09e6c7a40d321182f`.
The two retained statement bindings name revision
`265c595edd72eab10f3b08a36cb010ad407cf48b`; their statement digests remain unchanged.

The journey column names a related subject, **not proof of equivalence**.
Only the two explicitly bound assets claim receipt-validation correspondence.
The main journey currently requests `edgeInsertAbsent`; naming it as this
suite's active-registration journey would be inaccurate. The `register`
journey covers active insertion with the naming application; the `Register`
asset below covers the narrower open-registry receipt. No extra asset or
new evidence was invented to complete this table.

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
| `insert_active_transaction_row` | register (related naming-application journey; this asset uses the open registry) | `Edge.Register` — receipt-validation cases |
| `update_terminal_transaction_row` | retirement / retire-verify | GAP: no asset binds this statement |
| `fold_batch_claimed_mint_by_kind_key` | GAP: no dedicated journey; conformance runner produces the two-key observation | `Fold.KeyedMint` — receipt-validation cases |

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
| `register` | `Edge.Register`, narrower open-registry receipt boundary; naming-specific approval behavior is not bound here |
| `retirement` | GAP: no product asset; `Support.Receipt` only checks a retirement receipt's codec |
| `recovery` | GAP: no product asset |
| `repair` | GAP: no product asset |
| `verifier` | GAP: no product asset |
| `li01` | GAP: no product asset |
| `li-refusals` | GAP: no product asset |
| `lmlc` | GAP: no product asset |
| `retire-verify` | GAP: no product asset |

`complete` is a runner summary, not a new product subject. The nine sibling
executables above are all the immediate `offchain/journey/*/Main.hs` entries.

## Every product asset

- `Edge.Register` binds `insert_active_transaction_row`. Request, application,
  token destination, refund, signer, configuration and occupied-key cases stay
  together. The related inversion remains an explicit binding gap.
- `Fold.KeyedMint` binds `fold_batch_claimed_mint_by_kind_key`. Its two-key
  batch and refusal controls stay together. Its dedicated journey is a gap.
- No product asset lacks a Lean binding. `Story`, `Fixture` and `Support`
  modules are not additional product assets.

## The binding check's measured limit

`find_stale_bindings` in `coverage/singular_coverage/debt.py:253` iterates the
coverage record's checks and mappings. It does not read Haskell bindings.
The coverage report's `stale bindings 0` does not quantify over the Haskell
story binding population; exactly two constants — `insertActiveRow` and
`keyedMintFold` — are bound against the committed manifest; a story binding
outside that list resolves against nothing and the report still prints zero.
The population gap is [issue 213](https://github.com/lambdasistemi/singular/issues/213).

The existing test command is `nix run --quiet .#conformance-tests` from
`conformance/` (`.github/workflows/conformance.yml`, unit-test step).
Its two-constant check was observed failing after the actual `insertActiveRow`
binding was changed to `Singular.Statements.missing_registration_theorem`:
1 example, 1 failure, expected True but got False. The valid binding was restored.
No new binding checker or CI job was introduced.

These gaps do not change a row's state. Receipt validation does not execute
a journey or demonstrate all conjuncts of a Lean theorem.

# Theorem manifest

As a proof reviewer, use this register to identify exactly which statements were supplied, that each one is proved, and from which axioms. Each declaration retains its exact qualified name and statement digest so that a changed or missing obligation can be detected.

All 41 declarations are **PROVED**. The proofs are in [Statements.lean](../lean/Singular/Statements.lean) and draw on [Lemmas.lean](../lean/Singular/Lemmas.lean); the statement text of every declaration is unchanged since it was frozen, so every digest below equals the one recorded while the statements were admitted. The executable source-derived manifest is [theorem-debt.json](../lean/theorem-debt.json). The bounded parser checks exact qualified identities and normalized statement hashes, derives each status from the proof text, and rejects unlisted holes, axioms, admit and unsafe declarations. A compiled gate in [Audit.lean](../lean/Singular/Audit.lean) runs while the library builds: it collects the axioms of every theorem in the frozen module and fails the build if any lies outside `propext`, `Classical.choice` and `Quot.sound`. The model check cross-checks that compiled report against the manifest. Re-admitting one theorem turns the build red; that control was exercised before the proofs were recorded. This is an identity and axiom check, not a semantic completeness audit: the proofs establish properties of the model, not that the model is the right model.

## Exact declaration inventory

| Qualified declaration | Statement SHA-256 | Status |
| --- | --- | --- |
| `Singular.Statements.insert_commitment_injective` | `acc639ab7fb78912b91ded316423260606a202c8bc9097d0c0cdb1561134e45c` | PROVED / standard axioms |
| `Singular.Statements.action_domain_separation` | `cef29367c350e02e94d4b897691e8764274bc763e1c45f342f4565cf5194844c` | PROVED / standard axioms |
| `Singular.Statements.createInsert_iff` | `66c628ab6c6190f045733f221a3ed5ae1791d56b6614f3089aa92a146c547588` | PROVED / standard axioms |
| `Singular.Statements.mintWithdraw_iff` | `659faf3a5fc1ca25b31cd336cf49ca1e0af3ab0f38a773495106154376bb3438` | PROVED / standard axioms |
| `Singular.Statements.release_iff` | `49b33cc0154a21b3396366356beab4f68bc138270c808981ab74e3a36256abd7` | PROVED / standard axioms |
| `Singular.Statements.evolve_iff` | `f48dbb5f2ef278a5cc7cd83e910aa3c5a0cb89e0b5efc7303caa68caa2b2f120` | PROVED / standard axioms |
| `Singular.Statements.outsider_iff` | `c4ee5484925c4d51a130c544d73195fc0fc8f1526c1311ba52c3edd81a70b79b` | PROVED / standard axioms |
| `Singular.Statements.withdraw_iff` | `a80f2964ecef9859907ea00a24ee69b35d84919ef555f44a5913b16ea180e1f2` | PROVED / standard axioms |
| `Singular.Statements.fold_iff` | `0c335c6e6f3902a7b8c295112f74ccd70515cbdca4715846442828e69c3538f6` | PROVED / standard axioms |
| `Singular.Statements.moveAction_iff` | `d75ee497b27abbff41d7e2f2e4ed1c945f551381d4de9cdc2ae4e9f1beb08589` | PROVED / standard axioms |
| `Singular.Statements.escape_refused` | `442700a69b1f5aeb6c5dfbf464b6ac7699006d4f2839e6cb630dddd3e006c908` | PROVED / standard axioms |
| `Singular.Statements.foldOne_insert_iff` | `ebda4ebd3dedf81f497472b68a75f42f335b6746f07759f9a181d7c5ab31faba` | PROVED / standard axioms |
| `Singular.Statements.foldOne_terminal_iff` | `2b3a1a84f9b7edba0fa0cfd9e1b01e2feef4e15907920bf17587aece09de7f49` | PROVED / standard axioms |
| `Singular.Statements.sequential_fold_cons` | `036a059420c87f319c3fb30ea7cbb0402ac46d78d7bb24672707cd5d7e556319` | PROVED / standard axioms |
| `Singular.Statements.supply_conservation` | `bee62c7b2b55eced153bab9f44e4709302712d388dffbac8524695ff49231e11` | PROVED / standard axioms |
| `Singular.Statements.over_terminal` | `27e06f051360a1f456719d02c0540fb6f8f7c06a41719cfc5bf0ee1fdc38ef0a` | PROVED / standard axioms |
| `Singular.Statements.over_no_representative` | `6958c0e472a303e62408ba9d84bb3faa5cc30a4d87beae6ec9f5caf7666eafdf` | PROVED / standard axioms |
| `Singular.Statements.pending_insert_no_representative` | `9ef17faaa9f2b361bbe0773b3afdec07c8d24acf928d3bce096cc943c184a740` | PROVED / standard axioms |
| `Singular.Statements.minting_requires_configured_issuer` | `60eb0ef6f74924fcf635dfc22ed65710b8e6762f94393e748718812aede9dbfa` | PROVED / standard axioms |
| `Singular.Statements.withdrawal_preserves_registry_supply` | `d278087ed94e0f538ccba5a04a94e1089c39774d069dc580091f2a38dd11e5b7` | PROVED / standard axioms |
| `Singular.Statements.exact_withdraw_scope` | `124546ee7fbb4379968ce1bccc7ba801c567cc09a699c52246cfdd6eb0d0499d` | PROVED / standard axioms |
| `Singular.Statements.local_evolution_registry_unchanged` | `b9301d1fa5ff7cf94d1c3b7c1b40e8386bf6be04e9e36dc543080b7b9cb0cd54` | PROVED / standard axioms |
| `Singular.Statements.release_is_operation_specific` | `643ec0b79778c3ba900aeca9063cedf21ab69e4dfc91779d0dd08d2afcd160d9` | PROVED / standard axioms |
| `Singular.Statements.release_removes_application_custody` | `9dd3fc799f072da1b92138fffb41fea7d6f588d25e7287064b5bed244fc6fbbd` | PROVED / standard axioms |
| `Singular.Statements.request_single_spend` | `ae3f74db25591349b0a826095d304480afb889b08bb342657bac4883304c2dca` | PROVED / standard axioms |
| `Singular.Statements.approval_scope_checked` | `7ec380d3b33906216bfcf9b744ceb1f9e230e3b876075121992cb574fc8b67da` | PROVED / standard axioms |
| `Singular.Statements.outsider_not_admitted` | `e8c0f448671514d014ad96351044f4aba210abdd95d32589a4306b0f980fa447` | PROVED / standard axioms |
| `Singular.Statements.native_witness_even_zero_net` | `d9ea77d84e54a54d62703fc9a00d03c722761992cc9f1ae036f01404a718135c` | PROVED / standard axioms |
| `Singular.Statements.nonzero_action_invokes_policy` | `aa81ba4d2e49f07948dcd3d24d53a9f8137d5a5abc03dac2a7f2ee9c028dec00` | PROVED / standard axioms |
| `Singular.Statements.existing_action_does_not_refresh_scope` | `bf5af377450b8b506405e9b9a85a166d19f72fcfc52722bbb8bf9e54b7e2f15f` | PROVED / standard axioms |
| `Singular.Statements.resolve_unauthenticated` | `4c95c9efca592a49413037e25e7c63105b93eec86d3ec970e77db0d33bd86c51` | PROVED / standard axioms |
| `Singular.Statements.resolve_absent` | `2205bd05ac27a0844d6628edad2b90ebebd00832c8dd6c950d639ec87c0d378b` | PROVED / standard axioms |
| `Singular.Statements.resolve_over` | `d3ad85aa68922db7bb461886a83e633ae46ddc1781ab7471d9b44af78a8b42f4` | PROVED / standard axioms |
| `Singular.Statements.resolve_address_iff` | `73fdf86e1c1d5dd5fe8fe655b0ee0fb11640e64abc0d38469abbc7868a80d2e1` | PROVED / standard axioms |
| `Singular.Statements.resolve_pending_iff` | `ebd55cc8e4631ab1b36e6e7c0cd345e4fec5564c7fba656000f81aed98430f78` | PROVED / standard axioms |
| `Singular.Statements.release_registry_independent` | `65cb3e5a1c732a6f6c70c82f8a1e0129ec1f3dc42a1cfbfda4e32787290b6d08` | PROVED / standard axioms |
| `Singular.Statements.insert_creation_registry_independent` | `7fa294756d1ad4a6181bff035caee00fe0867414e24f7558ba111dd7e0b07c32` | PROVED / standard axioms |
| `Singular.Statements.whole_release_acceptance_independent` | `05a46a442c1c999445e8e6c59fc83a1b9db14dbd8d901fa27d9ab54ba6071440` | PROVED / standard axioms |
| `Singular.Statements.whole_release_refusal_independent` | `7020410f873edf5239da5c1a31a8727a41b902dd2ac3d35adba1666c0b822dd4` | PROVED / standard axioms |
| `Singular.Statements.whole_insert_acceptance_independent` | `e0c47d8e2252b5abe2b910bc7094a451f56c9eb00d2ba3c507e8d6b3b3601187` | PROVED / standard axioms |
| `Singular.Statements.whole_insert_refusal_independent` | `3b025c6a01a6d1bf3dd6f86ee976a7265f02bf0dd44941896ae3e4473d30b3d1` | PROVED / standard axioms |

## Inversions and statement domain

Public inversions cover createInsert, mintWithdraw, release, evolve, outsider, withdraw, fold, moveAction, unconditional escape refusal, Insert and terminal foldOne branches, sequential composition, and address/pending resolver branches. Fold branch inversions expose exact guards and effects rather than merely restating a success boolean. Preservation obligations use Reachable where ledger invariants are needed; exact executable inversions quantify raw inputs. All inversions are proved. The reachable-state obligations `supply_conservation`, `over_no_representative` and `withdrawal_preserves_registry_supply` go through a stronger invariant than `WellFormed`: every custody record carries the current representative of its key, and every custody identifier is recorded in `used` and unique. Three statements, `over_terminal`, `release_removes_application_custody` and `request_single_spend`, quantify a reachable state without needing it; their proofs hold for every state.

A whole-transition statement that terminal request custody can leave only through completion is still missing. The unconditional `escape_refused` statement and Reachable supply claims do not establish that general coverage obligation. The terminal Withdraw refusal in the finite corpus adds an executable example, not the missing theorem or a completeness result.

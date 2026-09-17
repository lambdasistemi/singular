# Model ledger

As a reviewer deciding how far to trust this model, use this page to see what it
covers, what it deliberately abstracts, and — because this revision replaced the
model wholesale — what happened to every guarantee the previous one made.

This is a **candidate at model-and-proofs stage**. The executable machine is
`Singular.step` in [the model source](../lean/Singular/Model.lean). Every
declaration is proved from the standard axioms; there is no audit verdict and no
acceptance claim here.

## What the model is, and what it abstracts

The trie answers two questions and nothing else: is this key known, and where in
its life is it. Applications store nothing in the leaf. Seven edges move a leaf,
each an MPFS primitive applied to a state, each a delta over three token kinds.

Deliberate abstractions, each of which a reader should hold against every claim
below:

| abstraction | what it stands for | what it therefore cannot show |
| --- | --- | --- |
| tagged commitments | collision-free canonical commitments | that a real BLAKE2b digest is collision-free |
| the trie as a list | an authenticated map whose root is derived from its content | the MPF proof mechanics, or proof size |
| the approval asset name | `blake2b_256(edge ‖ key ‖ owner ‖ destination)` | that the real hash binds the tuple |
| supplied contract evidence | a ledger that ran the application's own validators | that those validators do what they claim |
| atomic selected batch | a fold that never skips a failure | anything about batch construction or ordering policy |

## The retirement map

The previous model had **44** generic declarations. Registry mode
replaced the alphabet, so most of them no longer have a subject. Every one is
accounted for here — **1 carried**, **3 renamed**,
**40 retired** — because without this an auditor cannot tell a dropped
guarantee from a rename, and a manifest that quietly lost rows would still
satisfy every count.

| base declaration | disposition | reason |
| --- | --- | --- |
| `insert_commitment_injective` | **retired** | the Insert/Withdraw commitment pair is gone; approval identity is now the D-APPROVAL tuple commitment, bound by `no_tree_change_without_approval` |
| `action_domain_separation` | **retired** | the Insert/Withdraw commitment pair is gone; approval identity is now the D-APPROVAL tuple commitment, bound by `no_tree_change_without_approval` |
| `createInsert_iff` | **retired** | the free-form action algebra is gone. The registry has seven edges and no `release`, `evolve`, `outsider`, `withdraw` or `moveAction`; their inversions are superseded by the seven edge inversions |
| `mintWithdraw_iff` | **retired** | the free-form action algebra is gone. The registry has seven edges and no `release`, `evolve`, `outsider`, `withdraw` or `moveAction`; their inversions are superseded by the seven edge inversions |
| `release_iff` | **retired** | the free-form action algebra is gone. The registry has seven edges and no `release`, `evolve`, `outsider`, `withdraw` or `moveAction`; their inversions are superseded by the seven edge inversions |
| `evolve_iff` | **retired** | the free-form action algebra is gone. The registry has seven edges and no `release`, `evolve`, `outsider`, `withdraw` or `moveAction`; their inversions are superseded by the seven edge inversions |
| `outsider_iff` | **retired** | the free-form action algebra is gone. The registry has seven edges and no `release`, `evolve`, `outsider`, `withdraw` or `moveAction`; their inversions are superseded by the seven edge inversions |
| `withdraw_iff` | **retired** | the free-form action algebra is gone. The registry has seven edges and no `release`, `evolve`, `outsider`, `withdraw` or `moveAction`; their inversions are superseded by the seven edge inversions |
| `fold_iff` | **retired** | the three-operation fold is replaced by the seven edges; their inversions are the seven `*_inversion` statements |
| `empty_fold_never_ok` | **retired** | subsumed by `empty_fold_error`, which gives the exact refusal rather than only its impossibility |
| `empty_fold_error` | **carried** | same name, same meaning: a zero-request batch is refused |
| `moveAction_iff` | **retired** | the free-form action algebra is gone. The registry has seven edges and no `release`, `evolve`, `outsider`, `withdraw` or `moveAction`; their inversions are superseded by the seven edge inversions |
| `escape_refused` | **retired** | the `escape` action no longer exists |
| `foldOne_insert_iff` | **retired** | the three-operation fold is replaced by the seven edges; their inversions are the seven `*_inversion` statements |
| `foldOne_terminal_iff` | **retired** | the three-operation fold is replaced by the seven edges; their inversions are the seven `*_inversion` statements |
| `sequential_fold_cons` | **renamed** | `fold_batch_cons` — the cons inversion, restated over `foldActions` because `foldBatch` refuses an empty tail |
| `supply_conservation` | **retired** | superseded by S3 `biconditional_supply_sync` with W1 and W2, which state the supply law as a biconditional rather than as conservation across one step |
| `over_terminal` | **retired** | superseded by T1 `termination`. It is a generic statement, not a naming one, and T1 states the stronger fact: a terminal leaf admits no edge at all, so the key is never re-booked |
| `over_no_representative` | **retired** | superseded by W4 `witness_kinds_exclude`: a terminal key carries no active token because the three kinds exclude each other |
| `pending_insert_no_representative` | **retired** | there is no pending state: `insertActive` books in one fold, and O1 `occupancy` states when it may |
| `minting_requires_configured_issuer` | **renamed** | `no_tree_change_without_approval` (P1), which additionally pins the four policies across the fold |
| `withdrawal_preserves_registry_supply` | **retired** | there is no withdrawal edge; refunds are the absent token's deposit, bound by R-ADA in the corpus and by the custody conjunct of the invariant |
| `exact_withdraw_scope` | **retired** | there is no withdrawal edge; refunds are the absent token's deposit, bound by R-ADA in the corpus and by the custody conjunct of the invariant |
| `local_evolution_registry_unchanged` | **retired** | `release` and `evolve` are application-side moves that never touch the trie; NM2 states that as root equality for naming's `maintain` and `recover` |
| `release_is_operation_specific` | **retired** | `release` and `evolve` are application-side moves that never touch the trie; NM2 states that as root equality for naming's `maintain` and `recover` |
| `release_removes_application_custody` | **retired** | `release` and `evolve` are application-side moves that never touch the trie; NM2 states that as root equality for naming's `maintain` and `recover` |
| `request_single_spend` | **retired** | the incarnation and approval-scope machinery is gone (R1); a request is spent once as part of L1 `booked_at_most_once` |
| `approval_scope_checked` | **retired** | the incarnation and approval-scope machinery is gone (R1); a request is spent once as part of L1 `booked_at_most_once` |
| `outsider_not_admitted` | **renamed** | `no_tree_change_without_approval` (P1): an unapproved request is not folded, now stated for every tree edge at once |
| `native_witness_even_zero_net` | **retired** | the consumer hook is gone (R7, `consumerPin` removed); the mint check is the cage's own summed delta, exercised by the corpus fold rows |
| `nonzero_action_invokes_policy` | **retired** | the consumer hook is gone (R7, `consumerPin` removed); the mint check is the cage's own summed delta, exercised by the corpus fold rows |
| `nonempty_fold_invokes_consumer` | **retired** | the consumer hook is gone (R7, `consumerPin` removed); the mint check is the cage's own summed delta, exercised by the corpus fold rows |
| `existing_action_does_not_refresh_scope` | **retired** | asset-scope reuse is gone with `assetScope` and `incarnation` (R1) |
| `resolve_unauthenticated` | **retired** | the `Resolution` vocabulary is gone. A consumer reads tokens, never the root (interface §7), so what replaced it is W1–W4 plus the leaf itself |
| `resolve_absent` | **retired** | the `Resolution` vocabulary is gone. A consumer reads tokens, never the root (interface §7), so what replaced it is W1–W4 plus the leaf itself |
| `resolve_over` | **retired** | the `Resolution` vocabulary is gone. A consumer reads tokens, never the root (interface §7), so what replaced it is W1–W4 plus the leaf itself |
| `resolve_address_iff` | **retired** | the `Resolution` vocabulary is gone. A consumer reads tokens, never the root (interface §7), so what replaced it is W1–W4 plus the leaf itself |
| `resolve_pending_iff` | **retired** | the `Resolution` vocabulary is gone. A consumer reads tokens, never the root (interface §7), so what replaced it is W1–W4 plus the leaf itself |
| `release_registry_independent` | **retired** | registry-independence of the old action algebra; the registry-mode equivalent is that the guarantees hold for every application unconditionally, which is what the open-application instance demonstrates |
| `insert_creation_registry_independent` | **retired** | registry-independence of the old action algebra; the registry-mode equivalent is that the guarantees hold for every application unconditionally, which is what the open-application instance demonstrates |
| `whole_release_acceptance_independent` | **retired** | registry-independence of the old action algebra; the registry-mode equivalent is that the guarantees hold for every application unconditionally, which is what the open-application instance demonstrates |
| `whole_release_refusal_independent` | **retired** | registry-independence of the old action algebra; the registry-mode equivalent is that the guarantees hold for every application unconditionally, which is what the open-application instance demonstrates |
| `whole_insert_acceptance_independent` | **retired** | registry-independence of the old action algebra; the registry-mode equivalent is that the guarantees hold for every application unconditionally, which is what the open-application instance demonstrates |
| `whole_insert_refusal_independent` | **retired** | registry-independence of the old action algebra; the registry-mode equivalent is that the guarantees hold for every application unconditionally, which is what the open-application instance demonstrates |

The registry-mode statements that replace them are listed in
[the theorem manifest](theorems.md).

## What is covered, and what is not

Covered: the seven edges and their deltas; the complement of the edge table as
refusals with distinct reasons; admission by an approval scoped to the request's
tuple; the leaf codec both ways; the fold's atomicity, zero-request refusal and
mint check; the custody census and the deposit's destination; and the eleven
promises over states reachable from genesis.

Not covered, and named rather than left to be discovered:

- **On-chain conformance.** Nothing here says the cage validator implements this
  model. That is the next ticket's obligation.
- **The simulator.** It replays 38 registry rows, 24 naming rows and 21
  lifecycle rows and reproduces each verdict, and a mirror check binds the
  Lean it ships to the Lean it was built from. That is agreement on the
  exported inputs, not equivalence — and the transcriber is the model's
  author, so it is not an independent measurement either.
- **Plurality from genesis.** W3 states that from any reachable terminal state
  arbitrarily many attestations can be minted. It does not construct a terminal
  key with zero attestations from genesis; that is a reachability claim about a
  fresh key and is not proved here.
- **Quantitative mutation coverage.** Four mutants are executed
  ([the mutation ledger](mutants.md)); there is no survivor census.

# #325 plan

**Strategy.** Keep the #299 journal as the single record and extend it; do not introduce a second store. Recovery reads only the journal, the saved bodies and one acquired view (#323); it never submits. Rollback and exclusion are decided from chain evidence about the exact journalled transaction.

**Invariants.**

- I1 Distinct outcomes (R1): every submission ends each command in exactly one named case; the receipt carries it.
- I2 Prepared before send (R2).
- I3 Crash-atomic local files (R3).
- I4 Reconcile on next command, at most once per edge, without submission (R4).
- I5 Rollback invalidates by appended line and restores the mirror to the journalled root before (R5).
- I6 Append-only evidence (R6).
- I7 Model effects unchanged (R7).

**Live boundaries.** The DevNet node; process kill and harness hold points (existing `SINGULAR_HARNESS_*` convention, inert when unset); a rollback produced on a generated DevNet (mechanism is the commit owner's; if none exists without new infrastructure, that is a question, not a substitute control).

**Slices.**

- S1 Outcomes, durable local commit and reconciliation on the next command: R1 (without rollback), R2, R3, R4, R6, R7; DevNet controls lost acknowledgement, interrupted persistence and accepting; docs for those outcomes.
- S2 Rollback: R5 and the rollback/exclusion parts of R1; DevNet rolled-back inclusion control; docs completed (R9).

Each slice is bisect-safe and leaves `singular-cli` runnable.

**Constraints.** Owned: `offchain/cli` command flow (`Receipt`, `Session` submission path, `Entry`, `Create`, `Inspect` resolver), the local-file writers they use, recovery controls under `tools/` and their flake app and CI step, `docs/`. Not owned: `Node/Indexer*.hs` and the indexer adapter (#324), `Node/View.hs` semantics (#323). A needed change there is a question to the epic owner.

# Delivery plan

Use the existing issue branch and PR. Preserve bf97f105 and its historical
evidence. Opus owns implementation and tests; Grok independently checks committed
checkpoints; the ticket owner owns specs, gate synthesis and disposition.
Muse/GLM may perform bounded mechanical tasks with no semantic authority.

## Slices

| Slice | Deliverable | Requirements | Exit evidence |
|---|---|---|---|
| S01 | Current-base integration, constitutional translation, generic model driver and replayable registration/retirement protocol. | R01–R04 | Existing model/corpus parity; driver success/refusal/error controls; one complete field mapping and readable story for review. |
| S02 | Registration uses the shared concrete abstraction and complete declared model observations. | R03–R06, R08 | Real positive run; changed-field and unknown-identity controls; old delivery adapter retired. |
| S03 | Connected retirement and applicable refusals use the same driver and abstraction. | R02–R09 | Registration-to-retirement trace; burn/leaf controls; refusal disagreement control; old retirement adapter retired. |
| S04 | Keyed-mint batch migration and context sharing with E2E. | R05–R09, R11 | Correct batch and wrong allocation; same scenario under supplied contexts; no product text anchors remain. |
| S05 | Whole-project consumer inventory, ratchet, CI execution and reader-facing artifact integration. | R08, R10, R12 | Removed consumer, skipped run and stale definition fail; actual CI receipts drive the book; publication boundary reported. |

S01 precedes S02; S02 precedes S03; S04 consumes the stabilized abstraction.
The mechanical theorem/CI inventory may be prepared in parallel without claiming
coverage. Review the representative S01 contract/story before broad migration.

## Scope

S01 may touch .specify/memory/constitution.md, Lean interface/corpus/build files,
conformance packaging and focused checks, and the CI/justfile integration needed
to run those checks. Keep accepted model functions and theorem meanings frozen.
Existing onchain/offchain implementation is outside S01; main integration must
preserve concurrent work. Later fences are assigned per slice before dispatch.
No worker creates new issues, edits unrelated branches, merges or deploys.

## Verification and publication

Two independent worker tables map acceptance rows to verbatim workflow commands;
the owner synthesizes their union. Missing jobs are MISSING-CI-JOB. Required new
checks become CI changes in the slice, never private substitute acceptance gates.
Uncited falsification is NONE CITED, not an invented historical RED.

Keep the existing required root CI, coverage snapshot and conformance-suite
checks before a push. Workers run checks and retain compact receipts binding
command, cwd, candidate/tree, inputs, exit, duration and evidence hash. The owner
does not implement or run the subject tests. Grok reviews committed checkpoints
and receipts, including failure modes, without rewriting the worker's code.

Use StGit increments on this lane, preserving published evidence identities.
Only the ticket owner pushes after checkpoint approval and required checks;
workers have local commit authority only. Keep PR/gist previews current under
the user's standing publication authorization. Candidate, review, acceptance,
merge and release remain distinct.

Ceilings: each spec artifact <=100 lines; worker packets <=140 lines. Split an
oversized mandate. Model/provider telemetry is recorded only when available.

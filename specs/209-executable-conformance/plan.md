# Delivery plan

Each child ticket has its own branch and pull request. Preserve bf97f105 and its
historical evidence. Opus owns implementation and tests; Grok independently
checks committed checkpoints; the ticket owner owns specs, gate synthesis and
disposition. Muse/GLM may perform bounded mechanical tasks with no semantic
authority.

## Children

| Ticket | PR | Deliverable | Requirements | Exit evidence |
|---|---|---|---|---|
| #220 | 217 | Executable book DSL and stakeholder stories, on a test-owned exception-safe resource lifetime. | R08 | Total render/fold over one instruction set; the migrated case sweep; no hidden global fixture state. |
| #221 | 226 | Constitutional translation, generic model driver and replayable registration/retirement protocol. | R01–R04 | Existing model/corpus parity; driver success/refusal/error controls; one complete field mapping and readable story for review. |
| #222 | — | Registration uses the shared concrete abstraction and complete declared model observations. | R03–R06, R08 | Real positive run; changed-field and unknown-identity controls; old delivery adapter retired. |
| #223 | — | Connected retirement and applicable refusals use the same driver and abstraction. | R02–R09 | Registration-to-retirement trace; burn/leaf controls; refusal disagreement control; old retirement adapter retired. |
| #224 | — | Keyed-mint batch migration and context sharing with E2E. | R05–R09, R11 | Correct batch and wrong allocation; same scenario under supplied contexts; no product text anchors remain. |
| #225 | — | Whole-project consumer inventory, ratchet, CI execution and reader-facing artifact integration. | R08, R10, R12 | Removed consumer, skipped run and stale definition fail; actual CI receipts drive the book; publication boundary reported. |

#220 and #221 do not wait on each other: their owned surfaces do not intersect,
#221 adds no Haskell, and #220 touches neither the Lean sources nor the model
check. #222 depends on both; #223 on #222; #224 on #223; #225 on #224.

The mechanical theorem/CI inventory for #225 may be prepared at any time without
claiming coverage: an inventory is a denominator, never evidence. Review #221's
representative contract and story before the broad migration in #222.

## Scope

#221 may touch .specify/memory/constitution.md, Lean interface/corpus/build
files, conformance packaging and focused checks, and the CI/justfile integration
needed to run those checks. It adds no Haskell. Keep accepted model functions and
theorem meanings frozen. Existing onchain/offchain implementation is outside it.

PR 226 carries this spec set so a reader can see where the driver sits in the
epic. Carrying the plan is not authority to act on it: PR 226 implements #221
only, and #220 and #222-#225 are each fenced by their own ticket.

Later fences are assigned per child before dispatch. No worker creates new
issues, edits unrelated branches, merges or deploys.

## Verification and publication

Two independent worker tables map acceptance rows to verbatim workflow commands;
the owner synthesizes their union. Missing jobs are MISSING-CI-JOB. Required new
checks become CI changes in the child, never private substitute acceptance gates.
Uncited falsification is NONE CITED, not an invented historical RED.

Keep the existing required root CI, coverage snapshot and conformance-suite
checks before a push. Workers run checks and retain compact receipts binding
command, cwd, candidate/tree, inputs, exit, duration and evidence hash. The owner
does not implement or run the subject tests. Grok reviews committed checkpoints
and receipts, including failure modes, without rewriting the worker's code.

Use StGit increments on each lane, preserving published evidence identities.
Only the ticket owner pushes after checkpoint approval and required checks;
workers have local commit authority only. Keep PR/gist previews current under
the user's standing publication authorization. Candidate, review, acceptance,
merge and release remain distinct.

Ceilings: each spec artifact <=100 lines; worker packets <=140 lines. Split an
oversized mandate. Model/provider telemetry is recorded only when available.

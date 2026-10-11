# Gate

The acceptance of [#518](https://github.com/lambdasistemi/singular/issues/518) is the repository's own CI: each acceptance line of the [spec](spec.md) is bound to the verbatim command of an existing job, with the exit that job asserts. Nothing here is a bespoke check. Version v1, frozen before any code is written (amended once before dispatch, after the plan review, to add the pull request each line belongs to; amended a second time at the stacked base for workflow line numbers and one open row below; amended a third time as v1.2 after the base moved to `58335316`, for workflow line numbers again and the rows under "Gate additions at `58335316`"; v1.3 maps one more acceptance line to an existing row and widens when it runs, at the auditor's addition during the builder run; no settled check changed); changes after the freeze are a new version with the settled rows unchanged.

## How it was written

Two tables were written independently, then synthesized once. The ticket owner's table has sha256 `af9b40091a642895d4f48cfff57c8395654062b44b169f3cd37cbddc48370cae`; the table of the gate-author auditor seat (GLM through the pi harness) has sha256 `cd2df8ebd9059d99034ebb047ebc25afd5f979e62ffeb4a90a3b322edccb542b`. The owner wrote its table before reading the auditor's. Both start from the same acceptance lines (sha256 `7a4ab83c5558ef9add3c09cfcc8e83facd9c684a7f0e0f34587da7e9ccb1a438`). The auditor read the workflows at base `76bb0993`; every command below was read again at `e3c9ab01` and then at `24e0c9ba`, and once more at `58335316`, the base of this branch (the split's approved head); the line numbers are those of `58335316`. Against `24e0c9ba` the lines of `ci.yml` after `offchain-component-build` moved by 43 (the split added the application-separation steps and two jobs for the open-datum package) and the lines of `registry.yml` after the focused-suite step moved by one; `conformance.yml` and the first two `ci.yml` rows did not move; no command or check changed. The one wording change since the auditor's table: `edge-unsupported` became the model's own `edge-inadmissible`, because the base now admits two edges only.

Conflicts and gaps, resolved:

| line | owner | auditor | resolved |
|---|---|---|---|
| model agreement | local conformance unit suite and the hosted batch row | the hosted batch row only | both: the unit suite carries the agreement test and its same-key control (a test added in this ticket to an existing command); the hosted batch row carries the live comparison where observable |
| lost race | mapped to the lost-acknowledgement recovery job | no job provokes two racing folds: missing | the owner's mapping was wrong (a lost acknowledgement is another case). The line is proved at unit level; the executed race is not claimed and is a recorded residual |
| recovery | killed and cross-wallet parts | accepting path | union of the three |
| docs | docs, presentation and release checks | documented flags only; prose uncovered | union; the prose is a text claim, a lead, checked by rendering and reading; the speech stamps of this spec set are asserted by `rendered-docs` |
| fences | no command checks "unchanged" | same | owner's mechanical path fence at acceptance (below) |

## Commands

Local rows run in minutes on a developer machine; hosted rows run only on the pushed head. Minutes are estimates from the job shape and `timeout-minutes`. A "red run" is a failed GitHub Actions run of that job, the evidence that the command can fail; where none exists in the last eighty failed runs the commit owner shows the focused product RED instead.

| name | where | workflow, job, line | verbatim command | exit | min | red run |
|---|---|---|---|---|---|---|
| focused-offchain-suite | local | registry.yml `journey`, step "Run the focused off-chain suite", working directory `offchain`, line 506 | `nix run --quiet .#cage-tests` (inner loop: `-- --match "[cli]"`) | 0 | 5-10 | 37652720574, job 112906712893 |
| conformance-unit-suite | local | conformance.yml `conformance-checks`, working directory `conformance`, line 166 | `nix run --quiet .#conformance-appendix-tests` | 0 | 10 | 37900182135, job 113720650187 |
| offchain-lint | local | ci.yml `offchain-lint`, line 64 | `(cd offchain && nix run --quiet .#lint)` | 0 | 5 | 37212674486, job 111466848229 |
| offchain-component-build | local | ci.yml `offchain-component-build`, working directory `offchain`, line 96 | `nix build --quiet .#component-build` | 0 | 10 | 37660042064, job 112924920603 |
| conformance-format | local | conformance.yml `format-check`, line 85 | `nix run --quiet .#format-check` | 0 | 3 | 37625613465, job 112806480516 |
| conformance-hlint | local | conformance.yml `format-check`, line 89 | `nix run --quiet .#hlint-check` | 0 | 3 | 37625613465, job 112806480516 |
| repository-lint | local | ci.yml `dev-shell`, line 314 | `nix develop --quiet -c just lint` | 0 | 5 | 37763865424, job 113268117521 |
| code-inventory | local | ci.yml `inventory`, line 241 | `nix run --quiet .#inventory-check` | 0 | 3 | 37763865424, job 113268117488 |
| rendered-docs | local | ci.yml `rendered-docs`, line 289 | `nix run --quiet .#docs-check` | 0 | 10 | 37808253758, job 113420624182 |
| presentation-check | local | ci.yml `dev-shell-checks`, line 338 | `nix develop --quiet -c just check-presentation` | 0 | 3 | 37808253758, job 113420623893 |
| release-docs-check | local | ci.yml `release-check`, line 363 | `nix run --quiet .#release-check` | 0 | 5 | none in the window: focused RED |
| cli-flags | local | registry.yml `cli-flags`, lines 962 and 964 | `nix run --quiet .#cli-flags-check`; `nix run --quiet .#cli-flags-controls` | 0 | 5 | none in the window: focused RED |
| demo1-journey-from-archive | hosted | registry.yml `demo1-archive`, line 605 | `nix run --quiet .#demo1-cli-check` | 0 | 20-40 | 37649976734, job 112891678603 |
| demo1-two-actor-control | hosted | registry.yml `demo1-two-actor-control`, line 632 | `nix run --quiet .#demo1-two-actor-control` | 0 | 20-40 | 37649976734, job 112891678687 |
| demo1-refusal-controls | hosted | registry.yml `demo1-refusals`, line 665 | `DEMO1_CONTROLS_RESULTS="$RUNNER_TEMP/demo1-controls-results" nix run --quiet .#demo1-cli-controls` | 0 | 20-40 | 37660041958, job 112927742684 |
| demo1-attach-parts | hosted | registry.yml `demo1-attach-part`, line 924 | `nix run --quiet .#demo1-cli-attach-${{ matrix.part }}` | 0 | 20 | 37808253616, job 113420075888 |
| demo1-public-readback | hosted | registry.yml `demo1-readback`, line 706 | `nix run --quiet .#demo1-readback-check` | 0 | 20 | none in the window: focused RED |
| recovery-accepting | hosted | registry.yml `cli-recovery-accepting`, line 737 | `nix run --quiet .#cli-recovery-accepting` | 0 | 10-20 | 37808253616, job 113420075676 |
| recovery-lost-answer | hosted | registry.yml `cli-recovery-lost-answer`, line 768 | `nix run --quiet .#cli-recovery-lost-answer` | 0 | 10-20 | 37808253616, job 113420075989 |
| recovery-killed | hosted | registry.yml `cli-recovery-killed`, line 799 | `nix run --quiet .#cli-recovery-killed` | 0 | 10-20 | 37808253616, job 113420075501 |
| recovery-cross-wallet-parts | hosted | registry.yml `cli-recovery-cross-wallet-part`, line 866 | `DEMO1_KEEP_SCRATCH=1 nix run --quiet .#cli-recovery-cross-wallet-part -- '${{ matrix.part }}'` | 0 | 10-20 each | 37808253616, job 113420579726 |
| devnet-e2e-lanes | hosted | registry.yml `e2e-part`, line 332 | `REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#cage-tests-e2e -- --match "{lane:$LANE}" --fail-on=empty` | 0 | 10-25 | 37676065669, job 112981938154 |
| batch-instructions-asked-of-the-model | hosted | conformance.yml `conformance-batch`, line 218 | `REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run batch --receipts-dir "$receipts"` | 0 | 10-25 | 37755208632, job 113237957191 |

## Acceptance line to commands

The PR column says which pull request the line belongs to (1, 2 or both); the commands are the same in both.

| acceptance line | PR | commands that prove it |
|---|---|---|
| each-request-judged-alone | 1 | focused-offchain-suite (properties and examples in the selection spec, with the failing control that refuses when several are pending) |
| one-request-per-key | 1 | focused-offchain-suite |
| capacity-bound-prefix-and-remainder | 1, 2 | focused-offchain-suite (the bound is an argument; the receipt carries bound and provenance) |
| two-vocabularies-never-mixed | 1 | focused-offchain-suite; demo1-refusal-controls (the receipt readers) |
| example-four-requests | 1, 2 | focused-offchain-suite; conformance-unit-suite (the selected batch asked of the model) |
| selection-agrees-with-the-model-batch | 1 | conformance-unit-suite (acceptance, equal state, mint and paid, same-key control); batch-instructions-asked-of-the-model (live, where observable) |
| fold-spends-exactly-the-selection | 1, 2 | focused-offchain-suite (builder spec); devnet-e2e-lanes; demo1-journey-from-archive |
| receipt-lists-settled-and-excluded | 1 | focused-offchain-suite; demo1-journey-from-archive; demo1-refusal-controls |
| journal-binds-every-transition-to-one-transaction | 2 | focused-offchain-suite (with a fixture of a line written before the change); recovery-accepting |
| recovery-covers-every-included-request | 2 | focused-offchain-suite; recovery-accepting; recovery-killed; recovery-cross-wallet-parts |
| lost-race-is-stale-state | 2 | focused-offchain-suite only; the executed race is not claimed |
| registry-fold-takes-the-selection | 1, 2 | focused-offchain-suite; cli-flags; demo1-refusal-controls |
| combined-forms-take-the-same-selection | 1, 2 | focused-offchain-suite; demo1-journey-from-archive |
| unsettleable-request-left-and-named | 1 | demo1-journey-from-archive; demo1-refusal-controls |
| two-actors-one-fold | 2 | demo1-journey-from-archive; demo1-two-actor-control (still fails where designed) |
| interrupted-fold-reconciles-every-request | 2 | recovery-killed; recovery-accepting; recovery-cross-wallet-parts |
| docs-state-what-is-shipped-and-its-limits | 1, 2 | rendered-docs; presentation-check; release-docs-check; cli-flags |
| fences | 1, 2 | the root gate below; the owner path fence |

## Gate additions at `58335316`

Three rows added in v1.2, none replacing a settled one. Each is the verbatim command of an existing job at `58335316`. They are the ticket owner's own rows: neither gate-author table could cover them, because the jobs did not exist (the open-datum jobs) or the step was not read as a gate row (the separation pair).

| name | where | workflow, job, line | verbatim command | exit | min | red run |
|---|---|---|---|---|---|---|
| application-separation | local | ci.yml `offchain-component-build`, lines 105 and 106 (the same pair under a nix-and-git-only PATH, lines 107 and 108) | `nix run --quiet .#application-separation-check`; `nix run --quiet .#application-separation-controls` | 0 | 2 | focused RED at the rebased head `c3bc79d1`: the check exits 1, naming the word `open-datum` in `offchain/lib/Singular/Registry/FoldSelection.hs` and `offchain/test/Singular/Registry/FoldSelectionSpec.hs` |
| open-datum-tests | local | ci.yml `open-datum-tests`, line 151 | `cd applications/open-datum/offchain && nix run --quiet .#open-datum-tests` | 0 | 5-10 | none in the window: focused RED |
| open-datum-build-and-lint | local | ci.yml `open-datum-component-build`, lines 129 and 130 | `cd applications/open-datum/offchain && nix build --quiet .#component-build`; `cd applications/open-datum/offchain && nix run --quiet .#lint` | 0 | 8 | none in the window: focused RED |

| acceptance line | PR | row that proves it |
|---|---|---|
| fences | 1, 2 | application-separation: no file under the registry tree `offchain/` names an application, comments and test values included; the selection receives the application's executable name as an argument |
| registry-fold-takes-the-selection | 1, 2 | open-datum-tests; open-datum-build-and-lint (the entry commands that call the same fold compile and their specs run) |
| combined-forms-take-the-same-selection | 1, 2 | open-datum-tests; open-datum-build-and-lint |
| all-pending-entry-point-unchanged (invariant of the builder run, added by the auditor in v1.3) | 1 | open-datum-tests: the existing control of the all-pending entry point's empty-set behaviour lives in the application package's `BurnSourceSpec` and the registry suite does not run it |

## Root gate

Every required status check of the `main` ruleset (id 22633401), 67 at `e3c9ab01`, must be green on the exact pushed head, each one individually: Aiken blueprint builds first; Backend contract suite on every adapter; Build Gate; Cage vectors match the generator; CLI recovery — a lost acknowledgement; CLI recovery — a process killed at its hold points; CLI recovery — the accepting path; Code inventory; Compiled script identity matches the manifest; Conformance checks without a devnet; Conformance devnet: a wrong model reason fails the row; Conformance devnet: batch instructions asked of the model; Conformance devnet: early rejection inside the windows; Conformance devnet: honest fold budget regression; Conformance devnet: reject and retract refund controls; Conformance devnet: retire-active-key; Conformance devnet: the canonical-identity rows; Conformance devnet: the generic rows; Conformance devnet: the retraction window; Conformance devnet: the running book; Conformance devnet: the serialization rows; Conformance Haskell format and lint check; Demo 1 journey from the release archive; Demo 1 public-indexer readback; Demo 1 refusals on one existing registry; Demo 1 refusals on one existing registry — indexer-reads; Demo 1 refusals on one existing registry — over-allowance; Demo 1 refusals on one existing registry — takes; Demo 1 refusals on one existing registry — tampered-a; Demo 1 refusals on one existing registry — tampered-b; Development shell build; Devnet E2E lanes select the whole suite; Devnet E2E on the fresh blueprint; Devnet E2E part: cage; Devnet E2E part: criterion 3; Devnet E2E part: driver and replay; Devnet E2E part: fork recovery; Devnet E2E part: node, boot, insert and config; Devnet E2E part: update to terminal; Documentation release checks; Documented CLI flags and refusal controls; Generic, canonical-identity and serialization rows on a real devnet; Lean model and exact statement debt; Live documentation preview; Naming validators build, refuse, and match their pinned identity; Naming wire vectors match the epic-15 contract; Off-chain component build; Off-chain lint; Onchain Aiken unit and property suite passes; On-chain release assembly and artifact checks; Rendered documentation; Simulator browser checks; Simulator corpus parity and controls; The bounded registry journey, narrated end to end; Theorem coverage gate — inventory, ratchet and completion as distinct results; Theorem coverage strict completion (reporting); Vendored v0.2.0 vectors match the live corpus; Workflow parses, lints clean, owned docs page bound; CLI recovery — another wallet's fold: cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND; CLI recovery — another wallet's fold: cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer; CLI recovery — another wallet's fold: cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SUBMIT; CLI recovery — another wallet's fold: cross-wallet:SINGULAR_HARNESS_HOLD_BEFORE_COMMIT; CLI recovery — another wallet's fold: cross-wallet:SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED; CLI recovery — discover the cross-wallet case matrix; Demo 1 ordinary CLI refusal controls; Demo 1 two actors — Bob opening Alice's file fails the journey; Development shell checks.

The local candidate gate carries a budget of 40 minutes per candidate: focused-offchain-suite (narrowed to what the slice can break), conformance-unit-suite, offchain-lint, offchain-component-build, conformance-format, conformance-hlint, rendered-docs; from v1.2 also application-separation on every candidate (seconds), and open-datum-tests with open-datum-build-and-lint on a candidate that edits `applications/open-datum/`; from v1.3 open-datum-tests also on a candidate that edits the shared fold builder (`offchain/lib/Singular/Registry/TxBuilder/Update.hs` or `Update/Context.hs`). `nix develop --quiet -c just ci` runs once on the final candidate. The lint and format commands are run on the base first as a control, so that a hint present on both is known to be old and a hint only on the candidate is this slice's. Hosted CI at the exact head, including every Demo 1 job and every recovery job, is the net; a hosted failure is one repair commit, never a local rerun of the hosted list.

## Rows without an existing command, or resting on this ticket's own change

- **Model agreement** needs a new example in the conformance unit suite; the command exists, the test is added here. Falsified by its own same-key control.
- **Devnet items** run in existing jobs whose script content changes here (`tools/demo1_cli_journey.sh`, `tools/cli_recovery_controls.sh`): CI change in this ticket, proved by the pushed head's jobs.
- **Path fence.** No job checks that `lean/`, `onchain/`, `naming-onchain/` and `simulator/formal/` are unchanged; the model, script-identity and blueprint jobs prove consistency, not absence of edits. The owner checks, at acceptance, that `git diff --stat origin/main...HEAD -- lean onchain naming-onchain simulator/formal` is empty. A path fence, not a behaviour check.
- **Prose of the pages** and the capacity number in them: no job asserts prose. The receipt field carrying the bound and its provenance is asserted in the focused suite; the page text is a lead, read at acceptance.
- **Executed fold race.** No job provokes two folds racing on one state output; a race control in the Demo 1 family would be a missing job, left as a residual rather than invented.
- **The open-datum package's tests.** The split moved the specs of the entry commands into the package `open-datum`, whose suite `open-datum-tests` is an app of that package's flake. At `58335316` the hosted jobs `open-datum-tests` and `open-datum-component-build` exist (`ci.yml` lines 131 and 109), and the rows `open-datum-tests` and `open-datum-build-and-lint` under "Gate additions at `58335316`" cite them. Pull request 1 edits one spec there (the group that tests the removed `foldTarget`) and the entry's combined forms, so a candidate that edits `applications/open-datum/` runs both rows locally.
- **Reading of the documentation row while the base is red (version v1.1, rows unchanged).** `rendered-docs` fails on the stacked base itself, for five stale narration clips of pages the command-line split edited (reproduced on the base by the commit owner; the split's owner regenerates them before its merge). For a candidate before the docs slice, the row is satisfied when the only failure is stale narration clips, the stale set equals those five plus the clips of pages that candidate edits (this ticket's own: the two `docs-offchain-api-reference` sections), and every other part of the run passes. The row is green at the head only after the docs slice regenerates this ticket's two clips and the split's five are regenerated; no clip is edited by hand. No settled row is edited, removed or reordered.

# Gate

The acceptance of [#519](https://github.com/lambdasistemi/singular/issues/519) is the repository's own CI: each acceptance line of the [spec](spec.md) is bound to the verbatim command of an existing job, with the exit that job asserts. Nothing here is a bespoke check. Version v2, frozen before any code is written: the first gate (version v1, sha256 `aa22825b…`) re-derived on main `38c7fbc1`, with every v1 row and its meaning kept. Changes after the freeze are a new version with the settled rows unchanged.

## How it was written

Two tables were written independently, then synthesized once. The ticket owner's table has sha256 `cb6df290b67bebf73c95031b27faf714d600e3dfd74bda196ff206bf90a9484f`; the table of the gate-author auditor seat (GLM through the pi harness) has sha256 `b14d12a28c7d37b90af064ac39ad56a48f6016486506ef84173950fbbfd72d5a`. The owner froze its table before reading the auditor's. Both start from the same nineteen acceptance lines (sha256 `f45cb455bfffdd2457939e19ac97915b889b62465647c9cbbb60e985c6ff6bf2`); the spec's acceptance lines are the same set, regrouped by pull request and renamed after the cut into four pull requests. One wording of the shared acceptance lines was corrected after both tables were written, with no check changed: line 4 said the window precedes the edge reasons; the validator checks the fixed edge set first, so an excluded edge is `edge-inadmissible` whatever the window, and the window precedes the approval and leaf reasons. Every command below was first read from the workflows at base `e3c9ab01`. On 2026-10-14 the plan was re-derived on main `38c7fbc1`: every cited workflow line and job name was read again on that base and shows the command it is cited for, four rows were added (the two hosted hygiene checks that appeared since, and the open-datum application's identity and Aiken suite, which share the fixtures module pull request 4 edits), and no settled row, command or expected exit changed. The red-run citations are runs of the earlier base and stay as evidence that the commands can fail. The owner also read each red run the auditor cited and each it found itself, and checked the job's conclusion with `gh run view`.

Conflicts and gaps, resolved:

| line | owner | auditor | resolved |
|---|---|---|---|
| model statements, corpora, constitution table | `model-check` | `model-check` | agreed. No failed run of the `model` job exists in the last 250 failed runs of `ci.yml`: the falsification is the focused product RED, the statements committed failing before the rules exist |
| permanent contract's anchor | `model-check` and `build-gate` (the transport check runs inside the build gate) | `model-check`, noting the package build | union |
| consumers | model, simulator, browser, coverage, conformance unit suite, application model | the same, without the application model | union: the application model is a consumer that unfolds `foldBatch` |
| compiled-validator evidence | `aiken-suite`, whose flake check also evaluates exported contexts against the compiled bytes with the always-accept fault control | `aiken-suite` (unit tests) | owner's, since the boundary check is what evaluates the compiled validator; the unit tests are the other half |
| live window row | the existing batch job with the new row appended: a CI change in this ticket | no workflow change | owner's: appending a row is a workflow change; the pushed head's job is the proof |
| derived lifecycle corpus | not listed | `naming-drift-check`, which reads `lean/lifecycle-corpus.json` | added: every Lean edit restamps that corpus |
| expired request on a devnet | the Demo 1 journey and the refusal controls | the journey | union |
| fences | `script-identity`, `blueprint`, `aiken-suite`, an owner's path fence | `script-identity`, the naming validators | union plus the path fence: no job checks that a file was not edited |
| red-run citations | from the survey and the search below | one cited run concluded `success` for its job (Demo 1 refusals, 37913118613) | replaced by 37808253616 |

## Commands

Local rows run in minutes on a developer machine; hosted rows run only on the pushed head. Minutes are estimates from the job shape and `timeout-minutes`. A "red run" is a failed GitHub Actions run of that job, the evidence that the command can fail; where none exists in the runs searched the commit owner shows the focused product RED instead.

| name | where | workflow, job, line | verbatim command | exit | min | red run |
|---|---|---|---|---|---|---|
| model-check | local | ci.yml `model`, line 232 | `nix run --quiet .#model-check` (inner loop: `nix develop --quiet -c lake build`, then `python3 tools/check_model.py`) | 0 | 15-25 | none in the window: focused RED |
| build-gate | local | ci.yml `build-gate`, line 33 | `nix build --quiet .#build-gate` (runs `lake build`, the axioms reports and `tools/check_m1_transport.py`) | 0 | 25 | 37900182236 |
| simulator-check | local | ci.yml `simulator`, line 252 | `nix run --quiet .#simulator-check` | 0 | 10 | 37755208565 |
| browser-check | local | ci.yml `browser`, line 272 | `nix run --quiet .#browser-check` | 0 | 10 | 34361461922 |
| coverage-check | local | ci.yml `coverage`, line 430 | `nix run --quiet .#coverage-check` | 0 | 5 | 37755208565 (job) |
| coverage-tests | local | ci.yml `coverage`, line 433 | `nix run --quiet .#coverage-tests` | 0 | 5 | 37755208565 |
| coverage-gate | local | conformance.yml `coverage-gate`, lines 1150, 1153, 1155, 1157, working directory `conformance` for the first two | `nix build --quiet --no-link .#coverageGateTests`; `nix build --quiet --no-link .#coverageGateSnapshot`; `nix run --quiet ./conformance#coverage-gate -- --root . inventory`; `nix run --quiet ./conformance#coverage-gate -- --root . ratchet` | 0 | 15 | 37764727502 |
| conformance-unit-suite | local | conformance.yml `conformance-checks`, line 226, working directory `conformance` | `nix run --quiet .#conformance-appendix-tests` | 0 | 10 | 37900182135 |
| application-model | local | ci.yml `dev-shell-checks`, line 508 | `nix develop --quiet -c just application-model` | 0 | 10 | 37757702153 |
| naming-drift-check | local | registry.yml `vector-drift`, line 347 | `nix run --quiet .#naming-drift-check` | 0 | 5 | none in the window: focused RED |
| focused-offchain-suite | local | registry.yml `journey`, step "Run the focused off-chain suite", working directory `offchain`, line 596 | `nix run --quiet .#cage-tests` (inner loop: `-- --match "[builders]"` and `-- --match "[cli]"`) | 0 | 5-10 | 37652720574 |
| offchain-lint | local | ci.yml `offchain-lint`, line 64 | `(cd offchain && nix run --quiet .#lint)` | 0 | 5 | 37212674486 |
| offchain-component-build | local | ci.yml `offchain-component-build`, working directory `offchain`, line 96 | `nix build --quiet .#component-build` | 0 | 10 | 37655363046 |
| conformance-format | local | conformance.yml `format-check`, line 89 | `nix run --quiet .#format-check` | 0 | 3 | 37625613465 |
| conformance-hlint | local | conformance.yml `format-check`, line 93 | `nix run --quiet .#hlint-check` | 0 | 3 | 37625613465 |
| repository-lint | local | ci.yml `dev-shell`, line 478 | `nix develop --quiet -c just lint` | 0 | 5 | 37763865424 |
| code-inventory | local | ci.yml `inventory`, line 305 | `nix run --quiet .#inventory-check` | 0 | 3 | 37763865424 |
| rendered-docs | local | ci.yml `rendered-docs`, line 453 | `nix run --quiet .#docs-check` | 0 | 10 | 37905345631 |
| presentation-check | local | ci.yml `dev-shell-checks`, line 509 | `nix develop --quiet -c just check-presentation` | 0 | 3 | 37808253758 |
| release-docs-check | local | ci.yml `release-check`, line 536 | `nix run --quiet .#release-check` | 0 | 5 | none in the window: focused RED |
| cli-flags | local | registry.yml `cli-flags`, lines 1109 and 1111 | `nix run --quiet .#cli-flags-check`; `nix run --quiet .#cli-flags-controls` | 0 | 5 | none in the window: focused RED |
| aiken-suite | local, hosted | registry.yml `aiken-suite`, line 180, working directory `onchain` | `nix flake check` (runs the Aiken unit and property tests, the blueprint and identity checks, and the permanent-boundary check with its always-accept fault control; inner loop: `aiken check -m <module>` in the onchain dev shell) | 0 | 15 local, 45 hosted | 37465175800 |
| script-identity | local | registry.yml `script-identity`, line 135, working directory `onchain` | `nix build --quiet --no-link --print-out-paths .#script-identity` | 0 | 15 | 35696066200 |
| blueprint | local | registry.yml `blueprint`, line 105, working directory `onchain` | `nix build --quiet --no-link --print-out-paths .#plutus-blueprint` | 0 | 10 | none in the window: focused RED |
| application-script-identity | local | registry.yml `application-script-identity`, line 237, working directory `applications/open-datum/onchain` | `nix build --quiet --no-link --print-out-paths .#script-identity` | 0 | 15 | none in the window: focused RED |
| application-aiken-suite | local, hosted | registry.yml `application-aiken-suite`, line 261, working directory `applications/open-datum/onchain` | `nix flake check` (the open-datum application's tests use the registry's fixtures module that pull request 4 edits) | 0 | 15 local, 45 hosted | none in the window: focused RED |
| workflow-commands-resolve | hosted | ci.yml `workflow-commands-resolve`, line 335 | `nix run --quiet .#workflow-commands-resolve-controls` (every command a workflow runs resolves; pull request 4 appends to one) | 0 | 25 | hosted only |
| declared-checks-hosted | hosted | ci.yml `declared-checks-hosted`, line 379 | `nix run --quiet .#declared-checks-hosted "$RUNNER_TEMP/issue-states.txt"` (every declared check has a hosted step; pull requests 3 and 4 add tests inside existing suites and no job) | 0 | 25 | hosted only |
| conformance-batch-job | hosted | conformance.yml `conformance-batch`, line 278 | `REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run batch --receipts-dir "$receipts"` (the live window row is appended to this command: CI change in this ticket) | 0 | 10-30 | 37757702122 |
| conformance-live-jobs | hosted | conformance.yml, the jobs `conformance-budget` (233), `-book` (279), `-retire` (302), `-refund-controls` (382), `-reject-early` (500), `-retraction` (597), `-wrong-reason` (688), `-generic` (739), `-identity` (786), `-serialization` (873) | the command each job runs, as written | 0 | 30 each | 37764727502 (book), 37649976842 (retire), 37908396450 (generic), 37900182135 (serialization), 37755208632 (retraction), 37757702122 (refund-controls, reject-early); budget: none in the window, focused RED |
| demo1-journey-from-archive | hosted | registry.yml `demo1-archive`, line 695 | `nix run --quiet .#demo1-cli-check` | 0 | 20-40 | 37808253616 |
| demo1-refusal-controls | hosted | registry.yml `demo1-refusals`, line 861 | `DEMO1_CONTROLS_RESULTS="$RUNNER_TEMP/demo1-controls-results" nix run --quiet .#demo1-cli-controls` | 0 | 20-40 | 37808253616 |

## Acceptance line to commands

| acceptance line | PR | commands that prove it |
|---|---|---|
| batch-cannot-consume-what-it-creates | 1 | model-check; conformance-unit-suite (the pair asked of the model through the transport) |
| batch-burns-only-live-holdings | 1 | model-check |
| independent-requests-fold-as-a-batch | 1 | model-check |
| permanent-contract-anchor-follows | 1 | model-check; build-gate (the transport check); application-model |
| model-consumers-follow | 1, 2 | model-check; build-gate; simulator-check; browser-check; coverage-check; coverage-tests; coverage-gate; naming-drift-check; conformance-unit-suite; application-model |
| constitution-amended | 1, 2 | model-check (the translation table is reconciled with the declared surface in both directions) |
| fold-admitted-up-to-the-deadline | 2 | model-check; conformance-unit-suite |
| fold-refused-for-any-request-past-its-deadline | 2 | model-check |
| each-request-judged-from-its-own-submission-time | 2 | model-check; conformance-unit-suite |
| admission-comes-before-the-law | 2 | model-check |
| chain-and-model-agree-under-the-witness | 2 | conformance-live-jobs; conformance-batch-job |
| builder-refuses-a-fold-outside-its-window-before-signing | 3 | focused-offchain-suite |
| builder-refuses-a-batch-that-consumes-what-it-creates-before-signing | 3 | focused-offchain-suite |
| builder-and-model-agree-on-admission | 3 | conformance-unit-suite (with its failing control) |
| receipt-names-a-request-excluded-for-its-window | 3 | focused-offchain-suite; demo1-refusal-controls |
| in-window-request-admitted-end-to-end and expired-request-left-and-named-end-to-end | 3 | demo1-journey-from-archive; demo1-refusal-controls |
| compiled-validator-rejects-a-fold-whose-bound-passes-a-deadline and compiled-validator-rejects-a-batch-consuming-what-it-creates | 4 | aiken-suite |
| chain-refuses-a-fold-past-a-deadline-live | 4 | conformance-batch-job |
| docs-state-what-ships-and-its-limits | 2, 3, 4 | rendered-docs; presentation-check; release-docs-check; cli-flags |
| fences | 1, 2, 3, 4 | script-identity; blueprint; application-script-identity; application-aiken-suite; workflow-commands-resolve; declared-checks-hosted; aiken-suite; offchain-lint; offchain-component-build; conformance-format; conformance-hlint; repository-lint; code-inventory; the root gate below; the owner path fence below |

## Root gate

Every required status check of the `main` ruleset (93 on `38c7fbc1`, read from the ruleset) must be green on the exact pushed head, each one individually. The local candidate gate carries a budget of 40 minutes per candidate, narrowed to what the pull request can break:

| pull request | local candidate gate |
|---|---|
| 1 and 2 | model-check, simulator-check, browser-check, coverage-check, coverage-tests, coverage-gate, naming-drift-check, conformance-unit-suite, application-model, conformance-format, conformance-hlint |
| 3 | focused-offchain-suite (narrowed), conformance-unit-suite, offchain-lint, offchain-component-build, conformance-format, conformance-hlint, rendered-docs |
| 4 | aiken-suite (the onchain flake check), application-aiken-suite, conformance-format, conformance-hlint |

`nix develop --quiet -c just ci` runs once on each final candidate. The lint and format commands are run on the base first as a control, so that a hint present on both is known to be old and a hint only on the candidate is this pull request's. Hosted CI at the exact head, including every conformance devnet job and every Demo 1 and recovery job, is the net; a hosted failure is one repair commit, never a local rerun of the hosted list.

## Rows without an existing command, or resting on this ticket's own change

- **Builder and model agree on admission** needs a new example in the conformance unit suite; the command exists and the test is added in this ticket. Falsified by its own control: a version that admits one past the deadline must fail it.
- **Compiled-validator evidence** is new Aiken tests, new exported contexts and new checker rows inside the existing `aiken-suite` command. Falsified by the checker's always-accept program, which must fail the new labels, and by the focused product RED: weakening the validator's window rule by one millisecond in a scratch copy turns the new tests red (the scratch copy is never committed).
- **The live window row** is one appended row in the `run` command of the existing batch job: CI change in this ticket, proved by the pushed head's job. If the suite's own mechanism makes it larger than the pull request's budget, it is cut and filed as a follow-up, and the acceptance line stays unmet and published as such.
- **Devnet items** run in existing jobs whose script content changes here (`tools/demo1_cli_journey.sh`, `tools/demo1_cli_controls.sh`): CI change in this ticket, proved by the pushed head's jobs.
- **Path fence.** No job checks that a file was not edited: `script-identity` and `blueprint` prove the compiled hashes did not move, not that no validator source changed. The owner checks, at acceptance, that `git diff --stat origin/main...HEAD -- onchain/validators onchain/lib applications/open-datum/onchain naming-onchain onchain/script-identity.json onchain/permanent-contract.json ':!onchain/validators/*.tests.ak' ':!onchain/lib/registry_fixtures.ak'` is empty. A path fence, not a behaviour check. Its positive control: the same command with no exclusions lists `onchain/lib/registry_fixtures.ak` and the new test files once pull request 4 is in, so the fence is seen able to report.
- **Prose of the pages and the conformance book:** no job asserts prose; the computed rows are asserted by the docs check. A text claim, a lead, read at acceptance.

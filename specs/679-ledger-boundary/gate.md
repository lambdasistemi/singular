# Gate for the ledger boundary

As the ticket owner, I accept this child only when each row below is green in its hosted job at the exact head, and each checkpoint the auditor reads is approved at an ancestor of that head.

## How this gate was made

Two tables were written independently at base `45cd8a75`: the ticket owner's, and the gate author's (Codex gpt-6.1-sol, high). This page is their union, with one command per row, each copied verbatim from its workflow step. Every row asserts exit 0 except the completion row, whose step asserts that the inner command exits 1 while the step itself exits 0. A red run is a real failed run of that step on this repository; "none found" means none in the searched window (22 September to 16 October).

## Rows

| Row | Workflow, job | Verbatim command | Red run |
|---|---|---|---|
| model check | `ci.yml` model | `nix run --quiet .#model-check` | none found |
| simulator | `ci.yml` simulator | `nix run --quiet .#simulator-check` | [37755208565](https://github.com/lambdasistemi/singular/actions/runs/37755208565/job/113238939931) |
| browser | `ci.yml` browser | `nix run --quiet .#browser-check` | none found |
| coverage report | `ci.yml` coverage | `nix run --quiet .#coverage-check` | none found |
| coverage tests | `ci.yml` coverage | `nix run --quiet .#coverage-tests` | [37755208565](https://github.com/lambdasistemi/singular/actions/runs/37755208565/job/113238939958) |
| coverage gate tests | `conformance.yml` coverage-gate, in `conformance` | `nix build --quiet --no-link .#coverageGateTests` | [37755208632](https://github.com/lambdasistemi/singular/actions/runs/37755208632/job/113237957281) |
| coverage gate verdicts | `conformance.yml` coverage-gate, in `conformance` | `nix build --quiet --no-link .#coverageGateSnapshot` | [37757702122](https://github.com/lambdasistemi/singular/actions/runs/37757702122/job/113246214715) |
| coverage inventory | `conformance.yml` coverage-gate | `nix run --quiet ./conformance#coverage-gate -- --root . inventory` | none found |
| coverage ratchet | `conformance.yml` coverage-gate | `nix run --quiet ./conformance#coverage-gate -- --root . ratchet` | none found |
| coverage completion stays incomplete | `conformance.yml` coverage-gate | the step's own script around `nix run --quiet ./conformance#coverage-gate -- --root . completion`, inner exit 1 | none found |
| application model | `ci.yml` dev-shell-checks | `nix develop --quiet -c just application-model` | [37757702153](https://github.com/lambdasistemi/singular/actions/runs/37757702153/job/113247725310) |
| rendered documentation, paper and narration | `ci.yml` rendered-docs | `nix run --quiet .#docs-check` | [37755208565](https://github.com/lambdasistemi/singular/actions/runs/37755208565/job/113238940059) |
| presentation | `ci.yml` dev-shell-checks | `nix develop --quiet -c just check-presentation` | [37808253758](https://github.com/lambdasistemi/singular/actions/runs/37808253758/job/113420623893) |
| conformance presentation | `conformance.yml` lint | `nix run --quiet .#presentation-check -- --front README.md --register docs/model-ledger.md --register docs/theorems.md --register docs/mutants.md docs/consumer-conformance.md` | none found |
| conformance transport | `conformance.yml` conformance-checks, in `conformance` | `nix run --quiet .#conformance-appendix-tests` | [38897248752](https://github.com/lambdasistemi/singular/actions/runs/38897248752/job/116960573466) |
| conformance inventory | `conformance.yml` conformance-checks, in `conformance` | `nix run --quiet .#conformance -- list` | none found |
| script identity | `registry.yml` script-identity, in `onchain` | `nix build --quiet --no-link --print-out-paths .#script-identity` | none found |
| script hash comparison | `registry.yml` script-identity | `nix run --quiet .#script-hash-comparison` | none found |
| build gate | `ci.yml` build-gate | `nix build --quiet .#build-gate` | [38726293124](https://github.com/lambdasistemi/singular/actions/runs/38726293124/job/116392863860) |
| code inventory | `ci.yml` inventory | `nix run --quiet .#inventory-check` | [37763865424](https://github.com/lambdasistemi/singular/actions/runs/37763865424/job/113268117488) |
| inventory controls | `ci.yml` inventory | `nix run --quiet .#inventory-controls` | none found |
| workflow commands | `ci.yml` workflow-commands-resolve | `nix run --quiet .#workflow-commands-resolve-controls` | none found |
| declared checks hosted | `ci.yml` declared-checks-hosted | its three steps: `.#declared-checks-classify-controls`, `.#declared-checks-issue-states`, `.#declared-checks-hosted` | none found |
| development shell | `ci.yml` dev-shell | `nix build --quiet --no-link .#devShells.x86_64-linux.default` | none found |
| lint | `ci.yml` dev-shell | `nix develop --quiet -c just lint` | [38262988483](https://github.com/lambdasistemi/singular/actions/runs/38262988483/job/114869842981) |
| lint controls | `ci.yml` dev-shell-checks | `nix develop --quiet -c just lint-controls` | [38262988483](https://github.com/lambdasistemi/singular/actions/runs/38262988483/job/114869842649) |
| documentation release | `ci.yml` release-check | `nix run --quiet .#release-check` | none found |
| release artifacts | `ci.yml` release-artifacts | `nix run --quiet .#release-artifacts -- "$RUNNER_TEMP/release"` and `.#verify-release-controls` on the same directory | [38252068503](https://github.com/lambdasistemi/singular/actions/runs/38252068503/job/114822254995) |
| release review archive | `ci.yml` release-review-reproduction | `nix run --quiet .#release-review-check` and the extracted-archive step | [38238332736](https://github.com/lambdasistemi/singular/actions/runs/38238332736/job/114777726659) |
| preview | `ci.yml` preview, pull requests only | the build-candidate step and `nix run --quiet .#preview-check` | [38726293124](https://github.com/lambdasistemi/singular/actions/runs/38726293124/job/116392863876) |

## What each acceptance line rests on

| Acceptance line | Rows |
|---|---|
| the library, the instance and the examples build; every new statement is proved from the three standard axioms | model check: the compiled gate fails the build when a statement uses any other axiom, a proof hole included, and the keyword audit refuses a hole outside the facade |
| the registry-free library imports no Singular module, and a planted import is refused | model check, as a change in this ticket to the model checker, with its control in the same run |
| every premise has a satisfying example | model check pins the example statement in the manifest; that its conjuncts name every premise is the auditor's statements-frozen verdict |
| consumers regenerated | simulator, browser, the coverage rows, application model, conformance transport and inventory, rendered documentation, release archive rows |
| speech stamped | rendered documentation, presentation, conformance presentation |
| no behaviour change | script identity, script hash comparison, build gate; and the lane's diff fence: no path under `onchain/`, `offchain/`, the application sources, the blueprint or the script identity file differs from the base |
| repository hygiene | code inventory, inventory controls, lint, lint controls, development shell, workflow commands, declared checks hosted |
| the paper's register lists the new statements | rendered documentation proves the paper renders; no hosted job reconciles the register with the axiom report, so its content is the auditor's paper verdict (gap raised in the plan review) |

## Running it

- Every candidate: a scoped `lake build` of the modules changed, then `nix run --quiet .#model-check`, `nix run --quiet .#simulator-check` and `nix run --quiet .#coverage-tests`.
- The paper candidate adds `nix run --quiet .#docs-check`.
- The final candidate: `nix develop --quiet -c just ci` once, then the push.
- Every other row runs hosted only: the release archive, presentation, lint, inventory, conformance transport and the application model among them. A hosted failure is one repair commit, never a local campaign.
- Every command runs memory-capped and time-bounded with stdin closed.

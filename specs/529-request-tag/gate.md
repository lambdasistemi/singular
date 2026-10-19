# Checks and their evidence boundaries

## Story

As a reviewer, I want to know which executable command tests each promise, which existing command merely carries future cases, and which evidence is still missing.

This is a proposed check set, not a frozen or passing gate. Commands below are read from the workflows at `45cd8a75`; working directories matter. The previous plan at `662663f9` is historical discovery only: its bond/forfeit cases, Lean slice, old workflow lines and former ownership order are not acceptance authority. No additional gate-author seat is commissioned by this document. The approved compact team has the ticket owner prepare this table and the persistent auditor inspect the bound checkpoints.

All executions use the memory, swap and timeout wrapper in the [plan](plan.md). Every row expects exit zero unless explicitly stated. Existing job success proves only the cases actually executed. New product assertions require an executable hosted step in the same diff. Candidate checks are selected by each slice's changed inputs; final affected-consumer checks run locally before the first push, then hosted failures are repaired without locally replaying the hosted matrix.

| Promise or consumer | Exact existing command | Directory and workflow | Use and missing evidence |
|---|---|---|---|
| Booking mint and request exits | `nix flake check` | `onchain`; `registry.yml:180` | Candidate carrier for new real Aiken cases. New semantics not present yet; historical RED: none found in this intake. |
| Economic fold routing and state preservation | `nix flake check` | `onchain`; `registry.yml:180` | Candidate carrier for exact donation, burn, carrier and immutable-state controls; required new behavior, not yet executed. Historical behavioral RED: none found. |
| Registry blueprint | `nix build --quiet --no-link --print-out-paths .#plutus-blueprint` | `onchain`; `registry.yml:105` | Candidate compiled artifact; no ledger claim. Historical RED: none found. |
| Registry identity | `nix build --quiet --no-link --print-out-paths .#script-identity` | `onchain`; `registry.yml:135` | Changed identity propagation. Historical RED: none found. |
| Naming consumers | `nix flake check` | `naming-onchain`; `registry.yml:80` | Before first push when changed or consumed; not proof of booking. Historical RED: none found. |
| Application on-chain consumer | `nix flake check` | `applications/open-datum/onchain`; `registry.yml:261` | Before first push; model conflict must be resolved separately. Historical RED: none found. |
| Off-chain compilation | `nix build --quiet .#component-build` | `offchain`; `ci.yml:96` | Candidate when wire/builders change; builds tests but does not establish their execution. Historical RED: none found. |
| Off-chain lint | `(cd offchain && nix run --quiet .#lint)` | repository root; `ci.yml:64` | Candidate for changed Haskell. Historical RED: none found. |
| Compiled wire vectors | `nix build --quiet --no-link .#checks.x86_64-linux.cage-test-vectors` | repository root; `ci.yml:138` | Before first push; actual encoding correspondence. Historical RED: none found. |
| Off-chain tests | `nix run --quiet .#cage-tests` | `offchain`; `registry.yml:596` | New focused booking/discovery/exit cases must actually execute here or in a named dedicated job. Historical RED: none found. |
| Application library tests | `cd applications/open-datum/offchain && nix run --quiet .#open-datum-tests` | repository root; `ci.yml:182` | Before first push; old termination expectations cannot be silently weakened. Historical carrier RED: [run 38897248626, job 116960571370](https://github.com/lambdasistemi/singular/actions/runs/38897248626/job/116960571370), exact command exited one during test-component build at b967426b; not a behavioral RED. |
| Packaged CLI journey | `nix run --quiet .#demo1-cli-check` | repository root; `registry.yml:695` | Before first push and hosted; must bind actual compiled identities. It does not yet carry the stranger-expiry story. Historical RED: none found. |
| Conformance blueprint encoding | `nix build --quiet --no-link .#registry-blueprint-correspondence` | `conformance`; `conformance.yml:215` | Candidate after wire changes. Historical RED: none found. |
| Conformance appendix | `nix run --quiet .#conformance-appendix-tests` | `conformance`; `conformance.yml:226` | Harness evidence only. Historical RED: none found. |
| Public row inventory | `nix run --quiet .#conformance -- list` | `conformance`; `conformance.yml:229` | Publication only, never execution of rows. Historical RED: none found. |
| Conformance formatting | `nix run --quiet .#format-check` | `conformance`; `conformance.yml:89` | Candidate after Haskell edits. Historical RED: none found. |
| Conformance lint | `nix run --quiet .#hlint-check` | `conformance`; `conformance.yml:93` | Candidate after Haskell edits. Historical RED: none found. |
| Bound model | `nix run --quiet .#model-check` | repository root; `ci.yml:232` | Final non-regression; no implementation claim. Historical RED: none found. |
| Simulator mirror | `nix run --quiet .#simulator-check` | repository root; `ci.yml:252` | Final non-regression; no ledger claim. Historical RED: none found. |
| Application model replay | `nix develop --quiet -c just application-model` | repository root; `ci.yml:508` | Final non-regression; Q-003 means legacy success cannot accept the new consumer behavior. Historical RED: none found. |
| Documentation and speech | `nix run --quiet .#docs-check` | repository root; `ci.yml:453` | Before first push; source freshness and rendering checks, not visual acceptance. Historical RED: none found. |
| Presentation | `nix develop --quiet -c just check-presentation` | repository root; `ci.yml:509` | Planning and changed-page validation. Historical RED: none found. |
| Published coverage | `nix run --quiet .#coverage-check` | repository root; `ci.yml:430` | Honest incomplete baseline, not completion. Historical RED: none found. |
| Local aggregate | `nix develop --quiet -c just ci` | repository root; `justfile:71` | Once before the first push, locally only; hosted steps above remain distinct. Not yet run. |

## Product cases requiring new hosted execution

No existing executed case has been identified for the complete born-tagged mint, unrelated-wallet junk sweep, ordinary-funded economic retraction, stranger expiry or indexed-discovery pollution stories. These are required CI changes in this ticket, not optional local checks. Before freezing a slice, name the description-language row, executable runner and exact workflow invocation. Until then its gate is incomplete. A real behavioral RED and matching GREEN must be retained for each new boundary; setup failures do not fill that column.

The full required hosted-check inventory is refreshed at push from the workflows and runs, including affected release artifacts and journeys. No exact-head hosted run exists for this branch yet. The reporting-only coverage completion command may exit one for declared debt; that is neither a failed implementation test nor a completeness proof.

## Budget and freeze

Each focused candidate set has a 30-minute wall budget and every individual invocation has the 900-second cap. The first-push consumer pass is scheduled once; an over-cap command is escalated, not granted a larger timeout by the writer. The runtime manifest will bind exact membership, directory, command, base, source fence, expected exit and evidence paths after the representation and shared-boundary decisions. This page does not authorize execution against an unfinished contract.

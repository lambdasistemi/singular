# Gate: the existing CI commands that prove each slice

This page is the frozen gate for ticket 494. It is the union of two tables written independently
from the specification and its acceptance lines, one by the ticket owner and one by a GLM gate
author who never saw the first, synthesized once here. Every command is an existing step of
`.github/workflows/ci.yml` or `.github/workflows/conformance.yml` at base `e3c9ab01`; nothing is
invented. Hosted checks on the exact pushed head are the net for every row.

## Story

As the auditor judging a slice, I read which commands decide it, which of them run on every
candidate and which once before the push, and which acceptance lines have no command at all, so
that I trust a green gate for exactly what it proves and no more.

## Provenance

| Input | Hash (sha256) |
|---|---|
| Ticket owner's table | `69dbaf4d48d89b89a3393d5bbc8a694d1905a06d751d69b3933d4fddb31bad39` |
| Independent author's table | `2c47e561b278ba72612fd6d12beae8a9d93cf1fdb2ce93ab4fe4f143e029a6cf` |
| This page | the hash of the committed page is recorded in the ticket owner's journal at freeze |

Conflicts, resolved by the workflow line that decides them. The author listed the retire-active-key
row as re-based onto evidenced rejection; the workflow (`conformance.yml:266-306`) runs a row with no
rejection step, so it stays a guard that a fold's question did not change. The author listed the batch
row under slice four; the batch harness story is re-based in slice two and only re-run in slice four.
The author's rows for the release assembly, the build gate and the off-chain lint reach no file of this
ticket and are left to the hosted checks. One row is the ticket owner's alone: the repository's
aggregate run once on each final candidate.

## The rows

Commands run from the repository root unless a working directory is given. "Candidate" means every
candidate of the named slices; "final" means once on the final candidate of a slice before the push;
"hosted" means only the hosted check on the pushed head. Minutes are estimates from the last green
runs. The red run column is the earlier attempt's hosted run (`a7224021`, run 37757702122 or
37757702153, or `4ee2082b`, run 37755208632) that shows the command can fail.

| Row | Command | Slices | Tier | Min | Exit | Red run and failing line |
|---|---|---|---|---|---|---|
| Model check | `nix run --quiet .#model-check` (`ci.yml:117`) | 1 2 4 | candidate | 20 | 0 | The slice's own failing control; none found hosted |
| Simulator check | `nix run --quiet .#simulator-check` (`ci.yml:137`) | 1 2 4 | candidate | 8 | 0 | 37755208565: `Error: identity/formal/Driver.lean` |
| Application corpus | `nix develop --quiet -c just application-model` (`ci.yml:283`) | 1 2 4 | candidate | 8 | 0 | 37757702153: `FAIL the regenerated corpus equals the committed corpus` |
| Coverage gate | in `conformance`: `nix build --quiet --no-link .#coverageGateTests`, `.#coverageGateSnapshot`; then `nix run --quiet ./conformance#coverage-gate -- --root . inventory`, `... ratchet`, and `... completion` (`conformance.yml:1089-1100`) | 1 2 4 | candidate | 2 | 0 for the first four; completion must exit 1 | 37757702122: `FAIL-CLOSED population ... 5 claimed but no longer discovered` |
| Conformance without a devnet | in `conformance`: `nix build --quiet --no-link .#registry-blueprint-correspondence`; `bash test/ci/dedicated-row-control.sh`; `nix run --quiet .#conformance-appendix-tests`; `nix run --quiet .#conformance -- list` (`conformance.yml:155-169`) | 1 2 3 4 | candidate | 2 | 0 | 37755208632: unit suite exit 1 |
| Format and lint | in `conformance`: `nix run --quiet .#format-check` then `.#hlint-check` (`conformance.yml:85,89`) | 1 2 3 | candidate | 2 | 0 | none found |
| Retraction window row | the job "the retraction window": `bash test/ci/dedicated-row.sh retract-outside-window -- ... nix run --quiet .#conformance -- run retract-outside-window`, then its assertions (`conformance.yml:561-612`) | 1 | candidate, once | 2, devnet | 0 | 37755208632: `property not found: submittedAt` |
| Wrong-reason control | the job "a wrong model reason fails the row" (`conformance.yml:653-663`) | 1 | final | 1, devnet | 0 | 37755208632: `the altered row did not fail naming both reasons` |
| Batch harness row | `REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run batch --receipts-dir "$receipts"` (`conformance.yml:215-218`) | 2 4 | candidate (2), final (4) | 2, devnet | 0 | 37757702122: `the model refused a lawful batch` |
| Refund controls row | the job "reject and retract refund controls": `bash test/ci/dedicated-row.sh reject-and-retract-refund-controls -- ...` then its assertions (`conformance.yml:346-424`) | 2 | candidate | 2, devnet | 0 | 37757702122: `chain=deposit-returned lean=reject-evidence-missing` |
| Running book | `... nix run --quiet .#conformance -- book --receipts-dir "$receipts"` (`conformance.yml:238-241`) | 2 | final | 9, devnet | 0 | 37757702122: same reason mismatch |
| Generic rows | in `conformance`: `bash ../.github/scripts/ci_generic_rows.sh` (`conformance.yml:704`) | 2 3 | final | 9, devnet | 0 (the handled session-debt exit is asserted inside the step) | 37757702122: `disagree for reject at cg08-key`; CI change in this ticket (slice three) |
| Retire-active-key row | the job "retire-active-key": `bash test/ci/dedicated-row.sh retire-active-key -- ... run permanent-retire-active-key`, then `bash test/ci/permanent-retirement-evidence.sh` (`conformance.yml:266-306`) | 2 | final | 3, devnet | 0 | 37757702122: `retirement evidence moved` |
| Early-rejection row | the job "early rejection inside the windows": `bash test/ci/dedicated-row.sh reject-inside-processing-and-retraction-windows -- ...` with its assertions and placement counts (`conformance.yml:464-521`) | 3 | candidate | 4, devnet | 0 | 37757702122: `lean=reject-evidence-missing`; CI change in this ticket |
| Refusal extent | in `conformance`: `nix run --quiet .#conformance-extent -- ../specs/287-traced-refusal-reasons/extent.md <the rows' receipt directories>` (`conformance.yml:1031`) | 2 3 | final, after the rows above | 1 | 0 | runs 37446336658, 37452765931: job failed |
| Workflow lint | `for f in .github/workflows/*.yml; do nix run --quiet nixpkgs#yq-go -- eval '.' "$f" > /dev/null; done`; the `actionlint` step; the `presentation-check` step (`conformance.yml:42-55`) | 2 3 | candidate | 1 | 0 | none found |
| Documents | `nix run --quiet .#docs-check` (`ci.yml:235`); `nix develop --quiet -c just check-presentation`; `nix run --quiet .#release-check` (`ci.yml:309`) | all | final | 17 | 0 | 37905345631: `only a program's receipt carries steps` |
| Code inventory | `nix run --quiet .#inventory-check` (`ci.yml:187`) | all | final | 4 | 0 | 37763865424: `5 unmapped/unknown files` |
| Strict coverage report | `nix run --quiet .#coverage-check`, then `nix run --quiet .#coverage-tests` (`ci.yml:212,215`) | 1 2 4 | final | 8 | 0 | 37755208565: `lean/theorem-debt.json drifts from the extraction` |
| Browser check | `nix run --quiet .#browser-check` (`ci.yml:157`) | 1 2 4 | final | 5 | 0 | none found |
| Repository sanity | `nix develop --quiet -c just ci` (adds the dev-shell checks, the whole-repository lint and the format controls) | all | final, once | 40 | 0 | the ticket owner's own row |
| Hosted only | the fold budget regression, the canonical-identity and serialization sessions (`conformance.yml:190-195,749-798,836-955`), the build gate, the release assembly and verification, the off-chain lint and build | none reached | hosted | | 0 | fence check: no slice touches their files |

## Budget per candidate

The repository aggregate already runs the model, application, simulator, browser, documents,
inventory, format and lint rows locally, so a final run is the aggregate plus the rows it does not
cover: the coverage gate, the strict coverage report, the release check and the slice's devnet rows.

| Slice | Every candidate | Once before the push |
|---|---|---|
| One | 44 minutes: the rows marked candidate, the retraction row once | about 53: the aggregate, the strict coverage report, the release check, the wrong-reason control |
| Two | 47 | about 74: the aggregate, the strict coverage report, the release check, the running book, the generic rows, the retire row, the extent |
| Three | 9 | about 54: the aggregate, the release check, the generic rows, the extent |
| Four | 40 | about 54: the aggregate, the strict coverage report, the release check, the batch row |

Rows run in parallel where independent. A candidate over budget has its devnet rows moved to the
hosted checks or the slice is cut again; nobody waits on a gate. A hosted failure is one repair
commit, never a local rerun of the hosted job list.

## Acceptance lines with no command

Two lines have no CI job: that the rulings and the truth table are recorded, and that the evidence
contract and its release record exist. The truth table is also exported as corpus rows that the model
check replays, which covers its content; the pages render under the documents row, which covers their
existence. Nothing asserts the rulings' wording or the release record's fields. This is a missing CI
job, reported to the epic owner; no local check is invented. Until it is answered the persistent
auditor reads those pages at the pre-push checkpoint. The clause "published unmet as the ruling
directs" has no job either, but its carrier is the generic rows' expected-debt assertion, a CI change
in slice three.

## Falsification

A single green proves nothing. The slice's own failing control is committed first and must fail for the
right reason: slice one's retraction scenarios, slice two's historical scenario accepted on the base,
slice four's two-batch scenarios. Each failure class a row covers has a cited red run above; a row
with none found is covered by that control or by the aggregate. Falsifying the unchanged guard rows
(retire-active-key, wrong-reason) is their hosted reds on the earlier attempt.

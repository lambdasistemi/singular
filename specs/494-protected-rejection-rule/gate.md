# Gate: the existing CI commands that prove each slice

This page is the frozen gate for ticket 494. It is the union of two tables written independently
from the specification and its acceptance lines, one by the ticket owner and one by a GLM gate
author who never saw the first, synthesized once here. Every command is an existing step of
`.github/workflows/ci.yml` or `.github/workflows/conformance.yml` at base `e7b55ac9`; nothing is
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
row as re-based onto evidenced rejection; the workflow (`conformance.yml:302-381`) runs a row with no
rejection step, so it stays a guard that a fold's question did not change. The author listed the batch
row under slice four; the batch harness story is re-based in slice two and only re-run in slice four.
The author's rows for the release assembly, the build gate and the off-chain lint reach no file of this
ticket and are left to the hosted checks. One row is the ticket owner's alone: the repository's
aggregate run once on each final candidate.

## The rebase onto `e7b55ac9`

Checked on 13 October 2026 by finding every command below in the two workflows on the new base: none
of the commands changed, and the jobs that carry them kept their names. Only their line numbers moved,
so the citations below are the new ones. The only change inside a job a row uses is a new
format-controls step in the format and lint job, which first checks the real root exactly as the
format check does. The conformance workflow now also starts on a change under `applications/`, which
this ticket's regenerated application files will trigger. Because no existing row changed its command or
its subject, no gate author was commissioned again.

Two hosted jobs that did not exist at the old base can be broken by this ticket's files; they are the
ticket owner's rows, listed in the last row of the table and run only on the pushed head:
"Release review archive reproduction" archives the Lean model, the simulator, the constitution, the
theorem page and the transport source and re-checks them from the extracted bytes, and "Declared
checks are hosted" refuses any flake app or check that no workflow step names. The jobs for the
open-datum application's Haskell, the registry test vectors and the negative host read none of the
files this ticket edits.

## Gate version 2: the book, the generic rows and the extent check turn green in slice three

Found while slice two was built: the running book contains every program that has a chapter, among them the dedicated
early-rejection program, and the generic session contains the standing unmet consumer-requirement row. Decision B turns
both lawful in slice three, so at the end of slice two they cannot agree and these three rows cannot exit 0. Slices two
and three are pushed together, so no red head is pushed. Version 2 moves three rows from slice two to the final tier of
slice three and changes nothing else: the running book, the generic rows and the refusal extent check. The slice-two
commit places the lawful rejects of those rows after both windows with expiry evidence; their end-to-end proof is the
hosted run on the head that includes slice three.

## The rows

Commands run from the repository root unless a working directory is given. "Candidate" means every
candidate of the named slices; "final" means once on the final candidate of a slice before the push;
"hosted" means only the hosted check on the pushed head. Minutes are estimates from the last green
runs. The red run column is the earlier attempt's hosted run (`a7224021`, run 37757702122 or
37757702153, or `4ee2082b`, run 37755208632) that shows the command can fail.

| Row | Command | Slices | Tier | Min | Exit | Red run and failing line |
|---|---|---|---|---|---|---|
| Model check | `nix run --quiet .#model-check` (`ci.yml:232`) | 1 2 4 | candidate | 20 | 0 | The slice's own failing control; none found hosted |
| Simulator check | `nix run --quiet .#simulator-check` (`ci.yml:252`) | 1 2 4 | candidate | 8 | 0 | 37755208565: `Error: identity/formal/Driver.lean` |
| Application corpus | `nix develop --quiet -c just application-model` (`ci.yml:506`) | 1 2 4 | candidate | 8 | 0 | 37757702153: `FAIL the regenerated corpus equals the committed corpus` |
| Coverage gate | in `conformance`: `nix build --quiet --no-link .#coverageGateTests`, `.#coverageGateSnapshot`; then `nix run --quiet ./conformance#coverage-gate -- --root . inventory`, `... ratchet`, and `... completion` (`conformance.yml:1131-1165`) | 1 2 4 | candidate | 2 | 0 for the first four; completion must exit 1 | 37757702122: `FAIL-CLOSED population ... 5 claimed but no longer discovered` |
| Conformance without a devnet | in `conformance`: `nix build --quiet --no-link .#registry-blueprint-correspondence`; `bash test/ci/dedicated-row-control.sh`; `nix run --quiet .#conformance-appendix-tests`; `nix run --quiet .#conformance -- list` (`conformance.yml:215-229`) | 1 2 3 4 | candidate | 2 | 0 | 37755208632: unit suite exit 1 |
| Format and lint | in `conformance`: `nix run --quiet .#format-check` then `.#hlint-check` (`conformance.yml:89,93`) | 1 2 3 | candidate | 2 | 0 | none found |
| Retraction window row | the job "the retraction window": `bash test/ci/dedicated-row.sh retract-outside-window -- ... nix run --quiet .#conformance -- run retract-outside-window`, then its assertions (`conformance.yml:597-687`) | 1 | candidate, once | 2, devnet | 0 | 37755208632: `property not found: submittedAt` |
| Wrong-reason control | the job "a wrong model reason fails the row" (`conformance.yml:688-738`) | 1 | final | 1, devnet | 0 | 37755208632: `the altered row did not fail naming both reasons` |
| Batch harness row | `REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run batch --receipts-dir "$receipts"` (`conformance.yml:278`) | 2 4 | candidate (2), final (4) | 2, devnet | 0 | 37757702122: `the model refused a lawful batch` |
| Refund controls row | the job "reject and retract refund controls": `bash test/ci/dedicated-row.sh reject-and-retract-refund-controls -- ...` then its assertions (`conformance.yml:382-499`) | 2 | candidate | 2, devnet | 0 | 37757702122: `chain=deposit-returned lean=reject-evidence-missing` |
| Running book | `... nix run --quiet .#conformance -- book --receipts-dir "$receipts"` (`conformance.yml:301`) | 3 | final | 9, devnet | 0 | 37757702122: same reason mismatch |
| Generic rows | in `conformance`: `bash ../.github/scripts/ci_generic_rows.sh` (`conformance.yml:764`) | 3 | final | 9, devnet | 0 (the handled session-debt exit is asserted inside the step) | 37757702122: `disagree for reject at cg08-key`; CI change in this ticket (slice three) |
| Retire-active-key row | the job "retire-active-key": `bash test/ci/dedicated-row.sh retire-active-key -- ... run permanent-retire-active-key`, then `bash test/ci/permanent-retirement-evidence.sh` (`conformance.yml:302-381`) | 2 | final | 3, devnet | 0 | 37757702122: `retirement evidence moved` |
| Early-rejection row | the job "early rejection inside the windows": `bash test/ci/dedicated-row.sh reject-inside-processing-and-retraction-windows -- ...` with its assertions and placement counts (`conformance.yml:500-596`) | 3 | candidate | 4, devnet | 0 | 37757702122: `lean=reject-evidence-missing`; CI change in this ticket |
| Refusal extent | in `conformance`: `nix run --quiet .#conformance-extent -- ../specs/287-traced-refusal-reasons/extent.md <the rows' receipt directories>` (`conformance.yml:1091`) | 3 | final, after the rows above | 1 | 0 | runs 37446336658, 37452765931: job failed |
| Workflow lint | `for f in .github/workflows/*.yml; do nix run --quiet nixpkgs#yq-go -- eval '.' "$f" > /dev/null; done`; the `actionlint` step; the `presentation-check` step (`conformance.yml:22-56`) | 2 3 | candidate | 1 | 0 | none found |
| Documents | `nix run --quiet .#docs-check` (`ci.yml:453`); `nix develop --quiet -c just check-presentation`; `nix run --quiet .#release-check` (`ci.yml:532`) | all | final | 17 | 0 | 37905345631: `only a program's receipt carries steps` |
| Code inventory | `nix run --quiet .#inventory-check` (`ci.yml:305`) | all | final | 4 | 0 | 37763865424: `5 unmapped/unknown files` |
| Strict coverage report | `nix run --quiet .#coverage-check`, then `nix run --quiet .#coverage-tests` (`ci.yml:430,433`) | 1 2 4 | final | 8 | 0 | 37755208565: `lean/theorem-debt.json drifts from the extraction` |
| Browser check | `nix run --quiet .#browser-check` (`ci.yml:272`) | 1 2 4 | final | 5 | 0 | none found |
| Repository sanity | `nix develop --quiet -c just ci` (adds the dev-shell checks, the whole-repository lint and the format controls) | all | final, once | 40 | 0 | the ticket owner's own row |
| Review archive and declared checks | the job "Release review archive reproduction": `nix run --quiet .#release-review-check`, then the archived check and default apps run from the extracted archive (`ci.yml:577-621`); the job "Declared checks are hosted": `nix run --quiet .#declared-checks-hosted` (`ci.yml:336-379`) | 1 2 4 | hosted | | 0 | none found; the ticket owner's row, added at the rebase |
| Hosted only | the fold budget regression, the canonical-identity and serialization sessions (`conformance.yml:233-255,786-1030`), the build gate, the release assembly and verification, the off-chain lint and build | none reached | hosted | | 0 | fence check: no slice touches their files |

## Budget per candidate

The repository aggregate already runs the model, application, simulator, browser, documents,
inventory, format and lint rows locally, so a final run is the aggregate plus the rows it does not
cover: the coverage gate, the strict coverage report, the release check and the slice's devnet rows.

| Slice | Every candidate | Once before the push |
|---|---|---|
| One | 44 minutes: the rows marked candidate, the retraction row once | about 53: the aggregate, the strict coverage report, the release check, the wrong-reason control |
| Two | 47 | about 50: the aggregate, the strict coverage report, the release check, the retire row |
| Three | 9 | about 80: the aggregate, the release check, the running book, the generic rows, the extent |
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

## Gate version 3: the rows of slices five to ten

Added before the first economic coder, from existing CI commands only. Two independent tables were synthesized once: the ticket owner's (the
slice rows above carried to the model slices, plus the documentation rows) and a Grok gate author's, read from the workflows at the plan commit
(`handoffs/gate-table.md` in the author's runtime root, sha256 `bf90020c3812cfa1b458431d9e4f5ea7066b934f209fa8c551367df690c07c52`). The author
found seven acceptance lines with no command; the disposition of each is below, and three of them become "CI change in this ticket" rows. The
settled rows above are unchanged.

| Row | Command | Slices | Tier | Min | Exit | Red run |
|---|---|---|---|---|---|---|
| Model check, including the axioms guard (every proved statement depends only on `propext`, `Classical.choice`, `Quot.sound`, and `sorryAx` or `Lean.ofReduceBool` fail) | `nix run --quiet .#model-check` (`ci.yml:232`); the guard is `tools/check_model.py:141` and `lean/Singular/Audit.lean` during the build | 5 6 7 8 | candidate | 20 | 0 | the slice's own failing control; none found hosted |
| Simulator check | `nix run --quiet .#simulator-check` (`ci.yml:252`) | 5 6 7 8 | candidate | 8 | 0 | 37755208565: `Error: identity/formal/Driver.lean` |
| Application corpus | `nix develop --quiet -c just application-model` (`ci.yml:506`) | 5 6 7 8 | candidate | 8 | 0 | 37757702153: `FAIL the regenerated corpus equals the committed corpus` |
| Coverage gate and real-tree tests | `nix build --quiet --no-link .#coverageGateTests`, `.#coverageGateSnapshot`; `nix run --quiet ./conformance#coverage-gate -- --root . inventory`, `ratchet`, `completion` (`conformance.yml:1131-1165`); `nix run --quiet .#coverage-tests` (`ci.yml:433`) | 5 6 7 8 | candidate | 3 | 0, completion 1 | 37757702122: `FAIL-CLOSED population`; 37755208565: `AssertionError: 79 != 67` |
| Conformance without a devnet, transport tests | `nix run --quiet .#conformance-appendix-tests` and the neighbouring commands (`conformance.yml:215-229`) | 5 6 7 | candidate | 2 | 0 | 37755208632: unit suite exit 1 |
| Format and lint of the Haskell the transport touches | `nix run --quiet .#format-check` then `.#hlint-check` in `conformance` (`conformance.yml:89,93`) | 5 6 7 | candidate | 2 | 0 | 38110736278: `Suggestion: Redundant $` |
| Batch asked of the model, once, because the transport reaches it with the new fields absent | the job "batch instructions asked of the model" (`conformance.yml:278`) | 5 6 7 | candidate, once | 3, devnet | 0 | 37757702122: `the model refused a lawful batch` |
| Lint of the files the slices add | `nix develop --quiet -c just lint` (`ci.yml:478`) | 5 to 10 | final | 2 | 0 | 38357384720: `lint: FAILED` |
| Documents, including narration and speech of every edited page | `nix run --quiet .#docs-check` (`ci.yml:453`); `nix develop --quiet -c just check-presentation` (`ci.yml:507`); `nix run --quiet .#release-check` (`ci.yml:532`) | 5 to 10 | final | 17 | 0 | 38119535187: `missing speech` |
| Code inventory, which must classify the paper sources | `nix run --quiet .#inventory-check` (`ci.yml:305`); CI change in this ticket (slice nine): `tools/code_inventory.py` classifies `paper/**` | 5 to 10 | final | 4 | 0 | 37763865424: `5 unmapped/unknown files` |
| Strict coverage report, browser check | `nix run --quiet .#coverage-check` (`ci.yml:430`); `nix run --quiet .#browser-check` (`ci.yml:272`) | 5 6 7 8 | final | 8 | 0 | 37755208565 |
| The built site contains the paper PDF; CI change in this ticket (slice nine) | `nix run --quiet .#docs-check` (`ci.yml:453`) once `tools/check_site.py` asserts the PDF is in the built site and the page links it | 9 10 | candidate | 2 | 0 | the current red `docs-check` runs show the checker fails; the new assertion is falsified by the slice's failing control |
| The paper's theorem table equals the audit report and every Lean name the paper cites resolves; CI change in this ticket (slice nine): a table generator under `tools/`, run by the documents check | `nix run --quiet .#docs-check` (`ci.yml:453`) with the generator's check step added to `nix/docs.nix` | 9 10 | candidate | 2 | 0 | the slice's failing control |
| Repository sanity | `nix develop --quiet -c just ci` | 5 to 10 | final, once | 40 | 0 | the ticket owner's own row |
| Review archive and declared checks | the jobs of the version 2 section (`ci.yml:577-621`, `ci.yml:336-379`) | 5 to 10 | hosted | | 0 | the ticket owner's row |
| Hosted aggregate | the devnet rows of the conformance workflow, which ask the same driver with the new fields absent, and the rest of the CI and registry workflows | 5 to 10 | hosted | | 0 | fence check: no slice touches their files |

Acceptance lines with no command, and what is done:

| Line | Disposition |
|---|---|
| Economic theorems live outside the files the axioms guard walks | The theorems and the kept counterexamples are declared in `lean/Singular/Statements.lean`, in the namespace the guard and the register already cover; `lean/Singular/Economics.lean` holds definitions only. No new check is needed. |
| Each statement expected to fail has its counterexample kept | Each is a named theorem in that namespace stating that the counterexample exists, so the register, the audit report and the paper's table list it. |
| The restatement table | A published record of old and new identities, committed as data, not a runnable check. |
| No sentence of the paper claims more than the Lean statement it cites | No command can read a sentence. The generator's check (previous table) makes every cited name resolve, and the persistent auditor reads the paper against the statements at the final checkpoint of slices nine and ten. |
| The constitution version string | The reconciliation reads declared names only; the persistent auditor reads the version at the final checkpoint of slice five. |

Budget per candidate: slices five to eight about 40 minutes, the rows marked final about 60 once before a push; slices nine and ten about 5
and 25.

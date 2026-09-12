# Bounded feasibility evaluation — `lambdasistemi/tasty-bdd` for the #80 story layer

Issue #80 · epic 18 · evaluation only, **not an adoption**, **not delivered coverage**.
Inspected revision, built and executed here: `f55494c9b917ec12b4d01e506694b1a5c3b41b56`
("permit multiple whens, added tasty still work test, fixed And case"), verified same
as `lambdasistemi/tasty-bdd` master HEAD by `ls-remote`; the stale `paolino/tasty-bdd`
name is retired everywhere in this directory. The spike resolves it through a
`source-repository-package` stanza (`cabal.project`); the tree carries no vendored
copy and no lock file was refreshed.
Recommendation returned to the epic-18 owner with this evidence; adoption is a separate,
owner-owned decision. Nothing here reduces any obligation's debt.

## What was run (per the NOTE-001/NOTE-002 conditions, in order)

One real Lean obligation, one real implementation boundary, no toy:

- **Obligation (pinned):** `Singular.NamingStatements.naming_occupied_key_refuses_duplicate`
  (manifest statement digest `5bb53ab9…aa33c86b`, PROVED) — a competing certified Insert for
  the now-occupied key is refused with the named registry reason; the Lean model pins the
  refusal at `Singular/Model.lean:175` (`occupied-key`).
- **Implementation execution:** the packaged conformance runner
  (`nix build ./conformance#conformance`) driving row **CG05** — *Insert on a key that is
  already present* — against a real devnet with the real compiled blueprint, including its
  executing negative control (a fresh cage accepting a valid insert, proving the refusal
  discriminates).

Spike sources: `spike-app/Main.hs`, `spike.cabal` (`hs-source-dirs: spike-app` — the
committed file wrongly said `app` and could never have built), `cabal.project`
(source-repository pin above; the spike builds and runs outside the repo, in `/tmp`).

## Results, each journaled from an actual run on this host

| check | result | evidence |
|---|---|---|
| 1. minimal positive scenario compiles and runs under the pinned Nix environment (GHC 9.12.3, conformance dev shell) | PASS | `cabal build all` clean; the honest story passed end to end in 47.06 s |
| 2. deliberately failing scenario compiles and runs | PASS | `spike negative` fails exactly the lying assertion ("deliberate lie: the refusal must not have happened…") |
| 3. failing assertion produces a failing process status | PASS | `spike negative` exits **1** (`1 out of 2 tests failed`) |
| 4. teardown behaviour on real resources | **PARTIAL — see findings** | the scenario's own `GivenAndAfter` teardown removed the receipts dir on success; on a *failed* scenario the teardown did not run (see F-2) |
| 5. repaired adapter: passing story cleans up, proven | PASS | `spike positive` exits 0 with all assertions green; the release proof records the receipts dir gone and no marker nodes remaining |
| 6. repaired adapter: failing story cleans up, proven | PASS | `spike negative` exits 1 on the deliberate lie; the release proof still exists with the dir gone and no marker nodes remaining — the F-2 repair |
| 7. repaired adapter: SIGKILL-abandoned session reaped | PASS | spike `SIGKILL`ed mid-devnet leaves an orphaned node; `spike reap` finds it by marker, terminates it, removes the session dir and exits 0 with none remaining — the abnormal-exit class no in-process bracket survives |

Story assertions that passed in positive mode (all computed from the runner's real output):
exit success; `1/1 rows ok`; `REFUSED at submit` (script-attributed, phase-2 marker); the
control line `the refusal discriminates`; the receipt artifact `receipt-CG05.json` exists.

## Findings, each with its adoption consequence

- **F-1 — repaired in the adapter; mechanism stated precisely.** Two earlier runs left
  running nodes, observed against a different lane's runner. Against this tree's pin
  (`cardano-node-clients` `38fc1917`, whose `withCardanoNode` brackets terminate-plus-wait
  and session-dir removal), normal exits clean up after themselves — verified here: no
  `/tmp/conformance-*` residue and no live session nodes after the repaired positive and
  negative runs. What no in-process bracket can survive is abnormal termination (SIGKILL,
  CI timeout): the process dies without running finalizers. The adapter therefore owns
  session teardown outright: every story run exports a unique marker `TMPDIR`, and release
  (SIGTERM, grace, SIGKILL, verify) plus the standalone `spike reap` mode reclaim exactly
  that marker's nodes and directory — sibling lanes and infra nodes can never match.
  Demonstrated on a SIGKILL-orphaned live node (reaped by marker, verified gone).
  *Blocks adoption* until this teardown exists — now present and proven above (checks 5–7).
  Neither the row runner (`conformance/app/Conformance/Run.hs`, sibling-owned) nor the
  devnet library (epic 17) was touched.
- **F-2 — repaired in the adapter; mechanism read from source, not inferred.**
  `Test.Tasty.Bdd.run` composes all teardowns *before* the `When` action runs, so any
  exception from `When` skips them entirely, and `Then`-assertion failures skip them
  under the default ingredients (`FailFast` branch). The adapter now binds the session
  through tasty's `withResource` (acquire: marker dir, receipts dir, node baseline;
  release: reap, remove, write the release proof) and binds **no** real resource lifetime
  through `GivenAndAfter`. Demonstrated: the negative run exits 1 with the release proof
  present, the dir gone and no marker nodes left (check 6). A cleanup claim with no
  failing-path demonstration would be the honour system this epic rejects.
- **F-3 (minor, adapter ergonomics):** `Test.BDD.Language` exports a `when` combinator that
  collides with `Control.Monad.when`; adapters need a qualified-import convention.
  *Does not block* — a naming convention in the adapter solves it.
- **F-4 (README staleness, confirmed):** the README's `testBdd` example does not compile
  against the exported API; `testBehavior`/`testBehaviorIO`/`testBehaviorF` from source (and
  the repo's own tests) are the correct integration path, as the inspection said.
  *Does not block* — upstream README fix or a note in our adapter docs.

## What the library supplies, and what our adapter must add

Supplies: phase-indexed `Language` GADT (`Given`/`GivenAndAfter`/`When`/`Then`/`End`), free
do-notation, Tasty integration (`testBehavior`/`testBehaviorIO`/`testBehaviorF`), teardown
ordering, per-`Then` assertions fed from the `When` result.

Our adapter must add (none of it provided): Lean vocabulary extraction and theorem
identities (`name` + `statementSha256` bindings), domain nouns/actions/predicates outside
the generic plumbing, non-vacuity enforcement (the free interface permits an empty program,
repeated `when_` blocks and `When action End` — an empty `Then` set is expressible),
seeds/discard-rate/shrinking evidence export, per-scenario identity for the coverage
record, and failure-safe resource teardown — provided since this revision:
`withResource` owns the session (marker dir, receipts dir, node baseline) and release
reaps marker nodes, removes the marker tree and writes the release proof, on pass
and on failure alike. `Given` keeps precondition checks only; no real resource
lifetime rides `GivenAndAfter`. The `when`-vs-`Control.Monad.when` collision (F-3)
is handled by the qualified `CM.when` convention used throughout `spike-app/Main.hs`.

## Comparison against the human-correspondence requirement

The constructors carry actions and assertions, not theorem IDs or clause-by-clause readings;
the runner names whole scenarios. The clause-level reading surface (`Given`/`When`/`Then`
bound one-to-one to Lean clauses) must live in our vocabulary/mapping layer and the
rendered correspondence view — feasible (see `../correspondence/`), but it is adapter work,
not library output.

## Recommendation (to the epic-18 owner, for the user's review)

**Adopt `lambdasistemi/tasty-bdd` as the generic sequencing/Tasty plumbing for the story layer,
behind a thin Singular adapter, conditional on:**

1. F-2 handled in the adapter (failure-safe teardown wrapper) before any scenario binds a
   real resource — done, checks 5–6;
2. F-1 session teardown present and proven (checks 5–7) before stories drive devnet sessions in
   CI;
3. operator review of the two representative rendered stories — the ground instance
   (`../correspondence/naming_occupied_key_refuses_duplicate.md`) and the equivalence under
   load (`../correspondence/fold_iff.md`) — before any DSL scales across the suite.

GHC 9.12.3 compatibility is established for the evaluated surface by this spike's builds
and runs. Alternative frameworks were not evaluated (out of scope by instruction). This
evaluation does not reduce any debt row: the obligation it exercised remains unmapped and
insufficient-layer in the record.

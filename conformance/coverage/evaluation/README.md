# Bounded feasibility evaluation — `paolino/tasty-bdd` for the #80 story layer

Issue #80 · epic 18 · evaluation only, **not an adoption**, **not delivered coverage**.
Inspected revision, built and executed here: `f55494c9b917ec12b4d01e506694b1a5c3b41b56`
("permit multiple whens, added tasty still work test, fixed And case").
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

Spike sources: `spike-app/Main.hs`, `spike.cabal`, `cabal.project` (tasty-bdd vendored at the
pinned checkout; no repository lock refreshed; the spike ran outside the repo, in `/tmp`).

## Results, each journaled from an actual run on this host

| check | result | evidence |
|---|---|---|
| 1. minimal positive scenario compiles and runs under the pinned Nix environment (GHC 9.12.3, conformance dev shell) | PASS | `cabal build all` clean; the honest story passed end to end in 47.06 s |
| 2. deliberately failing scenario compiles and runs | PASS | `spike negative` fails exactly the lying assertion ("deliberate lie: the refusal must not have happened…") |
| 3. failing assertion produces a failing process status | PASS | `spike negative` exits **1** (`1 out of 2 tests failed`) |
| 4. teardown behaviour on real resources | **PARTIAL — see findings** | the scenario's own `GivenAndAfter` teardown removed the receipts dir on success; on a *failed* scenario the teardown did not run (see F-2) |

Story assertions that passed in positive mode (all computed from the runner's real output):
exit success; `1/1 rows ok`; `REFUSED at submit` (script-attributed, phase-2 marker); the
control line `the refusal discriminates`; the receipt artifact `receipt-CG05.json` exists.

## Findings, each with its adoption consequence

- **F-1 — the row runner leaks its devnet cardano-node process and session dir on normal
  exit.** Two separate runs left two running nodes (`/tmp/conformance-<pid>-<ts>/cardano-e2e`);
  cleanup performed by the evaluator; the fix belongs to the runner, not the BDD layer.
  *Blocks adoption of devnet-bound stories in CI:* stories that drive real sessions must not
  leak a node per run. *Does not block* pure/in-process stories, or CI-external use. To lift:
  the runner tears down (or explicitly reuses) its session and node on exit, verified by a
  no-leak assertion like the spike's.
- **F-2 — under `defaultMain`'s default ingredients, a scenario that fails skips its
  `GivenAndAfter` teardown** (observed: the receipts dir survived a failed scenario). The
  library exposes `afterEach`/`withResource` as the escape hatch; this matches the inspected
  reference's fail-fast caveat and now verifies it empirically. *Blocks adoption as-is:* any
  real resource (devnet session, files, keys) bound through bare `GivenAndAfter` leaks on the
  first red scenario — precisely when cleanup matters most. To lift: our adapter binds every
  real resource through a failure-safe wrapper (`withResource`/`afterEach` or an explicit
  finalizer test) and never through bare `GivenAndAfter`; demonstrated once on a real
  resource before any scaled use.
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
record, and failure-safe resource teardown (F-2).

## Comparison against the human-correspondence requirement

The constructors carry actions and assertions, not theorem IDs or clause-by-clause readings;
the runner names whole scenarios. The clause-level reading surface (`Given`/`When`/`Then`
bound one-to-one to Lean clauses) must live in our vocabulary/mapping layer and the
rendered correspondence view — feasible (see `../correspondence/`), but it is adapter work,
not library output.

## Recommendation (to the epic-18 owner, for the user's review)

**Adopt `paolino/tasty-bdd` as the generic sequencing/Tasty plumbing for the story layer,
behind a thin Singular adapter, conditional on:**

1. F-2 handled in the adapter (failure-safe teardown wrapper) before any scenario binds a
   real resource;
2. F-1 fixed or bounded in the conformance runner before stories drive devnet sessions in
   CI;
3. operator review of the two representative rendered stories — the ground instance
   (`../correspondence/naming_occupied_key_refuses_duplicate.md`) and the equivalence under
   load (`../correspondence/fold_iff.md`) — before any DSL scales across the suite.

GHC 9.12.3 compatibility is established for the evaluated surface by this spike's builds
and runs. Alternative frameworks were not evaluated (out of scope by instruction). This
evaluation does not reduce any debt row: the obligation it exercised remains unmapped and
insufficient-layer in the record.

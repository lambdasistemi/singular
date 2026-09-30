# Research for the fold budget control

As the ticket owner, I want each planning decision traced to the source line that forces it, so the control mutates the real declaration path and runs the real CI command.

## Source map

All paths are at base `24ecba3f02840424c65b68bf391fccb61b43ea2f`.

| Link | Source | Fact |
| --- | --- | --- |
| CI step | `.github/workflows/conformance.yml` lines 144 to 146 | In `conformance/`, the step runs `nix run --quiet .#conformance-tests` with no environment. |
| App | `conformance/flake.nix`, `runningBook` | Builds `../onchain#plutus-blueprint` only when `REGISTRY_BLUEPRINT` is unset. Then it runs the appendix unit suite, prints `Harness appendix: honest fold budget regression`, runs `fold-budget-regression --receipts-dir <tmp>`, then `conformance book`. The shell stops at the first nonzero step. |
| Regression target | `conformance/conformance.cabal`, `fold-budget-regression`; `test/fold-budget/BudgetMain.hs` | It links the test fixture instead of the production no-op, runs row CG21, prints a failure line and exits nonzero on any exception, and prints `fixed fallback refused; evaluated interpreter accepted` on success. |
| Fixture | `test/fold-budget/Conformance/FoldFixture.hs` | On the first fold it measures every purpose, sets the fallback one below the peak, requires the node to refuse that submission, and returns the fallback as the fold's default units. |
| Runner | `app/Conformance/Run/Live.hs` lines 914 to 949 and 661 to 698 | The fold's default units come from the fixture. The runner probes, evaluates and allocates a per-purpose declaration, then assembles the submitted transaction with `build declared`. |
| Guard | `app/Conformance/Run/Live.hs` lines 758 to 760 | Before submission the runner requires the assembled transaction's per-purpose units to equal its declaration, and fails locally otherwise. |
| Attribution | `app/Conformance/Run/Live.hs` lines 823 to 838 and 2740 to 2755 | A node refusal is recorded with the declaration; the step line reports `refusalKind=budget`, `budgetPurposes` and `overDeclaredPurposes` when execution budget caused it. |
| Builder | `app/Conformance/Run/Fold.hs` `unitsFor` | A purpose absent from the per-purpose map takes the fold's default units. |
| Allocation | `app/Conformance/Run/Units.hs`, `lib/Conformance/PurposeUnits.hs` | Evaluated units are measured by the node and allocated within the protocol limits. |

## Decisions

The mutation replaces the runner's per-purpose declaration itself with the fold's default units for every purpose, which the fixture set to its fixed fallback. This is the regression the issue names: the evaluated declaration replaced by a fixed guess. Assembly, the consistency guard and refusal attribution all read that one declaration, so the guard passes and the transaction reaches the node. Probing and measurement still run.

The planning audit rejected a narrower mutant that only emptied the map handed to the final assembly: the guard then fails locally before any submission, which is not a ledger refusal. No guard is disabled to make a mutant reach the node.

The mutant is a local commit on a detached worktree made by applying the committed patch to the candidate. The run record therefore reports a clean tree and a commit whose difference from the candidate is the patch. It is never pushed.

Both runs use the CI command in `conformance/`, with `REGISTRY_BLUEPRINT` set to the candidate's blueprint built once. The wrapper computes the same value when the variable is absent, so this is the same code path with the nested build lifted out and bound.

The genesis directory is the wrapper default in each tree's own store copy. The two copies differ in store path, so the record binds a content digest of the directory.

## Alternatives rejected

A CI step running the mutant on every pull request would add a second full devnet run and duplicate the conformance job. The ticket excludes that.

An environment-armed control inside the product runner, like the CA04 control, would add a production switch for a test-only fault. The regression target exists so the public runner never links that fixture.

A unit test of the allocator, a source search for the declaration, the local guard's failure or the fixture's expected refusal cannot fail when the runner stops using the evaluated declaration. None of them is a RED.

# Recorder call shape

As the coder, I want the recorder's interface fixed before I write it, so the retained evidence has one reproducible entry point.

## Recorder

`conformance/review/fold-budget-control/record --candidate CANDIDATE --out OUT`

| Argument | Type | Constraint |
| --- | --- | --- |
| `CANDIDATE` | commit id | a clean local commit containing the patch and the recorder |
| `OUT` | directory | created fresh, and receives the two records and the two raw logs |

Effects: it creates and removes its own detached worktrees outside the issue worktree, and creates one local mutant commit that is never pushed. It runs nix builds and two devnet runs. It exits 0 only when the pair is admissible under the data model, and nonzero otherwise, with the reason in its own output.

## Runner, unchanged

The patch changes no signature. It replaces the value bound as the per-purpose declaration in the generic fold step of `Conformance.Run.Live`. No check is removed or weakened.

## Regression target, conditional

Only under R280-06: `main :: IO ()` in `BudgetMain` keeps its command line, `--receipts-dir DIR`. It exits nonzero when the CG21 session ends without the row's expected verdict, including when the runner's own honest fold is refused.

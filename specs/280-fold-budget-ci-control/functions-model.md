# Recorder call shape

As the coder, I want the recorder's interface fixed before I write it, so the retained evidence has one reproducible entry point.

## Recorder

`conformance/review/fold-budget-control/record.sh --candidate CANDIDATE --out OUT`

| Argument | Type | Constraint |
| --- | --- | --- |
| `CANDIDATE` | commit id | a clean local commit containing the patch and the recorder |
| `OUT` | directory | created fresh, and receives the two records and the two raw logs |

`OUT` must not exist yet; the recorder creates it before its first command, so every captured output survives an early refusal. Effects: it creates and removes only its own detached worktrees outside the issue worktree, reports any failure to remove them in its exit status, and creates one local mutant commit that is never pushed. Every git and nix command it runs is journalled with argument vector, directory, times, exit and an output digest; build stages inside one `nix run` belong to that invocation. It runs nix builds and two devnet runs. It exits 0 only when the pair is admissible under the data model, and nonzero otherwise, with the reason in its own output.

## Runner, unchanged

The patch changes no signature. It replaces the value bound as the per-purpose declaration in the generic fold step of `Conformance.Run.Live`. No check is removed or weakened.

## Regression target, conditional

Only under R280-06: `main :: IO ()` in `BudgetMain` keeps its command line, `--receipts-dir DIR`. It exits nonzero when the CG21 session ends without the row's expected verdict, including when the runner's own honest fold is refused.

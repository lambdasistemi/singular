# Fold budget control pair

As a registry integrator, I want evidence that the conformance job's own command fails when the runner stops declaring script budgets from node evaluation, so a green conformance job means honest folds are budgeted by measurement.

## What the pair shows

The conformance job runs `nix run --quiet .#conformance-tests` in `conformance/`. That command runs the appendix unit suite, then the fold budget regression, then the product book.

The pair is two runs of that command against one validator blueprint, one genesis and one node:

- **Mutant.** The candidate with one committed change, `fixed-fallback.patch`. In the generic fold step, the per-purpose declaration the runner assembles, checks and submits becomes the fold's default units, which the regression fixture sets to its fixed fallback, instead of the evaluated allocation. Probing and evaluation still run, and the runner's own check that the assembled transaction carries its declaration still passes. The command exits nonzero. Its log shows the fixture's one-below-measured submission refused, then the runner's own submission of the same fold refused by the node and attributed to execution budget with the over-declared purposes named, then the regression reporting failure. The product book is not reached.
- **Restored.** The candidate itself, with the evaluated declaration in place. The command exits 0. Its log shows the same fixture refusal, the regression's success line and the book completing.

`mutant.json` and `restored.json` record each run. Every field is read by the recorder from git, the filesystem, nix or the captured output. Each retained log, `mutant.log` and `restored.log`, is the complete stdout and stderr of its run, and the record's log digest is the SHA-256 of that file.

## Reproduce

From a clean checkout of the candidate:

```sh
conformance/review/fold-budget-control/record.sh --candidate "$(git rev-parse HEAD)" --out "$(mktemp -d)"
```

The recorder needs `git`, `nix` and `jq`, builds the blueprint once from the candidate, and creates its mutant as a local commit on a detached worktree that it removes at exit. It exits 0 only when the pair is admissible: both runs behave as required, and the records agree on the Lean model tree and driver corpus, the blueprint, the genesis directory content, the node version, the command and the environment. Its witness patterns are fixed in the recorder itself, so a run cannot pass by matching something looser than what a failing run must show.

The retained records name the candidate they were recorded against. To check them, compare each log's SHA-256 with the record's `log` field.

## Limits

- One candidate's command failing on one fixed-fallback mutant, and passing when restored. A later change to the regression target or the runner is not controlled until the recorder is run again.
- The run is local. It is not evidence from CI on a published head.
- Execution units are not observable in the Lean model, so this is ledger and harness evidence. It establishes no Lean statement.
- The mutant is one way to stop declaring evaluated budgets. It does not show that every other way fails the command.
- The recorder journals the git and nix commands it runs itself. Builds that `nix run` performs inside are not journalled beyond the store paths the record names.

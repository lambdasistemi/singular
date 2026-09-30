# Reproduce the fold budget control

As a reviewer with this repository and Nix, I want one command that repeats the control pair on a candidate I choose.

## Run the pair

From a clean checkout of the candidate:

```sh
conformance/review/fold-budget-control/record.sh --candidate "$(git rev-parse HEAD)" --out "$(mktemp -d)/pair"
```

The recorder builds the validator blueprint once. It commits the fixed-fallback patch on a detached worktree and runs `nix run --quiet .#conformance-tests` in its `conformance/` directory, which should fail. It then runs the same command in the candidate's own tree, which should pass. It exits 0 only when both runs behave as required and share their blueprint, genesis, node and command.

## Read the result

`mutant.json` should show a nonzero exit. Its witnesses show the appendix suite passing, the fixture's one-below submission refused, the runner's own submission refused for exceeding its declared units, and the regression failing. `restored.json` should show exit 0 with the regression's success line and the book completing. Each log's digest should match its record.

## Check the retained pair

The committed records and raw logs in `conformance/review/fold-budget-control/` come from one such run against the candidate named in the records. Compare each log's SHA-256 with the record's `log` field.

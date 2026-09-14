# Run naming lifecycles on an existing deployment

As a joiner, I can claim, recover and retire names using my existing registry
without first funding the large devnet refusal fixtures. This implements the
operator's 2026-09-14 A-004 ruling; Lean revision
`bbd81f2f86c07a9963e9a6aa35c1a8457d7ba38e` and validators are unchanged.

The three naming runners select the positive lifecycle automatically on an
external public test network. They require `--deployment`; register claims
`--spelling` (default `alice`), recovery claims `rc-main` and maintains its
recovered controller, and retirement claims `rt-over`, recovers, retires and
completes it into Over. An already claimed spelling stops before funding.
Default devnet runs, including attached runs with magic 42, retain all rows.

From `offchain/`, supply the blueprints and external-node settings as usual:

```sh
nix run .#register-rows -- --node-socket /run/node.socket --network-magic 1 \
  --wallet-skey ./joiner.skey --deployment ./preprod.json --funding-only
```

Run that preflight for `recovery-rows` and `retirement-rows` too. Add their
reported requirements and compare with the wallet's spendable balance before
removing `--funding-only`. The allowance includes actual claim/request deposits,
minimum change, collateral, and fees bounded by live protocol parameters and
reference-script sizes. Reserved outputs are not a claim of fees spent.
Reference-script publications are excluded from funding selection.

Each manual transaction is evaluated by the node and rebalanced before signing;
connected folds already use node evaluation. Aggregate memory and steps must fit
the live per-transaction limit. An overflow prints both the measured requirement
and the limit and stops; extra funds cannot repair it. No refusal transactions
are submitted by the public lifecycle. Mirrors are saved after connected folds,
so a later failure preserves the completed registry transition.

For local verification, `bash deployment-attach-check.sh --lifecycle` exercises
this path on a devnet, checks duplicate preflight and unchanged deployment
counts, and retains the fresh-bootstrap counter control. Without the flag it
runs the existing full suites. `cabal test cage-tests` includes aggregate memory
and steps overflow controls with an accepted exact-boundary case.

Release 0.6.0 predates this runner repair. Its deployment verifier remains
usable; public lifecycle runs require the repaired source until the next release.

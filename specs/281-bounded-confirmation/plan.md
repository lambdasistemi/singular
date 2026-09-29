# Bound every wait on a submitted transaction

As the ticket owner, I want one mechanism for bounding a wait, applied to submission, indexed confirmation and session confirmation. I want the existing ad hoc window message replaced by that mechanism rather than kept beside it, and every negative case seen to fail before the fix.

## Delivery

1. Intake is done: the source map, the historical evidence, the frozen base and draft PR #314. One approved coder owns all production code, tests and local commits: first GLM 5.3, then Claude Sonnet 5.5 on the operator's instruction. The ticket owner is the final auditor and commissions no other seat.
2. RED commit: the new specs and any behavior-neutral seams they need to compile. Each negative spec executes its subject under its own time guard and fails because the wait does not end. Pre-existing specs pass. A compile or setup failure is not a RED.
3. Fix commit: the shared wait bound, the bounded submitter at every construction site, indexed and session confirmation under the bound, the wait-aware catch at every classifier that reaches a submission or confirmation, and the old window failure path deleted.
4. The ticket owner audits the exact candidate with the coder parked. The audit covers semantics, negative-control adequacy, cancellation and cleanup, whole-wait coverage and unchanged success.
5. Push the audited candidate to the draft PR. Format, lint, component compile, end-to-end and devnet compatibility are bound to the exact head's CI jobs. The PR stays draft until those are green; no merge is authorized.

## Execution budget

Eight local invocations were granted in three steps, 15 minutes each and 90 minutes in total. Every Nix, build, test, format and lint command counts; reading an existing build log is not an invocation. All eight are spent. The audit reads source and receipts, and CI on the exact head carries format, lint, every component compile, the end-to-end runs and the devnet runs.

| Slot | Owner | Command | Expected |
| --- | --- | --- | --- |
| First | first coder | `nix run --quiet .#cage-tests` in `offchain`, as `.github/workflows/registry.yml` runs it | spent: the library did not compile, so no RED |
| Second | second coder | the same command at the first RED commit | spent: the new specs did not compile, so no RED |
| RED | second coder | the same command at the RED commit | nonzero exit; only the new negative specs fail, each on its own guard |
| GREEN | second coder | the same command at the candidate | exit 0 |
| Audit RED | second coder | the same command at the checks for the first audit's findings | nonzero exit; only the closed-window and window-read checks fail |
| Audit GREEN | second coder | the same command at their repair | exit 0 |
| Elapsed RED | second coder | the same command at the whole-call elapsed checks | nonzero exit; only those checks fail, on the elapsed they report |
| Elapsed GREEN | second coder | the same command at the one-clock repair | exit 0 |

## Evidence limits

The unit specs establish the bound and the failure shape over stub submitters, a real in-memory indexer and stub sessions. They do not reproduce a real node withholding a verdict. Devnet success compatibility is established by the exact head's CI, not locally. Node reads outside these waits keep their current behavior: address, parameter and evaluation queries, and the `awaitChain` observation. The bound stays in this repository; `cardano-node-clients` is not changed.

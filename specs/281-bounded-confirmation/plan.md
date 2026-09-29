# Bound every wait on a submitted transaction

As the ticket owner, I want one mechanism for bounding a wait, applied to submission, indexed confirmation and session confirmation. I want the existing ad hoc window message replaced by that mechanism rather than kept beside it, and every negative case seen to fail before the fix.

## Delivery

1. Intake is done: the source map, the historical evidence, the frozen base and draft PR #314. One approved coder owns all production code, tests and local commits: first GLM 5.3, then Claude Sonnet 5.5 on the operator's instruction. The ticket owner is the final auditor and commissions no other seat.
2. RED commit: the new specs and any behavior-neutral seams they need to compile. Each negative spec executes its subject under its own time guard and fails because the wait does not end. Pre-existing specs pass. A compile or setup failure is not a RED.
3. Fix commit: the shared wait bound, the bounded submitter at every construction site, indexed and session confirmation under the bound, the wait-aware catch at every classifier that reaches a submission or confirmation, and the old window failure path deleted.
4. The ticket owner audits the exact candidate with the coder parked. The audit covers semantics, negative-control adequacy, cancellation and cleanup, whole-wait coverage and unchanged success.
5. Push the audited candidate to the draft PR. Format, lint, component compile, end-to-end and devnet compatibility are bound to the exact head's CI jobs. The PR stays draft until those are green; no merge is authorized.

## Execution budget

There were four local invocations, 15 minutes each and 30 minutes in total. Every Nix, build, test, format and lint command counts; reading an existing build log is not an invocation. All four are spent. The audit reads source and receipts, and the repair from the first audit is verified as the parent rules. CI on the exact head carries every further compile.

| Slot | Owner | Command | Expected |
| --- | --- | --- | --- |
| First | first coder | `nix run --quiet .#cage-tests` in `offchain`, as `.github/workflows/registry.yml` runs it | spent: the library did not compile, so no RED |
| Second | second coder | the same command at the first RED commit | spent: the new specs did not compile, so no RED |
| RED | second coder | the same command at the RED commit | nonzero exit; only the new negative specs fail, each on its own guard |
| GREEN | second coder | the same command at the candidate | exit 0 |

## Evidence limits

The unit specs establish the bound and the failure shape over stub submitters, a real in-memory indexer and stub sessions. They do not reproduce a real node withholding a verdict. Devnet success compatibility is established by the exact head's CI, not locally. Node reads outside these waits keep their current behavior: address, parameter and evaluation queries, and the `awaitChain` observation. The bound stays in this repository; `cardano-node-clients` is not changed.

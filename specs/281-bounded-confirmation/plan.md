# Bound every wait on a submitted transaction

As the ticket owner, I want one mechanism for bounding a wait, applied to submission, indexed confirmation and session confirmation. I want the existing ad hoc window message replaced by that mechanism rather than kept beside it, and every negative case seen to fail before the fix.

## Delivery

1. Intake is done: the source map, the historical evidence, the frozen base and draft PR #314. The approved GLM coder owns all production code, tests and local commits. The ticket owner is the final auditor and commissions no other seat.
2. RED commit: the new specs and any behavior-neutral seams they need to compile. Each negative spec executes its subject under its own time guard and fails because the wait does not end. Pre-existing specs pass. A compile or setup failure is not a RED.
3. Fix commit: the shared wait bound, the bounded submitter at every construction site, indexed and session confirmation under the bound, and the old window failure path deleted.
4. The ticket owner audits the exact candidate with the coder parked. The audit covers semantics, negative-control adequacy, cancellation and cleanup, whole-wait coverage and unchanged success.
5. Push the audited candidate to the draft PR. Format, lint, component compile, end-to-end and devnet compatibility are bound to the exact head's CI jobs. The PR stays draft until those are green; no merge is authorized.

## Execution budget

There are four local invocations, 15 minutes each and 30 minutes in total. Every Nix, build, test, format and lint command counts.

| Slot | Owner | Command | Expected |
| --- | --- | --- | --- |
| RED | coder | `nix run --quiet .#cage-tests` in `offchain`, as `.github/workflows/registry.yml` runs it | nonzero exit; only the new specs fail, each on its own guard |
| GREEN | coder | the same command at the candidate | exit 0 |
| Repair | coder | one repair, released by the ticket owner | stated when released |
| Audit | ticket owner | one targeted run, if the audit needs it | stated before use |

## Evidence limits

The unit specs establish the bound and the failure shape over stub submitters, a real in-memory indexer and stub sessions. They do not reproduce a real node withholding a verdict. Devnet success compatibility is established by the exact head's CI, not locally. Node reads outside these waits keep their current behavior: address, parameter and evaluation queries, and the `awaitChain` observation. The bound stays in this repository; `cardano-node-clients` is not changed.

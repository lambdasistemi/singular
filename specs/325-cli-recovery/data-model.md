# #325 data model

> **Replay supersedes the former local proof state.** This record preserves the
> #325 recovery design and its original requirement names. Under #381, ordinary
> commands reconstruct proof state from public state-token history. They neither
> read nor write a proof mirror or `state.json`, and the journal supplies no replay
> edge or root. Recovery still appends submission phases and observations; public
> history selects the trie, including after a rollback. References below to the
> former local mirror commit are historical and are superseded by this rule.

- journal-events-existing-prepared-submitted-acknowledged-rejected Journal events. Existing: `prepared`, `submitted` (acknowledged), `rejected`, `submit-unknown` (unknown outcome), `confirmed` (included), `unconfirmed` (timeout, or the wait failed), `observed`. Added: `rolled-back` (a line after `confirmed` or `observed` for the same transaction whose effect is no longer on chain) and `excluded` written by recovery when chain evidence shows the transaction can never land. Settled: `observed`, `rejected`, `excluded`. Every other last event is unresolved, `rolled-back` included.
- recovery-line-names-its-evidence-chain-point A recovery line names its evidence (the chain point it was read at and the fact read). A `rolled-back` line names the root the mirror returned to.
- local-commit-state-mirror-root-state-json Local commit state: mirror root, `state.json` root and the journal's last settled fold must agree after reconciliation; between a `confirmed` fold and its `observed` line the mirror is at the journalled root before or root after, never anything else.
- invariant-for-journalled-fold-edge-number-applications Invariant: for each journalled fold edge, the number of applications to the mirror equals the number of `observed` lines for it minus the number of `rolled-back` lines after them, and is 0 or 1.

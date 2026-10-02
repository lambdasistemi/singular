# #325 data model

- D1 Journal events. Existing: `prepared`, `submitted` (acknowledged), `rejected`, `submit-unknown` (unknown outcome), `confirmed` (included), `unconfirmed` (timeout, or the wait failed), `observed`. Added: `rolled-back` (a line after `confirmed` or `observed` for the same transaction whose effect is no longer on chain) and `excluded` written by recovery when chain evidence shows the transaction can never land. Settled: `observed`, `rejected`, `excluded`. Every other last event is unresolved, `rolled-back` included.
- D2 A recovery line names its evidence (the chain point it was read at and the fact read). A `rolled-back` line names the root the mirror returned to.
- D3 Local commit state: mirror root, `state.json` root and the journal's last settled fold must agree after reconciliation; between a `confirmed` fold and its `observed` line the mirror is at the journalled root before or root after, never anything else.
- D4 Invariant: for each journalled fold edge, the number of applications to the mirror equals the number of `observed` lines for it minus the number of `rolled-back` lines after them, and is 0 or 1.

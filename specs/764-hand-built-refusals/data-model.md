# Data for hand-built transactions refused by the deployed validators

Issue 764, first slice. The records the check produces and the invariants over them. Modules are in
[the modules model](modules-model.md).

## Verdict row

| Field | Meaning |
| --- | --- |
| case | one of `taken-key`, `update-without-controller`, `token-leaving-holding` |
| role | `refusal` (one fact wrong) or `control` (that fact restored) |
| altered fact | the one fact the refusal changes, in words; `none` for a control |
| transaction | the identifier of the transaction the harness built |
| node outcome | `refused` or `accepted`, from the node's answer |
| blamed script | the validator the node's failure names, for a refusal |
| on the chain | whether the chain's own record holds the transaction |
| verdict | `pass` or `fail`, computed from the fields above |

## Invariants

- six-rows: the table has exactly one refusal row and one control row per case.
- refusal-means-script-failure: a refusal row passes only when the node outcome is `refused`, the failure is an explicit
  failure of the code of the named validator and not an exhausted budget, the blamed script is the one the case names, and
  the chain's own record does not hold the transaction.
- control-means-accepted-and-recorded: a control row passes only when the node outcome is `accepted` and the chain's own
  record holds the transaction.
- one-fact: a refusal and its control differ in exactly the altered fact; the table names it.
- assertions-can-fail: each of the two judging assertions is run on the other role's receipt and must fail there.
- no-verdict-without-receipt: a missing or unreadable receipt makes its row `fail`, never an absent row.

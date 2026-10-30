# Data: a window on each transaction body

Issue 334. Follows [the modules model](modules-model.md).

| Field | Meaning | Validation |
| --- | --- | --- |
| validity upper bound | the slot from which the transaction can no longer land | present on every transaction the commands build; inside the ledger's time horizon; derived from the acquired view, never from the wall clock alone |
| validity lower bound | the slot from which it can land | set where the validator's window rules need one; unchanged elsewhere |

## Invariants

- a body the commands build with no upper bound is a defect the census must name.
- the signing command's rule that a recorded deadline equals the body's upper bound keeps holding with a bound on every body.
- the journal format records the deadline it already records.

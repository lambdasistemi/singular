# Wait bound data

As an operator reading a failed run, I need the failure to say which wait gave up, on which transaction, after how long and against which bound.

## Boundaries

| ID | Data | Invariant |
| --- | --- | --- |
| D281-S | Wait stage: submission, indexed confirmation, session confirmation | Exactly one stage per failure; the stage names the wait that gave up, not its caller. |
| D281-F | Named wait failure: stage, ledger transaction id, measured elapsed seconds, bound seconds | An exception, never a submit result. Its rendering contains the stage, the transaction id in hex, the elapsed time and the bound. Elapsed is measured on the monotonic clock from the start of the whole wait. |
| D281-B | Submission bound | A named, documented finite constant, greater than zero and at most the 300 second confirmation window. It is the production value at every construction site. |
| D281-X | Indexed window | The existing 300 seconds (150 polls of 2 seconds) in production. Tests inject a shorter one. |
| D281-L | Session confirmation wall-clock limit | Finite. It is derived when the wait begins from the same window the tip deadline expresses (the validity upper bound plus two minutes, or the fixed 300 seconds), so a healthy transaction keeps its full window. Tests inject a shorter one. |

No serialized, ledger-facing or conformance-receipt representation changes. The wait failure is never written to a receipt.

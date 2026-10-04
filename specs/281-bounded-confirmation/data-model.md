# Wait bound data

As an operator reading a failed run, I need the failure to say which wait gave up, on which transaction, after how long and against which bound.

## Boundaries

| ID | Data | Invariant |
| --- | --- | --- |
| wait-stage-submission-indexed-confirmation-session-confirmation | Wait stage: submission, indexed confirmation, session confirmation | Exactly one stage per failure; the stage names the wait that gave up, not its caller. |
| named-wait-failure-stage-ledger-transaction-id | Named wait failure: stage, ledger transaction id, measured elapsed seconds, bound seconds | The one way a wait on a submitted transaction gives up. That is when its wall-clock bound fires, and, for session confirmation, also when the chain tip passes the confirmation deadline first. It is an exception, never a submit result and never an error call a classifier could read as a refusal. Its rendering contains the stage, the transaction id in hex, the elapsed time and the bound, and for a closed window also the deadline slot. Elapsed is measured on the monotonic clock from the start of the whole wait. |
| named-documented-finite-constant-greater-than-zero | Submission bound | A named, documented finite constant, greater than zero and at most the 300 second confirmation window. It is the production value at every construction site. |
| existing-seconds-polls-seconds-in-production-tests | Indexed window | The existing 300 seconds (150 polls of 2 seconds) in production. Tests inject a shorter one. |
| session-confirmation-wall-clock-limit | Session confirmation wall-clock limit | Finite. It is derived when the wait begins from the same window the tip deadline expresses (the validity upper bound plus two minutes, or the fixed 300 seconds), so a healthy transaction keeps its full window. Tests inject a shorter one. |

No serialized, ledger-facing or conformance-receipt representation changes. The wait failure is never written to a receipt.

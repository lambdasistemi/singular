# #184 — modules model

## Changed responsibilities

| module | responsibility in this ticket |
|---|---|
| conformance runner | Execute register-active-key against the registry already booted with the open application and produce its observed receipt. |
| receipt library | Represent and fail-closed validate the complete register-active-key edge observation while retaining backward compatibility for other rows. |
| conformance workflow | Invoke register-active-key, account for its receipt and assert the accepted/refused/control evidence at the CI boundary. |
| consumer conformance page | State only what the candidate-bound workflow actually executes and its known trace limitation. |

## Dependency direction

The accepted Lean statements govern register-active-key. The runner observes the chain and
constructs receipt evidence; the receipt library validates that evidence; the
workflow consumes it; documentation describes the workflow result. No
downstream copy defines behavior for an upstream layer.

## Promotion

register-active-key-specific execution remains in the existing runner. Shared receipt
structures remain in the receipt library because the workflow and loader both
consume them. No new abstraction or cross-edge framework is introduced.

## Outside this ticket

Lean, validator behavior, request encoding, simulator behavior and other edge
rows retain their existing owners. A need to change one is a ticket-owner
question, not an implicit dependency.

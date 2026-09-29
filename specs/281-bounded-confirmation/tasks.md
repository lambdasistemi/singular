# Delivery ledger for bounded waits

As an integrator, I need each task stamp to name its commit and receipt rather than treat a build as behavior proof.

## Work items

| Task | Completion evidence | Status |
| --- | --- | --- |
| T281-01 | Intake: source map of every wait, historical evidence, frozen base, mandate and draft PR #314. | Complete at this mandate commit. |
| T281-02 | RED commit: new specs for the three waits and the unchanged-success cases; the RED invocation fails only on the new negative specs, each on its own time guard. | Complete: 747bae7, and d0a3182 for the audit repair. The red runs failed only on the new negatives (272 with 8 failing at the pre-rebase c3276d0, then 283 with 7 failing at d0a3182). |
| T281-03 | Fix commit: the wait module, bounded submitter at every construction site, both confirmations under the bound, the wait-aware catch at every classifier with its inventory, old window path deleted; the GREEN invocation exits 0. | Complete: e6a6f80 and the repair c58dd00. The green run at c58dd00 passed all 283 examples. |
| T281-04 | Ticket-owner final audit of the exact candidate with the coder parked, recorded against its commit. | Complete: the first audit found two blocking defects at the pre-rebase 9327667, and the repair passed its audit at c58dd00. |
| T281-05 | Audited candidate pushed; format, lint, component compile, end-to-end and devnet jobs green on the exact head; PR body maps requirements to specs and states the limits. | Open. |

Task stamps do not substitute for the invocation receipts, the audit record or remote CI evidence. No merge is authorized by this ticket's current grant.

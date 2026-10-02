# Delivery ledger for bounded waits

As an integrator, I need each task stamp to name its commit and receipt rather than treat a build as behavior proof.

## Work items

| Task | Completion evidence | Status |
| --- | --- | --- |
| intake-source-map-wait-historical-evidence-frozen | Intake: source map of every wait, historical evidence, frozen base, mandate and draft PR #314. | Complete at this mandate commit. |
| red-commit-new-specs-for-three-waits | RED commit: new specs for the three waits and the unchanged-success cases; the RED invocation fails only on the new negative specs, each on its own time guard. | Complete: 747bae7, d0a3182 and 92f469c. Each red run failed only on its new checks: 8 at the pre-rebase c3276d0, 7 at d0a3182, 2 at 92f469c. |
| commit-wait-module-bounded-submitter-at-construction | Fix commit: the wait module, bounded submitter at every construction site, both confirmations under the bound, the wait-aware catch at every classifier with its inventory, old window path deleted; the GREEN invocation exits 0. | Complete: e6a6f80, c58dd00, f059821, 9ba85a7 and 8d31827. The green run at 8d31827 passed all 285 examples. |
| ticket-owner-final-audit-exact-candidate-coder | Ticket-owner final audit of the exact candidate with the coder parked, recorded against its commit. | Complete at 8d31827. Earlier audits found the unbounded window reads and the closed window read as a refusal (at 9327667), a stale facade sentence (at 4f1b4e6) and elapsed time that did not cover the whole call (raised by the parent at c58dd00), and each was repaired. |
| audited-candidate-pushed-format-lint-component-compile | Audited candidate pushed; format, lint, component compile, end-to-end and devnet jobs green on the exact head; PR body maps requirements to specs and states the limits. | Open. |

Task stamps do not substitute for the invocation receipts, the audit record or remote CI evidence. No merge is authorized by this ticket's current grant.

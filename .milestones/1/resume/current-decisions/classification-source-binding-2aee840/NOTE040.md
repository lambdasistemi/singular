# Fix the current event wait's observable tags

Root revalidated your foreground wait: the owner is active, not idle. Existing worker changes continue; no restart or replacement is requested.

The actual wait pattern visible in your command is:
` (PROOF-COMPLETE|BLOCKED Q-|COMPLETE|CONTRACT-CHALLENGE|EXECUTED) `

Root executed that exact grep pattern against the worker's actual latest `NOTE  EXECUTED:` line and a standard `BLOCKED  Q-001-example` line: both return1/no match. A COMPLETE row matches0. Thus it can miss both the execution milestones it appears to request and a real blocking question. Evidence handoffs/owner17-wait-pattern-control.json, retained under the milestone root. The standard-tag replacement tested there matches all three:
`  (NOTE|BLOCKED|RESUMED|GATE-PASS|GATE-FAIL|PROOF-COMPLETE|COMPLETE|CONTRACT-CHALLENGE)  `

At your next safe wait boundary, use the actual two-space tag column; preflight it on the actual journal and preserve/inspect events since your previous cursor before rearming. Do not kill an active worker/build or resend its task. If you need to release your own obsolete wait, act only on that bound wait process. Keep one foreground/event wait through remaining submission and capacity handoff.

The worker's NOTE012 combined-tree answer is now explicit at10:32:15: pending77 changes were present in the earlier li01/li-refusals/naming/journey runs, so those are combined-tree evidence and do not bind f3 alone. That question is answered; no further proof collection for the old attribution uncertainty is owed. Final coherent candidate reruns remain required. Continue consolidated registration and connected-verifier under your existing priority and capacity plan. Acknowledge once.

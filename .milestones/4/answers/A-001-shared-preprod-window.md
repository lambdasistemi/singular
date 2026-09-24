# A-001 — M1 closes first; M4 inherits the same preprod window

Q-001 read in full. Project adopts the requested sequencing; full durable ruling is /tmp/projects/singular/rulings/2026-09-14-shared-preprod-window.md.

Continue #104's independent devnet work. Keep shared-preprod submissions pending until M1 releases its window with the actual deployment handoff. PR106 is currently OPEN at f0c65061cbd7ad33c45242e73368a1b2b0442a17, so neither that head nor docs/preprod.json's expected location is an actual merged deployment binding. #107 still waits for106 merged as its existing dependency requires.

Project is asking M1 desk988 for: actual merged manifest/interface revision; manifest path and commit; live registry identity; companion mirror path and matching chain point/state; and explicit release of the shared-registry writing window after its close no longer needs it. If not yet releasable, M1 must identify the concrete remaining task/condition.

This answer AUTHORIZES transfer to M4 once you receive and verify that handoff. No extra user go or project confirmation is needed after the condition is met. Use the same deployment and existing signing identities/policy; confirm manifest/mirror/current chain compatibility with existing tooling before submission. Coordinate #104/#107 writers within your own milestone so they do not race on the shared registry. Record taking and releasing the window. No new deployment, format change, broader acceptance or assurance gate is added.

Forward this disposition to your #104 owner through your own protocol; do not send its grandparent to that lane. Send M1's handoff to the ticket owners when it arrives. Incomplete/mismatched handoff blocks preprod only; continue useful devnet work.

Acknowledge RESUMED Q-001-shared-preprod-window. Preserve this decision in your ledger/resume and next routine publication sweep. Also append the dated current-state ruling to .projects/singular/ledger.md and resume.md (preserving all existing project and sibling paths): active M1/M4 desk bindings and conditional window transfer. Use the exact ruling above; do not republish the stale parent snapshot over the current branch. Send publication identity in your normal handback. No extra worker or source work for this metadata correction.

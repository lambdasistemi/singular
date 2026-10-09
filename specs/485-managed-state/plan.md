# Plan

Base: PR #524 `cd51926e3ea09a86ed0b1ac68718b0d8eb619df2`, already contains
current main `33ed4c2202f1abff53a5f19665f92ac098381176`. Continuation branch
`feat/485-managed-state`, worktree `/code/singular-issue-485`. Do not edit
the separate E301-owned rename worktree or force its branch. Integrate new
main at a stopped writer boundary before final verification.

1. Establish baseline and inventory parser, session, creation, attachment,
   inspection and recovery path consumers. Reproduce missing directory refusal
   with an otherwise valid invocation and inspect the real call path.
2. Introduce one identity-based managed-state resolver shared by all commands.
   Parsing remains pure; environment and wallet identity resolution occur in
   IO before locking. Reuse existing wallet/address/token encoders. Never
   derive identity from secret bytes or a key path. Add no competing registry
   metadata or domain interpreter.
3. Make directory selection optional, resolve command paths centrally where
   possible, and adapt creation after seed selection before submission.
   Preserve lock ordering, durable journal phases and reconciliation.
4. Update ordinary consumers and connected proof to run through the default
   resolver with isolated HOME/XDG locations. Reuse #501 journey/isolation and
   existing recovery controls; avoid another duplicated devnet harness.
5. Run focused controls, connected proof and required gates. Freeze candidate,
   commission GLM review, repair supported findings, publish and merge after
   exact-head hosted checks. Close #485 only on full acceptance.

Sol owns mandate, coordination and acceptance; Muse owns implementation and
local source commits; GLM independently reviews the frozen candidate. One
source writer. No extra seat, no overlapping #381 implementation producer.

Shared CLI interface consumers include sibling #437/#471 and E301 rehearsal.
Publish the optional managed-root semantics before integration. Historical
explicit directories are not silently migrated or treated as chain authority.

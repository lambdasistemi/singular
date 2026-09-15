# Repair tasks

The controller story in [the specification](spec.md) is delivered in one slice.
Execute sequentially with one worker; external audit follows submission.

## Prevent new pollution and diagnose old pollution

- [x] T001 Read the constitution and bind the frozen behavior in `spec.md` and `plan.md`.
- [x] T002 Add the three reproduction tests and discriminating value controls in `naming-onchain/validators/application.tests.ak`; record behavioral RED.
- [x] T003 Repair value equality, named shape refusal and insert-fold shape in `naming-onchain/validators/application.ak`; record GREEN.
- [x] T004 Add a named extra-token maintenance check in `offchain/` and update affected Haskell mirrors or verifiers; run its positive control and refusal.
- [x] T005 Regenerate `naming-onchain/script-identity.json` and verify the Aiken suite and identity gate.
- [x] T006 Add the implementation invariant to `offchain/naming-correspondence.md`, document compatibility in `docs/`, and curate speech companions.
- [x] T007 Run root `just ci` and relevant presentation checks; submit a draft PR and journal `READY-FOR-AUDIT`.
- [ ] T008 After external audit PASS and green remote checks, merge with a merge commit and journal the merge SHA and completion.

## Dependency order

Specification precedes tests; tests precede code; code precedes regenerated
identity and verification; the frozen candidate precedes independent audit;
audit PASS and completed remote checks precede merge. No parallel agents.

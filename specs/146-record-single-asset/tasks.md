# Repair tasks

The controller story in [the specification](spec.md) is delivered in one slice.
Execute sequentially with one worker; external audit follows submission.

## Prevent new pollution and diagnose old pollution

- [x] read-constitution-bind-frozen-behavior-in-spec Read the constitution and bind the frozen behavior in `spec.md` and `plan.md`.
- [x] add-three-reproduction-tests-discriminating-value-controls Add the three reproduction tests and discriminating value controls in `naming-onchain/validators/application.tests.ak`; record behavioral RED.
- [x] repair-value-equality-named-shape-refusal-insert Repair value equality, named shape refusal and insert-fold shape in `naming-onchain/validators/application.ak`; record GREEN.
- [x] add-named-extra-token-maintenance-check-in Add a named extra-token maintenance check in `offchain/` and update affected Haskell mirrors or verifiers; run its positive control and refusal.
- [x] regenerate-naming-onchain-script-identity-json-verify Regenerate `naming-onchain/script-identity.json` and verify the Aiken suite and identity gate.
- [x] add-implementation-invariant-offchain-naming-correspondence-md Add the implementation invariant to `offchain/naming-correspondence.md`, document compatibility in `docs/`, and curate speech companions.
- [x] run-root-just-ci-relevant-presentation-checks Run root `just ci` and relevant presentation checks; submit a draft PR and journal `READY-FOR-AUDIT`.
- [ ] after-external-audit-pass-green-remote-checks After external audit PASS and green remote checks, merge with a merge commit and journal the merge SHA and completion.

## Dependency order

Specification precedes tests; tests precede code; code precedes regenerated
identity and verification; the frozen candidate precedes independent audit;
audit PASS and completed remote checks precede merge. No parallel agents.

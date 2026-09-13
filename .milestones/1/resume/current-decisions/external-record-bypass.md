# Proven release-record substitution bypass at 26495f8

Root ran one bounded gate probe from a frozen `git archive` of 26495f810c2d67b75ff71f2ea524bbd9903dce5b, using the pinned project's Python3.13.12 and the gate's own sufficient synthetic fixture. No product worktree was mutated. Evidence is retained in /tmp/singular-release-record-QuFJrn: candidate.tar, frozen source, real temporary Git fixture, external-record.json, result.json and complete stdout/stderr for both commands. Root's pointer file is handoffs/release-record-probe-path.txt.

Fixture HEAD af0cc69f2c31dc1b0126347967691dcefed599c6 is CLEAN and commits an incomplete record. Both invocations use this exact root and --candidate:

1. `release --record <fixture>/record.json` -> exit1, COMPLETION: INCOMPLETE.
2. `release --record <outside>/external-record.json` -> exit0, COMPLETION: COMPLETE.

The external file is the sufficient fixture record saved before committing the incomplete one. This is explicitly a synthetic checker-path counterexample, not project conformance evidence. The defect is actual and isolated: only the record argument changes; HEAD, root and tracked state remain identical and clean.

The code explains it: check_candidate_binding validates root, then cmd_release loads arbitrary record_path supplied by _defaults. Its claim that record/inventory/implementation are therefore the candidate's own is false for that path. Default GATE_DIR resolution also needs care in the packaged program: a record in an installed tool closure is not automatically the requested repository candidate's record.

Complete NOTE029's existing input-binding requirement now. For `release`, resolve the authoritative/default record from the declared candidate root. Any supported override must be demonstrably an approved tracked input of that same candidate, with bytes equal to its committed blob and no symlink/ignored/external-input escape; alternatively reserve arbitrary overrides for non-release analysis commands. The publication wrapper must select the intended record explicitly. Do not fix the control by merely setting a fake dirty flag or deleting --record from the probe while leaving the release path exposed.

Add this real-Git control to the permanent suite: committed incomplete record still returns debt, but external COMPLETE substitution must fail closed specifically as an unbound release input. Keep a clean sufficient committed-record success control. Existing dirty/nested/nonrepo controls remain. Bind the packaged Git/runtime dependencies with the publication wiring as already assigned; do not rerun or reopen PR84.

This is the already stated same-candidate input contract, with an executable RED witness. No new auditor, scope or semantic ruling. Finish the bounded repair through the existing worker, then the strict publication boundary.

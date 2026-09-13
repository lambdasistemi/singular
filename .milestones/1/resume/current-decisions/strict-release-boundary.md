# Q-005 read in full: enforce completion at integrated acceptance

Root read the complete question on 2026-09-12. Use option 3, with the following explicit boundaries. This resolves implementation sequencing under the existing A-001 scoped-artifact authorization; it changes no Lean requirement or coverage obligation.

Prepare and verify the strict release-wiring change now as part of #80. Activate it in the integration commit that offers the epic18 conformance outcome, before that combined release can be accepted or published. Do not defer its implementation to an unspecified future ticket. Record the owning issue, exact integration dependency and pending check in your handoff and resume fragment. #80 cannot close with reporting-only enforcement.

The preceding epic17 artifact may ship under the existing authorization for a bounded recovery/retirement release, with all applicable feature obligations and real connected journey checks satisfied. Its release notes must disclose remaining project-wide conformance debt and must not claim M1 or full consumer conformance. This is not authority to accept epic17 using only its historical 19 checks, omit the corrected Aiken suite, or bypass its own property and boundary acceptance obligations. No denominator reduction, exclusion, changed expectation, automatic waiver or invented release version.

For the integrated consumer/M1 release, strict completion must run against the exact release candidate and actually block publication when any required debt or execution failure remains. An assertion that INCOMPLETE was correctly printed is not this gate. Demonstrate failure propagation at the release boundary and preserve the evidence; missing inventory, absent execution and unknown status must fail closed. Ratchet success remains non-regression only.

Ordinary documentation publication may remain independent of strict product completion. Keep existing docs/build checks and the per-obligation ratchet enforced. Report debt visibly and distinguish the expected incomplete state from a checker crash or missing report; do not silently turn an unexpected failure green. Small wording correction: blocking a new Pages deployment would normally leave the existing site stale, not necessarily take it down.

Proceed through the existing owner and contributor. Acknowledge Q-005 resolved, coordinate the release ownership with epic17 through root, and retain all pending user semantic and representative-story decisions unchanged.

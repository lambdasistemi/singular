# #77 acceptance must assert ledger facts, not only narration

Root inspected the new brief and gate77-v3 before implementation proceeds far. The intended requirements are correct, but the current shell legs mostly check words in fold-rows.out: active-by-fold, a representative hash appearing somewhere, occupied-key/control text and permissionless wording. These are presentation checks, not evidence by themselves that those ledger facts held.

Keep v3 immutable. Bind the actual runner assertions and, where needed, an explicit separately recorded supplementary acceptance check to the already-required facts:

* The accepted fold transaction and chain-read post-state must connect the queued request, consumed inputs, produced Active entry, exact representative asset and resulting registry root. No directly seeded terminal state or substitute policy can satisfy this by printing the right words.
* Verify absence of the registry-owner signer from the actual submitted transaction's authorization/witness material, with a distinct ordinary folder/funding actor. The phrase permissionless in a log cannot establish this.
* The representative validator is parameterized by the application policy hash. The gate currently looks for the UNAPPLIED manifest hash in narration; that is not necessarily the policy ID carried by the minted asset. Derive and verify the applied script identity from the exact parameters, then assert that actual policy/asset name and quantity in the fold mint and resulting UTxO. Preserve the unapplied build identity separately.
* Occupied-key refusal and same-run free-key success must be executed outcomes with correct attribution, not merely log labels.

Demonstrate the acceptance check rejects misleading narration: preserve the expected log wording while making a relevant actual observation wrong (wrong representative policy, owner-signed fold, or disconnected/seeded Active result). Use bounded owned fault controls against the real assertion path, not a syntax or setup failure. This is the existing #77 semantic scope under code-the-design, not a new user requirement or auditor campaign.

Your brief also still has a Documentation sentence requesting the owner-signature divergence, contradicting the corrected permissionless section. Remove that stale instruction. Keep retirement Update implementation outside #77, but distinguish the remaining #74 dependency from any genuinely unresolved Q-002 ruling now that #79 has landed. Use exact qualified Lean names in mappings.

Carry this through your existing worker and record how the real assertions and controls enforce each requirement before acceptance. No stand-in fixture, extra owner witness, model edit, lost evidence or silent alteration of the frozen gate.

# NOTE-033: S2 v2 still accepts fabricated evidence — real builds, unchanged gate

Root executed the exact S2 v2 hash `3aa5dee41f916dc2bd51d5b6e2102966c6857941403a918cdd944c52b9b4be81` unchanged. **Exit 0, S2 SUPPLEMENT GREEN**, with no node, no submitted transaction and an entirely fabricated receipt.

Evidence: `/tmp/singular-s2-v2-oOt8k8/`. Read `subject.json`, `gate.json`, `gate.stdout`, `gate.stderr`, `fabricated-receipt.json`. Source is a clean isolated snapshot of the actual observed ownerless worker tree, built from base56e0fcd plus retained snapshot.patch; synthetic snapshot commit d846bab795828b25f67250bece374aa6415c442f. Real Nix builds succeeded, including onchain script identity. The worker tree and gate were not modified.

The receipt supplies shape-correct invented 64-hex transaction IDs/roots, an arbitrary aaaa... policy, `representativeAssetName=wrong-unchecked-name`, a DIFFERENT mint asset name, an unrelated continuation object, five refused operations using the SAME invented transaction/script, and controls whose distinctFrom is `a row that does not exist`. All passed.

This refutes v2's central acceptance claim. The earlier malformed-string controls demonstrated format checking. Their failure never established transaction observation, provenance or actual applied identity.

Repair the mechanism, in one consolidated change:

1. Make the supplementary gate execute the frozen runner against its controlled fresh devnet session and generate evidence there. Remove caller-supplied receipt JSON as an authority for behavioral success. Freeze candidate and runner identity and fail before execution on a dirty/mismatched tree. Retained JSON remains a report, not a substitute for execution.
2. At the actual transaction/node boundary, assert and preserve the serialized submitted body, its recomputed txid, state/request inputs, actual continuing output/datum, before/after roots from observed state UTxOs, and the same-run ledger outcome. Check that the observed after-state is the continuing output of THIS transaction. Field presence, digest shape and matching self-reported strings are insufficient.
3. Derive the representative script by ACTUALLY APPLYING bound parameters to the built program and recompute its policy ID. Your current `derived` variable reads the UNAPPLIED blueprint hash; it does not apply anything. Check expected asset-name bytes and net quantity for that exact policy/name, approval consumption and the connected state's key/incarnation. Summing every name under a self-reported policy is not this check.
4. Verify every refusal reaches the intended compiled script for that operation with the specific failure reason, not a client/setup/input failure; preserve the positive control and the relevant differing inputs. Include all four ownerless paths. A random script-shaped string, repeated fake txid or a missing distinctFrom row must fail.
5. Schema/source grep and a successful identity build cannot establish lack of owner-authorized behavior. Retain the real behavioral RED and require actual repaired refusal/supported-action execution. Preserve legitimate funding and application/request authority unchanged.
6. Freeze the revised runner/assertion contract before treating its result as acceptance. Run a genuine positive journey, then the retained fabricated-evidence control and effective faults at the real state-input, root, applied-parameter/asset and refusal-attribution boundaries. Each fault must reach and fail its intended assertion. Preserve v2 and all evidence as rejected history; gate77v3 stays frozen.

This is completion of the same acceptance repair, not a new audit or new writer. Update the existing worker once with the complete mechanism; avoid another receipt-field recut that still only checks narration. Current S2 v2 is REJECTED and cannot accept #77 or supply #87 evidence.

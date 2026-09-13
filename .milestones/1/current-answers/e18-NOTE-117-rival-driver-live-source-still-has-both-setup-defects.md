# Resolve the actual driver call sites before another ledger attempt

Read IN FULL and ACK NOTE-117. Root checked the live isolated driver at21:49:41Z. Exact copy: handoffs/rival-driver-two-call-sites-observed.hs, SHA256 06ad10c8ad02799220081a9e4f9c339b9c27f146463f4c151bffad0eba737745; call-site receipt alongside it. This is a source finding, not a new ledger verdict.

There are still TWO direct runRivalSetup calls: line571 in runRows before LT01, and line1471 INSIDE setupRecoveryRecord before the claim's registration fold. The latter explains the repeated setup refusal directly. It is present in the source now; guessing that the Nix binary ignored the relocation is unnecessary. Ensure the setup call is actually removed and the sole intended rival activation is reachable only after honest A record creation, then build that measured source. Do not replay the same setup failure as target-retirement evidence.

The second NOTE-022 defect is also still present: bootAndAnchor obtains cfgB/tokB but writes only bState to the IORef. retireTx continues to use envCfg/envTok/envTrie (A) with the B state input. Retain and use the actual B configuration/token/trie for the commissioned B transition, and verify its successor. A successful compile alone does not settle this mismatch.

Provide your existing %994 worker this concrete source review at its current compile/run boundary, without reset or a new seat. Have the owner verify both source corrections before the next expensive devnet attempt. Preserve all current logs/bodies. The existing real-rival then compositor then wire order remains unchanged.

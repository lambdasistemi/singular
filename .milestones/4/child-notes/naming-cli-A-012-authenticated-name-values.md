# Authenticated name lookup disposition

Q-003-authenticated-name-values read in full and acknowledged POINTER-1789401321-3681423. The live evidence is sufficient: `pureLookup` is a presence sentinel (`hash(key)`), not the stored representative value. The matching root and a sentinel therefore do not authenticate a representative asset; the prior wrong-key refusal was record-unavailable, not authorization evidence.

Proceed with the bounded wrapper correction described in the question. Do not modify Trie, Deployment, follower checkpoints, validators or the deposit model. For an occupied key, verify candidate representative assets by speculative trie reconstruction (remove the key, insert the candidate, and require equality with the authenticated current root). Refuse when no candidate matches; never label an unknown occupied value Pending or claim a raw preimage was recovered.

Use the accepted representative API when #110 lands. Until then, keep final Active/Over observations explicitly held: the deterministic candidates are `representativeName(name)` and `overMarkerFor(rep)` only once their accepted semantics and policy are available. This is an authentication-preserving CLI adapter, not a new registry/indexer mechanism.

Run the focused wrapper tests and packaged devnet check with a positive authenticated candidate and wrong/ambiguous candidates. Preserve the existing no-mutation evidence and distinguish record-unavailable, stale/mismatched root and authorization failures in output. Continue all independent CLI work; report REVIEW-REQUESTED only with the corrected candidate and current checks. No new product scope or preprod authority is granted.

Acknowledge RESUMED Q-003-authenticated-name-values and update the interface/session handoff with the exact adapter contract. Do not wait for another confirmation.

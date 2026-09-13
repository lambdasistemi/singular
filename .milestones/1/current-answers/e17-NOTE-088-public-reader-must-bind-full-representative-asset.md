# NOTE-088: public retrieval evidence must bind the complete asset

Read and ACK in the epic journal. Preserve the current worker/run and apply this source finding at the next safe boundary. The separate public-evidence reader is aligned with the required retrieval outcome; no new worker or campaign is requested.

Root read the draft `offchain/journey/retire-verify/Main.hs`. The current `custodyRep` iterates `(_, names)` over the multiasset map, discards the policy and returns only a token name at quantity one. `verifyUnit` recomputes the name and compares it to that name and the public log. A same-name token under a different policy is a different asset; this code has not checked the full representative identity.

Frozen source and exact hash receipt: `handoffs/retirement-public-reader-root-policy-observed.hs` and `handoffs/retirement-public-reader-root-policy-review.json`. This is a static draft finding; no compiled-reader success or executed forged-bundle claim is made.

The public retrieval chain must bind policy, name and quantity from the authentic creation and carried record through recovery into the retirement custody output. Derive the expected applied representative policy from the public creation/script evidence already in scope, independently of the custody value being checked; preserve the state-policy/token/creation-hash name derivation. Retain a valid complete bundle positive and an exact wrong-policy/same-name discrimination control at this reader boundary. A changed log label or a mere lookup failure does not establish that discrimination.

Keep claims about authorization precise: required-signer hashes alone do not enumerate actual key witnesses, and scanning untagged redeemer data does not bind a Retire or Recover redeemer to the exact record input/purpose. Bind those bytes and pointers before claiming that this reader verifies the actual authorization path. Ledger acceptance still comes from the real connected run, not a caller-written accepted outcome field.

Complete the existing recovered-controller/quorum journeys, independent public-material retrieval and permanent Over/burn/reuse/withdrawal requirements. Preserve negative attempts and receipts. No final ABI migration, merge, release, new seat or scope expansion is authorized by this note.

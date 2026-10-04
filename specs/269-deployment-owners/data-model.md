# Deployment record invariants

As an operator, I need the manifest and mirror files I already carry to remain readable by the same tools and to identify the same live registry.

## Values and boundaries

| ID | Value | Invariant |
| --- | --- | --- |
| preserve-refrole-refhash-refoutref-refaddress-refaddressbytes-their | `ReferenceScript` | Preserve `refRole`, `refHash`, `refOutRef`, `refAddress`, `refAddressBytes` and their generic JSON keys and order. |
| preserve-current-fields-constructors-generic-json-instances | `Deployment` | Preserve all current fields, constructors, generic JSON instances, pretty encoding and trailing newline. Keep the release, Lean revision, seed, policy/script identities, economics, reference outputs and bootstrap transactions bound to their current meanings. |
| preserve-compiled-bytes-policy-pins-used-compare | `CageParts` | Preserve the compiled bytes and policy pins used to compare a release with a manifest; no extra release-derived schema is introduced. |
| preserve-configuration-token-ordered-reference-utxos-state | `Attached` | Preserve configuration, token, ordered reference UTxOs and state UTxO for existing callers. |
| preserve-mirrortries-per-token-mttoken-mtmpf-mtkv | `Mirror` and `MirrorTrie` | Preserve `mirrorTries`, per-token `mtToken`, `mtMpf`, `mtKv`, `mtJournal`, `mtMetrics`, hex keys/values, absent-file empty map and replacement write format. |

The chain root is an observation of the concrete authenticated map, not an equality to Lean's abstract FNV commitment. No mirror JSON field is a substitute for checking the loaded trie's root against a live state datum. The current check is performed by the retained journey callers and must be described at that actual boundary.

`Attached` contains resolved outputs without a proof that their state datum agrees with the manifest's active policy or windows. That stronger claim belongs only to `verifyDeployment` in the current implementation.

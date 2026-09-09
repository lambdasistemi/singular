# Decisions and executable abstractions

The behavioral baseline is the [protocol specification](../specs/protocol/spec.md), [responsibilities](overview.md), [lifecycle](lifecycle.md), [certification boundary](certification.md) and [illustrative naming profile](naming-demo.md) merged in commit `fac38e643aa5d93f5bb6bb88acd9b9dd5b78e66f`. The S1 candidate adds an executable interpretation for review. It does not close the construction decisions below.

## Adopted behavior

| Source | Binding requirement |
| --- | --- |
| R1, R4, R6 | Insert is Absent → Active with representative creation; Update is Active → Over with burn; Delete is Active → Absent with burn. Over is terminal. |
| R2–R4 | The configured application policy directly issues separate Insert and Withdraw action assets with exact, domain-separated action commitments. An additional mandatory native request policy is not selected for those actions. |
| R3 | Insert approval exists at action minting and binds the initial application output. Approval is not a key reservation. Native recognition does not prove arbitrary application semantics. |
| R4 | Withdraw targets the exact pending Insert and declared refund effects, creates no representative and changes no registry entry. Original Insert approval is insufficient. |
| R5–R6 | The releasing application validator authorizes the exact Update/Delete request. That request retains the existing representative until valid completion; no ordinary cancellation or sweep releases it. |
| R1, R5 | Applications may evolve their own state while preserving their representative, without a registry Update. Active describes an outstanding representative, including request custody. |
| R7–R9 | Folds use successive registry states, have no native privileged folder gate, and require executing witnesses for transitions and custody even when per-asset mint quantities net to zero. |

These requirements incorporate the later action-asset and executing-witness corrections. Earlier alternatives requiring a second native Insert/Withdraw request policy are superseded. Policy identity and application spending-script identity remain distinct semantic roles even when an implementation shares a script hash.

## Proposed abstraction boundary

An executable logical map may stand for authenticated MPF state, a tagged structured value may stand for an unambiguous action commitment, and an explicit witness or contract parameter may stand for a ledger validator's authenticated result. These abstractions make the intended transition law inspectable without choosing a serialization, hash function, script deployment or application policy. Their exact use and limitations are recorded beside the Lean definitions and in the [model ledger](model-ledger.md).

Required native output parameters remain explicit fields such as representative identity and quantity, datum, destination and supported value requirements. The model is not authority to introduce a universal transaction-predicate language. Example names, addresses and policy identities are illustrative values, not production schemas or a global allowlist.

The desired identity is **one canonical registry per application policy ID**, without an arbitrary independent instance parameter. The policy can serve as a downstream trust anchor, conditional on its issuance invariants, but parameterizing by that reusable ID does not prevent duplicate creation of the same registry asset and state. Bootstrap must enforce an at-most-once invariant. An asset is identified by policy ID and asset name; a policy ID alone identifies a distinguished singleton only when its issuance rules enforce that distinction. An application-supplied one-shot bootstrap certificate could avoid a separate Singular nonce parameter; consuming a nonce UTxO is another construction option. The mechanism remains open under D1. The current model starts with a supplied `Config` and contains no registry-creation transition, so it establishes neither bootstrap enforcement nor deployed registry uniqueness.

## Open construction decisions

| ID | Still requires a ruling or construction | Boundary for this candidate |
| --- | --- | --- |
| D1 | Configuration authentication, registry/policy identity and hash dependencies | Logical authenticated configuration; no chosen script-hash-cycle solution. |
| D2 | Canonical encoding/hash, action-asset reuse/disposal, optional terminal-request token and burn branch | Explicit action commitments and logical witness/scope checks; no selected binary schema or token economy. |
| D3 | Withdrawal approval conditions, refund economics and disposal | Exact cancellation target and declared refund requirements; application approval remains conditional. |
| D4 | Representative identity and approval scope across Delete/reinsert | Scoped logical authorization and explicit representative identity; no universal incarnation allocation scheme selected. |
| D5 | Batch selection, limits and failure presentation | Sequential transition semantics; executable examples do not establish capacity, fairness or a skip policy. |
| D6 | Ledger transaction shapes, allocation of checks to concrete scripts and shared libraries | Executing logical witness obligations, including net minting; no proof of Cardano execution or imported MPFS guarantees. |
| D7 | Naming normalization, authorization, datum schema, resolver authentication and economics | Illustrative register/resolve/change-address stories under explicit model assumptions. |

## Evidence and next stage

The candidate's Lean build, exact admission inventory, exported finite corpus and browser checks are creator evidence. Every theorem remains **STATED**, with its `sorry` debt visible. Independent audit, accepted statements, proof completion and production conformance have not been commissioned as part of this delivery.

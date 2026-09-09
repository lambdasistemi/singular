# Prior art and reuse candidates

The inspected projects provide substantial precedent for Singular's architecture and mechanics. No ready-made implementation of its complete contract was established in this bounded comparison. This is not a novelty claim, security audit or exhaustive search. Source inspection does not establish deployed behavior.

The meaningful comparison is authorization timing and the request/NFT lifecycle. An equivalent registry would not be disqualified merely because it uses a different authenticated-set representation.

| Candidate | Relevant precedent | Gap against Singular's intended contract |
| --- | --- | --- |
| AdaDomains | Separate name registry and application state; pooled mint requests; local address changes | Published architecture does not establish action-bound certification or distinct permanent retirement/reusable deletion; inspected SDK supplies resolution, not registry validators |
| ADA Handle DeMi | MPF-backed order fulfillment and burn/delete mechanics | Inspected fulfillment requires an allowed-minter signature and Handle-specific effects; no matching generic certified terminal-request lifecycle established |
| Distributed Set | Generic byte-string set and configurable required mint/stake script | Hook checks invocation in the set-changing transaction; no staged certified-request and representative lifecycle supplied |
| CIP113 implementation | Registry authentication, configurable issuance and transfer credentials | Registry keys are derived token policy IDs; live withdrawal delegation and shared programmable custody differ; no matching Delete/Over lifecycle |
| Masumi registry-v2 | Consumed-input-derived NFT identity and versioned token operations | Does not supply application-selected key absence or the Active/Over registry contract |

## Evidence and useful boundaries

**AdaDomains.** The [whitepaper, sections 3–4](https://www.adadomains.io/white_paper.pdf) describes separate registry/domain state, pooled requests and address changes. [Project resolution documentation](https://www.adadomains.io/docs/domain-resolution/) describes reading the domain datum. The inspected [resolver SDK at 302235c](https://github.com/adadomains/adadomains-sdk/blob/302235c1661fc333ae318663aab293ddbc7deaaa/packages/resolver-sdk/src/resolver/AdaDomainsResolver.ts) supplies resolution code. These establish architectural precedent and a public resolver, not an inspected generic registry implementation. Historical throughput assertions are not adopted here.

**ADA Handle DeMi.** At `1b5623c`, [mint/burn validation](https://github.com/koralabs/decentralized-minting/blob/1b5623cde772851162b778f1ff42feed80e69443/smart-contract/lib/validations/minting_data/validation.ak) traverses MPF proofs and checks an allowed minter. [Order validation](https://github.com/koralabs/decentralized-minting/blob/1b5623cde772851162b778f1ff42feed80e69443/smart-contract/lib/validations/orders/validation.ak) supplies execution/cancellation/refund conditions. Mechanical overlap is useful; replacing application and governor rules is substantive work.

**Distributed Set.** The [validator at 4b0547a](https://github.com/micahkendall/distributed-set/blob/4b0547a5106fe26733c290ce567f2723c50b5289/validators/distributed_set.ak) and [utilities](https://github.com/micahkendall/distributed-set/blob/4b0547a5106fe26733c290ce567f2723c50b5289/lib/distributed_set/util.ak) authenticate set changes with current mint/withdrawal invocation. They do not supply Singular's prior-action receipt and NFT custody lifecycle.

**CIP113.** At `1e83ed9`, the [registry](https://github.com/cardano-foundation/cip113-programmable-tokens/blob/1e83ed97347ff6ebaf7784a81a4308915f272917/validators/registry.ak), [issuance policy](https://github.com/cardano-foundation/cip113-programmable-tokens/blob/1e83ed97347ff6ebaf7784a81a4308915f272917/validators/issuance_mint.ak) and [programmable base](https://github.com/cardano-foundation/cip113-programmable-tokens/blob/1e83ed97347ff6ebaf7784a81a4308915f272917/validators/programmable_logic_base.ak) provide relevant authentication and policy-binding techniques. Their live delegation and custody contract would require substantive adaptation.

**Masumi.** The [registry-v2 mint policy at ce96026](https://github.com/masumi-network/masumi-payment-service/blob/ce960265eac56b9d468173e052e64fa4c9e7a2f2/smart-contracts/registry-v2/validators/mint.ak) addresses generated asset identities and versioning. That is a different uniqueness problem from a registry of application-selected keys.

[CIP89's beacon pattern](https://cips.cardano.org/cip/CIP-0089) is also relevant precedent for minting that certifies an application UTxO. A complete uniqueness, request and retirement protocol remains additional work.

These candidates warrant component-level evaluation once a reuse target is concrete. License compatibility, toolchain fit and correctness require their own checks; this comparison grants none of them. Singular remains a design with unimplemented conformance obligations. Continue with the [naming walkthrough](naming-demo.md) or [protocol specification](../specs/protocol/spec.md).

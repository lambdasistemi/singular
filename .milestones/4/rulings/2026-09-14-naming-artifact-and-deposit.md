# Naming executable and registration deposit — operator rulings, 2026-09-14

User intent in this live milestone conversation:
- "I want a naming executable that give the user the chance to manage the registry"
- "also we want to set a price barrier so squatting is expensive"
- "it's refundable on Over"
- "and it's a deployment parameter"
- "A commited address" (answering whether the refund goes to an address committed at registration or the current controller)

The user-facing milestone artifact is a naming executable. Working command name singular-naming; expose the existing naming lifecycle individually, with registry attachment, inspection and follower/folder integration, using existing builders and Lean semantics. The full existing lifecycle is the desk's stated default in the absence of a narrower answer, not a new protocol rule. A dedicated implementation ticket preserves the existing frozen #104/#107 acceptance.

Pricing is a registration deposit, not a non-refundable fee. Its amount is a deployment parameter. Holding a registered name locks the deposit; the refund becomes available only when the naming lifecycle reaches Over. There is no new adjustable-price administrator authorized. Amount/unit representation and exact command spelling are technical choices to bind in the resulting design; do not invent a default economic price for the operator's deployment.

Refund destination is an address committed at registration, as selected by the operator. The refund must respect that commitment when the name reaches Over. These pricing choices are now settled. Any further ambiguity affecting the actual model transition must be raised concretely from the Lean definitions; technical encoding choices remain with the implementing owner.

This changes protocol semantics and needs a separate ticket with the operator rulings represented in Lean before the on-chain/off-chain behavior is implemented. Do not attach it as expanded acceptance to #104, #107 or the naming CLI wrapper. The naming executable must expose the final deployment parameter once the pricing implementation is available; do not add an inert flag as completion evidence.

Existing deployed-registry and writing-window authority is unchanged. A new parameter may affect future script/deployment identities; this ruling does not silently authorize replacing M1's current shared preprod deployment or modifying old manifests. Track compatibility and any demonstration deployment explicitly in the pricing ticket.

## Delivery order ruled by the operator

"so first ticket is update the model to accomodate that, run it in parallel". The first deposit ticket updates only the executable Lean model and relevant examples/statements. It runs alongside the naming executable and folder work. Validator/offchain/deployment/CLI pricing implementation is a separate later ticket after the model change is accepted and merged. No protocol implementation is authorized inside the first model ticket.

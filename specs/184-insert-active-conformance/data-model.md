# #184 — data model

## CG21 receipt relationship

One CG21 receipt has exactly one edge observation. That observation binds one
accepted fold to one open policy, active policy, key and requested destination,
plus two distinct refusal legs. Every refusal leg binds one rejected
transaction to its failing script identities and one accepted control
transaction.

## Fold observation fields

The edge observation carries: open policy identity and parameter count; active
policy and key; fold transaction id; minted assets; requested and observed
destination; delivered assets; empty refunds; empty signers; destination-datum
byte binding; tip coverage; non-root configuration preservation; and committed
root agreement.

Asset identity is `(policy, name, quantity)`. Transaction ids and policy
identities are nonempty chain observations. The delivered set contains exactly
one active-policy asset at the inserted key with quantity one.

## Refusal-leg fields

Each refusal leg carries rejected transaction id, attributed script hashes,
optional surfaced trace, accepted control transaction id and a nonempty
distinguisher. CG21 has two required legs: same-key duplicate and wrong keyed
mint distribution. Neither may be absent or reused as the other.

## Validation invariants

For CG21 the edge observation and every named field are mandatory. Both keys
in the keyed-mint leg are distinct. Every accepted transaction is candidate
bound and comes from the same invocation. An absent ledger trace stays absent;
refusal names are established at the compiled-validator boundary.

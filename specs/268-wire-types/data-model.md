# Wire data contracts

As an integrator, I need the same constructors, selectors, strictness and `Data` layout after the source moves. Each row is a before-to-after declaration and instance map, not a new wire specification.

## Declaration and instance map

| Original `Types.hs` declaration | New sole owner | Codec instances at intake | Stock derived instances at intake | Compatibility constraint |
| --- | --- | --- | --- | --- |
| `OnChainTokenId` | Primitive | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same newtype, selector and constructor-zero wrapper. |
| `OnChainTxOutRef` | Primitive | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same strict hash and index fields in order. |
| `OnChainRoot` | Primitive | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same newtype and direct byte literal. |
| `Edge`, seven edge constants, `edgeName` | Request | none | none | Same plain integer alias, tags and diagnostic names, including inadmissible tags. |
| `OnChainRequest` | Request | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Seven strict fields in the existing order; destination remains a two-element list. |
| `RequestPhase`, `requestPhase` | Request | none | `Show`, `Eq` for `RequestPhase` | Same three constructors and strict deadline comparisons. |
| `OnChainTokenState`, four policy-byte accessors | State | `ToData`, `FromData`, `UnsafeFromData` for the type | `Show`, `Eq` for the type | Same eight strict fields and order; accessors retain signatures and bytes. |
| `CageDatum` | State | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Request/state constructors stay zero/one; `AbsentCustody` stays refund-only at constructor two. |
| `Neighbor` | Proof | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same three strict fields and constructor-zero encoding. |
| `ProofStep` | Proof | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same strict fields and branch/fork/leaf constructor indices. |
| `Migration` | Redeemer | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same two strict fields and constructor-zero encoding. |
| `MintRedeemer` | Redeemer | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same mint/migrate/burn indices. |
| `RequestAction` | Redeemer | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same update/rejected indices. |
| `UpdateRedeemer` | Redeemer | `ToData`, `FromData`, `UnsafeFromData` | `Show`, `Eq` | Same five indices, including the retained unused `Sweep` constructor. |
| `ConsumerRedeemer` | Redeemer | `ToData` only | `Show`, `Eq` | `Hook` remains nullary at constructor zero; do not add decoders. |
| `mkD`, `unD`, `bsToD`, `bsFromD`, `bbsToD`, `bbsFromD` | Primitive | helpers, not instances | none | Preserve their conversion behavior; they become private to the owners. |

The 14 data and newtype declarations each derive `stock (Show, Eq)`; the `Edge` type synonym has no own instance declaration. The explicit codec inventory is twelve triples plus the single `ConsumerRedeemer` encoder: 37 instances. No derived or explicit instance is added or dropped by the move.

Every original `Types` export remains a facade export with the same constructor and field visibility. The only intended change in type identity is the defining module reported by Haskell reflection; inspect actual consumers for reliance on that representation and record the result. Do not claim generic identity preservation from compiling alone.

The wire oracle is independent literal `Data`, Aiken's committed vector file and the current Aiken source, not a value created by the codec under test. The existing `TypesSpec` checks request edge/deposit positions, eight-field state order, refund-only custody, retired two-field refusal, unused constructor-five refusal and phase endpoints. Its roundtrips are supporting checks, not the sole wire oracle. Issue #178 separately owns the sole-asset cardinality and Conformance publication obligations; this ticket preserves their existing tests and state.

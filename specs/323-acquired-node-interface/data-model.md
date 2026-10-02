# #323 data model

- chainpoint-network-magic-era-name-slot-block ChainPoint: network magic, era name, slot, block header hash. Origin is not a ChainPoint. Equality is on all four fields.
- view-one-acquired-ledger-state-fields-its View: one acquired ledger state. Fields: its ChainPoint; protocol parameters as a value captured once at acquire; UTxOs at an address; UTxOs by input (for reference and collateral inputs) when a builder needs them; whether a script credential has a registered reward account; POSIX ms to slot (floor and ceiling); script evaluation of a transaction. Valid only inside the acquire scope (scope-closed-view-used-after-its-scope). Carries no submission.
- provider-read-interface-exactly-one-acquire-operation Provider (read interface): exactly one acquire operation from a view-consuming action to its result. No query is reachable except through a view.
- signed-transaction-submitter-signed-transaction-type-constructible Signed transaction and submitter: a signed-transaction type constructible only by the signing function; the write capability accepts only that type and returns the node's acknowledgement or rejection unchanged. Separate from provider-read-interface-exactly-one-acquire-operation.
- memory-chain-in-memory-adapter-state-chainpoint Memory chain (in-memory adapter state): ChainPoint, protocol parameters, UTxO set, registered script credentials, slot/time configuration. Mutations advance the point; acquire snapshots the whole value.

Relationships: one operation → one View → one ChainPoint; a write journal entry → the ChainPoint of the View its body was built from.

# Functions

Signatures only. Bodies stay out of this file.

| Name | Arguments | Result | Constraint |
|---|---|---|---|
| `trieErase` | `t : Trie`, `k : Key` | `Trie` | no pair in the result has key `k` |
| `trieGet` after `trieErase` | `trieErase t k`, `k` | `Leaf` | equals `.unknown` |
| `applyEdge` deletion arms | unchanged `RegistryState`, `Action` | `Result` | `state.trie` is `trieErase` of the previous trie at the request key; `config.root` is `rootOf` of that trie |
| `applyEdge_deleteAbsent` | unchanged | the existing conjuncts | trie and root conjuncts use `trieErase` |
| `applyEdge_deleteActive` | unchanged | the existing conjuncts | trie and root conjuncts use `trieErase` |
| `delete_absent_inversion` | unchanged | the existing biconditional | trie and root conjuncts use `trieErase` |
| `delete_active_inversion` | unchanged | the existing biconditional | trie and root conjuncts use `trieErase` |
| reachable stored leaf | `s : RegistryState`, `Reachable s` | `Prop` | every stored leaf is not `.unknown` |
| `leafByte` | unchanged | unchanged | `0xFF` arm kept |
| `expectedSequenceOutcome` | a sequence step record | `Bool` | `deleteAbsent` with comparison `agrees` is accepted; `deleteActive` stays unsupported |

# Deleting a key removes it from the model's registry

Issue: https://github.com/lambdasistemi/singular/issues/235
Parent: https://github.com/lambdasistemi/singular/issues/209
Base: `7eba114be158a75669a72cd79649424d8a29ded0`
Rung: 3 for the chain comparison of an absent-key deletion; 1 for the pure trie lemmas.

## Story

As a reader of the conformance book, I see a key's deletion agree with the model on a real chain.

## What is wrong

A deleted key is a non-member. `applyEdge` writes it back as an explicit entry, `trieSet s.trie key .unknown` (`lean/Singular/Model.lean` deletion arms). `rootOf` then commits that entry through `leafByte`'s `0xFF` arm. A registry that never stored the key has a different root, while `trieGet` answers `unknown` in both. Burn, refund, custody and transaction shape already agree.

## Requirements

| ID | Observable |
|---|---|
| R1 | `trieErase t k` drops every pair whose key is `k`. Both deletion arms of `applyEdge` use it. |
| R2 | `trieGet (trieErase t k) k = .unknown`. Lookup-based refusal stays `key-unknown`. |
| R3 | No `RegistryState` that is `Reachable` stores a trie pair whose leaf is `.unknown`. |
| R4 | Every theorem whose conclusion fixes a post-deletion trie as `trieSet … .unknown` is restated to `trieErase` and proved. Mint, custody, held and paid conclusions stay. |
| R5 | `#print axioms` on every restated theorem does not name `sorryAx`. |
| R6 | The driver corpus is regenerated from the changed statements. |
| R7 | The unnamed sequence submits `deleteAbsent` for a key that same sequence inserted as Absent, while the key is still Absent. The devnet receipt records that step as agreeing with the model, including root and trie. |
| R8 | The generated book no longer publishes that deletion as a disagreement. The step's result is the receipt, not a typed sentence. |

## Decision: `leafByte`'s `0xFF` arm

The arm stays. It is the codec of the lookup answer `Leaf.unknown`, which `trieGet` still returns for a missing key. `rootOf` commits only pairs that are stored. After `trieErase`, a reachable registry never stores `.unknown`, so that byte is not a membership mark and is not emitted for a deleted key. Removing the arm would make `leafByte` partial or drop `Leaf.unknown`. `transition` still yields `.unknown` as the lookup answer of a deletion. That is the leaf result, not a stored entry.

## Statements whose trie conjunct changes

Custody, held, mint and paid conjuncts are unchanged. Only the post-deletion trie and the root of that trie change from `trieSet … .unknown` to `trieErase`.

| Theorem | File | Before | After |
|---|---|---|---|
| `applyEdge_deleteAbsent` | `lean/Singular/Lemmas.lean` | trie = `trieSet s.trie a.key .unknown` | trie = `trieErase s.trie a.key` |
| `applyEdge_deleteActive` | `lean/Singular/Lemmas.lean` | trie = `trieSet s.trie a.key .unknown` | trie = `trieErase s.trie a.key` |
| `delete_absent_inversion` | `lean/Singular/Statements.lean` | same trie conjunct | `trieErase` |
| `delete_active_inversion` | `lean/Singular/Statements.lean` | same trie conjunct | `trieErase` |
| `update_terminal` refusal row at the unknown trie | `lean/Singular/Statements.lean` | `txOf { s with trie := trieSet s.trie r.key .unknown }` = `key-unknown` | subject trie is `trieErase`; conclusion stays `.error "key-unknown"` |

If the `key-unknown` conclusion is false once the explicit entry is gone, stop. Do not change the error string to make it true.

Any further theorem whose conclusion equates a post-deletion trie with `trieSet … .unknown` is the same restatement. A conclusion other than that trie and its root is not.

## Out of scope

The off-chain `deleteActive` transaction. `deleteActive` stays unsupported in the unnamed sequence. The registration comparison. The on-chain validators. `leafByte`'s `0xFF` arm, which this ticket keeps.

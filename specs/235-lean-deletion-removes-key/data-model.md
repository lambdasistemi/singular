# Data

`Trie` stays `List (Key × Leaf)`.

A deleted key is absent from that list. It is not the pair `(key, .unknown)`.

`trieGet` of a missing key remains `.unknown`. That answer is the lookup default, not an entry.

`leafByte .unknown` remains `0xFF`. `rootOf` commits a leaf byte only for a pair that is in the trie. A reachable trie has no `.unknown` leaf, so a deleted key contributes no byte.

`Reachable` is unchanged: the empty trie, then states produced by successful `step`s.

Custody, held tokens, mint and the refund paid on `deleteAbsent` are unchanged. `deleteActive` still pays nothing.

The sequence receipt gains one `deleteAbsent` step whose comparison is agreement. `deleteActive` remains unsupported.

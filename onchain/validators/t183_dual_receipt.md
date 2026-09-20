# T183 dual-codec receipt (S20)

Commit carries both codecs: old `Request` (`Operation` + `tip`) and new
`EdgeRequest` (`edge` 0-6, no `tip`, `held >= state.tip`, `deposit == held -
tip`). Every other-edge G3 fixture folded under BOTH encodings with identical
verdicts; one valid read-terminal control accepts under both.

Executed via `aiken check` (`t183_dual.tests.ak`): 18 tests (8 old-refuse +
8 new-refuse + 2 accept), all green on this commit.

| # | old fixture (Operation, trie) | old verdict | new edge (same trie) | new verdict | mapping |
|---|---|---|---|---|---|
| 1 | Update(0x00,0x00) on absent | refuse (`update-to-absent`) | 5 deleteActive on absent | refuse (`no-approval`; with approval `edge-inadmissible`) | G3 retires; shape gate becomes trie gate |
| 2 | Update(0x01,0x00) on active | refuse (`update-to-absent`) | 2 updateActive on active | refuse (`no-approval`; with approval `edge-inadmissible`) | same |
| 3 | Update(0x00,0x02) on absent | refuse (`update-absent-to-terminal`) | 3 updateTerminal on absent | refuse (`no-approval`; with approval `edge-inadmissible`) | same |
| 4 | Update(0x01,0x01) on active | refuse (`update-active-to-active`) | 2 updateActive on active | refuse (`no-approval`; with approval `edge-inadmissible`) | same |
| 5 | Update(0x02,0x01) on terminal | refuse (`edge-from-terminal`) | 2 updateActive on terminal | refuse (`no-approval`; with approval `edge-inadmissible`) | same |
| 6 | Delete(0x02) on terminal | refuse (`edge-from-terminal`) | 5 deleteActive on terminal | refuse (`no-approval`; with approval `edge-inadmissible`) | same |
| 7 | Read(0x00) on absent | refuse (`read-absent`) | 6 witnessTerminal on absent | refuse (`edge-inadmissible`) | Lean `read-absent` |
| 8 | Read(0x01) on active | refuse (`read-non-terminal`) | 6 witnessTerminal on active | refuse (`edge-inadmissible`) | Lean `read-active` |
| C | Read(0x02) on terminal | accept | 6 witnessTerminal on terminal | accept | new codec is live |

G1 (`leaf-codec`) retires: no value bytes in the new wire. `tip-mismatch`
retires: no tip field; `tip-coverage` stays as `held >= state.tip`.
`deposit-mismatch` is new (explicit deposit). MPFS proof failures keep their
verdicts (walk reused via `canonicalOp`).

Next commit removes the old codec (`Request`, `Operation`, `RequestDatum`
index 0) and renames `EdgeRequest`/`EdgeRequestDatum` to `Request`/
`RequestDatum` at index 0. Final head must NOT contain the old codec.

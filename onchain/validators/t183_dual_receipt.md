# T183 dual-codec receipt (S20, NOTE-002 standard)

Both codecs in this commit: old `Request` (`Operation` + `tip`) and transient
`EdgeRequest` (SAME value bytes + edge tag, no `tip`, `held >= state.tip`,
`deposit == held - tip`). The SAME scenario — same trie, same key, same bytes —
folds under both with the same outcome and, for refusals, the same trace
compared as a value via `state.shapeTrace`. Non-read rows carry approval under
both; reads carry none (C4). One mutation per class shows disagreement.

Executed: `aiken check` in `onchain/` (S04 aiken-suite component); all green.

| scenario | old outcome+trace | new outcome+trace | equal | mutation (unequal) |
|---|---|---|---|---|
| update_absent_to_absent: Update(00,00) on absent | refuse `update-to-absent` | refuse `update-to-absent` | yes | update class: valid Update(00,01) old accepts / new wrong-tag(5) refuses `edge-mismatch` |
| update_active_to_absent: Update(01,00) on active | refuse `update-to-absent` | refuse `update-to-absent` | yes | (same update mutation) |
| update_absent_to_terminal: Update(00,02) on absent | refuse `update-absent-to-terminal` | refuse `update-absent-to-terminal` | yes | (same update mutation) |
| update_active_to_active: Update(01,01) on active | refuse `update-active-to-active` | refuse `update-active-to-active` | yes | (same update mutation) |
| update_from_terminal: Update(02,01) on terminal | refuse `edge-from-terminal` | refuse `edge-from-terminal` | yes | (same update mutation) |
| delete_terminal: Delete(02) on terminal | refuse `edge-from-terminal` | refuse `edge-from-terminal` | yes | delete class: valid Delete(00) old accepts / new wrong-tag(5) refuses `edge-mismatch` |
| read_absent: Read(00) on absent | refuse `read-absent` | refuse `read-absent` | yes | read class: valid Read(02) old accepts / new wrong-tag(2) refuses `edge-mismatch` |
| read_active: Read(01) on active | refuse `read-non-terminal` | refuse `read-non-terminal` | yes | (same read mutation) |
| valid updateActive (control) | accept | accept | yes | — |
| valid deleteAbsent (control) | accept | accept | yes | — |
| valid readTerminal (control) | accept | accept | yes | — |

G1 (`leaf-codec`) for non-codec bytes is unchanged on both (same `codecOk`
first); `tip-mismatch` retires on the new path only (no tip field;
`tip-coverage` stays as `held >= tip`); `deposit-mismatch`/`edge-mismatch`
are new-path-only gates after the shape gate, so no G3 trace changes.
MPFS proof failures keep their verdicts (walk reused on the same bytes).

Next commit removes the old codec (`Request`, `Operation`, `RequestDatum`
index 0) AND the transient `requestValue` from `EdgeRequest`, renaming
`EdgeRequest`/`EdgeRequestDatum` to `Request`/`RequestDatum` at index 0.
Final head must NOT contain the old codec.

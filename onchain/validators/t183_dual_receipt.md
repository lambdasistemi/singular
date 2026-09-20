# T183 dual-codec receipt (S20, NOTE-002 standard) — EXTENDED over #177 updateTerminal

Both codecs in this commit: old `Request` (`Operation` + `tip`) and transient
`EdgeRequest` (SAME value bytes + edge tag, no `tip`, `held >= state.tip`,
`deposit == held - tip`). The SAME scenario — same trie, same key, same bytes —
folds under both with the same outcome and, for refusals, the same trace
compared as a value via `state.shapeTrace` for the pre-admission G3 shapes
and via `state.terminalFault` / `state.tokenMissingRefusal` for the admitted
terminal edge (#177). Non-read rows carry approval under
both (terminal rows carry approval(3, ..) under both); reads carry none (C4).
One mutation per class shows disagreement.

Extended set on rebased main `019e2584a67148d62d40b58a74f117763060d924` (#177
merged): the terminal-edge class (`Update(01,02)` on active, edge 3) with its
accepting control and six refusal scenarios plus reason-value rows, per
NOTE-005 §3 / NOTE-006 §3. Gate-S-v1 extent GREW (NOTE-005 §5): S20 now
quantifies over #177's `updateTerminal` rows as well.

Executed: `bash -c 'cd /code/singular-issue-183/onchain && nix develop --command aiken check'` — exit 0, 352 passed / 0 failed overall, `t183_dual.tests` 53 passed / 0 failed (33 pre-rebase + 20 terminal).

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
| valid updateTerminal (control): Update(01,02) on active, witness held, burn -1 | accept | accept | yes | — |
| updateTerminal unknown key: empty trie | refuse `key-unknown` (`terminalFault` value) | refuse `key-unknown` (`terminalFault` value) | yes | terminal class: valid Update(01,02) old accepts / new wrong-tag(5) refuses `edge-mismatch` |
| updateTerminal absent leaf: Update(01,02) on absent | refuse `not-booked` (`terminalFault` value) | refuse `not-booked` (`terminalFault` value) | yes | (same terminal mutation) |
| updateTerminal terminal leaf: Update(01,02) on terminal | refuse `terminal-immutable` (`terminalFault` value) | refuse `terminal-immutable` (`terminalFault` value) | yes | (same terminal mutation) |
| updateTerminal no witness: active leaf, held=[] | refuse `token-missing` (`tokenMissingRefusal` value) | refuse `token-missing` (`tokenMissingRefusal` value) | yes | (same terminal mutation) |
| updateTerminal surviving carrier: two witnesses in, one survives | refuse `token-missing` (strict `sole` duty) | refuse `token-missing` (strict `sole` duty) | yes | (same terminal mutation) |
| updateTerminal wrong-key witness: keyB token for keyA burn | refuse `token-missing` (strict `sole` duty) | refuse `token-missing` (strict `sole` duty) | yes | (same terminal mutation) |
| reason values (encoding-independent construction sites) | `terminalFault` empty→`key-unknown`, absent→`not-booked`, terminal→`terminal-immutable`, active→None; `tokenMissingRefusal`→`token-missing` | same | yes | — |

G1 (`leaf-codec`) for non-codec bytes is unchanged on both (same `codecOk`
first); `tip-mismatch` retires on the new path only (no tip field;
`tip-coverage` stays as `held >= tip`); `deposit-mismatch`/`edge-mismatch`
are new-path-only gates after the shape gate, so no G3 trace changes.
MPFS proof failures keep their verdicts (walk reused on the same bytes).

Next commit removes the old codec (`Request`, `Operation`, `RequestDatum`
index 0) AND the transient `requestValue` from `EdgeRequest`, renaming
`EdgeRequest`/`EdgeRequestDatum` to `Request`/`RequestDatum` at index 0.
Final head must NOT contain the old codec.

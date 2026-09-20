# T183 dual-codec receipt (S20, NOTE-002 standard) — EXTENDED over #177 updateTerminal

Both codecs in this commit: old `Request` (`Operation` + `tip`) and transient
`EdgeRequest` (SAME value bytes + edge tag, no `tip`, `held >= state.tip`,
`deposit == held - tip`). The SAME scenario — same trie, same key, same bytes —
folds under both with the same outcome and, for refusals, the same trace
compared as a value via `state.shapeTrace` for the pre-admission G3 shapes
and via `state.terminalFault` / `state.tokenMissingRefusal` for the admitted
terminal edge (#177). Non-read rows carry approval under
both (terminal rows carry approval(3, ..) under both); reads carry none (C4).
One disagreement control per class (NOTE-007, the one authorized repair for
review 004): the SAME scenario with contradictory encodings — the old
`Operation` says one edge, the new `edge` tag says another — folded under
both with DIFFERENT reasons (old accepts from the `Operation`, new refuses
`edge-mismatch` from the tag). Nothing mutates `nextRoot`, proofs, or
anything both encodings read the same way. No class needed a LIMIT: update,
delete, read, and terminal all carry contradictory encodings.

Extended set on rebased main `019e2584a67148d62d40b58a74f117763060d924` (#177
merged): the terminal-edge class (`Update(01,02)` on active, edge 3) with its
accepting control and six refusal scenarios plus reason-value rows, per
NOTE-005 §3 / NOTE-006 §3. Gate-S-v1 extent GREW (NOTE-005 §5): S20 now
quantifies over #177's `updateTerminal` rows as well.

Executed: `bash -c 'cd /code/singular-issue-183/onchain && nix develop --command aiken check'` — exit 0, 352 passed / 0 failed overall, `t183_dual.tests` 53 passed / 0 failed (33 pre-rebase + 20 terminal; this repair changes two `nextRoot`s and comments only, no test added or removed).

| scenario | old outcome+trace | new outcome+trace | equal | mutation (unequal) |
|---|---|---|---|---|
| update_absent_to_absent: Update(00,00) on absent | refuse `update-to-absent` | refuse `update-to-absent` | yes | class control: `valid_update_absent_to_active` equal=no row below |
| update_active_to_absent: Update(01,00) on active | refuse `update-to-absent` | refuse `update-to-absent` | yes | (same update class control) |
| update_absent_to_terminal: Update(00,02) on absent | refuse `update-absent-to-terminal` | refuse `update-absent-to-terminal` | yes | (same update class control) |
| update_active_to_active: Update(01,01) on active | refuse `update-active-to-active` | refuse `update-active-to-active` | yes | (same update class control) |
| update_from_terminal: Update(02,01) on terminal | refuse `edge-from-terminal` | refuse `edge-from-terminal` | yes | (same update class control) |
| delete_terminal: Delete(02) on terminal | refuse `edge-from-terminal` | refuse `edge-from-terminal` | yes | class control: `valid_delete_absent` equal=no row below |
| read_absent: Read(00) on absent | refuse `read-absent` | refuse `read-absent` | yes | class control: `valid_read_terminal` equal=no row below |
| read_active: Read(01) on active | refuse `read-non-terminal` | refuse `read-non-terminal` | yes | (same read class control) |
| valid_update_absent_to_active (preservation) | accept | accept (tag 2) | yes | — |
| valid_update_absent_to_active (control: same scenario, Operation Update(00,01) vs tag 5) | accept (reads Operation → edge 2) | refuse `edge-mismatch` (reads tag 5 ≠ derived 2) | no | SAME scenario id folded twice; proves new reads the tag; `nextRoot`/`custody`/`outputs`/`mint`/`approval` identical |
| valid_delete_absent (preservation) | accept | accept (tag 4) | yes | — |
| valid_delete_absent (control: same scenario, Operation Delete(00) vs tag 5) | accept (reads Operation → edge 4) | refuse `edge-mismatch` (reads tag 5 ≠ derived 4) | no | SAME scenario id folded twice; proves new reads the tag; `nextRoot`=empty, custody/outputs/mint/approval identical |
| valid_read_terminal (preservation) | accept | accept (tag 6) | yes | — |
| valid_read_terminal (control: same scenario, Operation Read(02) vs tag 2) | accept (reads Operation → edge 6) | refuse `edge-mismatch` (reads tag 2 ≠ derived 6) | no | SAME scenario id folded twice; proves new reads the tag; roots/outputs/mint identical, no approval (C4) |
| valid updateTerminal (preservation): Update(01,02) on active, witness held, burn -1 | accept | accept (tag 3) | yes | — |
| valid updateTerminal (control: same scenario, Operation Update(01,02) vs tag 5) | accept (reads Operation → edge 3) | refuse `edge-mismatch` (reads tag 5 ≠ derived 3) | no | SAME scenario id folded twice; proves new reads the tag; roots/witness/burn/approval identical |
| updateTerminal unknown key: empty trie | refuse `key-unknown` (`terminalFault` value) | refuse `key-unknown` (`terminalFault` value) | yes | class control: `valid updateTerminal` equal=no row below |
| updateTerminal absent leaf: Update(01,02) on absent | refuse `not-booked` (`terminalFault` value) | refuse `not-booked` (`terminalFault` value) | yes | (same terminal class control) |
| updateTerminal terminal leaf: Update(01,02) on terminal | refuse `terminal-immutable` (`terminalFault` value) | refuse `terminal-immutable` (`terminalFault` value) | yes | (same terminal class control) |
| updateTerminal no witness: active leaf, held=[] | refuse `token-missing` (`tokenMissingRefusal` value) | refuse `token-missing` (`tokenMissingRefusal` value) | yes | (same terminal class control) |
| updateTerminal surviving carrier: two witnesses in, one survives | refuse `token-missing` (strict `sole` duty) | refuse `token-missing` (strict `sole` duty) | yes | (same terminal class control) |
| updateTerminal wrong-key witness: keyB token for keyA burn | refuse `token-missing` (strict `sole` duty) | refuse `token-missing` (strict `sole` duty) | yes | (same terminal class control) |
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

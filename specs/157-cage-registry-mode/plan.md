# #157 — plan and invariant mandate

One PR, `code-the-design`: the frozen #156 Lean is the behavioral authority;
this ticket makes the Aiken correspond to it. Every invariant row binds a Lean
identity or a #156 row, a Given/When/Then, the executable Aiken observation that
exhibits it, and a control able to fail for the intended reason. A row whose
only check would be reading source is a blocked question, not a row.

## Strategy

Order is fixed by dependency, not preference:

1. **Types and codec first** — `State` eight fields, `Operation.Read`,
   `Request.destination`, `CageDatum.AbsentCustody`, the codec bytes — so the
   blueprint, the Haskell encodings and the conformance rows can be regenerated
   once and every later slice compiles against them.
2. **The cage** — C2 admissibility, C3 read, C4 admission, C5 delta, C6
   destinations and custody, C8 coverage; `consumer.ak` deleted in the same
   commit as the withdrawal requirement, never one without the other.
3. **The token policies** — `witness(kind, registry)`; `representative.ak`
   retired.
4. **Naming** — the approval arms, the fold-created record, retirement's
   co-minted terminate approval; `naming.ak` loses its value vocabulary.
5. **Conformance and docs** — re-baseline, then the naming pages.

Nothing is pushed red to `main`; intermediate red heads on this draft branch are
permitted (A-002). The PR is stacked on #156's branch and targets it; it is
re-targeted to `main` when #156 merges.

## Staffing

Operator ruling, verbatim: "use codex as eo, opus as to, glm or muse as co";
"use opus as auditor".

- Ticket owner: `claude` (Opus).
- Commit owner: `glm --approve` if its probationary fence allows Aiken and the
  Haskell encodings; else `muse --approve`. One seat.
- Auditor: fresh Opus, `claude --dangerously-skip-permissions --model
  'claude-opus-5[1m]' --effort high`, own pane, own worktree, loading
  `commit-auditor` and `code-the-design`.
- `draft=NONE`.

## Constraints

- The frozen #156 Lean and its refusal reasons are the vocabulary; an Aiken
  trace label maps to exactly one Lean reason, and the mapping is a table in the
  handback.
- No new proof code enters the cage: the read uses `mpf.update(root, key,
  proof, v, v)`.
- Constructor indices already published are kept; new constructors are
  appended (`Read` 3, `AbsentCustody` 2, `destination` last field). Removed
  constructors (`Fold`, `Cancel`, `WithdrawApproval`, `InsertApproval`) are a
  declared contract change, listed in the conformance page.
- `just test` in both partitions must contain, for every refusal row, a test
  whose name carries the row id and whose failure is the named trace.
- Script identities are regenerated (`just script-identity-regen`) and the
  hashes recorded in the handback; `docs/preprod.md` is not touched (the
  deployed instance is the old contract until #153).

## Invariant rows — the cage

`Given / When / Then` is the obligation; **Observation** the Aiken test or
property that exhibits it; **Control** the seeded fault that must fail for the
named reason.

### Codec and combinations

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| G1 | #156 C1–C3 | Given a request whose value bytes are not `0x00`/`0x01`/`0x02`; when folded; then refused `leaf-codec`. | Rows for `0x03`, empty, `6f766572`, a 32-byte spelling | A permissive decoder accepts `0x03`: the row must then fail |
| G2 | #156 D2, R2 | Given each of the seven rows of C2 on its before-leaf; when folded with the matching mint; then accepted and the root advances (or, for `Read`, is unchanged). | One accepting test per row | Each row with its delta off by one refuses `delta-mismatch` |
| G3 | #156 R3, D6 | Given each refused shape of C2; when folded; then refused with its own trace, before any proof is checked. | One refusing test per shape; traces pairwise distinct where R3 says the facts differ | Removing one guard turns its row accepting |
| G4 | #156 D3 | Given `[Insert j, Read k 0x02, Insert l]`; when folded; then the read's proof verifies against the middle root and the final root equals the two inserts. | Accepting test with the proof built against the intermediate root | The same proof built against the initial root, and against the final root, each refuses |
| G5 | interface §2 | Given a batch of only reads; when folded; then accepted with `root` unchanged. | Accepting test, two reads of one terminal key | Zero consumed requests refuses `empty-fold` (existing `prop_empty_modify_refuses`, kept) |

### Admission

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| A1 | #156 D4, I-P1 | Given a tree-edge request whose UTxO carries no asset under `application_policy`; when folded; then refused `no-approval`. | One refusing test per tree edge | The same request with the approval accepts |
| A2 | D-APPROVAL | Given an approval whose name is not `blake2b_256(edge ‖ key ‖ owner ‖ destination)` of this request; when folded; then refused `approval-binding`. | Rows: wrong edge, wrong key, wrong owner, wrong destination | The correctly bound name accepts |
| A3 | #156 D4 | Given a `Read` request with no approval; when folded; then accepted. | Accepting test | An approval under a foreign policy on a tree edge refuses `no-approval` |
| A4 | #156 I-P1 | Given the eight pinned fields; when a `Modify` changes any of the seven non-root fields; then refused. | One refusing test per field | Preserving all seven accepts (existing `modify_altered_*` rows generalised) |

### Delta and mint

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| M1 | #156 D2, I-W1 | Given a fold of `Insert(0x01) k`; when the mint carries two active tokens for `k`, or one for `k` and one for `j`; then refused `delta-mismatch`. | Two refusing tests | Exactly one accepts |
| M2 | #156 I-W2, I-W4 | Given a leaf `0x01` for `k`; when a fold mints an absent token for `k`; then refused — there is no C2 row for it. | Refusing test | `Insert(0x00)` on an unknown key accepts |
| M3 | #156 I-S1 | Given a leaf `0x01` for `k`; when `Read(0x01) k` is folded; then refused `read-non-terminal`. | Refusing test | `Read(0x02)` on a `0x02` leaf accepts |
| M4 | #156 I-S3, I-W4 | Given `Update(0x00, 0x01) k`; when the mint carries +1 active and no −1 absent; then refused `delta-mismatch`. | Refusing test | −1 absent, +1 active accepts |
| M5 | #156 D2 | Given any fold; when any asset moves under a token policy that no consumed request entails; then refused `delta-mismatch`. | Refusing test with a stray terminal mint | — (M1 is the control) |

M1–M4 are the four #154 mutants at Aiken level; the ledger records each as a
refusing test with its accepting control. They are not "the mutated validator
fails to compile".

### Destinations and custody

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| T1 | D-DEST | Given `Insert(0x01) k` naming destination `(addr, h)`; when the fold puts the active token at another address, or at `addr` with a datum of another hash, or in two outputs; then refused `destination`. | Three refusing tests | One output at `addr` with datum hashing to `h` accepts |
| T2 | D-DEST | Given `Read(0x02) k` naming `(addr, h)`; when the terminal token lands elsewhere; then refused `destination`. | Refusing test | Named output accepts |
| T3 | D-CUSTODY | Given `Insert(0x00) k` with refund `r`; when the absent token is not in exactly one output at the cage's address with inline `AbsentCustody { k, r }`; then refused `absent-custody`. | Rows: wallet output; cage output with wrong key; wrong refund; extra asset | The exact custody output accepts |
| T4 | R-ADA, D-CUST | Given custody `AbsentCustody { k, r }` holding `L` lovelace; when `Update(0x00,0x01) k` or `Delete(0x00) k` is folded; then the custody UTxO is spent and an output at `r` receives at least `L`. | Two accepting tests with inserter ≠ booker | Paying `r` less than `L`, paying the booker's destination instead, or leaving custody unspent, each refuses `refund` |
| T5 | D-CUSTODY | Given a custody UTxO; when spent in any transaction that is not a `Modify` consuming a request for its key with one of the two consuming operations; then refused. | Refusing tests: plain spend; `Modify` for another key; `Modify` with `Read` | T4 is the control |

### Coverage and retraction

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| V1 | C8 (was R1) | Given a consumed request carrying less lovelace than its tip; when folded; then refused `tip-coverage`. | Refusing test | Funded request accepts (ported from `r1_*`) |
| V2 | C9 | Given a `Read` request in phase 2; when retracted by its owner; then accepted; by another signer, refused. | Accepting and refusing tests | An `Update` retract still refuses `withdraw-insert-only` |

## Invariant rows — the token policies

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| P1 | interface §5 | Given `witness(kind, registry)` for each kind; when minted or burned in a transaction that does not spend the registry state token with `Modify`; then refused `no-fold`. | Three refusing tests | Inside a fold, in the cage's quantity, accepts |
| P2 | I-W3 | Given a terminal token; when burned in a transaction with no fold at all; then accepted. | Accepting test | An active or absent burn outside a fold refuses `no-fold` |
| P3 | D-ASSET | Given a fold that mints under a token policy an asset whose name is not the request's key; when validated; then the cage refuses `delta-mismatch`. | Refusing test | Key-named asset accepts |

## Invariant rows — naming

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| N1 | R-NM4 `insertActive` | Given `Approve { insertActive, k, controller, (record addr, datum hash) }`; when minted with the controller's signature; then accepted; without it, refused `controller-signature`. | Accepting and refusing tests | Wrong datum hash in `destination` yields a different name: the fold then refuses A2 |
| N2 | R-NM4 `updateActive` | As N1 on a `0x00` leaf. | Same pair | Same |
| N3 | R-NM4 `insertAbsent` | Given `Approve { insertAbsent, k, refund, - }`; when minted with no signature; then accepted. | Accepting test | — (N4 is the negative) |
| N4 | R-NM4 `deleteAbsent` | Given custody `AbsentCustody { k, r }` as a reference input; when `Approve { deleteAbsent, k, r', - }` is minted; then accepted iff `r' = r` and `r`'s payment key signs. | Accepting test; refusing: wrong `r'`; right `r'` unsigned; no reference input | — |
| N5 | R-NM4 `deleteActive` | Given `Approve { deleteActive, .. }`; when minted under any signatures; then refused `never-certified`. | Refusing test | — |
| N6 | D-TERMINATE | Given a `Retire` by the controller (LT01) or a distinct-member quorum (LT02); when the same transaction mints `Approve { updateTerminal, k, .. }` and creates the completion request carrying it; then accepted. Below quorum (LT03), refused. | Three tests, ported | A terminate approval minted with no `Retire` in the transaction refuses `retire-required` |
| N7 | N3 fold-created record | Given an `insertActive` fold; when the record output at the application address carries the bound datum and exactly the active token; then accepted (cage T1). Given a record with a second asset; refused `record-single-asset`. | Accepting and refusing tests | — |
| N8 | N4 completion | Given completion-only custody holding the active token for `k` and its co-created `Update(0x01,0x02)` request; when folded; then custody is spent, the token burned, the leaf `0x02`. | Accepting test (LT rows ported) | A completion whose burn is not the held token refuses (existing `held_burned_exactly_once`) |
| N9 | NM2 | Given a live record; when `Maintain` or `Recover` runs; then the registry state is not an input and the root is unchanged. | Existing LM/LR rows, re-run | A `Maintain` that spends the state refuses |
| N10 | #156 T1 | Given a `0x02` leaf; when any request for `k` is folded; then refused (C2). | Rows for each operation on `0x02` | — |

## Invariant rows — consumers and docs

| id | Given / When / Then | Observation | Control |
|---|---|---|---|
| X1 | Given the new blueprint; when CS01, CS02, CS08 and the address rows run; then they pass against the eight-field datum, `Read`, `destination` and `AbsentCustody`, and the page lists old and new fields side by side as a contract change. | `blueprint-check`, `param-check`, the devnet rows | The six-field encoding demanded fails the run |
| X2 | Given `docs/naming-lifecycle.md`, `docs/naming-demo.md`, `docs/recovery-retirement.md`; when read; then each carries the state table, the seven edges, the four laws, and "no application script at fold time"; speech stamped. | `just check-presentation` exit 0 | An unstamped page fails |

## Trace-label table

The handback carries the table `Aiken trace → Lean reason` for every refusal
above; the auditor checks it is total over the Lean refusal reasons that the
cage can reach, and that no Aiken trace maps to two reasons.

## Gates

**Gate S — this ticket, focused.** `just test` and `just script-identity` in
both partitions; the Haskell encoding round-trips against the regenerated
blueprint (`blueprint-check`); `consumer.ak` absent from the tree; the
trace-label table total; `just check-presentation`; the diff inside
`onchain/`, `naming-onchain/`, `conformance/`, `offchain/` encodings only as
needed for the blueprint change, the three naming docs and their speech, and
`docs/consumer-conformance.md`. Authored and falsified per class before the
commit owner starts; blind-audited per `gate-script`.

**Ticket gate.** `nix develop --quiet -c just ci` exit 0 on the head, green
GitHub CI on the exact pushed head, fresh Opus `commit-auditor` report bound to
candidate and base, mutants M1–M4 each recorded as refusing test plus control.

## Evidence required at acceptance

- `just test` and `just script-identity` receipts in both partitions;
- the regenerated `script-identity.json` hashes in the handback;
- the trace-label table;
- the mutant ledger (M1–M4) as refusing tests with controls;
- the conformance re-baseline receipts and the contract-change section;
- fresh independent audit report; green CI on the pushed head.

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
2. **The cage** — seven-admitted-edges admissibility, read-preserves-intermediate-root read, tree-edge-admission-by-approval admission, mint-matches-edge-deltas delta, token-destinations-and-refunds
   destinations and custody, request-covers-tip coverage; `consumer.ak` deleted in the same
   commit as the withdrawal requirement, never one without the other.
3. **The token policies** — `witness(kind, registry)`; `representative.ak`
   retired.
4. **Naming** — the approval arms, the fold-created record, retirement's
   co-minted terminate approval; `naming.ak` loses its value vocabulary.
5. **Conformance and docs** — re-baseline, then the naming pages.

Nothing is pushed red to `main`; intermediate red heads on this draft branch are
permitted (operator answer (A-002)). The PR is stacked on #156's branch and targets it; it is
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
| request-whose-value-bytes-not-x00-x01 | #156 leaf-codec-and-operations–read-preserves-intermediate-root | Given a request whose value bytes are not `0x00`/`0x01`/`0x02`; when folded; then refused `leaf-codec`. | Rows for `0x03`, empty, `6f766572`, a 32-byte spelling | A permissive decoder accepts `0x03`: the row must then fail |
| seven-rows-on-its-before-leaf-folded | #156 singular-edge-singular-delta, seven-edges-interface | Given each of the seven rows of seven-admitted-edges on its before-leaf; when folded with the matching mint; then accepted and the root advances (or, for `Read`, is unchanged). | One accepting test per row | Each row with its delta off by one refuses `delta-mismatch` |
| refused-shape-folded-refused-its-own-trace | #156 refused-combinations-as-complement, singular-step-refusal-reasons | Given each refused shape of seven-admitted-edges; when folded; then refused with its own trace, before any proof is checked. | One refusing test per shape; traces pairwise distinct where refused-combinations-as-complement says the facts differ | Removing one guard turns its row accepting |
| insert-j-read-k-x02-insert-l | #156 singular-read-root-threading | Given `[Insert j, Read k 0x02, Insert l]`; when folded; then the read's proof verifies against the middle root and the final root equals the two inserts. | Accepting test with the proof built against the intermediate root | The same proof built against the initial root, and against the final root, each refuses |
| batch-reads-folded-accepted-root-unchanged | interface §2 | Given a batch of only reads; when folded; then accepted with `root` unchanged. | Accepting test, two reads of one terminal key | Zero consumed requests refuses `empty-fold` (existing `prop_empty_modify_refuses`, kept) |

### Admission

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| tree-change-needs-approval | #156 singular-admits-config-applicationpolicy, tree-change-requires-approval | Given a tree-edge request whose UTxO carries no asset under `application_policy`; when folded; then refused `no-approval`. | One refusing test per tree edge | The same request with the approval accepts |
| approval-binds-request | approval-asset-binding | Given an approval whose name is not `blake2b_256(edge ‖ key ‖ owner ‖ destination)` of this request; when folded; then refused `approval-binding`. | Rows: wrong edge, wrong key, wrong owner, wrong destination | The correctly bound name accepts |
| read-needs-no-approval | #156 singular-admits-config-applicationpolicy | Given a `Read` request with no approval; when folded; then accepted. | Accepting test | An approval under a foreign policy on a tree edge refuses `no-approval` |
| configuration-pins-preserved | #156 tree-change-requires-approval | Given the eight pinned fields; when a `Modify` changes any of the seven non-root fields; then refused. | One refusing test per field | Preserving all seven accepts (existing `modify_altered_*` rows generalised) |

### Delta and mint

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| fold-insert-x01-k-mint-carries-two | #156 singular-edge-singular-delta, active-witness-unique | Given a fold of `Insert(0x01) k`; when the mint carries two active tokens for `k`, or one for `k` and one for `j`; then refused `delta-mismatch`. | Two refusing tests | Exactly one accepts |
| leaf-x01-for-k-fold-mints-absent | #156 absent-witness-unique, witness-kinds-exclude | Given a leaf `0x01` for `k`; when a fold mints an absent token for `k`; then refused — there is no seven-admitted-edges row for it. | Refusing test | `Insert(0x00)` on an unknown key accepts |
| leaf-x01-for-k-read-x01-k | #156 terminal-attestation-sound | Given a leaf `0x01` for `k`; when `Read(0x01) k` is folded; then refused `read-non-terminal`. | Refusing test | `Read(0x02)` on a `0x02` leaf accepts |
| update-x00-x01-k-mint-carries-active | #156 supply-matches-leaf-state, witness-kinds-exclude | Given `Update(0x00, 0x01) k`; when the mint carries +1 active and no −1 absent; then refused `delta-mismatch`. | Refusing test | −1 absent, +1 active accepts |
| any-fold-any-asset-moves-under-token | #156 singular-edge-singular-delta | Given any fold; when any asset moves under a token policy that no consumed request entails; then refused `delta-mismatch`. | Refusing test with a stray terminal mint | — (fold-insert-x01-k-mint-carries-two is the control) |

fold-insert-x01-k-mint-carries-two–update-x00-x01-k-mint-carries-active are the four #154 mutants at Aiken level; the ledger records each as a
refusing test with its accepting control. They are not "the mutated validator
fails to compile".

### Destinations and custody

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| active-token-requested-destination | request-destination-binding | Given `Insert(0x01) k` naming destination `(addr, h)`; when the fold puts the active token at another address, or at `addr` with a datum of another hash, or in two outputs; then refused `destination`. | Three refusing tests | One output at `addr` with datum hashing to `h` accepts |
| terminal-token-requested-destination | request-destination-binding | Given `Read(0x02) k` naming `(addr, h)`; when the terminal token lands elsewhere; then refused `destination`. | Refusing test | Named output accepts |
| absent-token-registry-custody | absent-custody-datum | Given `Insert(0x00) k` with refund `r`; when the absent token is not in exactly one output at the cage's address with inline `AbsentCustody { k, r }`; then refused `absent-custody`. | Rows: wallet output; cage output with wrong key; wrong refund; extra asset | The exact custody output accepts |
| spent-custody-refunds-inserter | custody-lovelace-refund, absent-custody-datum | Given custody `AbsentCustody { k, r }` holding `L` lovelace; when `Update(0x00,0x01) k` or `Delete(0x00) k` is folded; then the custody UTxO is spent and an output at `r` receives at least `L`. | Two accepting tests with inserter ≠ booker | Paying `r` less than `L`, paying the booker's destination instead, or leaving custody unspent, each refuses `refund` |
| custody-spend-requires-consuming-fold | absent-custody-datum | Given a custody UTxO; when spent in any transaction that is not a `Modify` consuming a request for its key with one of the two consuming operations; then refused. | Refusing tests: plain spend; `Modify` for another key; `Modify` with `Read` | spent-custody-refunds-inserter is the control |

### Coverage and retraction

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| request-covers-tip | request-covers-tip | Given a consumed request carrying less lovelace than its tip; when folded; then refused `tip-coverage`. | Refusing test | Funded request accepts (ported from `r1_*`) |
| terminal-read-owner-retraction | owner-retraction | Given a `Read` request in phase 2; when retracted by its owner; then accepted; by another signer, refused. | Accepting and refusing tests | An `Update` retract still refuses `withdraw-insert-only` |

## Invariant rows — the token policies

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| witness-kind-registry-for-kind-minted-or | interface §5 | Given `witness(kind, registry)` for each kind; when minted or burned in a transaction that does not spend the registry state token with `Modify`; then refused `no-fold`. | Three refusing tests | Inside a fold, in the cage's quantity, accepts |
| terminal-token-burned-in-transaction-no-fold | terminal-witnesses-plural | Given a terminal token; when burned in a transaction with no fold at all; then accepted. | Accepting test | An active or absent burn outside a fold refuses `no-fold` |
| fold-that-mints-under-token-policy-asset | token-name-is-registry-key | Given a fold that mints under a token policy an asset whose name is not the request's key; when validated; then the cage refuses `delta-mismatch`. | Refusing test | Key-named asset accepts |

## Invariant rows — naming

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| controller-authorizes-active-insertion | naming-approval-rules `insertActive` | Given `Approve { insertActive, k, controller, (record addr, datum hash) }`; when minted with the controller's signature; then accepted; without it, refused `controller-signature`. | Accepting and refusing tests | Wrong datum hash in `destination` yields a different name: the fold then refuses approval-binds-request |
| controller-authorizes-absent-to-active-update | naming-approval-rules `updateActive` | As controller-authorizes-active-insertion on a `0x00` leaf. | Same pair | Same |
| absent-insertion-needs-no-signature | naming-approval-rules `insertAbsent` | Given `Approve { insertAbsent, k, refund, - }`; when minted with no signature; then accepted. | Accepting test | — (refund-owner-authorizes-absent-deletion is the negative) |
| refund-owner-authorizes-absent-deletion | naming-approval-rules `deleteAbsent` | Given custody `AbsentCustody { k, r }` as a reference input; when `Approve { deleteAbsent, k, r', - }` is minted; then accepted iff `r' = r` and `r`'s payment key signs. | Accepting test; refusing: wrong `r'`; right `r'` unsigned; no reference input | — |
| active-deletion-never-certified | naming-approval-rules `deleteActive` | Given `Approve { deleteActive, .. }`; when minted under any signatures; then refused `never-certified`. | Refusing test | — |
| recovery-authorizes-retirement | recovery-authorizes-retirement | Given a `Retire` proving the committed recovery key (reveal + signature) or a distinct-member quorum (distinct-quorum control); when the same transaction mints `Approve { updateTerminal, k, .. }` and creates the completion request carrying it; then accepted. Below quorum (below-quorum control), refused. **The current control key alone: refused `retire-needs-recovery-key`** (the recovery authorization ruling). | Four tests: recovery-key accepts; quorum accepts; below quorum refuses; control key alone refuses | A terminate approval minted with no `Retire` in the transaction refuses `retire-required`; a wrong reveal refuses as in `lr02` |
| request-deposit-returned | token-destinations-and-refunds | Given a folded booking or read whose request carried value `V` and tip `t`; when the fold completes; then the destination output carries at least `V − t`. | Accepting test with the exact residual | A fold that keeps the residual for the folder, or under-funds the destination output, refuses `deposit-returned` |
| fold-created-record-holds-active-token | absent-insertion-needs-no-signature fold-created record | Given an `insertActive` fold; when the record output at the application address carries the bound datum and exactly the active token; then accepted (cage active-token-requested-destination). Given a record with a second asset; refused `record-single-asset`. | Accepting and refusing tests | — |
| retirement-custody-burns-held-token | refund-owner-authorizes-absent-deletion completion | Given completion-only custody holding the active token for `k` and its co-created `Update(0x01,0x02)` request; when folded; then custody is spent, the token burned, the leaf `0x02`. | Accepting test (retirement cases ported) | A completion whose burn is not the held token refuses (existing `held_burned_exactly_once`) |
| local-record-change-preserves-registry | local-record-update-preserves-registry | Given a live record; when `Maintain` or `Recover` runs; then the registry state is not an input and the root is unchanged. | Existing maintenance and recovery rows, re-run | A `Maintain` that spends the state refuses |
| terminal-key-refuses-tree-change | #156 terminal-key-cannot-change | Given a `0x02` leaf; when any **tree-changing** request for `k` is folded — `Insert`, `Update`, `Delete` with any value — then refused (seven-admitted-edges, `edge-from-terminal`). `Read(0x02)` for `k` is **accepted** and mints `+1 terminal` (seven-admitted-edges, read-preserves-intermediate-root, batch-reads-folded-accepted-root-unchanged, leaf-x01-for-k-read-x01-k): terminal-key-cannot-change is stated for every edge but `witnessTerminal`. | Rows for each tree-changing operation on `0x02`; one accepting `Read(0x02)` row | Admitting any tree-changing operation on `0x02` turns its row accepting; refusing the read turns batch-reads-folded-accepted-root-unchanged red |

## Invariant rows — consumers and docs

| id | Given / When / Then | Observation | Control |
|---|---|---|---|
| compiled-wire-conformance | Given the new blueprint; when blueprint-encoding-round-trip, submitted-datum-byte-round-trip, state-fields-chain-round-trip and the address rows run; then they pass against the eight-field datum, `Read`, `destination` and `AbsentCustody`, and the page lists old and new fields side by side as a contract change. | `blueprint-check`, `param-check`, the devnet rows | The six-field encoding demanded fails the run |
| published-naming-lifecycle | Given `docs/naming-lifecycle.md`, `docs/naming-demo.md`, `docs/recovery-retirement.md`; when read; then each carries the state table, the seven edges, the four laws, "no application script at fold time", and the retirement section states the two known weaknesses (the quorum is fixed for the life of the name; the quorum can retire while the controller is present) and that retirement needs the recovery key or the quorum; speech stamped. | `just check-presentation` exit 0 | An unstamped page fails |

## Trace-label table

The handback carries the table `Aiken trace → Lean reason` for every refusal
above; the auditor checks it is total over the Lean refusal reasons that the
cage can reach, and that no Aiken trace maps to two reasons.

## Gates

**acceptance checks — this ticket, focused.** `just test` and `just script-identity` in
both partitions; the Haskell encoding round-trips against the regenerated
blueprint (`blueprint-check`); `consumer.ak` absent from the tree; the
trace-label table total; `just check-presentation`; the diff inside
`onchain/`, `naming-onchain/`, `conformance/`, `offchain/` encodings only as
needed for the blueprint change, the three naming docs and their speech, and
`docs/consumer-conformance.md`. Authored and falsified per class before the
commit owner starts; blind-audited per `gate-script`.

**Ticket gate.** `nix develop --quiet -c just ci` exit 0 on the head, green
GitHub CI on the exact pushed head, fresh Opus `commit-auditor` report bound to
candidate and base, mutants fold-insert-x01-k-mint-carries-two–update-x00-x01-k-mint-carries-active each recorded as refusing test plus control.

## Evidence required at acceptance

- `just test` and `just script-identity` receipts in both partitions;
- the regenerated `script-identity.json` hashes in the handback;
- the trace-label table;
- the mutant ledger (fold-insert-x01-k-mint-carries-two–update-x00-x01-k-mint-carries-active) as refusing tests with controls;
- the conformance re-baseline receipts and the contract-change section;
- fresh independent audit report; green CI on the pushed head.

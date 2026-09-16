# #156 — plan and invariant mandate

Strategy, slice, and the exact invariant rows. Every row binds a Lean identity, a
Given/When/Then, the executable model observation that exhibits it, and a control
able to fail **for the intended reason**. A row whose only check would be a
source-text match is not a row: it is a blocked question naming the row.

## Strategy

The model is rewritten, not migrated. `Value`, `incarnation`, `assetScope` and
`reuseIdentity` are deleted; the edge set replaces the three-operation
`insert/update/delete` vocabulary; `Config` goes to eight fields. Because every
naming module imports the model, and because the corpora and manifests are
byte-bound to the sources they are generated from, **no partial tree builds**.
This is therefore one slice, not three: a tree that has the new `Model.lean` and
the old `NamingStatements.lean` does not compile, so it is not a bisect point.

Order inside the slice is fixed by the issue: **definitions first**, so the model
can be reasoned about; then the generic statements; then the open application as
the smallest instantiation, proved first; then naming; then the generated
surfaces and the correspondence page.

## Constraints

- Lean is the behavioral authority. Do not weaken a statement to make it provable;
  a proved weaker statement is the wrong contract. Escalate as a user story.
- Sorry-free at acceptance. `#print axioms` for every statement in the frozen
  modules yields only `propext`, `Classical.choice`, `Quot.sound`.
- The compiled axiom gate (`Singular.Audit`) runs while the library elaborates; it
  must keep covering every statements module, including the naming ones.
- **`tools/check_model.py` is outside this ticket's surface and is treated as
  frozen** (pending Q-001). Its constraints therefore bind the deliverable:
  the generic corpus source extent stays the current six-file `GENERIC_SOURCES`
  list; the generic corpus keeps row-id prefixes `S01`–`S21` and `N01`–`N07`;
  the naming corpus keeps its six sections and the prefixes
  `SP, NQ, NF, NS, NR, NRP`; the lifecycle corpus keeps the **exact**
  `LIFECYCLE_IDS` set. Meaning is re-stated over the new model; identities are
  preserved. If a row's meaning cannot survive under its current id, that is a Q,
  not a silent rename.
- No `sorry` outside `lean/Singular/Statements.lean`; `audit_sources` rejects
  `axiom`, `admit`, `unsafe`, `implemented_by`, `extern` anywhere in `lean/`.
- Planning artifacts carry no implementation. The commit owner owns every line of
  Lean, every generator row, and every proof.

## Slice

**T-S1 `registry-mode-model`** — the whole model rewrite, its statements, both
instances, the regenerated surfaces and the correspondence page, as one
bisect-safe commit. Maximum two audited submissions.

## Invariant rows

`Given / When / Then` are the obligation. **Observation** is the executable model
row or inversion that exhibits it. **Control** is the seeded fault that must make
that observation fail, and fail for the named reason.

### Definitions

| id | Lean identity | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| D1 | `Singular.Leaf`, `Singular.State` | Given any key; when its leaf is read; then it is `Unknown` or `Known s` with `s ∈ {Absent, Active, Terminal}` and nothing else. `Value`, `incarnation`, `assetScope`, `reuseIdentity` do not exist. | Corpus rows covering all four leaf shapes | A leaf carrying an application payload does not typecheck / does not decode |
| D2 | `Singular.Edge`, `Singular.delta` | Given an edge; when it is folded; then its from→to transition and its token delta are exactly the R2 table. | One accepted corpus row per edge with its recorded delta | Each edge with a delta off by one is refused `net-mint-mismatch` |
| D3 | `Singular.Read`, the fold's root threading | Given a batch `[…, Read k v, …]`; when the fold reaches position k; then the proof is verified against the **intermediate** root at that position and the leaf is unchanged. | An accepted `[Insert k v, Read k v]` batch; the leaf equal before and after the read | The same read verified against the initial or final root is refused |
| D4 | `Singular.admits`, `Config.applicationPolicy` | Given a tree-edge request without an approval under the pinned policy; when the fold runs; then it is refused. Given `witnessTerminal` without one; then it is accepted. | One refusal row per tree edge; one accepted read row | An approval under any other policy is refused |
| D5 | `Singular.Config` | Given the state datum; when its fields are enumerated; then exactly `root, maxFee, processTime, retractTime, applicationPolicy, activePolicy, absentPolicy, terminalPolicy`; no `consumerPin`. | Eight-field round-trip row | A nine-field or `consumerPin`-bearing datum does not decode |
| D6 | `Singular.step` refusal reasons | Given each of `insert Terminal`, `update Absent`, any edge out of `Terminal`, `deleteTerminal`, a zero-request batch, a mint ≠ summed delta; when folded; then each is refused with its own distinct reason. | One refusal row per combination, reasons pairwise distinct | Deleting one guard turns its row accepted |
| D7 | `Singular.route` | Given a fold minting an absent token; when it completes; then the absent token is in cage custody and the active/terminal tokens are at the request's named output. | Custody rows per token kind | An absent token routed to the request's output is refused |
| D-ADA | `Singular.route` (value) | Given `Known Absent` with its absent token in cage custody; when `updateActive` or `deleteAbsent` consumes it; then the value it held is paid to the output the consuming request names. | Value-flow row for both edges | Paying it to the folder, or retaining it in custody, is refused |

### Codec — frozen sibling contract for #157 and #152

| id | Lean identity | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| C1 | `Singular.encodeState`, `Singular.decodeState` | Given any `State`; when encoded and decoded; then the original returns. `0x00` Absent, `0x01` Active, `0x02` Terminal. | Round-trip row per state | A codec mapping two states to one byte fails the round trip |
| C2 | `Singular.decodeState` totality | Given any byte string that is not one of the three; when decoded; then no state is produced and the cage refuses the leaf. | Refusal rows for `0x03`, empty, multi-byte | A permissive decoder accepts `0x03` and the row goes green — it must not |
| C3 | naming-era bytes | Given a leaf byte string from the naming era (representative name, `over` marker); when decoded; then it is not a valid leaf. | Refusal row over a naming-era byte string | A decoder that still accepts naming bytes fails this row |

### Statements (interface §6 and §4)

Each is proved without `sorryAx` and carries the Given/When/Then below.

| id | Lean identity | Given / When / Then |
|---|---|---|
| I-P1 | `Singular.Statements.no_tree_change_without_approval` | Given any reachable state and any fold; when a tree change occurs; then the request carried an approval under the pinned application policy, and the pins are equal before and after. |
| I-L1 | `Singular.Statements.booked_at_most_once` | Given any reachable state; when a batch is folded; then a key is booked at most once at a time, the batch is atomic (all-or-nothing), and each request is spent once. |
| I-S1 | `Singular.Statements.terminal_attestation_sound` | Given a terminal token for `key` exists; when its provenance is traced; then it was minted by a fold that accepted `Read Terminal` for `key`, which holds only if the leaf was `Known Terminal`. No attestation of an `Active`, `Absent` or `Unknown` key exists. |
| I-S2 | `Singular.Statements.terminal_attestation_permanent` | Given a terminal token valid in state `s`; when any sequence of folds is applied; then it is valid in every later state, because a `Terminal` leaf admits no edge that moves it. |
| I-S3 | `Singular.Statements.biconditional_supply_sync` | Given any key and either biconditional kind; when the supply is counted; then it is 1 iff the key is in that token's state, and 0 otherwise — unconditionally. Identity is `(policy, key)`; a key recreated after `deleteActive` carries the same identity, by design. |
| I-O1 | `Singular.Statements.occupancy` | Given a key whose leaf is `Active` or `Terminal` ("taken"); when a booking edge (`insertActive` or `updateActive`) is folded; then it is refused; and when the key is not taken, it succeeds. |
| I-T1 | `Singular.Statements.termination` | Given `Known Terminal`; when any edge is attempted; then it is refused, so the key stays terminated forever and is never re-booked. |
| I-W1 | `Singular.Statements.active_witness_unique` | Given any key; when active tokens are counted; then at most one, and exactly one iff the leaf is `Known Active`. |
| I-W2 | `Singular.Statements.absent_witness_unique` | Given any key; when absent tokens are counted; then at most one, and exactly one iff the leaf is `Known Absent`. |
| I-W3 | `Singular.Statements.terminal_witness_plural` | Given `Known Terminal`; when terminal tokens are minted or burned; then any number may exist, all true, all freely burnable; and any exists only if the leaf is `Known Terminal`. |
| I-W4 | `Singular.Statements.witness_kinds_exclude` | Given any key; when the outstanding witnesses are examined; then at most one **kind** is outstanding: a consumer finding one kind knows the other two do not exist, without reading the state. |

### Instances

| id | Given / When / Then | Observation | Control |
|---|---|---|---|
| OA1 | Given the open application — a policy that certifies everything; when each statement I-P1…I-W4 is instantiated at it; then all hold. This is the smallest instantiation and is proved **first**. | Instantiation of every statement at the open policy | A statement that silently assumed naming's policy fails to instantiate |
| NM1 | Given naming; when a record is registered; then the record UTxO holds the active token and the trie carries only `Active`. | Naming corpus registration rows | A record whose data sits in the leaf fails D1 |
| NM2 | Given a live record; when `maintain` or `recover` runs; then the application UTxO is spent and **the trie is untouched** — root equal before and after. | Root-equality rows for both moves | A maintain that changes the root is refused |
| NM3 | Given retirement; when it completes; then it is `updateTerminal`, and the existing `over_terminal` and `naming_delete_refused` meanings hold over the new model. | Re-stated naming statements at their preserved identities | Re-admitting either statement turns the build red |
| NM4 | Given naming's approval policy; when an `insertActive` request carries the controller's signature, or `updateTerminal` the quorum's; then an approval is minted; for `deleteActive`, never. | Admission rows per edge | An approval minted for `deleteActive` is refused |
| NM5 | Given the naming recovery rows and `WellFormed`; when re-stated over the new model; then their meaning is preserved and their lifecycle ids are unchanged. | `LIFECYCLE_IDS` set equality holds | A dropped recovery row breaks the exact-set assertion |

### Mutants — the four named in #154

Each must break **its** law, under audit, with a positive control proving the law
holds on the unmutated model. A compile failure is **not** a behavioral kill and
may not be presented as one: each mutant must elaborate and then be refuted by a
statement or an executable row.

| id | mutant | must break |
|---|---|---|
| M1 | mint a second active token for a key | I-W1, and I-S3 for the active kind |
| M2 | mint an absent token for an active key | I-W2 and I-W4 |
| M3 | attest an active key (`Read Active` admitted) | I-S1 |
| M4 | leave the absent token outstanding on `updateActive` | I-S3 and I-W4 |

## Evidence required at acceptance

- `nix develop --quiet -c just model` exit 0;
- `nix develop --quiet -c just ci` exit 0 — **green criterion pending Q-001**;
- compiled axiom report clean for every statement above, no `sorryAx`;
- the four mutants each producing their intended law failure, each with its
  positive control, none classified from a compile failure;
- regenerated corpora, manifests, `docs/theorems.md` and its stamped speech file
  corresponding to the accepted revision;
- a fresh independent Opus `lean-auditor` report bound to candidate and base.

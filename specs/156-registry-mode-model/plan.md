# #156 — plan, slices and invariant mandate

Two sequential slices in one PR (ruling A-001). Every invariant row binds a Lean
identity, a Given/When/Then, the executable observation that exhibits it, and a
control able to fail **for the intended reason**. A row whose only check would be
a source-text match is not a row: it is a blocked question naming the row.

## Strategy

The model is rewritten, not migrated. `Value`, `incarnation`, `assetScope` and
`reuseIdentity` are deleted; the edge set replaces the three-operation
`insert/update/delete` vocabulary; `Config` goes to eight fields.

Because every naming module imports the model, and because the corpora and
manifests are byte-bound to the sources they are generated from, **no partial
Lean tree builds**: a tree with the new `Model.lean` and the old
`NamingStatements.lean` does not compile, so it is not a bisect point. Slice A is
therefore indivisible.

Because the simulator is a hand transcription of the model, slice A's tree is
green on the model gate and red on the simulator. That is expected and bounded:
it is never pushed and never claimed as repository-green.

Order inside slice A is fixed by the issue: **definitions first**, so the model
can be reasoned about; then the generic statements; then the open application as
the smallest instantiation, proved first; then naming; then the generated
surfaces and the pages.

## Slices

| slice | owns | author | auditor |
|---|---|---|---|
| **A — model** | `lean/**` (definitions, statements, proofs, lemmas, manifests, debt surfaces, `lean/*.json` corpora and their generators); `tools/check_model.py`; `docs/theorems.md`, `docs/model-ledger.md`, `docs/mutants.md` and their speech stamps | `glm --approve` loading `lean-creator` + `lean4` | fresh Opus loading `lean-auditor` |
| **B — simulator (#163)** | `simulator/**`; `docs/simulation.md`, `docs/LEAN-CLARITY.md`; the model-bound browser checks; the replayed corpora and the counts on the front page and `docs/design.md`; their speech stamps | `muse --approve` loading `lean-simulations` | fresh Opus loading `lean-simulations-auditor` |

**Slice B does not start until slice A's audit passes and the slice-A Lean
interface is frozen.** Slice B transcribes the frozen interface; it never edits
it. A slice-B finding against the Lean is a Q to this ticket owner, not a repair.

### Staffing, checked against the operator's rule

Operator ruling, verbatim: "use codex as eo, opus as to, glm or muse as co";
"use opus as auditor". It overrides the standing claude-below-milestone bar for
this epic.

- Slice A author `glm` — the one GLM seat this ticket is capped at.
- Slice B author `muse` — a different seat from slice A's author, as A-001
  requires, and inside the operator's GLM/Muse rule. **No escalation needed**:
  both launchers resolve in a non-interactive shell (`/home/paolino/.local/bin/glm`,
  `/home/paolino/.local/bin/muse`).
- Every gate auditor and candidate auditor:
  `claude --dangerously-skip-permissions --model 'claude-opus-5[1m]' --effort high`,
  fresh context, fresh runtime root, fresh detached audit worktree, own pane.
- Alternation holds at every edge: ticket owner `claude` ≠ authors `glm`/`muse`;
  authors `glm`/`muse` ≠ auditors `claude`.
- `draft=NONE`.

## Constraints

- Lean is the behavioral authority. Do not weaken a statement to make it provable;
  a proved weaker statement is the wrong contract. Escalate as a user story.
- Sorry-free at acceptance: every statement's axioms are exactly within
  `propext`, `Classical.choice`, `Quot.sound`.
- The compiled axiom gate (`Singular.Audit` and the naming gates) must keep
  covering **every** statements module. A statements module with no gate is a
  hole, not an omission.
- `tools/check_model.py` is **opened to the new identities, not relaxed**: exact
  identity matching, PROVED only from standard axioms, STATED for admitted
  declarations, byte-for-byte corpus regeneration, and the keyword/proof-hole
  audit over `lean/` all remain. Weakening any of them is a finding, not a repair.
- No `sorry` outside the frozen statements module; `audit_sources` keeps
  rejecting `axiom`, `admit`, `unsafe`, `implemented_by`, `extern` in `lean/`.
- **Nothing lands red; intermediate red heads on the draft branch are allowed.**
  A-002 relaxed this ticket's stricter reading: slice A may be pushed to the
  draft branch with the simulator legs red, so an audited candidate is not
  stranded on one worktree for the duration of slice B. Only the head marked
  ready-for-review must be green, locally and on GitHub CI.
- Planning artifacts carry no implementation. The authors own every line of Lean,
  every generator row, every proof, and every line of simulator JavaScript.

## Invariant rows — slice A

`Given / When / Then` is the obligation. **Observation** is the executable model
row or inversion that exhibits it. **Control** is the seeded fault that must make
that observation fail, and fail for the named reason.

### Definitions

| id | Lean identity | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| D1 | `Singular.Leaf`, `Singular.State` | Given any key; when its leaf is read; then it is `Unknown` or `Known s` with `s ∈ {Absent, Active, Terminal}` and nothing else. | Corpus rows covering all four leaf shapes | A leaf carrying an application payload does not elaborate |
| D1b | absence of the old vocabulary | Given the **elaborated environment**; when `Singular.Value`, `Entry.incarnation`, `Representative.assetScope`, `Config.reuseIdentity`, `Config.consumerPin` are looked up; then none resolves. | An environment query in the audit gate, not a grep | Re-adding any one of them makes the query find it and the leg fail |
| D2 | `Singular.Edge`, `Singular.delta` | Given an edge; when it is folded; then its from→to transition and its token delta are exactly the R2 table. | One accepted corpus row per edge with its recorded delta | Each edge with a delta off by one is refused `net-mint-mismatch` |
| D3 | `Singular.Read`, root threading | Given a batch `[…, Read k v, …]`; when the fold reaches position k; then the proof is verified against the **intermediate** root at that position and the leaf is unchanged. | An accepted `[Insert k v, Read k v]` batch; leaf equal before and after | `[Insert j, Read k Terminal, Insert l]` where the proof for `k` is valid **only** against the middle root: refused against the initial root and refused against the final root. A read at the last position is not a control — there the intermediate root *is* the final root, and at position 0 it is the initial root |
| D4 | `Singular.admits`, `Config.applicationPolicy` | Given a tree-edge request without an approval under the pinned policy; when folded; then refused. Given `witnessTerminal` without one; then accepted. | One refusal row per tree edge; one accepted read row | An approval under any other policy is refused |
| D5 | `Singular.Config` | Given the state datum; when its fields are enumerated; then exactly the eight of R7; no `consumerPin`. | Eight-field round-trip row | A nine-field or `consumerPin`-bearing datum does not decode |
| D6 | `Singular.step` refusal reasons | Given **any `(primitive, value, before-leaf)` triple that is not a row of the R2 table**, plus a zero-request batch and a mint ≠ the summed delta; when folded; then each is refused, and reasons are distinct **where the distinction is observable**. The refused reads `Read Active` and `Read Absent` are part of this set — the structural guard S1 rests on them. | One refusal row per named case of R3's table, reasons pairwise distinct except where R3 says one fact | Removing one guard turns its row accepted. `deleteTerminal` and "any edge out of `Terminal`" are one fact and are not required to carry two reasons |
| D7 | `Singular.route` | Given a fold minting an absent token; when it completes; then the absent token is in cage custody and the active/terminal tokens are at the request's named output. | Custody rows per token kind | An absent token routed to the request's output is refused |
| R-ADA | `Singular.route` (value), custody datum | Given `Known Absent` whose absent token sits in cage custody with the refund address the `insertAbsent` request named; when `updateActive` or `deleteAbsent` consumes it; then the value it held is paid to **that refund address**. | Value-flow row for both edges, with the inserter and the consumer distinct | Paying the consuming request's output, paying the folder, or retaining it in custody is refused. The row where inserter = consumer is not a control: it cannot distinguish R-ADA from the rejected D-ADA |
| D-CUST | custody invariant | Given any reachable state; when cage custody is enumerated; then it holds exactly the outstanding absent tokens, each with its refund address and its value — no more, no less. | Custody census row | An absent token in custody with no refund address, or a custody entry with no outstanding token, fails |

### Codec — frozen sibling contract for #157 and #152

| id | Lean identity | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| C1 | `Singular.encodeState`, `Singular.decodeState` | Given any `State`; when encoded then decoded; then the original returns. `0x00`/`0x01`/`0x02`. | Round-trip row per state | A codec mapping two states to one byte fails the round trip |
| C2 | `decodeState` totality | Given any byte string that is not one of the three; when decoded; then no state is produced and the cage refuses the leaf. | Refusal rows for `0x03`, empty, multi-byte | A permissive decoder accepts `0x03`; that row must then fail |
| C3 | naming-era bytes | Given a leaf byte string from the naming era; when decoded; then it is not a valid leaf. | Refusal row over a naming-era byte string | A decoder that still accepts naming bytes fails this row |

### Statements (interface §6 and §4)

Each proved without `sorryAx`, at these bound identities.

**Reachability is a hypothesis, not a weakening.** Over an arbitrary `State`
value the supply laws are simply false, so every row below quantifies over states
**reachable from genesis by folds** — `Singular.Reachable` (Model.lean:297), the
predicate `WellFormed` already uses. The interface's "unconditionally" means *no
application hypothesis*, never *no reachability hypothesis*. A row restated over
all syntactic states is wrong, not stronger.

| id | Lean identity | Given / When / Then |
|---|---|---|
| I-P1 | `Singular.Statements.no_tree_change_without_approval` | Given any reachable state and any fold; when a tree change occurs; then the request carried an approval under the pinned application policy, and the pins are equal before and after. |
| I-L1 | `Singular.Statements.booked_at_most_once` | Given any reachable state; when a batch is folded; then a key is booked at most once at a time, the batch is atomic, and each request is spent once. |
| I-S1 | `Singular.Statements.terminal_attestation_sound` | Given any reachable state and a terminal token for `key`; when its provenance is traced; then it was minted by a fold that accepted `Read Terminal` for `key`, which holds only if the leaf was `Known Terminal`. No attestation of an `Active`, `Absent` or `Unknown` key exists. |
| I-S2 | `Singular.Statements.terminal_attestation_permanent` | Given any reachable state `s` and a terminal token valid in it; when any sequence of folds is applied; then it is valid in every later state, because a `Terminal` leaf admits no edge that moves it. |
| I-S3 | `Singular.Statements.biconditional_supply_sync` | Given any reachable state and any key and either biconditional kind; when the supply is counted; then it is 1 iff the key is in that token's state, and 0 otherwise — unconditionally. Identity is `(policy, key)`; a key recreated after `deleteActive` carries the same identity, by design. |
| I-O1 | `Singular.Statements.occupancy` | Given any reachable state and a key whose leaf is `Active` or `Terminal`; when a booking edge is folded; then refused; and when the key is not taken, it succeeds. |
| I-T1 | `Singular.Statements.termination` | Given any reachable state and a key whose leaf is `Known Terminal`; when any edge is attempted; then refused, so the key stays terminated forever and is never re-booked. |
| I-W1 | `Singular.Statements.active_witness_unique` | Given any reachable state and any key; when active tokens are counted; then at most one, and exactly one iff the leaf is `Known Active`. |
| I-W2 | `Singular.Statements.absent_witness_unique` | Given any reachable state and any key; when absent tokens are counted; then at most one, and exactly one iff the leaf is `Known Absent`. |
| I-W3 | `Singular.Statements.terminal_witness_plural` | Given any reachable state and a key whose leaf is `Known Terminal`; when terminal tokens are minted or burned; then any number may exist, all true, all freely burnable; and any exists only if the leaf is `Known Terminal`. |
| I-W4 | `Singular.Statements.witness_kinds_exclude` | Given any reachable state and any key; when the outstanding witnesses are examined; then at most one **kind** is outstanding: a consumer finding one kind knows the other two do not exist, without reading the state. |

### Instances

| id | Given / When / Then | Observation | Control |
|---|---|---|---|
| OA1 | Given the open application — a policy that certifies everything; when each statement I-P1…I-W4 is instantiated at it; then all hold. The smallest instantiation, proved **first**. | Instantiation of every statement at the open policy | A statement that silently assumed naming's policy fails to instantiate |
| NM1 | Given naming; when a record is registered; then the record UTxO holds the active token and the trie carries only `Active`. | Naming corpus registration rows | A record whose data sits in the leaf fails D1 |
| NM2 | Given a live record; when `maintain` or `recover` runs; then the application UTxO is spent and **the trie is untouched** — root equal before and after. | Root-equality rows for both moves | A maintain that changes the root is refused |
| NM3 | Given retirement; when it completes; then it is `updateTerminal`, and `over_terminal` and `naming_delete_refused` hold over the new model. | Re-stated naming statements at their preserved identities | Re-admitting either statement turns the build red |
| NM4 | Given naming's approval policy; when a request arrives on each of the six edges; then it is certified exactly per **R-NM4**: `insertAbsent` for anyone; `updateActive` on the signature of the controller who will own the record; `deleteAbsent` on the signature of the refund address the `insertAbsent` request named; `insertActive` on the controller's; `updateTerminal` on the quorum's; `deleteActive` never. | One admission row per edge | Per edge: an approval for `deleteActive` at all; a `deleteAbsent` approval under **any signature but the refund address's**, and one under **no** signature; an `updateActive` approval **without** the controller's signature; an `updateTerminal` approval below quorum — each refused |
| NM5 | Given the naming recovery rows and `WellFormed`; when re-stated over the new model; then their meaning is preserved. | The lifecycle corpus replays under the new identities | A dropped recovery row is missing from the regenerated manifest |

### Mutants — the four named in #154

Each must break **its** law. A compile failure is **not** a behavioral kill and
may not be presented as one. For each mutant the ledger records, per mutant:

1. the mutated definition **elaborates** — so what is being measured is a
   semantic change, not a syntax error;
2. the kill is **either** a named statement whose proof no longer closes, with
   the failing goal recorded, **or** an executable corpus row whose verdict
   flips — and which of the two it is, is recorded, never left implicit;
3. a **positive control** on the unmutated model showing that same statement
   proves, or that same row holds.

| id | mutant | must break |
|---|---|---|
| M1 | mint a second active token for a key | I-W1, and I-S3 for the active kind |
| M2 | mint an absent token for an active key | I-W2 and I-W4 |
| M3 | attest an active key (`Read Active` admitted) | I-S1 |
| M4 | leave the absent token outstanding on `updateActive` | I-S3 and I-W4 |

`docs/mutants.md` today declares every row PROPOSED / NOT EXECUTED and defines a
kill as "the mutated model no longer builds". Both statements are superseded for
these four: they are executed, and a build failure alone does not count.

### R12 — the retirement map for the 44 generic declarations

| id | obligation |
|---|---|
| R12 | Slice A's handback gives **each** of the 44 declarations in the base `lean/theorem-debt.json` exactly one disposition: **carried** (same meaning, same or new identity), **renamed** (to which exact identity), or **retired** (with the reason). |

This exists because `over_terminal` is in `Singular.Statements`
(Statements.lean:142), not the naming layer, and T1 **supersedes** it rather than
preserving it — as do `over_no_representative`, `resolve_over` and the `consumer`
theorems in the same module. Without the map an auditor cannot tell a dropped
guarantee from a rename, and the page-against-manifest check (X1/A7) passes
happily on a manifest that quietly lost rows. The map is checked against the base
manifest, so a declaration that appears in neither the new manifest nor the map
is a finding.

### Slice-A audit obligations beyond the gate

The gate cannot judge these; the independent auditor must.

| id | obligation |
|---|---|
| Y1 | **The four mutants.** Each elaborates; the kill is a named statement whose proof no longer closes **or** a corpus row whose verdict flips, recorded per mutant; each with a positive control. No compile-failure kill. |
| Y2 | **`tools/check_model.py` still checks what it claims.** The author rewrites the file gate leg A2 runs, so A2 judges through an artifact under the author's control. Diff it against base and demonstrate, with **one seeded control each**, that exact-identity matching, PROVED-only-from-standard-axioms, STATED-for-admitted, byte-for-byte corpus regeneration and the keyword/proof-hole audit each still **fail** when violated. |
| Y3 | **R12's retirement map** is complete and honest against the base manifest. |

### A starting-state defect this slice must correct

Found by falsifying gate-a against the base tree, and recorded here rather than
absorbed silently (constitution, principle V — the rule applies to already
merged and released work).

`lean/theorem-debt.json` carries **44** proved declarations.
`docs/theorems.md` — whose stated purpose is an *"Exact declaration
inventory"* — has **41** table rows and asserts *"All 41 declarations are
PROVED"*. Three proved statements appear nowhere on the page:

```
Singular.Statements.empty_fold_error
Singular.Statements.empty_fold_never_ok
Singular.Statements.nonempty_fold_invokes_consumer
```

This shipped in the published v0.6.1 docs. The register under-reports the
statements that exist, and its total is wrong.

Two obligations follow:

| id | obligation |
|---|---|
| X1 | The rewritten `docs/theorems.md` equals its manifest exactly — every declaration present, the total derived rather than asserted. |
| X2 | **The check becomes permanent.** `tools/check_model.py` gains the page-against-manifest cross-check, so the class cannot recur once this ticket's gate is gone. Nothing in the repository checks it today, which is why a three-row gap survived a release. The check must be seen to fail before it is trusted. |

X2 is the finding turned into a property. A repair that only fixes the three
rows leaves the next divergence undetected.

## Invariant rows — slice B (#163)

| id | Given / When / Then | Observation | Control |
|---|---|---|---|
| B1 | Given the frozen slice-A interface; when the generic profile is played; then the seven edges and the read are exposed, with the token movement shown per edge. | Simulator profile exercised over every edge | An edge missing from the profile fails the denominator check |
| B2 | Given each illegal combination of R3; when attempted in the simulator; then it is refused **by name**, matching the model's reason. | One named refusal per combination | A generic "invalid" refusal that does not name the combination fails |
| B3 | Given the new corpora; when the simulator replays them; then every finite row agrees with the Lean-computed result. | Full-corpus replay with an executed/discovered denominator | A single altered expected verdict turns the replay red |
| B4 | Given the naming profile; when a retired key is read; then the Over witness is minted by a **folded read** and can be freely burned. | Naming profile journey | Minting it without a folded read fails |
| B5 | Given the front page and `docs/design.md`; when their counts are read; then they equal what actually replays. | Counts derived from the replay, not hand-written | A stale count fails its check |
| B6 | Given every changed page; when `just check-presentation` runs; then speech is fresh and stamped. | `just check-presentation` exit 0 | An unstamped page fails |
| B7 | Given the transcription; when `docs/LEAN-CLARITY.md` is written; then it records what the formal artifacts did and did not communicate to the transcriber. | The page, authored from the transcription experience | — (a record, not a check) |

Slice B states its finite-model limits explicitly: the simulator exhibits the
corpora it replays and proves nothing universally.

## Gates

Three frozen artifacts, each proved able to fail **per failure class** before the
work it judges begins, and each audited blind before that work starts.

**Gate A — slice A, focused**, version `a3`. Deliberately **not**
whole-repository green, since the simulator is red until slice B by
construction. Classes: the gate's own hash-bound header; Lean elaboration —
which is **also** where axiom cleanliness is bound, because `Singular.Audit`
throws during elaboration on any non-standard axiom, so a `sorryAx` reddens the
build itself; every discovered `*Statements` module actually reaching the
compiled axiom report; exact identity/manifest discipline with byte-for-byte
corpus regeneration; removed-vocabulary absence from the **elaborated
environment**; the refusal set of R3 including the refused reads, with distinct
reasons where the distinction is observable; the owned pages' declaration table
equal to its manifest; fresh speech stamps; and the diff staying inside slice A's
surface **measured from the frozen planning head**.

What gate A does **not** do, stated so a green run is not misread: it does not
execute the four mutants (Y1), does not verify `tools/check_model.py` still
checks what it claims (Y2), does not judge the retirement map (Y3), and does not
claim the repository green. Those are the independent audit's.

Changes from `a2`, all from A-002:

- **A3 is dropped, not weakened.** It could not flip independently of A1:
  `Audit.lean:25` throws at `lake build` on any non-standard axiom, so the
  build is already red before a separate axiom leg runs — including under the
  "clean seed" the v2 packet proposed. A leg that cannot fail on its own is
  worse than no leg, because it looks like a second opinion. The class is now
  documented against A1 and A4, which do bind it, and no build is spent proving
  a leg that cannot fail.
- **A5's removed list gains** `Singular.Operation` and
  `Singular.Config.representativePolicy` — the latter is renamed to
  `activePolicy`, so the old name surviving is exactly the failure to catch.
- **A6 gains the refused reads.** `Read Active` and `Read Absent` were in R5 but
  in neither R3 nor A6's required set, so the structural guard S1 depends on was
  unbound by the gate.
- **A9 diffs from the frozen planning head, not the base, and drops `specs/`
  from its allowlist.** As written in `a2` the author could rewrite the mandate
  it is judged against and the gate would allow it.

**Gate B — slice B, focused.** Classes: simulator build and self-test; full
corpus replay agreement; named refusal of every illegal combination; browser
checks; the count checks of B5; presentation and speech stamps.

**Ticket gate — the atomic result.** `nix develop --quiet -c just ci` exit 0 plus
both focused gates, run on the combined tree, plus green GitHub CI on the exact
pushed head. This is the only gate that may claim the repository green.

## Evidence required at acceptance

- `nix develop --quiet -c just model` exit 0 and `nix develop --quiet -c just ci`
  exit 0 on the combined tree;
- compiled axiom report clean for every statement, no `sorryAx`;
- the four mutants each producing their intended law failure, each with its
  positive control, each classified as statement-kill or row-kill, none
  classified from a compile failure;
- regenerated corpora, manifests and every owned page corresponding to the
  accepted revision, with fresh speech stamps;
- a fresh independent Opus `lean-auditor` report for slice A and a fresh
  independent Opus `lean-simulations-auditor` report for slice B, each bound to
  its candidate and base;
- green GitHub CI on the exact pushed head, which is pushed once, never red.

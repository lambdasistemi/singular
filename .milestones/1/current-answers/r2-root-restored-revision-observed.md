# R2 contract packet, revision 2 — current-contract columns + faithful request mapping

Commission: root NOTE-125 via t87b NOTE-025 (replaces the rev-1 packet in
place; rev-1 retained in root freeze `handoffs/r2-root-reviewed-packet.md`,
sha256 `75fae24f…`). Seat `%993`, worktree `/code/singular-e18-blaster`,
HEAD `970b15917a76982ad6db2b1c8efaaaa5f5d15969`. Scope boundary (kept):
no edit to accepted `lean/`, current producer/consumer source, or shared
coverage schema; no ledger campaign, push, merge or release. R2 and all
required debt remain M1. Stop for owner review.

Frozen inputs (root `handoffs/r2-root-contract-review.json`,
`2026-09-12T23:26:48Z`): rev-1 packet; observed `ModifyWitness.lean`
(`d5872428…`); observed `GradingSpan.lean` (`7d85737f…`); **current draft**
`state.ak` (`4c610231…`, source
`/code/singular-e17-issue-77/onchain/validators/state.ak`); **current
draft** `request.ak` (`aeacc217…`, same tree). Frozen copies read at
`/tmp/projects/singular/milestone-1/handoffs/r2-root-current-draft-state.ak`
(307 lines) and `r2-root-current-draft-request.ak` (112 lines); line
citations below refer to those frozen files.

## 0. Disposition of rev-1 (what was withdrawn and why)

Amended by NOTE-026 (root `handoffs/rejected-retirement-custody-root-
control.json`, `2026-09-12T23:36:36Z`; raw project
`/tmp/singular-root-rejected-custody-Jdn75Y`; frozen application source
`handoffs/rejected-custody-root-application.ak`, sha256
`24f4e8aa52efb99d553d925c70da7c3c20141f4f8510052ea84be7ee6760f8c8`).
Root ran bounded current-draft evidence: `aiken check` exit 0, 24/24
(12 unit + 12 property), including 5/5 `root_custody.tests` (titles and
verdicts in §1.b2). Staged sources pinned by sha (consumer.ak
`3db45e20…`, retirement_custody.ak `ab03efbf…`, state.ak `4c610231…`,
request.ak `aeacc217…`); deps stdlib `5jnqnd8z…-source` (same store path
as the t87b span). Scope stated by root: synthetic validator-context
tests, NOT ledger inclusion, actual program-hash binding, or reachable
naming history.

- WITHDRAWN as contract proposal: P1 ghost stuttering (a ghost assertion
  does not make a retained request absent); Option I (new on-ledger
  rejection outputs — unnecessary scope expansion, root-rejected);
  Option M as a standalone reject arm (insufficient for one real fold
  containing processed AND rejected requests); the absent-request-999
  grading as an R2 counterexample (deleted from `GradingSpan.lean`,
  replaced by §3); KERI excerpts as establishment (analogy-only
  background henceforth, §2.4).
- RETAINED as bounded historical result: the `5bd7c79` state-only
  funded CEK HALT (Leg B: 2,000,000 in, 1,999,500 refund, root zeros)
  — labeled ONLY as historical state-program execution (§1.a). It is
  not a current six-field transaction, request-validator run,
  registered-consumer run, ledger consumption, or permissionless-full-
  processing proof. Empty signatories establish none of those facts.

## 1. Three columns

### (a) Fixed historical baseline (executed, bounded)

`blaster/SingularBlaster/ModifyWitness.lean` at `5bd7c79` state program:
- Leg A (pre-existing): ownerless `Modify([Rejected])`,
  `RequestDatum(Request{token, KEY_OTHER, 0x6162, Insert(0x6364), tip
  500, submitted 1000})`, range lower `Finite 5000` vs threshold
  `1000+2000+1000-1 = 3999` (entirely-after → `is_rejectable`), empty
  signatories → HALT. No ADA: owners empty, refund checks inert.
- Leg B (this lane, additive only): same shape, request carries
  2,000,000 lovelace, refund output pays pubkey `KEY_OTHER` exactly
  1,999,500 (`owed = maxRefunded = 2M − 0 fee − 1·500 tip` under the
  HISTORICAL aggregate rule) → HALT. Uniqueness: fee=0, n=1 forces
  `owed == maxRefunded`, so HALT ⟺ value exact.
- Bound: old owner-bearing datum, pubkey request address, historical
  aggregate fee deduction, state-side CEK only. Nothing current. Kept
  SEPARATE from the current accepted Insert case (§1.b2) below.

### (b) Current agreed six-field producer/interface source (source-only)

State is six-field `root/tip/process_time/retract_time/
representative_policy/consumer_pin` — owner REMOVED (ownerless registry,
permissionless fold; `End -> fail` and `Sweep(_) -> fail` for every
party). Exact agreed semantics (frozen draft citations):

- **Pinned consumer withdrawal on every nonempty batch**
  (`state.ak:252-264`): `consumed = len(actions) − len(actionsTail)`;
  `expect consumed > 0`; `expect actionsTail == []`; `list.any
  withdrawals (credential is Script(hash) with hash == consumer_pin)`.
  Presence of the exact withdrawal credential forces ledger execution
  of that script; absence refuses; any other script does not satisfy.
- **Empty and surplus refusal** (same lines + NOTE-020 comment): empty
  processing refuses (no matching request consumed, no batch; a dummy
  withdrawal or a nonempty action list with no matching request does
  not manufacture nonemptiness); surplus unconsumed actions refuse;
  missing actions refuse at `uncons`. Checked before hook/fee/refund
  failures — each control fails on its own reason.
- **Exact request/action pairing**: one `uncons(actions)` per
  matching-token `RequestDatum` input, in input order; processed
  (`UpdateAction`) vs rejected (`Rejected`) decided per position by
  the redeemer list.
- **Per-rejected-owner floor, no aggregate fee** (`state.ak:128-143`,
  `:168-180`, `:191`): only `Rejected` rows accrue owners, at
  `inputLovelace − stateTip` (`state.ak:138`); `fee: _tx_fee` is
  explicitly ignored (`state.ak:191`); each row's output must carry
  `>= owed` (`state.ak:175`, per-owner no-underpayment, no upper
  envelope — min-UTxO top-ups from funding inputs may only add);
  processed rows accrue nothing (their value may leave to a checkpoint
  lock or change; the pinned hook judges the allocation). Totals
  close by ledger conservation + state no-drain
  (`output lovelace >= input lovelace`) + visible funding inputs.
- **Request `Contribute` checks** (`request.ak:44-67`): exact
  `requestToken == cageToken`; state input by ref carries the state
  token; `stateSpentWithModify` (tx redeemers map `Spend(stateRef)` to
  a `Modify(_)` redeemer); `in_phase1(range, submitted_at,
  process_time) || is_rejectable(range, submitted_at, process_time,
  retract_time)`.
- Config preservation: `representative_policy` (E-001 repair) and
  `consumer_pin` preserved exactly across every fold
  (`state.ak:209,214`); mint width-checks the pin (28 bytes).

### (b2) Current accepted Insert case (root custody-control tests 1+3)

Same nonempty expired Insert request consumed through
`Modify([Rejected])` (state arm, §1.b) + `Contribute` (request arm,
`request.ak:44-67`) with the exact consumer invoked, root unchanged,
and its per-owner **input-minus-tip** refund — under the CURRENT rule,
not the historical aggregate. Bounded evidence (synthetic
aiken-check validator contexts, NOT ledger/reachability):

- T1 `root_insert_reject_refund_all_three_accept` PASS
  (`fail_immediately`; mem 1219581, cpu 385470383): state +
  request-Contribute + consumer-withdrawal all accept one identical
  synthetic context; refund at the per-owner floor; root unchanged.
- T3 `root_terminal_without_consumer_is_refused` PASS
  (`succeed_eventually`; mem 548223, cpu 169691653): the same context
  WITHOUT the consumer withdrawal refuses at the state hook — trace
  quotes the exact `list.any withdrawals (… hash == consumer_pin …)`
  expect. Missing-consumer-withdrawal refusal stays explicit.

Full command `aiken check` exit 0, 24/24 (12 unit + 12 property),
`finishedAt 2026-09-12T23:40:19Z` (attempt 3; attempts 1-2 were
dependency-setup failures, retained in-project — no test failures).
Raw project `/tmp/singular-root-rejected-custody-Jdn75Y`, tests in
`validators/root_custody.tests.ak`.

### (c) Final integrated execution: UNAVAILABLE (explicit debt)

No current six-field transaction, no request-validator CEK run, no
registered-consumer withdrawal execution, no ledger consumption exists
in this lane. D1: which script hash is genesis-pinned as
`consumer_pin` for the cage under test (not in frozen sources).
D2: current-draft CEK execution of `validModify` + `validateContribute`
+ consumer withdrawal on one batch. D3: ledger submission. D4:
authentic naming setup showing a rejected terminal request actually
holding its representative at the request address (the root T2 case
ASSUMES the holding — conditional only). D5: representative
mint-policy execution for permanent `Over` (the custody exact-burn
positive is component-only). D6: actual compiled script-hash binding
of the staged programs. Nothing in §4-§6 waits on D1-D6 to be *read
and stated*; execution stays debt.

## 2. Registered consumer — only what it enforces (current implementation)

The actual current consumer is `validator consumer()` in
`onchain/validators/consumer.ak` (staged sha `3db45e20…`, same bytes in
the root raw project): withdraw-only (`withdraw(_redeemer:
ConsumerRedeemer, _credential, tx)` runs `check_requests(tx)` +
`check_rep_mints(tx)`; `else(_) → fail` — no spend path, no other
purpose). Per-batch enforced effects, and no more:

- `check_requests` (`consumer.ak:243-267`): at least one spent state
  (`states != []`); every matching-token request input in the tx
  carries lovelace `>= request.tip`. No signatures read — permissionless
  at the consumer level; authorization lives in producer + application
  layers.
- `check_rep_mints` (`consumer.ak:358+`): every positive
  representative-policy mint names a requested name AND equals the
  registry-bound recomputation over a claim control
  (`consumer_representative_name`, NOTE-009 rule). Vacuous when the
  batch mints nothing (the all-rejected case).
- The consumer judges funding and mint lineage, NOT request
  dispositions: no arm reads actions, timing, refunds, or custody. For
  an all-rejected batch its verdict is funding-ok/mint-vacuous plus
  forced execution via the producer's pin check.
- Missing withdrawal refuses at the STATE hook (T3 trace, §1.b2) — the
  refusal is producer-side presence-checking, not a consumer verdict.
- KERI duplicity-retention / freeze-replay specs remain analogy-only
  background (rev-1 §1 retired as establishment): they say nothing
  about what this consumer accepts.

Historical note (superseded for this batch): rev-1 read the keri-side
  `checkpoint_observer.ak` withdrawal arms at the bound revision as the
  consumer family. That reading is replaced by the actual current
  `consumer()` implementation above; keri observer material is not used
  for any batch verdict in this packet.

## 3. Faithful request mapping — executable present-request witness

The absent-999 grading is deleted (code + all ledger prose updated).
New battery in `blaster/abstract/GradingSpan.lean` (abstract recipe
exit 0; Model imported, never reimplemented), reusing `Grading`
fixtures (s2 holding authenticated insert request 7, w0, prop0/out0):

- Case (a) authenticated-but-expired: the SAME identified authenticated
  request (req0 id 7) folds to SUCCESS — SPAN-OK's guards
  (`step s2 (.fold [item0] mint0 [] w0)`, six `true`s). The abstract
  fold takes no validity range, so it cannot see expiry: compiled
  would reject-consume this datum out-of-window (Leg-A shape with the
  range swapped; timing rule source-derived) while abstract admits it.
  Mirror divergence, executable on the abstract side via existing
  guards, cited not re-run. Authentication here is the model flag
  `authenticatedOrigin = true`; compiled-side there is no such flag —
  authentication lives in signatories versus flags respectively (see
  origin distinction below).
- Case (b) modeled unauthenticated: the witness proper. `rOut` (id 8,
  insert, `prop0`, destination 90) is admitted via the EXISTING
  `.outsider` transition — the origin mapping for permissionless
  submission — emerging with `authenticatedOrigin = false`. W1 derives
  exact sets: pre ids `[7]` (from `s2`), post ids `[8, 7]` (cons
  order), applications byte-identical, `used` gains 8; admission
  itself `isOk`. W2: `fold [itemOut]` → `.error
  "unauthenticated-request"` (C2 false, request retained). W3:
  `withdraw 8 …` → `.error "withdraw-insert-only"` (no abstract exit —
  cf. compiled consumption+refund). W4: second admission of 8 →
  `.error "utxo-id-reuse"` — this establishes request UTxO-id reuse
  refusal ONLY, not naming-key non-reuse (entry keys/incarnations are
  a separate domain; corrected per NOTE-027). W5: outsider with `held
  = some rep0` → `.error
  "outsider-cannot-create-representative"`. Structural reason, beyond
  the refusal: the compiled `RequestDatum` carries NO held field
  (token/key/value/owner/tip/submitted only), so abstract held custody
  is NEVER derived from the request row alone — the real request and
  any distinct application/custody inputs are modeled separately,
  always (NOTE-126 mapping rule).
- Origin/authentication distinction (NOTE-027): the same-id outsider
  witness covers the UNAUTHENTICATED-origin mapping only.
  Permissionless processing (empty signatories, Legs A/B) is a
  SEPARATE compiled-side observation — compiled has no origin flags
  at all, so permissionless execution does not establish
  unauthenticated origin, and the outsider witness does not establish
  permissionlessness. Both assumptions are stated separately in §5
  side conditions; neither is derived from the other.
- W6 conditional shape (NOTE-027): `sCust` (request 8 + application 8)
  evaluated under `consume` yields request ids `[7]`, applications
  `[]` (guard `([7], [])`). This input is UNREACHABLE under the
  global fresh/used discipline — `.outsider` demands `fresh s r.id`,
  insert-fold demands `fresh s i.outputId` (`foldOne_insert_iff`),
  release/evolve demand freshness likewise — so an id already in
  `used` can never be re-admitted or re-created, and simultaneous
  request+application id 8 violates the discipline. Kept as a
  CONDITIONAL shape only: `consume` is a pure function, and evaluating
  it on this input validly demonstrates its two-list deletion
  semantics — a request-only removal must be a different function
  because (1) `consume`'s type asserts authority over application
  custody it must not touch, (2) the NOTE-126 separate-inputs rule
  requires row-addressed removal to preserve the request/custody
  separation, (3) W6 shows the consequence conditionally. No
  reachability claimed for `sCust`.
- Terminal/Update-shaped conditional + actual naming layout (NOTE-026/
  NOTE-126): a generic Update-shaped request ASSUMED to hold a
  representative at the request address can return that token under
  the three generic/current handlers (root T2
  `root_terminal_reject_returns_rep_all_three_accept` PASS,
  `fail_immediately`; mem 1456053, cpu 453240719 — conditional behavior
  ONLY, not evidence for the actual naming layout, authentic
  reachability, or a naming escape; fixture values synthetic, reachability
  not promoted). The actual naming layout differs: `application.retire`
  sends the representative to `retirement_custody_hash` and forbids the
  record continuation (frozen `rejected-custody-root-application.ak`,
  sha `24f4e8aa…`, `retire` arm), and the custody script spends ONLY on
  `held_burned_exactly_once` (frozen `retirement_custody.ak`, sha
  `ab03efbf…`; permissionless completion, no withdrawal/redirection
  path). The same synthetic refund context the three handlers accept
  is REFUSED by the actual custody handler without the exact burn
  (root T4
  `root_named_custody_prevents_redirect_after_three_handlers_accept`
  PASS, `succeed_eventually`; trace quotes
  `held_burned_exactly_once`), and the custody exact-burn positive
  (root T5 `root_custody_exact_burn_accepts_component_only` PASS,
  `fail_immediately`) controls ONLY that refusal — it does not execute
  the representative mint policy or prove permanent `Over`. No
  named-retirement escape established; request/custody mapping stays
  separate. Do not infer a naming escape from omission of the custody
  purpose.
- Case (c) unrelated garbage: compiled-only. `mkAction` else-branches
  (`requestToken != tokenId`, non-`RequestDatum`, non-inline datums)
  return `acc` unchanged — no action popped, no owner accrued — while
  the ledger still spends those inputs. Abstractly there are no tx
  inputs at all, so garbage has no counterpart by construction (not a
  gap — a domain absence, recorded so no projection maps garbage to a
  modeled request).

## 4. Smallest explicit transition + refinement relation (specified, not landed)

P1 ghost stuttering and Option I are WITHDRAWN (§0). Returned instead:
a per-item processed/rejected disposition inside the fold, specified
and tested at the spec level (W-series + W6-conditional), not
authorized to land. Preconditions and result, precisely:

DISPOSITION INPUT: the abstract fold takes items paired with the
compiled action at the same position: `(i, d)` with
`d ∈ {processed, rejected}` (the pairing mirrors the compiled
redeemer list order; exact pairing enforced compiled-side by
uncons-per-matching-request, `consumed > 0`, `actionsTail == []`).

- `processed`: EXACTLY existing `foldOne s i` effects, ordering
  unchanged (sequential left-to-right threading). No new semantics.
- `rejected`: require P1 `s.requests.find? (·.id == i.request) =
  some r` (present, same id — never an absent id); P2 timing
  rejectability as an EXPLICIT hypothesis (the Model has no clock;
  the hypothesis is discharged compiled-side by the `is_rejectable`
  arm on the observed window — side condition T1, §5); P3
  request-row-only removal `post.requests =
  pre.requests.filter (·.id != i.request)` with
  `post.applications = pre.applications`,
  `post.entries/approvals/config/used` unchanged (hence W4's
  UTxO-id discipline preserved: the id stays in `used`); P4
  `r.held == none` REQUIRED, else refuse fail-closed (held custody
  can only arrive via separately-mapped custody inputs per the
  NOTE-126 rule — never from the request row, which has no held
  field; a held-carrying rejected request is an explicit open, not
  silently droppable); P5 refund custody/destination carried as a
  refinement side condition (R1, §5), not as abstract value (the
  Model has no value plane). RESULT: logical contribution `[]`
  (no delta); registry/entries/root-equivalent unchanged at rejected
  positions; the step consumes the request row and nothing else.

Why not reuse `consume`: see W6-conditional (§3) — three reasons
(type authority, separate-inputs rule, demonstrated consequence).

## 5. Refinement side conditions + both directions

Side conditions (explicit, each discharged where stated):

- T1 timing: per rejected position, the observed validity window is
  rejectable w.r.t. (`submitted_at`, process/retract times) —
  compiled arm; abstract hypothesis P2.
- C0 consumer invocation/permission: every nonempty batch carries a
  withdrawal from exactly `consumer_pin` (producer presence check,
  `state.ak:252-264`; missing → refusal T3); the invoked `consumer()`
  withdraw runs `check_requests` (≥1 spent state; matching requests
  funded ≥ tip) + `check_rep_mints` (vacuous without mint). No
  signatures at the consumer level; the pin VALUE for the cage under
  test is D1 (unavailable, §1.c).
- M1 pairing: `consumed > 0`, `actionsTail == []`, uncons order —
  compiled checks; empty/surplus refuse on their own reasons.
- F1 funding: fees ride funding inputs visibly; state no-drain holds;
  min-UTxO top-ups only add (per-owner floors, no upper envelope).
- R1 refunds: per rejected owner, output `>= input lovelace −
  state tip` to the owner address; owner↔`refundAddress`
  correspondence assumed (Nat vs credential — refinement assumption,
  stated).
- N1 no-replay: ledger UTxO consumption (statement-backed, no model
  invariant claimed).
- K1 custody: rejected terminal requests with separately-established
  custody are OUTSIDE the request-only mapping until D4/D5 land
  (actual layout §3; no escape inferred from omission).

Forward (compiled accepted batch → abstract result): given an accepted
`Modify` batch (M1, C0, T1 per rejected position, R1, F1) with actions
A paired to matching requests R, the per-item disposition fold over
the mapped items yields: registry/entries unchanged at rejected
positions, `foldOne` effects at processed positions, logical = ordered
processed deltas only, removed ids = exactly consumed ids, `used`
monotone.

Backward (abstract result + realizability → compiled batch): given a
disposition result plus realizability (T1 windows reproducible,
consumer willing to withdraw, i.e. its envelope predicate satisfiable
over the tx; funding inputs cover fees/min-UTxO; request UTxOs present
with exact datums; state input present), there EXISTS an accepted
compiled batch with the same observable effects. Existence claim,
specified-unexecuted (D2/D3).

Distinguishing control (not mere endpoint success): mixed vs
all-rejected differ observably — post request-id sets (mixed removes
processed+rejected ids; all-rejected removes rejected ids only) AND
logical deltas (mixed: ordered processed deltas, possibly nonempty;
all-rejected: exactly `[]`). The W-series + SPAN-OK pin the abstract
endpoints; §4's equations pin the difference.

## 6. Affected statements (exact)

- `fold_iff` (Statements.lean:66-72): C2's meaning changes for mixed
  batches — `foldItems` gains the disposition arm; C1/C3/C4/C5
  unchanged in form (C3 over ordered mixed logical; C4/C5 vacuous for
  pure-rejected nets). The R2 grading now fails C2 on a PRESENT
  request with exact reasons (W2/W3), not on an absent id.
- `foldOne_insert_iff` / `foldOne_terminal_iff`: domain UNCHANGED
  (processed arm reuses `foldOne` verbatim) — conditional on the
  reuse; any deviation reopens both.
- Sequential `foldItems`: needs a disposition-sequence counterpart
  lemma (specified shape: cons case splits on `d`; NOT proved, NOT
  landed — listed so the proof obligation is visible).
- Outsider immortality: UNCHANGED except lifted exactly at the new
  rejected arm — outsider requests gain their one modeled exit
  (rejected-removal with P1-P5); fold/withdraw still refuse (W2/W3
  remain true). The lifting is the R2 closure, nothing more.
- Request/custody/no-reuse consequences: W4 (UTxO-id discipline),
  W5 + RequestDatum-has-no-held-field (separate-inputs rule), W6
  conditional (request-only removal shape). Naming key reuse,
  incarnation handling: untouched, out of scope.
- Adjacent, UNAFFECTED: `retirement_custody` /
  `held_burned_exactly_once` + `application.retire` layout
  (consumer-side, source-cited §3; the proposal neither weakens nor
  strengthens them); existing green processed behavior and legitimate
  nonempty all-rejected processing remain ADMITTED (no ban, no new
  role/signature gate on the `Rejected` arm — settled design).

## 7. What this packet does NOT claim (bounds)

- No quantified proof (finite CEK legs + aiken-check unit contexts +
  statement readings only).
- The five root controls establish: NO ledger submission, NO actual
  compiled script-hash binding, NO authentic naming history, NO final
  producer acceptance, NO migration permission. Fixture values
  synthetic; reachability not promoted.
- Unexecuted, open: entirely-before rejection, multi-request batches,
  mixed compiled batches, non-ADA request assets, request-side
  `Contribute` CEK run, D1-D6 (§1.c).
- KERI material: analogy-only; no keri code executed; nothing about
  keri's implementation claimed.
- The historical Leg-B refund pins lovelace arithmetic of the OLD
  aggregate rule only; min-UTxO top-up behavior unexecuted.
- The accepted register repair does NOT discharge these semantic
  debts (NOTE-126: independent reviewability kept).
- Rev-1 P1/Option-I/Option-M-standalone/999-grading/KERI-establishment:
  withdrawn, retained only in the root freeze for audit.

## 8. Reproduction + restoration appendix

Worktree HEAD `970b15917a76982ad6db2b1c8efaaaa5f5d15969`; lane files
uncommitted for owner review (register 4 byte-untouched since
acceptance; C5 + abstract + ledger-prose + this packet in flight).

```
$ lake build SingularBlaster.ModifyWitness   # Legs A+B HALT guards
Build completed successfully (302 jobs).     # exit 0 (4.24.0)
$ lake build                                  # full blaster lib
Build completed successfully (309 jobs).     # exit 0 (4.24.0)
$ bash blaster/abstract/run-abstract.sh       # G1/G2/G3 + GradingSpan W1-W6
abstract: G1/G2/G3 + GradingSpan receipt executed green   # exit 0 (4.25.0 recipe)
$ bash blaster/check_register_control.sh      # 20 legs, accepted tranche
CONTROL GREEN: legs 0,1,13a true-0; legs 2-12,13b,14-18 (seventeen mutants) true-nonzero attributed  # exit 0
$ aiken check  # root raw project /tmp/singular-root-rejected-custody-Jdn75Y (root-executed)
total: 24, passed: 24, failed: 0 (unit 12, property 12)  # exit 0
$ sha256sum tools/check_model.py | cut -c1-16
60dc1bc73347cd87                              # unchanged live tool digest
```

Restoration record (OWNER-CORRUPTION-FINDING-126): the rev-2 packet
file was found terminating mid-§3 with the literal marker
`...[truncated 8184 chars]` (194 lines + marker). False-completion
evidence preserved two ways, bound to the on-disk receipt:
root-frozen `handoffs/r2-root-truncated-rev2.md` + receipt JSON
(`bytes 10971, sha256
5d8f1e5acb6fb031f9f4e94df1395df95a95a8b36462a60a85e84c80e5110cd2`,
byte-identical to the corrupt file; the NOTE-127 prose 9ef/11895
pair is not present at the stated path and was not used) and lane
copy `handoffs/r2-contract-packet.CORRUPT-126.md`. Restoration:
head (intact §§0-2 through the §3 header) + this fully re-authored
tail (rest of §3, §§4-8 with NOTE-026/126 amendments and NOTE-027
witness corrections), concatenated and verified per the NOTE-027
checklist (headings, tail, marker-absent proof, line/byte/sha counts,
exact final lines, end-to-end disk read) before handoff.

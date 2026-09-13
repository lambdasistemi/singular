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
exit 0; Model imported, never reimplemented), reusing `Grading` fix
...[truncated 8184 chars]
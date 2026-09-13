# R2 contract packet — all-rejected consumption vs the abstract model

Commission: root NOTE-123 via t87b NOTE-024. Seat `%993`, worktree
`/code/singular-e18-blaster`. Scope boundary (kept): no edit to the
accepted Lean model (`lean/`), the producer, or the consumer contract
(`lean/Singular/NamingLifecycle.lean`). Lane-only additions:
`blaster/SingularBlaster/ModifyWitness.lean` (+1 executed funded-reject
leg, existing legs untouched). R2 and every affected invariant remain
explicit M1 debt — this packet proposes relations and options for root
arbitration; it accepts nothing.

Identities: worktree HEAD `970b15917a76982ad6db2b1c8efaaaa5f5d15969`,
tree `cdc99651feac020a3c75072c7c6c7ed67b18d04b` (plus uncommitted
lane changes listed in §8). KERI pin `14a64a4681d3e429fab5877062b5c476c2a4bfe2`
(`git cat-file -t` → `commit`; `git show -s` → `2026-09-07 Merge pull
request #386 from lambdasistemi/fix/383-gate-executability`).

## 1. The two behaviors being compared

**Pinned generic Singular behavior** = `lean/Singular/Model.lean` +
`lean/Singular/Statements.lean` at the frozen base (`fold_iff`,
`foldOne_*`, `step .fold/.outsider/.withdraw`, `consume`), with the
accepted correspondence page
`conformance/coverage/correspondence/fold_iff.md` §5.

**cardano-keri at the pin** = the KERI-on-Cardano specs at
`14a64a4`: duplicity-evidence retention (`specs/24-keystate/spec.md`)
and resolved-evidence replay without submission
(`specs/137-freeze-small/spec.md` US4). KERI facts used (exact
excerpts, `git show <pin>:<path>`):

- K1 — retention, `specs/24-keystate/spec.md:253`:
  `status : Active | FrozenFatal(DuplicityProof) | Closed` — the
  duplicity *proof* is retained inside the status. Consumption-with-
  effect is evidenced, never silent.
- K2 — replay, `specs/137-freeze-small/spec.md:74-86` (US4, P1):
  "Replaying it through the applied checkpoint and
  enforcement-observer boundary must reject **without evaluation
  leading to submission**." No work happens on replay; the checkpoint,
  not UTxO absence, bars re-execution.

Singular is the mirror image on both axes: the rejected request IS
consumed with real ledger effects and no registry trace (§2), and
replay is barred by UTxO absence rather than by a checkpoint (§2.5).
The abstract model expresses neither (§3).

## 2. Compiled side — the all-rejected batch (generic cage)

### 2.1 Exact Rejected branch

`onchain/validators/state.ak`, `mkAction` fold arm (unedited source):

```
Rejected -> {
  expect
    is_rejectable(
      validity_range,
      submitted_at,
      process_time,
      retract_time,
    )
  root
}
```

plus the per-input bookkeeping in the same arm: matching-token
`RequestDatum` inputs pop one action off the redeemer list,
accumulate `inputLovelace` under `requestOwner` into `owners`, and add
to `totalInputLovelace`. Root is returned unchanged.

Refund rule, `validModify` (same file, unedited):

```
let n = list.length(owners)
when n is {
  0 -> True
  _ -> {
    expect [_, ..refundOutputs] = outputs
    let orderedOwners = list.reverse(owners)
    let totalRefunded = sumRefunds(refundOutputs, orderedOwners)
    let owed = totalInputLovelace - tx_fee - n * tip
    let maxRefunded = totalInputLovelace - n * tip
    expect totalRefunded >= owed
    expect totalRefunded <= maxRefunded
```

`sumRefunds` requires each refund output to pay a `VerificationKey(vkh)`
address with `vkh == owner`, in order.

Request-side authorization, `onchain/validators/request.ak:58`
(unedited): `validateContribute` passes when
`in_phase1(validity_range, submitted_at, process_time) ||
is_rejectable(validity_range, submitted_at, process_time,
retract_time)` — the consumed request exits through the `Contribute`
arm's `|| is_rejectable` disjunct (source-derived; the CEK legs below
execute the state side only — labeled, not hidden).

Timing predicate, `onchain/validators/shared.ak:88-98` (unedited):

```
is_rejectable = interval.is_entirely_after(validity_range,
    submitted_at + process_time + retract_time - 1)
  || interval.is_entirely_before(validity_range, submitted_at)
```

### 2.2 Executed reachable setup (CEK, ownerless, both legs HALT)

`blaster/SingularBlaster/ModifyWitness.lean` (lane file):

| element | value |
|---|---|
| request datum | `RequestDatum(Request{token=TOKEN_NAME, owner=KEY_OTHER, key=0x6162, Insert(0x6364), tip=500, submitted_at=1000})` (`foldRequest`) |
| request input | `⟨reqRef=⟨TXID_SELF,1⟩, reqOut⟩`, pubkey address `KEY_OTHER` |
| state datum | `State{owner=KEY_OWNER, None, zeros, tip=500, process=2000, retract=1000}` (`foldDatum ROOT_ZERO`) |
| redeemer | `Modify([Rejected])` = `Constr 2 [List [Constr 1 []]]` (`rejectRedeemer`) |
| range | lower `Finite 5000`, upper `+∞` (`rejectRange`) |
| threshold | `1000+2000+1000-1 = 3999`; `5000` entirely-after → first disjunct true on either `Bool` mapping |
| signatories | `[]` (empty — permissionless, see §2.4) |
| state out | `rejectStateOut`: same address/value, datum `foldDatum ROOT_ZERO` — root unchanged |

- Leg A (unfunded, pre-existing): `runFold rejectCtxOut` → `HALT`
  (guard `/-- info: "HALT" -/`). Request carries no ADA: `owners`
  empty, refund checks inert — consumption + unchanged root executed,
  refund vacuous (recorded in-file, not hidden).
- Leg B (funded, NEW this packet): request carries 2,000,000 lovelace;
  outputs `[rejectStateOut, rejectFundedRefundOut]` with the refund
  paying `reqAddr` (pubkey `KEY_OTHER`) exactly **1,999,500**
  (`owed = maxRefunded = 2,000,000 - 0 (fee) - 1·500 (tip)`).
  `runFold ⟨rejectFundedTxInfo, …⟩` → `HALT` (guard green,
  `lake build SingularBlaster.ModifyWitness` exit 0, 302 jobs).
  Uniqueness without a second leg: fee=0 and n=1 force
  `owed == maxRefunded`, so HALT ⟺ refund value == 1,999,500 exactly;
  `sumRefunds` order/destination checks pin the payee to `KEY_OTHER`.

### 2.3 Refund destination/value (backing labeled per claim)

- Destination `KEY_OTHER` + value `1,999,500` + ordering: EXECUTED (Leg B).
- General rule (`owed`/`maxRefunded` bounds, min-UTxO top-up comment):
  SOURCE-DERIVED (`validModify`, excerpt §2.1), not executed beyond Leg B.
- Request-side `Contribute`-via-`is_rejectable` authorization:
  SOURCE-DERIVED (`request.ak:58`), not executed.

### 2.4 Request origin, timing, consumer permission

- Origin: the executed request is owner-keyed (`KEY_OTHER`) but the
  legs run with **empty signatories and HALT** — rejection is
  permissionless on the state side. No `authenticatedOrigin`-style
  gate exists in the compiled fold path. The closest modeled origin
  is `Action.outsider` (see §3.3).
- Request type/datum: `Insert(0x6364)` under key `0x6162`, tip 500,
  submitted_at 1000 — exact `foldRequest` above. An *insert-shaped*
  request is rejected purely on timing; the value is never inspected
  by the `Rejected` arm.
- Timing: entirely-after rejection at range lower 5000 vs threshold
  3999 (§2.2). The entirely-before disjunct is unexecuted (open leg,
  not claimed).
- Consumer permission: none required (ownerless HALT, both legs).
  Against K2: Singular needs no checkpoint because the UTxO is gone.

### 2.5 No-replay consequence (ledger-level, statement-backed)

The request input is *spent*: a second transaction naming `reqRef`
cannot be ledger-valid (UTxO absence). No model invariant is involved
— `lean/` has no replay theorem for requests, and none is claimed.
Contrast K2: keri bars replay by checkpoint evaluation *without*
submission; Singular bars it by prior consumption *with* effects
(refund paid, fee/tip taken).

## 3. Abstract side — what the model says (and cannot)

### 3.1 Affected theorem and clauses (exact)

`lean/Singular/Statements.lean:66-72` (`fold_iff`):

```
step s (.fold items mint net w) = .ok t ↔ w.nativeSpend = true ∧      (C1)
  foldItems s items = .ok t ∧                                         (C2)
  sameNet t.logical mint = true ∧                                     (C3)
  (nonzero mint = true → w.representativeMint = true) ∧               (C4)
  (actionNonzero net = true → w.applicationMint = true)               (C5)
```

The executed R2 grading (`blaster/abstract/GradingSpan.lean`, abstract
recipe exit 0): `itemR = { request := 999, … }` names a request absent
from `s2`, so `foldItems s2 [itemR] ≠ ok` AND
`step s2 (.fold [itemR] [] [] w0) ≠ ok` (guard `(false, false)`).
Precise clause effect: **C2 is false** (`foldOne` throws
`"request-unavailable"`); C1 holds (`w0.nativeSpend`), C3 holds
vacuously (no logical vs empty mint — sameNet over empties), C4/C5
hold vacuously (empty mint/net). The composed claim is FALSE while
the compiled component HALTs — the checker direction that must fire
RED here and GREEN on SPAN-OK is pinned in-file.

Pre/post abstract state for the proposed grading: pre `s2` (registry
holding insert request 7); post — none (step fails, no `Result`).
There is no abstract post-state with "request 999 consumed, root
unchanged, 1,999,500 refunded" because `.fold` has no value
accounting (`conformance/coverage/correspondence/fold_iff.md:181`:
"No **fees, tips, bonds or refund routing** — `.fold` has no value
accounting at all.").

### 3.2 The two sub-gaps

- (a) **No consume-without-logical op.** `Model.foldOne` always
  produces a logical delta on success (insert `+1` / terminal `-1`
  per `foldOne_insert_iff` / `foldOne_terminal_iff`); `consume`
  removes the request but only inside a logically-effective step.
  The compiled `Rejected` arm consumes with *empty* logical effect —
  inexpressible.
- (b) **No timing input.** `foldOne`/`step .fold` take no validity
  range, no `submitted_at`, no process/retract windows. Mirror
  divergence (statement-backed, no new execution needed): the SAME
  abstract success (SPAN-OK: `step s2 (.fold [item0] mint0 [] w0)`,
  guard `(true,true,true)`) corresponds to TWO compiled outcomes —
  HALT-with-root-advance in-window (`foldRange`) and
  HALT-with-reject-consumption out-of-window (`rejectRange`). The
  abstract fold cannot distinguish them.

### 3.3 Outsider immortality (statement-backed)

`step .outsider r` (`Model.lean:238-242`) admits any fresh, held-free
request with `authenticatedOrigin := false`. Such a request can never
leave the abstract registry: `foldOne` throws
`"unauthenticated-request"`; `step .withdraw` throws
`"withdraw-insert-only"` (requires `r.authenticatedOrigin`). It is
immortal abstractly — while compiled consumes + refunds it (Legs A/B
are ownerless and check no origin flag). This is the sharp form of R2:
not just "absent request fails", but "present-but-rejected requests
have no abstract exit at all".

## 4. Garbage separation (exact compiled rule)

`mkAction` (`state.ak`, unedited) skips — returning `acc` unchanged,
consuming no action, accruing no owner — inputs that are:

- non-`InlineDatum`, or datum not a `RequestDatum`;
- `RequestDatum` with `requestToken != tokenId`.

Such inputs are still spent as ledger inputs (their value is NOT
added to `totalInputLovelace`, no refund is owed for them), but the
validator imposes nothing about them. Sharp line: **modeled request
(consumed + refund obligation + action popped) vs garbage
(fold-ignored, no obligation)**. The abstract model has no counterpart
for either half of the garbage case (no ledger inputs exist
abstractly) — the separation is compiled-only, recorded here so no
projection maps garbage to a modeled request.

## 5. Proposed projection/stuttering relation (for arbitration, not landed)

Requirement (from commission): account for request consumption,
refund/no-replay, and the nonempty-batch obligation; must NOT erase
real consumed work into an empty fold.

Proposal P1 — **ledger-ghost stuttering**: relate one compiled
all-`Rejected` batch step to an abstract stutter
(`t.state = s.state` restricted to registry/entries/root) PLUS an
explicit ghost ledger
`consumed : List Nat` (request ids), `refunded : List (Nat × Int)`
(id → lovelace), with the relation demanding: every consumed id was
`In s.requests` pre-step and is absent post-step; every refunded pair
matches a `RequestDatum` owner/value in the batch with
`owed ≤ v ≤ maxRefunded` under the batch fee/tip; the batch is
nonempty; root/entries/registry identical. The ghost advances — the
step is observable in the relation — so nothing is erased into
`.fold []`. Faithful on legs A/B; it does not cover the entirely-before
disjunct (unexecuted, stays open).

Why not `.fold []`: an empty fold keeps `s.requests` intact and moves
no value; relating consumption to it would make "request present" and
"request consumed+refunded" indistinguishable — exactly the erasure
the commission forbids. P1 keeps them distinct via the ghost.

## 6. Smallest behavior-preserving options (root arbitration)

Neither is landed; both preserve all green endpoints and existing
theorems.

- **Option M (model extension, preferred for precision):** add ghost
  fields `consumedRequests : List Nat` and `refundsPaid : List (Nat × Int)`
  to `Model.State` (default `[]`), plus a `step` arm
  `.rejectConsume (ids)` that requires each id `In s.requests`,
  removes them (`consume` chain), appends the ghost entries, and
  returns empty logical. Scope: 2 new fields, 1 new action/arm, 0
  changed existing arms; `fold_iff` untouched (the arm is outside
  `.fold`); existing proofs recheck with defaults. Effect: R2 becomes
  expressible; the ghost still needs a refinement proof to ledger
  value movement (new debt, named).
- **Option I (implementation correction, heavier):** emit an on-ledger
  rejection-evidence output (e.g. datum naming the rejected request
  id + action index) so consumption leaves a registry-adjacent trace,
  keri-K1-style. Scope: `state.ak` output construction + new datum
  shape + offchain indexing; changes the compiled tx shape (all
  existing CEK legs re-run). Effect: narrows the R2 gap from the
  compiled side but does not by itself create the abstract op —
  still needs Option M for the mapping.

Recommended arbitration: land P1 as the stated relation + Option M as
the model debt ticket; Option I only if root wants K1-style evidence
on-ledger. **Do not restrict legitimate nonempty all-rejected
processing** (permissionless rejection is settled design per the
correspondence page §6 + `specs/protocol/spec.md:117`): no new
signature/role gate on the `Rejected` arm in either option.

## 7. What this packet does NOT claim

- No quantified proof (finite CEK legs + statement readings only).
- Entirely-before rejection, multi-request batches, mixed
  Update/Rejected batches, non-ADA assets in requests: unexecuted,
  open.
- Request-side `Contribute` CEK execution: open (source-derived only).
- KERI comparison is spec-level (pinned specs quoted); no keri code
  executed, no claim about keri's implementation — only the two
  disposition contrasts in §1 (retention K1, replay-without-submission
  K2), each with exact provenance.
- The funded leg pins lovelace arithmetic only; min-UTxO top-up
  behavior (`validModify` comment) is unexecuted.

## 8. Reproduction appendix (commands, raw outputs, true exits)

Worktree HEAD `970b15917a76982ad6db2b1c8efaaaa5f5d15969` (clean at
packet-writing time except the lane files below; no commit per
instruction — all tranches uncommitted for owner review).

Lane diff at packet time (9 files, all `blaster/` + owned gates):
`EVIDENCE.md`, `MAPPING.md`, `SingularBlaster/DdfcSpan.lean`,
`SingularBlaster/ModifyWitness.lean` (+funded-reject leg),
`abstract/GradingSpan.lean`, `check_register.py`,
`check_register_control.sh`, `gen_register.py`,
`obligation-register.json`.

```
$ git -C /code/cardano-keri cat-file -t 14a64a4681d3e429fab5877062b5c476c2a4bfe2
commit
$ git -C /code/cardano-keri show -s --format='%H %ci %s' 14a64a4681d3e429fab5877062b5c476c2a4bfe2
14a64a4681d3e429fab5877062b5c476c2a4bfe2 2026-09-07 17:18:56 +0100 Merge pull request #386 ...
$ lake build SingularBlaster.ModifyWitness   # funded-reject HALT guard
Build completed successfully (302 jobs).     # exit 0
$ lake build                                  # full blaster lib
Build completed successfully (309 jobs).     # exit 0
$ bash blaster/abstract/run-abstract.sh       # G1/G2/G3 + GradingSpan (R2 (false,false) + C5 pair)
abstract: G1/G2/G3 + GradingSpan receipt executed green   # exit 0
$ bash blaster/check_register_control.sh      # 20 legs
CONTROL GREEN: legs 0,1,13a true-0; legs 2-12,13b,14-18 (seventeen mutants) true-nonzero attributed  # exit 0
$ sha256sum tools/check_model.py | cut -c1-16
60dc1bc73347cd87                              # unchanged live tool digest
```

KERI excerpts verified via `git show <pin>:specs/24-keystate/spec.md`
(lines ~106, ~253) and `git show <pin>:specs/137-freeze-small/spec.md`
(lines 65-110) — quoted in §1.

# Mandate: ticket 494, protected rejection in the Lean model

This page is the whole contract a coder and an auditor are given for ticket 494. It binds the
work to an exact tree, quotes the rulings that govern it, lists the acceptance items with the
check that proves each, names what is out of scope, and states the evidence the pull request will
carry before any work starts. The coder and the auditor named below are launched only after the plan,
rebased onto the current main, has been reviewed.

## Story

As the epic owner reviewing this mandate, I read one page and find every fact a coder needs and
every limit a coder must respect, so that no coder wanders into a neighbouring ticket and no
auditor judges against a stale tree.

## Binding

| Field | Value |
|---|---|
| Ticket | 494 under epic 498 |
| Worktree | `/code/singular-issue-494` |
| Branch | `feat/494-protected-rejection-rule` |
| Base commit | `e7b55ac9` (main after the two-edge model, the command-line split, fold selection and the negative host); the plan was first written on `e3c9ab01` |
| Runtime root | `/code/singular-protected-rejection/.orch/protected-rejection/to-494-sonnet-2` |
| Lean revision | `lean/` at `e7b55ac9`; toolchain 4.27.0 pinned by `lean-toolchain` |
| Constitution | `.specify/memory/constitution.md` version 1.15.0 at `e7b55ac9` (the effects-and-state principle was added there), moving to 1.16.0 in this ticket |
| Specification set | the pages of `specs/494-protected-rejection-rule/`; their hashes are recorded in the ticket owner's journal at freeze |
| Earlier attempt | pull request 508, head `a7224021`, base `23964e66`; reference only, never rebased, retargeted or merged; superseded by this ticket's pull request |

The ticket touches no shipped command line. It changes the Lean model and everything generated
from or checked against it; the operator command that will one day carry the rule belongs to
tickets 495 and 496.

## The paramount story

As a requester, I book a valid request and observe that a permissionless processor cannot cancel
it and collect its tip without satisfying an explicit rejection rule.

## Rulings in force

The three rulings that decide the rule are quoted here in full, as the operator gave them, and again
in the brief of each slice that implements them. The [decisions](decisions.md) page gives their
stories. The rulings from the epic owner's brief of 9 October 2026 that bound this ticket follow.

### A lifecycle mismatch permits immediate rejection

> Authenticated incompatibility with the current lifecycle state permits immediate rejection even
> when a later transition could make the request eligible.

Refund amounts are unchanged by it, and ticket 361 is not resolved by it.

### Expiry follows both windows

> expiry-only rejection after both the processing and owner's reclaim windows end ... The expiry
> threshold is therefore submission time plus processing duration plus reclaim duration.

### A batch is judged on the state its earlier actions left

> Each action is judged against the state left by preceding actions in the same ordered batch.
> Rejection evidence binds that intermediate registry state/root.

### A request naming an excluded edge is rejectable at once

Epic owner ruling of 9 October 2026, as an application of the first ruling and not a new operator
decision: the first ruling admits rejection on "authenticated incompatibility with the current
lifecycle state". `Singular.transition` gives no successor for an excluded edge at any leaf, so such a
request is incompatible with every current state and is rejectable at once with the lifecycle evidence.

### What the public suite shows until the validators change

Decision of 9 October 2026 (operator ruling, option B): this ticket merges alone, ahead of ticket 495.
After it the suite shows two rows, and the second is never counted as passing.

- The rejection at once, with lifecycle evidence, of a request that cannot be folded: model and chain
  both accept and the owner is refunded. This row is green.
- The rejection, inside the windows, of a foldable request: an `insertActive` request for a key not yet
  registered. The model refuses and the chain accepts. The row is published as unmet by ruling, with a
  tripwire that turns red unless ticket 495 changes the validators so that the two agree; ticket 495's
  acceptance includes that flip.

The row books a foldable insertion because the insertion the standing row books today names an edge
the two-edge model excludes, which is rejectable at once and would leave the row without its subject.

### Only two grounds

Exactly two grounds authorize rejection, a lifecycle mismatch and expiry. A provider failure, a
missing processor-supplied input, an invalid proof and a generic script failure are never evidence of
inadmissibility (operator scope confirmation, recorded on the decisions page).

### The command-line split, the datum, the tag and the staffing

> the Singular CLI is the registry; the open datum is its own executable built on the Singular
> library. Build against the library's request and fold, not the open-datum envelope. Desk answer
> t528 Q-001: singular links no application code; the termination fold moves to the application's
> executable.

> the request keeps carrying its datum inline and the application decides its size.

The inline datum has no size cap (operator, 9 October 2026). Nothing in this ticket adds one.

> every request carries a tag minted by Singular's request policy; the bond at mint and forfeit on
> rejection are specified in #529; #494's rule is what makes a heavy forfeit safe. #494 does not
> model the tag or the bond; name where it hands off.

The handoff is the "What a rejection does" and "What a batch binds" sections of the
[evidence contract](contracts/rejection-evidence-contract.md): an admitted rejection leaves the
state, mints nothing and owes the deposit; ticket 529 attaches the bond forfeit to an admitted
rejection and nothing earlier.

> Codex is out for now. Claude seats at the highest levels, GLM and Muse at the working levels.

Applied, as amended for coding on 13 October 2026: ticket owner Claude Sonnet 5.5 at extra-high
effort; commit owner Muse (`muse --approve`); mute persistent auditor Grok
(`grok --always-approve -m grok-4.7 --effort high`) in a read-only detached audit worktree; a gate
author, also Grok, only for a gate row whose command or subject the rebase changed; no draft tool. The
GLM quota is exhausted until 14 October 2026, so no seat alternates or races while it is out.

> One merge into main at a time, in the order the desk publishes. Nobody rebases, retargets or
> merges without a slot.

Applied: validators and Lean (505, 494, 495, 529, 506) are one surface and strictly serial in that
order. The command-line split (528) and ticket 505 have merged and coding was released on 13 October
2026; this ticket merges only in the slot the desk grants and rebases only at a safe boundary.

## Acceptance, each item with the check that proves it

The gate is the existing CI commands in the [gate](gate.md), frozen before any coder runs, written
by the ticket owner and an independent author and synthesized once. Hosted checks on the exact head
are the net for every item.

| Acceptance item | Proving check |
|---|---|
| Rulings, concrete stories and the truth table are recorded | The decisions and data model pages; the corpus rows that export the table, replayed by the model check |
| The historical scenario is accepted on the base and refused after | The failing control committed at the start of slice two and the same scenario's exported row after it; the model check |
| Evidence and admission are defined with exact binding; unknown and Absent differ | The proved statement `rejection_admitted_iff` and its corpus rows; "Lean model and exact statement debt" |
| Each requirement is a proved statement exported as runnable cases; invalid evidence is not evidence | The statements named in the [functions model](functions-model.md), each proved from standard axioms; the model check; the exported refusing rows, one per refusal reason |
| Batch ordering and root semantics, with refund and tip unchanged and the refund rule not chosen | The batch statements and corpus rows (fold then reject accepted, reverse refused, empty refused); `rejection-effects-unchanged` |
| Constitution mapping, bindings, consumer record and ticket 320 history are updated; uncovered stays uncovered | The model check's reconciliation, "Rendered documentation", "Theorem coverage gate" and the published restatement table |
| The eight required checks that failed on 508 are green on the exact head, or the one that cannot be is published unmet as the decision above directs | The eight hosted jobs listed in the plan, run on the pushed head |
| An exact model revision and the evidence contract are released | The contract's release record, filled from the merge commit and the register |

## Out of scope, by number

Tickets 495 (validators), 496 (off-chain evidence and builders), 497 (connected acceptance), 487
(rejection as a separate command), 529 (the request tag, bond and forfeit), 361 (the refund policy),
500 (address pollution), 528 (the command-line split), 506 (verification of the packaged two-edge
contract), 532 (the approval a reject sends to the folder's change) and 310 (the open-datum
application, except regenerating its committed corpus). A coder
who needs to change something owned by one of them stops and reports it.

## The coder's brief and the auditor

The coder receives one brief per slice, each the whole of that slice with a terminal condition of
green, blocked or at capacity: [slice one](briefs/slice-one-booked-clock.md),
[slice two](briefs/slice-two-rejection-needs-evidence.md),
[slice three](briefs/slice-three-in-window-rows.md) and
[slice four](briefs/slice-four-mixed-batches.md). No run is counted and no nudge is sent. The
auditor is launched beside the coder from its first run, reads commits and receipts only, and is mute
toward the coder; the ticket owner carries one-line pointers between them. The push waits for every
checkpoint approved.

## Evidence the pull request will carry, and what stays uncovered

The pull request body is a fill-in of the repository's pull request template, whose sections are filled from this table; no essay is written at the end. It names the superseded earlier attempt, pull request 508 at head `a7224021`.

| Template section | Filled from |
|---|---|
| What changed, Why | The story and the paramount story above; the issue |
| How to verify | Links to the hosted jobs at the exact head: the eight listed in the plan plus the existing required set. A command that only runs locally is listed under Limits, not offered as evidence |
| Lean correspondence: exact model revision | The head commit and the register |
| Lean correspondence: requirement to statement to check | The functions model and the gate |
| Lean correspondence: restatement table | `conformance/coverage/protected-rejection-restatement.md` |
| Lean correspondence: historical scenario | Its exported row before and after |
| Principle VII mapping | What the harness change adds: the explicit inputs of the question builders, the owner and lifetime of anything that holds the registry identity, no thread, no hidden environment read |
| Limits | The list that follows |

Left uncovered by this ticket, and stated as such in the body: the validators (495); evidence
construction and every builder (496); any ledger acceptance of protected rejection (497); a
concrete proof format and its verifier; a live mixed batch, since no mixed transaction is built;
the refund discrepancy (361); address pollution (500); the tip's routing; and, until the validators
change, the chain's acceptance of a rejection the model refuses, published as unmet. Fold-time
admission is unchanged.

## Budget

One team per epic at a time. Each slice is one coder run and is cut again if it will run for hours.
The operator is on credits: the coder is Muse, the auditor is Grok, and no further seat is authorized.

# Mandate: ticket 494, protected rejection in the Lean model

This page is the whole contract a coder and an auditor are given for ticket 494. It binds the
work to an exact tree, quotes the rulings that govern it, lists the acceptance items with the
check that proves each, names what is out of scope, and states the evidence the pull request will
carry before any work starts. Planning only: the coder and the auditor named below are launched at
coding release, never before.

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
| Base commit | `e3c9ab01` (merge of 505, the two-edge model) |
| Runtime root | `/code/singular-protected-rejection/.orch/protected-rejection/to-494-sonnet-1` |
| Lean revision | `lean/` at `e3c9ab01`; toolchain pinned by `lean-toolchain` |
| Constitution | `.specify/memory/constitution.md` version 1.14.0 at `e3c9ab01`, moving to 1.15.0 in this ticket |
| Specification set | the pages of `specs/494-protected-rejection-rule/`; their hashes are recorded in the ticket owner's journal at freeze |
| Earlier attempt | pull request 508, head `a7224021`, base `23964e66`; reference only, never rebased, retargeted or merged |

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

Applied: ticket owner Claude Sonnet 5.5 at extra-high effort; commit owner Muse (`muse --approve`);
mute persistent auditor GLM (`/code/llm-settings/pi/glm --approve`) in a read-only
audit worktree; gate authors are the ticket owner and one GLM seat; no draft tool.

> One merge into main at a time, in the order the desk publishes. Nobody rebases, retargets or
> merges without a slot.

Applied: validators and Lean (505, 494, 495, 529, 506) are one surface and strictly serial in that
order; this ticket waits for the command-line split (528) and for the desk's slot, and rebases only
at a safe boundary.

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
| The eight required checks that failed on 508 are green on the exact head, or the one that cannot be is published unmet as the ruling directs | The eight hosted jobs listed in the plan, run on the pushed head |
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

The pull request body is a fill-in of this table; no essay is written at the end.

| Field | Filled from |
|---|---|
| Exact model revision | The head commit and the register |
| Mapping from requirement to statement to check | The functions model and the gate |
| Commands and exit codes | The gate's run receipts |
| Hosted job identifiers on the exact head | The eight listed in the plan, plus the existing required set |
| Restatement table | `conformance/coverage/protected-rejection-restatement.md` |
| Historical scenario | Its exported row before and after |

Left uncovered by this ticket, and stated as such in the body: the validators (495); evidence
construction and every builder (496); any ledger acceptance of protected rejection (497); a
concrete proof format and its verifier; a live mixed batch, since no mixed transaction is built;
the refund discrepancy (361); address pollution (500); the tip's routing; and, until the validators
change, the chain's acceptance of a rejection the model refuses, published as unmet. Fold-time
admission is unchanged.

## Budget

One team per epic at a time. Each slice is one coder run and is cut again if it will run for hours.
The operator is on credits: the coder is Muse, the auditor is GLM, and no further seat is authorized.

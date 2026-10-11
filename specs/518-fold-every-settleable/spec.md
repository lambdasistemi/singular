# One fold settles every settleable pending request

As a registry processor, I run `singular registry fold` (or `insert --fold`, or `terminate --fold`) and one transaction settles every settleable pending request, whoever booked it. Its receipt names each request it settled and gives the reason for each one it left out. Two users who booked at the same moment do not block each other.

Issue [#518](https://github.com/lambdasistemi/singular/issues/518), slice 1 of epic [#396](https://github.com/lambdasistemi/singular/issues/396). Read the [plan](plan.md) for the pull requests, the team and the command-line split this work followed, the [gate](gate.md) for the checks, the [touch list](touch-list.md) for every file, and the [tasks](tasks.md) for the commit boundaries. Base: `main` at `8a99415d` (the command-line split, #528, merged as `c6748950`).

## Stories

As Alice and as Bob, each booking from my own terminal and directory, I am not blocked by the other's booking: one `registry fold`, run by either of us or by anyone, settles both requests in one transaction, and each payout reaches its own owner.

As a processor, I learn from the receipt which requests the fold settled, with key, edge, owner and settlement, and which pending requests it left out, each with its reason and whether the reason comes from the model or from my own selection policy, so I know what the next fold or a reject has to take.

As a processor whose machine stops in the middle of a fold, I recover with the existing commands, and every request the fold included is reconciled, none twice.

As a processor who loses the race for the registry's state output, I get a refusal that names it, and a rerun folds whatever is still pending.

## What is wrong today

`registry fold` builds a fold only while exactly one request is pending (`foldTarget` in `Singular.CLI.FoldRules`) and otherwise refuses `concurrent-writer` before judging any request. Its journal, reconciliation and rollback bind one key, one edge and one root pair to a fold. The 2026-10-07 preprod rehearsal met this refusal (#489). The protocol already batches: the fold redeemer is `Modify(List<RequestAction>)`, the validator folds any subset of pending requests, and the model's `Singular.foldBatch` folds a list.

## Two pull requests

The slice is cut into two pull requests, each shippable on its own, each carrying the pages for what it ships. No page describes behaviour that is not on main.

**Pull request 1: each request judged alone, one settled per fold.** The pure selection in both vocabularies, the model-agreement test with its same-key control, and the command change: `registry fold` and the combined forms judge every pending request alone, never refuse `concurrent-writer` because several are pending, settle the first included request in ledger input order, and print the list receipt naming every exclusion with its reason and source. The capacity bound is 1. The journal, recovery and rollback stay single-request and unchanged. The one change below the command is the builder's subset entry point, used with exactly one request: today the builder spends every pending request, so settling the first included one alone needs it. Runnable outcome: with two pending requests, one of them stuck, `registry fold` settles the other and names the stuck one; the failure of the 2026-10-07 rehearsal is gone. Executed devnet item: an unsettleable request left and named while an eligible one settles.

**Pull request 2: many per fold.** The builder over several requests with the validity bound at the earliest deadline, the chained journal, recovery and rollback for many, the capacity bound of 9 with its provenance, and two executed devnet items: two actors book concurrently and one fold settles both, and an interrupted two-request fold reconciles both.

The list receipt ships in pull request 1 with a settled list of at most one, so its shape changes once; pull request 2 only lengthens the list.

## Rulings in force

Quoted here so no reader needs another page to know them.

- **Lean is the behavioural authority** (constitution 1.15.0, Principles I and II; Principle VII was added after the work was planned). Model: Lean tree `d9161edd0274b67151f331949521f34bbf18612f`, last changed by `20b35407` (#505); onchain tree `ce54a1c6866f61faf3008bc88171d64dd4a22473` at main `8a99415d`, which this branch does not change. Definitions this slice relies on: `Singular.refusal`, `Singular.step`, `Singular.allowed`, `Singular.foldBatch` and its driver question `Singular.Driver.runFoldBatch`. This slice changes no Lean, validator or blueprint file. Where Lean is ambiguous or underspecified for a claim, work stops and the question goes to the user as a story with the model revision.
- **Batch selection, option A** (epic owner, 2026-10-09): each pending request is judged on its own against the live state; at most one request per key per fold; included requests keep ledger input order; the longest fitting prefix is folded and the rest named. The five conditions below are binding.
- **Request datum inline, no size cap** (operator, 2026-10-09): "The request keeps carrying its datum inline; no size cap; the application decides what rides in it."
- **Batch capacity** (operator, 2026-10-08/09): "on preprod's execution budget (14 M memory units) a fold is estimated to hold about nine requests, bound by trie-proof verification, not datum size; the devnet grants ten times that memory and hides the limit. Measuring and raising it is #530. The fold selects a batch that fits a capacity bound and names in the receipt what it leaves for the next fold." No preprod number is claimed that was not measured under preprod parameters.
- **The command-line split** (#528): "build fold selection and receipts against the library's request and fold, not against the open-datum envelope, so #528 can move the command without rewriting this logic."
- **The request tag** is #529, not here: the fold keeps discovering requests at the request address, and moves to the tag only when #529 lands.
- **Rejection is not in the fold** (#498, Lean child #508 own the rejection rule): this slice adds no rejection to the fold and invents no rejection semantics.
- **Epic decomposition** (A-002, option B): this epic delivers #518 then #519 and settles #488 only. #486 is delivered by #528; #487 by #498.
- **Merge order**: one merge into main at a time, in the desk's order: #528 (merged), #381 (merged), this ticket's pull request 1, #358 slice 3, pull request 2, pull request 3, #477, #493.

The five conditions of option A:

1. Two vocabularies, never mixed. Model refusal reasons (from `Singular.refusal` and `Singular.step`) are reported verbatim. Selection reasons the model does not carry are named as processor selection policy in the receipt and the docs, and never appear as a ledger or model refusal.
2. Correspondence is checked, not asserted: a test runs each selected batch through the model's `foldBatch` question and requires acceptance, and compares its state, root, mint and paid with what the built fold produces where the harness can observe it. A negative control puts two requests of one key in one batch and requires the model to refuse it with the first refusing step's reason.
3. The four-request example below is an executable acceptance case with its expected receipt.
4. Residuals are recorded and mapped: the model has no batch transaction (`buildFold` is single-request) and no distinct-key commutation theorem, and same-key insert-then-terminate in one batch is excluded by selection here and enforced in model and validator by #519 ("no within-batch consumption").
5. The capacity number, its provenance, and the fact that preprod capacity is unmeasured (#530) are named.

## Selection

Each pending request is judged against the live registry state alone, never against what other pending requests would leave behind. The first check a request fails names its reason; a request that passes all of them is included.

1. It decodes as a request: otherwise `undecodable`.
2. Its edge is one the model admits, `insertActive` or `updateTerminal`: otherwise the model's `edge-inadmissible`.
3. Its processing window is open beyond the fold margin at the moment of the decision (today's single-request rule, applied to each request): otherwise `window-closed`.
4. The model's approval check accepts it: `no-approval` or `approval-mismatch`.
5. The model's leaf check accepts it from the live state: for an insertion `key-exists`; for a termination `token-missing` (no live output holds the key's active token), `key-unknown`, `not-booked` or `terminal-immutable`.
6. The application can settle it, asked through the application value: an insertion's carried datum reads, otherwise `application-datum-unreadable`; a termination needs the value's holding rules, which the neutral value (`singular`) does not carry, otherwise `application-required`, whose detail names the application's executable.
7. No earlier included request names the same key: otherwise `key-in-batch`.

The included requests keep ledger input order. If they exceed the capacity bound, the first requests up to the bound are folded and each remaining one is named `capacity`. Every pending request is in exactly one of the two lists, settled or excluded.

A request's verdict does not depend on the presence, absence or order of requests on other keys. That is the repair of the shape [#488](https://github.com/lambdasistemi/singular/issues/488) names: no check ranges over all pending requests to decide whether one may proceed.

### The two vocabularies

| source | reasons | where they come from |
|---|---|---|
| model refusal, verbatim | `edge-inadmissible`, `no-approval`, `approval-mismatch`, `key-exists`, `token-missing`, `key-unknown`, `not-booked`, `terminal-immutable` | `Singular.refusal`, reported as the model words them |
| selection policy | `undecodable`, `window-closed`, `application-datum-unreadable`, `application-required`, `key-in-batch`, `capacity` | the processor's own rules; the model has no counterpart for them |

A selection reason is never labelled as a refusal of the model, in the receipt or in the pages. Until #519 the model carries no processing-window admission, so `window-closed` is a selection reason.

### The four-request example

Registry state: key 7 unknown; key 9 active with its holding live. Pending, in ledger input order: r1 = insert key 7 (Alice); r2 = terminate key 9 (Bob); r3 = insert key 7 (Carol); r4 = insert key 11 (Dana), whose processing window closes in 10 seconds.

Expected receipt with a capacity of 9 (pull request 2): settled r1 (key 7, `insertActive`, owner Alice, the delivered output) and r2 (key 9, `updateTerminal`, owner Bob, the released holding and the deposit paid back to Bob); excluded r3 `key-in-batch` (selection policy) and r4 `window-closed` (selection policy). The next fold, judged from the state after this one, names r3 `key-exists` (model refusal).

Expected receipt with a capacity of 1 (pull request 1): settled r1; excluded r2 `capacity`, r3 `key-in-batch`, r4 `window-closed`, all selection policy. The next fold settles r2 and names r3 `key-exists` (model refusal) and r4 `window-closed`.

In both, the unit test passes the bound as an argument, so the same example is run at 1, 2 and 9.

### Capacity

Pull request 1 folds one request per fold: the bound is 1, and its provenance says that the journal binds one transition until the multi-request journal ships. Pull request 2 raises it to 9 requests, counted. Provenance of 9: the operator's estimate for preprod's execution budget of 14 million memory units, bound by trie-proof verification. It is not measured under preprod parameters; measuring and raising it is #530. A fold the network still cannot build or evaluate within its limits is a refusal that submits nothing.

## What the receipt says

One receipt shape for one request or many. Per settled request: the request, its key, its edge, its owner and its settlement (the live output and application datum it delivered, or the holding it released and the deposit paid back). Per excluded request: the request, the reason, and its source (`model-refusal` or `selection-policy`). For the transaction: its id, the folder, the root before and after, the validity bound and the post-build decision, the capacity bound with its provenance. The requests left for the next fold are the excluded ones named `capacity`.

## Journal, recovery and rollback (pull request 2)

A fold's journal line lists, in batch order, each request's key, edge, expected leaf and root pair; the pairs chain from the transaction's root before to its root after. A line written before this change reads as a batch of one. Observation proves each key the batch touches against the leaf its last transition expects, and the state output's root equal to the batch's last root after. Rollback returns every included request to pending and restores the root before. A fold whose state output was spent by another fold is refused `stale-state` and its journal closed; a rerun folds what is still pending. In pull request 1 these stay as they are today, for one request.

## Commands

- `singular registry fold` takes the selection: the first included request in pull request 1, the whole selection in pull request 2. `--request R` stays an expectation: the command is refused unless R is among the settled requests, and the refusal says why R is not. With nothing settleable it is refused `nothing-to-fold`, naming every exclusion. It never refuses `concurrent-writer` because several requests are pending.
- `insert --fold` and `terminate --fold`, which belong to the `open-datum` executable since the command-line split, fold the same selection and print the same receipt. If their own booked request is excluded, the command stops partial naming the request that stays pending and the reason.

## Acceptance

Each line names the check of the [gate](gate.md) that proves it, in italics at the end of the line. Lines marked 1 belong to pull request 1, lines marked 2 to pull request 2, lines marked 1+2 to both.

- [ ] (1) each-request-judged-alone: verdicts independent of other keys' requests; a control that refuses when several are pending must fail the same check. *focused-offchain-suite*
- [ ] (1) one-request-per-key: a later same-key request is `key-in-batch`. *focused-offchain-suite*
- [ ] (1) two-vocabularies-never-mixed: model reasons verbatim; policy reasons labelled as policy. *focused-offchain-suite, demo1-refusal-controls*
- [ ] (1+2) capacity-bound-prefix-and-remainder: the first requests up to the bound in order, the rest `capacity`; the bound (1, then 9) and its provenance in the receipt and the pages. *focused-offchain-suite*
- [ ] (1+2) example-four-requests: the receipts above. *focused-offchain-suite, conformance-unit-suite*
- [ ] (1) selection-agrees-with-the-model-batch: every selected batch, at any bound, is accepted by `foldBatch` and matches the built fold where observable; the same-key control is refused. *conformance-unit-suite, batch-instructions-asked-of-the-model*
- [ ] (1+2) fold-spends-exactly-the-selection: the state output and exactly the selected request outputs among those pending; PR 2 adds the validity bound at the earliest deadline among them. *focused-offchain-suite, devnet-e2e-lanes, demo1-journey-from-archive*
- [ ] (1) receipt-lists-settled-and-excluded. *focused-offchain-suite, demo1-journey-from-archive, demo1-refusal-controls*
- [ ] (2) journal-binds-every-transition-to-one-transaction, and an earlier line reads as a batch of one. *focused-offchain-suite with a pre-change line, recovery-accepting*
- [ ] (2) recovery-covers-every-included-request. *focused-offchain-suite, recovery-accepting, recovery-killed, recovery-cross-wallet-parts*
- [ ] (2) lost-race-is-stale-state. *focused-offchain-suite (unit only; the executed race is a residual)*
- [ ] (1+2) registry-fold-takes-the-selection. *focused-offchain-suite, cli-flags, demo1-refusal-controls*
- [ ] (1+2) combined-forms-take-the-same-selection. *focused-offchain-suite, demo1-journey-from-archive*
- [ ] (2) two-actors-one-fold, executed on a devnet: two actors book concurrently from their own directories, one fold settles both, each payout reaches its owner. *demo1-journey-from-archive, demo1-two-actor-control*
- [ ] (1) unsettleable-request-left-and-named, executed on a devnet: a request the fold cannot settle is left out and named while an eligible one settles. *demo1-journey-from-archive, demo1-refusal-controls*
- [ ] (2) interrupted-fold-reconciles-every-request, executed on a devnet: a submitted multi-request fold interrupted at its hold points is recovered by the existing commands, every included request reconciled, none twice. *recovery-killed, recovery-accepting, recovery-cross-wallet-parts*
- [ ] (1+2) docs-state-what-is-shipped-and-its-limits: the pages state the fold each pull request ships, the two vocabularies, the capacity bound and its provenance, and the residuals; the "exactly one is pending" rule is gone from them. *rendered-docs, presentation-check, release-docs-check, cli-flags*
- [ ] (1+2) fences: no change under `lean/`, `onchain/`, `naming-onchain/` or `simulator/formal/`; repository checks stay green. *the root gate and the owner path fence*

## Out of scope

By number: #519 processing-window admission (the model's `foldAdmission`; slice 2); #486 booking-time leaf check (delivered by #528); #487 mixed-action fold with rejection (delivered by #498); #498 and #508 the rejection rule; #528 the command-line split; #529 the request tag; #530 capacity measurement; #489 closed into the epic.

Surfaces other live slices own, so this slice stops and asks before touching them: the state-directory and session layer (#485, #477, #493), the funding and publication layer (#471, #406, #478, #479, #491), validators and Lean (#505, #494, #495, #529, #506), command-line module structure (#528). Pull request 2 touches `Session.hs`, `Receipt.hs` and `Reconcile.hs` for the journal's transition list only; the [touch list](touch-list.md) names the functions and flags the collision for the desk. #477 builds on that journal format after pull request 2.

## Limits and residuals

- Pull request 1 settles one request per fold; the story's "one transaction settles every settleable request" completes with pull request 2.
- `singular registry fold` carries the neutral application value, which has no holding rules: a termination is excluded `application-required`, naming the application's executable, and the application's own executable (`open-datum fold`) settles it. This is the split's design, shown in the receipt rather than refused for the whole command.
- The model has no batch transaction: the batch is compared with `foldBatch`'s state, mint and paid, not with a model transaction. Owner: #519.
- No distinct-key commutation theorem states that requests on distinct keys fold in any order. Owner: #519.
- Same-key insert-then-terminate in one batch is excluded here by `key-in-batch`; the model accepts such a batch, so enforcement in model and validator is #519's.
- Processing-window admission is a selection reason here, not a model refusal. Owner: #519.
- The capacity of 9 is an estimate, unmeasured under preprod parameters. Owner: #530.
- The model's root is its own commitment function and is not comparable with the chain's registry root; the live comparison reads mint, payments and leaves, never the root bytes.
- No hosted job provokes two folds racing on one state output; the lost-race line is proved by unit checks and by the existing refusal vocabulary, not by an executed race.
- The pages state the batch fold in prose; no hosted check asserts prose. They are checked by rendering and by reading.

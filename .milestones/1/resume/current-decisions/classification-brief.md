# t80d — classification and correspondence inventory for the 83 unclassified declarations (#80)

**Role:** bounded mechanical implementation. Parent: epic 18 owner, pane %914. **Seat:** Muse
(`muse --approve`). **context=FRESH** — new process, nothing inherited.
**Runtime root:** this directory.
**Worktree:** `/code/singular-e18-inventory` — yours alone.
**Branch:** `feat/coverage-classification-inventory`, base `a95f299` (current main, includes PR 86).

You succeed the retired `t80c-release-gate` in capacity only. **Its runtime root and its verified
gate stay unchanged — read them, write nothing there.** PR 86 completed publication-boundary
preparation; it did **not** complete #80.

Load `worker-protocol`, `code-the-design`, `worktrees`.

## The deliverable

A complete, **source-bound** classification and correspondence inventory for the **83 currently
unclassified declarations**, preserving all **192 existing identities** and all **109 public
contracts**.

For each declaration, give:

- exact **qualified symbol**;
- **source and signature digest**;
- **declaration form**;
- **defining behaviour and clauses**;
- **public-contract / transition dependencies**;
- **proposed disposition with rationale**;
- **explicit unresolved questions**.

**I judge the classifications. You cannot decide away a semantic obligation.** Missing rationale or
disputed semantics stay **open** and block acceptance of that classification — that is a correct
outcome, not a failure to finish.

## Rules that decide the work

- **Source occurrence counts are leads, not evidence.** A symbol used twice is not thereby a helper,
  and a symbol used nowhere is not thereby dead. Trace each helper into the applicable behavioural
  obligation, **or state precisely why it carries an independently testable obligation of its own.**
- **No blanket helper exemption. No denominator deletion. No manufactured PASS.** Helper status is
  justified by a declaration's statement and use, never by its filename or its location.
- Preserve **name, quantifier, hypothesis and conclusion correspondence** exactly.
- Existing real test evidence may be **indexed with its honest source and venue limits** — never
  silently promoted to final coverage.
- **No debt migrates between rows.** Unrelated implementation, execution and compiled-invariant
  debts are unchanged.

## Explicitly out of scope

No new DSL, no assumed story format, no Lean edits, no product Aiken or SDK changes, no fabricated
execution evidence. This work is **independent of the pending broad DSL/readability decision** —
do not anticipate it.

## Fences

Write only **new classification-inventory artifacts and their consistency checker and tests, under
`conformance/coverage/`**. Integration with existing inventory/record code happens **only after I
bind its contract** — ask first.

**Do not touch** t89's codecs, builders or row tests; **do not touch** t87's `blaster/` subtree.
Shared `completion.py` and release wiring stay **serial and owner-controlled**.

## The checker must be able to fail

It must go **RED** for a missing symbol, a duplicate symbol, a stale symbol, or an unjustified
disposition. **Prove each of those reject for its own distinct reason** before you claim it works —
a checker whose author wrote both it and its only test cases is the failure mode this project has
hit twice.

All original **192 identities must remain accounted** for.

## Terminal conditions

**One frozen clean candidate and the complete set of findings, delivered once.** No serial
prose-only rounds, and no replay of the publication gate.

Stop at: that candidate; `BLOCKED Q-NNN` with a named question; or `COMPLETE` with an **evidenced**
capacity limit and exact remainder. Journal tagged events via `status-event` — a terminal state
nobody can observe parks me indefinitely.

No merge, no push to main, no release. You are not alone in the codebase; do not revert edits made
by others.

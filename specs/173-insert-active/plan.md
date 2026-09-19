# #173 — implementation plan

## Status

- Completed: Lean-first slice accepted and pushed at `854f56f`; submission-2
  delta audit PASS, six of six rows, no findings.
- Current: compact mandate and slicing audit.
- Blockers: none. A-006 fixes duplicate refusal as `key-exists`; the separate
  keyed-mint control remains `net-mint-mismatch`.

## Vertical cut

There is one remaining implementation task and one runnable: the released
archive's `insert-active` command. It crosses validator, identity, builder,
conformance, devnet, journey, documentation and packaging in the same owner run.
There is no validator-only, builder-only or documentation-only task.

The already accepted Lean commit is a prerequisite design slice, not a second
implementation interpretation. The implementation must follow its constructed
transaction and refusal order.

## Surface map

| layer | owned surface | required copy / observation |
|---|---|---|
| Lean authority | accepted `lean/**` revision and generated consumers | no behavior change; identities and mirrors remain synchronized |
| on-chain substrate | `open.ak`; moved `witness.ak`; request/state encodings; script identities | parameterless open policy, four boot pins, edge-tagged request, no request tip |
| on-chain edge | cage `insertActive`, keyed mint comparison and named tests | active token at named output; `key-exists`; separate `net-mint-mismatch` |
| off-chain | boot/request/connected-fold builders; E2E and journey | same blueprint identities and wire fields as Aiken |
| conformance | edge fold/refusal; CS01/02/04/07/08; `rows.json` | executed old/new field and verdict mapping |
| product boundary | archive assembly, packaged `insert-active`, run page | runnable after extraction without checkout |
| derived copies | identities, blueprints, workflow assertions, coverage records, speech | exact regenerated or curated copy, never hand-divergent |

Anything outside this map is a planning challenge, not an implicit widening.

## Implementation sequence

One Opus commit owner receives only the frozen spec, task, Lean rows, Gate S and
source fence. It works inside one four-hour run:

1. Commit the RED bundle for A173-BOOT through A173-COPIES, using only existing
   CI job commands later frozen in Gate S. This is the first decision-review
   checkpoint.
2. Plant the open/witness/request substrate and its boot builders, then make
   A173-BOOT and A173-APPROVAL green as separate committed checkpoints.
3. Implement the cage edge with request/fold builders and make A173-EDGE then
   A173-REFUSALS green as separate committed checkpoints.
4. Add the packaged command and drive it through E2E, journey, conformance,
   docs and archive assembly; make A173-COMMAND and A173-COPIES green as
   separate committed checkpoints.
5. Regenerate only the enumerated identity/blueprint/coverage/page/speech
   consumers and create the pre-push decision record.

Each checkpoint records the invariant, the owner's single gate result, the
approach and rejected alternative, reliance on existing code, assumptions,
shortcuts and what the gate does not cover. The owner continues without waiting.

## Verification and senior review

After the slicing audit, two independent 15-minute authors—Grok and Codex—map
every acceptance line and touched workflow row to verbatim existing CI commands
and expected exits. The ticket owner synthesizes their workflow-cited union as
Gate S; no bespoke checker, mutant, self-test or separate gate audit is created.
A missing CI command is a question, not a local substitute.

The commit owner and one mute persistent senior auditor launch together. The
senior reads the frozen invariants, Lean rows, commits and decision records, but
not the owner's transcript or prose brief. It does not rerun gates or controls;
it approves, blocks, or escalates the requirement itself from code evidence.
Traffic is mediated by the ticket owner. The owner never waits, but push waits
for every acceptance line to have an approval bound to an ancestor SHA.

The senior may add an uncovered invariant only as a new Gate S row mapped to an
existing CI command. Settled rows remain byte-identical and ordered. During an
escalation it may suggest a row replacement/removal or requirement restatement,
but only the ruling creates a new gate version.

Before push, the ticket owner checks the whole approval trail and runs the
latest frozen Gate S once on the head. Remote CI must then be green on that exact
head. No end-of-slice inspector or duplicate verdict execution follows.

## Release and remainder

The first release was named before work: 0.7.0. After this ticket merges, the
epic owner owns the edge-scoped pre-release/tag that publishes the archive with
`insert-active`; this ticket only proves the archive bytes and command locally
and in CI.

If the four-hour wall is reached, retain one complete runnable cut—boot,
`insertActive`, packaged command—and list independent conformance/doc polish as
a `COMPLETE` remainder. Never ship a layer-only partial, stub another edge, or
weaken an accepted Lean meaning.

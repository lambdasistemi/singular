<!--
Sync impact report
Version: 1.4.0 -> 1.5.0 (Project 4 issue tracking)
Amended: 2026-09-23
Authority: user instruction 2026-09-23 that every Singular issue belongs in
Lambda Sistemi Project 4, the Cardano KERI demo schedule.
Added section: Issue tracking. Every Singular issue, including closed issues,
must appear in the project; creation and reconciliation must be automatic.
Modified principles: none; the behavioral and model obligations are unchanged.
Synchronized: AGENTS.md and .github/PROJECT4_INTAKE.md.
Templates: no Spec Kit templates exist; the PR template already requires
constitution review and needs no change.
Follow-up: enable Project 4's built-in auto-add rule for this repository with
filter `is:issue`; this project setting has no public write API.
Deferred placeholders: none.

Sync impact report
Version: 1.3.0 -> 1.4.0 (required signers become an obligation)
Amended: 2026-09-23
Authority: user ruling 2026-09-23 narrowing issue #228 to the fold's required
signers.
Changed obligations: `requiredSigners` is no longer a named unobservable field.
The model proves that no fold requires a signer
(`Singular.Statements.fold_requires_no_signer`), so the `tx` row's `signers`
carries that obligation: a consumer reads the submitted transaction's required
signers and compares them with the model's empty list.
Modified principles: none.
Synchronized: `Singular.Driver.declaredUnobservable` drops the name in the same
change; tools/check_model.py reconciles the two in both directions, and the
driver's surface digest moves with it.
Templates: no template change required.
Deferred placeholders: none.

Sync impact report
Version: 1.2.0 -> 1.3.0 (per-output minimum ada named unobservable)
Amended: 2026-09-22
Added sections: none. The model driver translation names one further
unobservable field, per-output ledger minimum ada, so a consumer compares every
other transaction field and leaves that one alone.

Sync impact report
Version: 1.1.0 -> 1.2.0 (model driver translation)
Amended: 2026-09-22
Added sections: the model driver translation — the concrete realization of each
declared operation and boundary observation, the identity rules binding a
scenario to the model and to its theorems, and the named unobservable fields,
the registry root's abstractness among them.
Modified principles: none; existing obligations are unchanged.
Synchronized: tools/check_model.py reconciles this section against the driver's
declared surface in both directions, in the required CI model job.
Templates: .github/pull_request_template.md already routes acceptance through
this constitution; no template change required.
Deferred placeholders: none.

Sync impact report
Version: 1.0.0 -> 1.1.0 (conformance suite audience and form)
Amended: 2026-09-21
Added principles: VI, the conformance suite is the product's public evidence
statement — published audience, receipt-computed state, published uncovered
rows, every claim said in the description language, total interpretation with a
discovered-extent control, requirement text over internal identifiers, harness
evidence as a marked appendix, and no restructure that moves a row's state.
Modified governance: records the user's 2026-09-21 instruction.
Synchronized: AGENTS.md.
Templates: .github/pull_request_template.md already routes acceptance through
this constitution; no template change required.
Deferred placeholders: none.

Sync impact report
Version: none -> 1.0.0 (first repository constitution)
Ratified and amended: 2026-09-11
Added principles: Lean authority; user-story escalation; behavioral correspondence;
evidence-bound acceptance; retrospective applicability.
Added governance: amendment authority and versioning; acceptance and release rules.
Synchronized: AGENTS.md; .github/pull_request_template.md.
Spec Kit plan/spec/tasks/command templates: absent; no template migration required.
Deferred placeholders: none.
-->

# Singular Constitution

As a Singular user or integrator, I must receive the behavior specified by the
accepted Lean model. As a contributor, I must be able to trace each delivered
behavior to that model and know when a decision belongs to the user.

## Core principles

### I. Lean is the behavioral authority

The accepted, revision-bound Lean model MUST govern the simulator, on-chain
validators, off-chain transaction construction, and conformance expectations.
Implementation MUST preserve its transitions, authorization, accepted and refused
outcomes, state and registry-root effects, token identity and custody, refunds,
and witness obligations. Imported code and pinned dependencies have the same
obligation as code written in this repository.

A passing suite, existing implementation, owner interpretation, or previous merge
MUST NOT replace the model as the behavioral authority. Contributors MUST NOT
change Lean or expected results merely to match an implementation. The user
retains authority to correct the model through the process below.

### II. Model errors and ambiguity require user stories

If Lean appears wrong, contradictory, underspecified for the behavior being
claimed, or ambiguous, the contributor MUST escalate to the user. A conflict
between Singular's model and a bound consumer model MUST take the same path;
an owner MUST NOT silently choose one or weaken the consumer requirement.

The escalation MUST contain:

- The actor, action and intended outcome: “As a ..., I want ..., so that ...”.
- A concrete starting state and action, the Lean result or competing readings,
  and the implementation's observed result.
- Exact model and implementation revisions, definitions, affected tickets or
  releases, evidence, and the limits of that evidence.
- The user-visible consequence, viable alternatives, and the decision needed.

Acceptance, merge, and release of affected behavior and dependent claims MUST
remain blocked until the user decides. Independent, settled work may continue.
No approval is needed to repair code that contradicts clear Lean. Technical
representation choices may proceed when their behavioral correspondence is
explicit and checked; a difference in representation alone is not a model error.

The user's ruling MUST be recorded in the repository with the affected story.
Lean, its statements/proofs and exported corpus MUST be updated as applicable
before dependent implementation is accepted. Simulator, implementation, tests,
documentation and release compatibility MUST then be aligned with that revision.

```mermaid
flowchart TD
    A[User story and accepted Lean revision] -->|Implement and check| B{Behavior corresponds?}
    B -->|Yes, evidence covers the claim| C[Eligible for acceptance]
    B -->|Code contradicts clear Lean| D[Repair code and regression check]
    D -->|Verify again| B
    B -->|Lean wrong, ambiguous or conflicting| E[Hold affected acceptance]
    E -->|Present concrete story and alternatives| F[User decision]
    F -->|Record ruling and update Lean first| A
```

### III. Verify the whole claimed behavior

Every behavior-changing PR MUST identify its user stories, exact Lean revision
and definitions, implementation entry points, and the executable checks and
observations connecting them. The mapping MUST cover both success and relevant
refusals, including who can supply every signature, witness and required input.
Representation refinements MUST explain and check preservation of observable
effects; matching case names or counts is insufficient.

An end-to-end lifecycle claim MUST exercise the connected transitions that
produce its starting and final states. Directly creating a fixture in the final
state, substituting an asset under another policy, or checking one isolated
validator MUST NOT be presented as evidence for the missing lifecycle. Such
fixtures can support narrower checks if those limits are stated explicitly.

Checks MUST demonstrate that a relevant reachable defect is detected at the
claimed boundary. A source inspection establishes source facts; a Lean proof
establishes its stated proposition; a simulator replay establishes the simulated
cases; a ledger claim requires the corresponding transaction and script
execution evidence. These forms of evidence MUST NOT be substituted for one
another. A helper's base case alone does not establish a complete transition.

### IV. Acceptance must preserve evidence and gaps

Review MUST bind the candidate commit, model revision, commands, actual results,
and remaining coverage gaps. Green CI is necessary for merge but does not alone
establish behavioral correspondence. Reviewers MUST inspect what each gate
actually proves, including positive and relevant negative controls.

An unresolved contradiction or ambiguity MUST NOT be closed as an “expected
gap”, waived by an owner, or converted into a passing conformance row. Missing
evidence MUST remain unverified. An unmet consumer requirement remains unmet
even if the implementation conforms to a different model.

A limited artifact may be described accurately, but changing an already accepted
story's scope requires an explicit user ruling. A release MUST NOT claim completion
of a story whose required effects or evidence are missing. The constitution does
not prescribe extra auditor seats; staffing follows the user's instructions.

### V. Apply the rule to previous work

These principles apply to previously merged code and released artifacts as well
as new work. When a retrospective check finds a discrepancy, contributors MUST
record the affected revisions and stories, preserve the original evidence, and
hold dependent acceptance until resolution. Prior closure or a published release
does not exempt a behavior from correspondence review.

Repairs MUST use forward changes. Historical commits, tags, artifacts and receipts
MUST NOT be rewritten to conceal a mismatch. Resolution requires the implementation
repair and its evidence, or an explicit user ruling followed by the model-first
alignment above. Publishing this constitution does not itself resolve any
existing implementation finding.

### VI. The conformance suite is the product's public evidence statement

The conformance suite is read by people outside this project who are deciding
whether to build on the registry. It is published — `docs/consumer-conformance.md`
— and it MUST be written for that reader, in the product's own words, without
requiring them to learn this project's internal vocabulary first.

Its worth to that reader is that it is honest about what has not been shown.
Row state MUST be computed from run receipts and MUST NOT be typed by hand.
`uncovered` MUST be published rather than hidden. A green step is not a
fulfilled consumer promise, and a passing suite MUST NOT be presented as one.

Every product claim MUST be expressed in the suite's description language, so
that a story cannot describe a case the suite does not run. A case that cannot
be said in that language is a finding to raise; it MUST NOT be written as a raw
assertion outside it. Interpretation of that language — execution and
rendering — MUST be total over the same instruction set, and the control proving
it MUST quantify over the discovered extent of that set rather than a listed
member. A renderer that silently drops an instruction publishes a claim the
suite never executed, which is the same defect as typing `executed` into a row.

Surfaces the reader navigates MUST carry requirement text, not internal
identifiers. Evidence about the project's own harness MUST be marked as an
appendix and MUST NOT occupy the body, whatever its volume.

Because the suite is a product surface rather than an internal test tree, a
change to it is a product change and is held to the same bar. A restructure
MUST NOT move any row's state by one increment and MUST NOT make an uncovered
row look covered.

## The model driver translation

The driver at `Singular.Driver.runSurface` executes the model's law and reports
a declared boundary. This section states what each declared name concretely
means, so a support module cannot invent the correspondence and a missing field
cannot be dropped in silence. The reconciliation is mechanical and runs in both
directions in `tools/check_model.py`: a declared name with no row here fails,
and a row naming something the driver does not declare fails. **That check
establishes that every name is stated — never that a stated realization is
true.** Whether a realization is correct is a review obligation under
Principle III, not something a name-reconciliation can earn.

Each operation is one of the seven edges, executed through `Singular.step` at
the request the scenario carries. An operation is refused when `Singular.refusal`
returns a reason; the driver reports that reason verbatim and never manufactures
one.

| declaration | kind | meaning |
|---|---|---|
| `insertAbsent` | realization | `Singular.step` with `Edge.insertAbsent`: books the key as `Known Absent` and records one custody entry holding the deposit and its refund address. |
| `insertActive` | realization | `Singular.step` with `Edge.insertActive`: books the key as `Known Active` and holds one active token routed to the request's output. |
| `updateActive` | realization | `Singular.step` with `Edge.updateActive`: moves a booked absent key to `Known Active`, consumes its custody entry and pays that entry's recorded value to its recorded refund address. |
| `updateTerminal` | realization | `Singular.step` with `Edge.updateTerminal`: retires an active key to `Known Terminal` and releases its active holding. |
| `deleteAbsent` | realization | `Singular.step` with `Edge.deleteAbsent`: returns a booked absent key to `unknown`, consuming its custody entry and paying its refund. |
| `deleteActive` | realization | `Singular.step` with `Edge.deleteActive`: returns an active key to `unknown` and releases its active holding. |
| `witnessTerminal` | realization | `Singular.step` with `Edge.witnessTerminal`: attests an already terminal key, adding a terminal holding and changing no leaf. |
| `config` | realization | the whole eight-field `Singular.Config` of the state the step produced, through the model's own `ToJson Config`. Not the root alone. |
| `custody` | realization | the custody census after the step: every outstanding absent token with its refund address and value. |
| `held` | realization | the held-token census after the step: every active and terminal holding with its key, kind and output. |
| `leaf` | realization | `Singular.trieGet` at the request's key in the produced state, spelled by `Singular.leafJson` as `null`, `absent`, `active` or `terminal`. |
| `mint` | realization | the executed result's own `mint`: the R2 keyed delta of the edge, each entry named by the registry's pinned policy for its kind and the asset name the model derives from the key. |
| `paid` | realization | the executed result's own `paid` list of (address, value) payments, which is non-empty exactly for the two edges that consume an absent token. |
| `root` | realization | `Singular.rootOf` over the produced trie — FNV-1a over the sorted (key, leaf byte) list. This is the model's own commitment function and is stated as abstract; see the unobservable rows below. |
| `state` | realization | the complete `Singular.RegistryState` after the step, serialized by the model's own instance so the row is a replayable input rather than a picture of an output. |
| `tx` | realization | the transaction `Singular.txOf` builds from the same executed step: its inputs, outputs, mint, signers and refunds, through the encoders in `Singular.Driver`. The driver builds no transaction of its own. `signers` carries an obligation: `Singular.Statements.fold_requires_no_signer` proves it empty for every fold, and a consumer compares it with the submitted transaction's required signers, each translated to the wallet identity whose payment key it is. |
| model declaration | identity | a scenario names an operation only through `Singular.Driver.edgeName`, which reads the model's own `ToJson Edge`, so the driver holds no second vocabulary for the seven edges. |
| theorem binding | identity | a scenario carries a theorem's qualified name and the `statementSha256` that `lean/theorem-debt.json` records for it. A statement that moves makes the binding stale and fails; a name alone would not. |
| surface digest | identity | `definitionDigest` is taken over the declared operation, observation and unobservable names together, so a silently widened or narrowed surface changes it. |
| law premise | identity | `Singular.Driver.consistentB`, the decidable finite characterization of `Singular.Consistent` over the keys a state actually mentions. It is checked on the state reached by the setup trace *before* any accepted observation is reported. A key the state mentions nowhere satisfies every conjunct trivially, which is why the finite extent does not weaken the premise. |
| starting state | identity | reached by running the setup trace through the law. A scenario that declares `requiresReachableState` must supply a non-empty trace, so a state typed in with the key already active cannot stand in for a lifecycle nobody executed. |
| outcome class | identity | `accepted`, `refused` and `unsupported` are disjoint. Only `accepted` carries observations; `refused` carries a reason `Singular.refusal` can produce; `unsupported` is the driver failing to reach the case and is never reported as a ledger refusal. |
| `concreteTrieHash` | unobservable | the real authenticated-map root a chain would carry. The model commits with FNV-1a and S01 introduces no Cardano byte model, so no byte-level agreement between `root` and a real registry root is claimed anywhere. |
| `outputMinimumAda` | unobservable | the minimum ada a ledger requires every output to carry. The model says nothing about it, so an output's `lovelace` is a logical zero rather than an amount; a consumer compares every other field of a transaction and leaves this one alone rather than reconstructing an equality the model never claimed. |
| `registryAddress` | unobservable | the registry's own address. The model has no vocabulary for it and the state output's address is `none` rather than an invented constant. |
| `scriptExecutionUnits` | unobservable | execution budget and fee measurement are ledger facts with no model counterpart. |
| `transactionId` | unobservable | the built transaction has no identity until a ledger accepts it. |
| `utxoReference` | unobservable | inputs are modelled by role, not by concrete output reference. |

## Development and review

Contributors MUST read this constitution before specifying, implementing or
accepting behavior. Plans, task lists, PRs and handoffs MUST carry forward the
story, model binding, required evidence and unresolved decisions. Repository and
agent instructions MUST link here rather than maintain competing authority rules.

The PR template is the acceptance record: behavioral changes supply the mapping
and checks; governance-only changes explain why runtime behavior is unchanged.
A reviewer MUST withhold acceptance for an unresolved affected story. When a
change exposes an existing model conflict, the conflict MUST be recorded and
routed to the user rather than silently incorporated into the new expectations.

## Issue tracking

Every issue in `lambdasistemi/singular`, whether open or closed, MUST appear in
[Lambda Sistemi Project 4](https://github.com/orgs/lambdasistemi/projects/4),
the shared Cardano KERI and Singular project board. Its demo timeline is one
view of that board. This includes epics, child issues, defects and work filed
outside the current milestone. Project membership, including an
automatically assigned default status, MUST NOT be read as a committed review
date, delivery estimate, owner assignment or acceptance verdict.

Project 4's built-in auto-add workflow MUST select `lambdasistemi/singular`
with filter `is:issue`, without a state or label restriction. Issue creators
MUST verify project membership after filing; if automatic intake has not yet
run, they MUST add the issue or record the intake failure for repair. The
milestone or project owner MUST reconcile existing and newly created issues
against the project and add any missing items. A project view hiding a closed
issue is not evidence that the issue is absent from the project.

## Governance

This constitution records the user's 2026-09-11 instruction that implementation
must never diverge from Lean, model errors and ambiguity must be escalated as
user stories, and the rule must apply retroactively. It supersedes conflicting
repository guidance and prior owner interpretations. An explicit later user
ruling may amend it; an agent or reviewer cannot grant itself an exception.

Principle VI records the user's 2026-09-21 instruction that the conformance
suite is the product bible, written for stakeholders rather than for this
project, and that this value is constitutional rather than the scope of the
ticket that first applied it.

The issue-tracking section records the user's 2026-09-23 instruction that all
Singular issues belong in Lambda Sistemi Project 4 so the Cardano KERI demo
schedule has a complete source-ticket inventory.

Amendments MUST record their authority, rationale, affected principles and
dependent guidance. Use a major version for incompatible principle changes, a
minor version for new or materially expanded principles, and a patch version for
clarifications without changed obligations. Each amendment MUST update the sync
impact report and check the repository's contributor instructions and templates.

**Version**: 1.5.0 | **Ratified**: 2026-09-11 | **Last amended**: 2026-09-23

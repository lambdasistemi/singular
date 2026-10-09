# Mutation ledger

As a reader of current permanent contract, I can register a fresh key and terminate it permanently.
The active model and compiled state support exactly tags 1 (`insertActive`) and
3 (`updateTerminal`); tags 0, 2, 4, 5 and 6 are explicitly refused, including
caller-constructed and mixed requests. Application payload maintenance is separate.
Current sources and receipts must be bound to the revised candidate.

The detailed walkthrough and measurements below are **archived broader model evidence**,
retained to explain the earlier contract; their broader success claims do not apply
to permanent contract. Historical sources are retained on `preserve/m2/pre-m1-source-removal`.
[The active theorem manifest](theorems.md) and
[the exact scope-retirement record](https://github.com/lambdasistemi/singular/blob/feat/505-permanent-m1/conformance/coverage/m1-scope-retirement.md)
explain the changed law and denominator. Unmet consumer requirements stay uncovered.

## Archived broader model evidence

As someone deciding whether to trust these proofs, use this register to see that
the model's guarantees actually constrain the model — that each law was shown to
**fail** when the behaviour it describes is broken, rather than merely shown to
compile when it is not.

The four mutations below are the ones the registry-mode epic names. Each was
executed. None is a proposal.

## What counts as a kill here

A mutant is killed when a **named obligation stops holding**, not when the file
stops compiling. Those are different events and only the first is evidence:

- the mutated definition must **elaborate** first, so what is measured is a
  semantic change and not a syntax error;
- the kill must land on an obligation, not on a restatement. Mutating
  `applyEdge` trivially breaks the effect lemmas that restate `applyEdge`, which
  proves nothing; so each mutation carries its effect lemma with it, and the
  failure surfaces where the *invariant* is established;
- a **positive control** shows the same obligations hold on the unmutated tree.

The first run of this campaign killed all four at the effect lemmas. That was a
near-tautological result and was discarded rather than reported.

The campaign mutated `Model.lean` at sha256 `c951e4bd7a0037431238affac3e85aa07f3c505d1a7fde4b15c9d86df7669cc8`. The current `Model.lean` is `beec6567f46b7b0bb273ebe3e28cf7197bf56668bcdf8dfd4590c58ec6d29d97`, and the campaign has not been rerun against it: the four rows below are evidence about the revision they name and nothing later.
A campaign is evidence about the exact definitions it broke, so a later model is
a later campaign, not a carried-forward result.

## The mutants

| id | mutation | must break | killed at | outcome |
| --- | --- | --- | --- | --- |
| mint-second-active-token | `insertActive` mints a **second** active token for the key | active-witness-unique, and supply-matches-leaf-state for the active kind | the active-supply conjunct of `step_ok_consistent`, `insertActive` branch | **KILLED** |
| mint-absent-on-active-key | `insertActive` also mints an **absent** token for the key it just made active | absent-witness-unique and witness-kinds-exclude | the custody-census conjunct of `step_ok_consistent`, `insertActive` branch | **KILLED** |
| attest-active-key | the read drops its terminal requirement, so an **active** key can be attested | terminal-attestation-sound | the terminality derivation in the `witnessTerminal` branch of `step_ok_consistent` | **KILLED** |
| leave-absent-custody-on-activation | `updateActive` **keeps** the custody entry, leaving the absent token outstanding | supply-matches-leaf-state and witness-kinds-exclude | the custody-census conjunct of `step_ok_consistent`, `updateActive` branch | **KILLED** |

Positive control: on the unmutated tree the statements prove, and the compiled
axiom report carries no `sorryAx`.

## Why the kills land where they do

Every promise in the interface is read off one invariant — `Consistent` — which
`step_ok_consistent` proves survives each of the seven edges. active-witness-unique and absent-witness-unique are its
supply conjuncts read one state at a time, supply-matches-leaf-state is the same fact stated as a
biconditional, witness-kinds-exclude follows from the supply conjuncts plus a key having one leaf,
and terminal-attestation-sound is its terminal-holding conjunct. So a mutation that breaks a supply law
breaks the invariant's corresponding conjunct, and everything downstream of it
fails with it.

attest-active-key is the one worth reading closely. Dropping the terminal requirement from the
read does not break arithmetic; it breaks a *derivation*. The `witnessTerminal`
branch establishes that the attested key's leaf is terminal by reading it out of
the verified read. With the mutation the read no longer carries that fact, so the
attestation can no longer be shown sound — which is exactly terminal-attestation-sound failing, and
exactly the defect the mutation describes.

## Limits

Four mutants are four points, not a mutation score. A campaign that enumerated
every guard and reported a survivor census would say more, and is not what this
is: these four were chosen because the interface names them as the failures its
witness laws exist to prevent.

A killed mutant shows the proofs constrain the mutated definition. It does not
show the definition is the right one — that is what the operator's rulings, the
interface and the simulation are for.

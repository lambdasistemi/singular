# Mutation ledger

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

The campaign mutated `Model.lean` at sha256 `c951e4bd7a0037431238affac3e85aa07f3c505d1a7fde4b15c9d86df7669cc8`.
A campaign is evidence about the exact definitions it broke, so a later model is
a later campaign, not a carried-forward result.

## The mutants

| id | mutation | must break | killed at | outcome |
| --- | --- | --- | --- | --- |
| M1 | `insertActive` mints a **second** active token for the key | W1, and S3 for the active kind | the active-supply conjunct of `step_ok_consistent`, `insertActive` branch | **KILLED** |
| M2 | `insertActive` also mints an **absent** token for the key it just made active | W2 and W4 | the custody-census conjunct of `step_ok_consistent`, `insertActive` branch | **KILLED** |
| M3 | the read drops its terminal requirement, so an **active** key can be attested | S1 | the terminality derivation in the `witnessTerminal` branch of `step_ok_consistent` | **KILLED** |
| M4 | `updateActive` **keeps** the custody entry, leaving the absent token outstanding | S3 and W4 | the custody-census conjunct of `step_ok_consistent`, `updateActive` branch | **KILLED** |

Positive control: on the unmutated tree the statements prove, and the compiled
axiom report carries no `sorryAx`.

## Why the kills land where they do

Every promise in the interface is read off one invariant — `Consistent` — which
`step_ok_consistent` proves survives each of the seven edges. W1 and W2 are its
supply conjuncts read one state at a time, S3 is the same fact stated as a
biconditional, W4 follows from the supply conjuncts plus a key having one leaf,
and S1 is its terminal-holding conjunct. So a mutation that breaks a supply law
breaks the invariant's corresponding conjunct, and everything downstream of it
fails with it.

M3 is the one worth reading closely. Dropping the terminal requirement from the
read does not break arithmetic; it breaks a *derivation*. The `witnessTerminal`
branch establishes that the attested key's leaf is terminal by reading it out of
the verified read. With the mutation the read no longer carries that fact, so the
attestation can no longer be shown sound — which is exactly S1 failing, and
exactly the defect the mutation describes.

## Limits

Four mutants are four points, not a mutation score. A campaign that enumerated
every guard and reported a survivor census would say more, and is not what this
is: these four were chosen because the interface names them as the failures its
witness laws exist to prevent.

A killed mutant shows the proofs constrain the mutated definition. It does not
show the definition is the right one — that is what the operator's rulings, the
interface and the simulation are for.

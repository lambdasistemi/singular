# Tasks

## Contract

Model base d92f35bf722120369c386ce09e6c7a40d321182f.
S1 delivery is verified at 88a7bceb3fc18115b7b1966401ae9f51cffd246e:
the frozen local gate and exact-head CI, Registry and Conformance passed;
all five implementation checkpoints are approved.

On 2026-09-22 the epic owner applied the operator's standing direction to
integrate the green checkpoint and split the rest. S1 is this ticket's
delivery. S2 transfers undiminished to an epic-owned residual under #154,
dependent on #209's DSL; it is no longer an open slice of this ticket.
These checks record S1 delivery and review readiness. Acceptance and merge
remain with the epic owner. No held or uncovered consumer is counted as passed.

- [x] T178-01 Correct the refund-only datum and all owned codecs/constructors.
- [x] T178-02 Derive custody identity from the complete asset set and retain executable valid, zero-asset and two-asset evidence.
- [x] T178-03 Preserve affected custody/refund behavior across validator and builder consumers with actual boundary observations.
- [x] T178-05 Publish the complete file/line/disposition inventory and wire compatibility limits.
- [x] T178-06 Verify root CI, snapshot, approval trail and exact-head Registry/Conformance; deliver a ready-for-review PR.

## Transferred residual

T178-04 is transferred, not completed or waived: the new conformance row for
the refund-only absent custody wire; registration at the actual CI judgment
sites; and an executed unregistered-row control. The epic owner retains this
obligation pending the DSL landing and authorization to file its separate issue.
S1's gate does not satisfy it.

## Evidence limits

The wrong-reference control reached edge 4 and still passed. Reference selection
remains a named uncovered consumer. The bound Lean model constrains custody,
token and refund obligations but does not model booking reference-input identity.
The existing CG11/CG12/CG19 authority holds remain held; naming is excluded and
unchanged. The final task-stamp commit changes delivery metadata only.

# Delivery plan

## Contract

Base d92f35bf722120369c386ce09e6c7a40d321182f. Two ordered behavioral slices
after a planning-only commit.
No production edits by the ticket owner.

S1 corrects shared custody representation, real validator/library consumers,
minimal existing consumer adaptations and edge documentation. S2 adds the bound
conformance row, registration and coverage metadata. S2 is held until the parent
reports the DSL merge, and remains required for full acceptance. No new
conformance test-tree additions in S1. Preserve existing edge semantics.

Before implementation: model base and source citations are verified; commit
the six mandate files and open a draft PR after required local checks.
Freeze Opus's Gate S against the acceptance lines. Missing CI
coverage is an explicit parent question; an existing Conformance selection and
verdict assertion may be extended as the ticket's authorized CI change.

The approved Sol owner records RED before production, then GREEN checkpoints
for each acceptance line and pre-push. It continues work while Opus reads only
commits and mechanical receipts/decision records. Every checkpoint is forwarded
immediately; every verdict is REVIEW-APPROVED or REVIEW-BLOCKED with a review
field. One repair per checkpoint, second block goes upward. No final audit seat.

T.O. acceptance checks the complete approval trail, exact final tree, task stamp
and frozen gate on the final head. Root CI runs from repository root. Snapshot
command runs from conformance/. Exact-head remote Registry and Conformance are
separate readiness conditions. No merge or release authority is implied.

Budget: four hours wall from ticket START, halfway assessment at two hours.
One full gate per candidate; inspect and fix only for concrete new failures or
deltas. Integrate an independently green checkpoint and split remaining work
when the authorized scope cannot fit; never label an incomplete wire accepted.
Gate author phase: 15 minutes, zero builds or controls, one approved Opus seat.
Artifact ceiling: each mandate file <= 5 KiB and <= 90 lines; six files together
<= 18 KiB/300 lines. Worker packet <= 12 KiB/180 lines. Measured bytes/lines
go in runtime measurements; provider tokens unavailable unless reported.

Publication boundary: naming-onchain's independent mirror remains outside this
ticket and epic. Record its exact location and incompatibility honestly. #211
owns the new command; simulator transaction replay is also outside this slice.

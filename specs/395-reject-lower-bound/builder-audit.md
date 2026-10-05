# Builder validity audit

As a maintainer, I want a transaction built from an acquired view to start
no later than that view's tip, so a sparse chain does not first reveal a
clock-dependent lower bound. This audit distinguishes corrected builders,
source observations and work that still needs its own repair. Read the
[story](spec.md) and [implementation plan](plan.md) alongside it.

## Rule and model

A reject starts at `cpSlot (viewPoint view)` and ends strictly later. Its
clock chooses only the upper bound. Lean `exitAdmission` admits `.reject`
without reading time ([Model.lean:1201](../../lean/Singular/Model.lean#L1201));
the state-validator property
`prop_reject_admitted_for_every_validity_range`
([cage.props.ak:201](../../onchain/validators/cage.props.ak#L201)) names the
corresponding script rule. No retract deadline is a premise of reject
admission. The client command's policy about when to offer rejection is a
separate concern.

A retraction still needs its finite interval inside phase two. If its phase-two
opening or its caller's chosen lower bound is ahead of the acquired tip, the
library now refuses `lower-bound-ahead-of-view` before balancing or evaluation.
It does not move the opening earlier or change the validator's phase rule.

The model and census are bound to base `22637d46`; the reject correction is
`877a04f3`; the retraction correction is `c2b44133`. Lean, scripts, corpus and
consumer expectations are unchanged. A source verdict below means inspection of interval
construction, not independent ledger execution or acceptance of a retained
journey.

## Builder census

The table covers the registry builders, their two retraction entry points and
callers, and the additional construction sites found by scanning Haskell and
shell sources for lower and upper validity setters. An absent lower bound is
unbounded below and satisfies this particular rule; that says nothing about
an upper bound expiring, script correctness or complete lifecycle behavior.
Source locations refer to this ticket's implementation after the corrections.

| Builder or entry point | Interval and source location | Verdict against the acquired-tip rule |
| --- | --- | --- |
| Reject, including reference-script form | `Reject.hs:241–250`, `:338–339`: tip lower; first convertible clock-based upper, at least lower plus one. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Reject.hs#L241). | Corrected here; built-body lag, clock-behind and shortened-horizon checks. |
| Retraction with caller tip | `Retract.hs:178–182`, `:218–220`: lower is max of supplied tip and ceiling phase-two opening; upper is first convertible window-end/fallback slot minus one. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Retract.hs#L178). | Corrected here: named refusal if lower exceeds the actual view tip. |
| Retraction without caller tip | `Retract.hs:104`: supplies zero to the same builder. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Retract.hs#L104). | Shares the acquired-tip guard; lower is phase-two opening when admitted. |
| Reclaim command | `CLI/Reclaim.hs:115–143`: reads the acquired tip, checks the window, passes that tip to retraction. [Source](../../offchain/cli/src/Singular/CLI/Reclaim.hs#L115). | Library guard also catches a ceiling opening beyond a floor-based caller check. |
| Connected fold | `ConnectedFold.hs:294–316`, `:396`: earliest processing deadline as upper, with clock-based conversion fallbacks; no lower. [Source](../../offchain/lib/Singular/Registry/TxBuilder/ConnectedFold.hs#L294). | No lower bound. |
| Update and ordinary fold | `Update.hs:195–196` selects the connected-fold upper; `Update/Build.hs:205` writes only upper. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Update/Build.hs#L205). | No lower bound. |
| Ordinary request booking | `Request.hs:94`, `:121`: clock stamps the request datum; basic body has no interval setter. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Request.hs#L94). | No lower or upper bound. |
| Edge booking | `Edges.hs:690–721`: clock stamps datum, basic body otherwise. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Edges.hs#L690). | No lower or upper bound. |
| Measured edge booking | `Edges.hs:848–871`: clock stamps datum, basic body evaluated and balanced. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Edges.hs#L848). | No lower or upper bound. |
| Script publication, including boot reference publication | `Edges.hs:329–337`: basic body. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Edges.hs#L329). | No lower or upper bound. |
| Boot | `Boot.hs:247`: basic body, with no validity assignment. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Boot.hs#L247). | No lower or upper bound. |
| Stake-script registration | `Register.hs:95–100`: only registers the credential in its build program. [Source](../../offchain/lib/Singular/Registry/TxBuilder/Register.hs#L95). | No lower or upper bound. Consumer-registration entry point was removed, so no extant interval to judge. |
| End and malformed-request cleanup | `Lifecycle.hs:129`, `:313`: basic bodies. [Source](../../offchain/lib/Singular/Registry/Lifecycle.hs#L129). | No lower or upper bound. |
| Indexer funding/consolidation | `Node/Indexer.hs:389`: basic body. [Source](../../offchain/node-internal/Singular/Registry/Node/Indexer.hs#L389). | No lower or upper bound. |
| Open-datum application update | `Application/OpenDatum/Update.hs:126–145`: build program spends, outputs, signs and attaches/references scripts. [Source](../../offchain/lib/Singular/Application/OpenDatum/Update.hs#L126). | No lower or upper bound. |
| Repair journey's ordinary retract | `journey/repair/Main.hs:1012`: calls no-tip library retraction through an obsolete provider interface. [Source](../../offchain/journey/repair/Main.hs#L1012). | Library corrected; journey itself remains unverified and needs its existing migration. |
| Repair journey's unsigned-owner retract control | `journey/repair/Main.hs:1152–1169`: ceiling phase-two opening lower; floor closing minus one upper. [Source](../../offchain/journey/repair/Main.hs#L1152). | Unguarded future lower: separate repair draft below. |
| Repair journey's permissionless fold | `journey/repair/Main.hs:1850–1898`: deadline/fallback upper only. [Source](../../offchain/journey/repair/Main.hs#L1850). | No lower bound; retained journey remains unverified. |
| Register journey's resume and support retracts | `journey/register/Main.hs:1701`, `:2739`: pass a separately observed tip to the library. [Source](../../offchain/journey/register/Main.hs#L1701). | Current library checks actual view; legacy caller interfaces still need the existing migration. |

## Further work

Two larger lower-bound findings have been drafted for the ticket owner:

- [Legacy repair validity draft](/home/paolino/.orch-runtime/singular/epic-301/to-395/commit-owner/handoffs/bug-legacy-repair-validity.md): the unsigned-owner control has no acquired view and cannot establish its intended validator refusal while its lower bound is still ahead. Repair is already classified unverified in the component inventory; this ticket does not revive it.
- [Conformance lower-bound draft](/home/paolino/.orch-runtime/singular/epic-301/to-395/commit-owner/handoffs/bug-conformance-lower-bound-view.md): placed rejects and hand-built retracts use time-derived openings across multiple acquisitions without comparing the resulting lower with a single acquired tip. Fixing their view and placement lifecycle exceeds the product builder repair.

These are source-derived counterexamples, not executed live failures. Their
interval contract and dependent acceptance remain open. A completed census
means every construction class was accounted for; it does not mean every
retained builder is safe or verified.

## Release failure

The release job failed for a different timing cause: its untampered conformance
reject batch's upper bound had expired. The [job](https://github.com/lambdasistemi/singular/actions/runs/37294907351/job/111713723071)
ran at `2a77ebbaf4ca30f2cda6c2fa29f10aad646e04b5`. Its archived node outcome for
transaction `38a71ec287ea38fc50d5623f3c5f452e8e3d136771556e8e40be47446c17bae9`
reports `OutsideValidityIntervalUTxO`: lower slot 1062, exclusive upper slot
1348, current slot 1372. The lower was behind the current slot; 1372 was already
past 1348. This settles the distinction from the product reject's future lower.

The generic row built and submitted three controls within one request window.
The first submitted at 10:30:39, the second at 10:30:51 and the untampered third
at 10:31:00 UTC on 2026-10-05. They reused the reported validity interval
`[1791196229200,1791196257800)`. The third became chain `unsupported` versus model
`accepted`, then the runner failed “record 2 does not agree with the model”.
The separate split-refund disagreement was explicitly recorded as the known
refund-position divergence under [#361](https://github.com/lambdasistemi/singular/issues/361);
it remains a disagreement and is not evidence of a successful consumer promise.

This conformance assembly uses its own `Run/Fold.hs:376–379` interval writer,
not the product reject builder. The
[expiry bug draft](/home/paolino/.orch-runtime/singular/epic-301/to-395/commit-owner/handoffs/bug-conformance-reject-window-expiry.md)
asks for enough time per control and a named setup failure before submission
when a placement expires. No local reproduction or conformance expectation
change is claimed.

Evidence retained under the commit-owner runtime: `evidence/release-job.log`
SHA-256 `60fb96eb4663fb8ff29442e31c2d5b17be101ac4ece85a2dfa8c457af30b15ed`,
lines 2929–2942 and 2995–2999; downloaded artifact `conformance-receipts`,
`conformance-receipts.FW80GS/replay/38a71ec287ea38fc50d5623f3c5f452e8e3d136771556e8e40be47446c17bae9/outcome.json`
SHA-256 `760f92c00e51d945a141b29d2ef6c571826a4df3df7d0486aacc19f75526c87e`.

## Sparse blocks and verification limits

One proposed Registry CI job runs the existing connected phase-three reject
on a genesis variant with active-slot coefficient 0.05, one-second slots and
an epoch of 2000 slots. It changes only the supplied genesis and adds one job.
The existing `E2E_GENESIS_DIR` input selects it; ordinary fast-window rows retain
their current genesis. The sparse job's ledger acceptance is pending exact-head
CI, and this page claims neither a local sparse run nor a preprod write.

The focused reject test executed a built body with a controlled view whose tip
lags the host clock: three checks passed, including 100 generated lag cases.
Its test-only commit failed against the unchanged base implementation. The
retraction tests passed five checks, including the existing funding and horizon
properties, and independently exercised both public builders, a future caller
slot and phase-two opening equality; their separate RED/GREEN receipts belong
to the commit checkpoints. Mock script evaluation is a builder boundary, not
script or live-ledger evidence. Broad checks and all PR checks are owed by
exact-head CI under the ticket's frozen gate.

## Harness and retained-source appendix

These additional builders carry test or retained-journey evidence. They do not
expand the claim about product acceptance.

| Construction class | Interval and source locations | Verdict |
| --- | --- | --- |
| Conformance hand-built fold/reject | `Run/Fold.hs:289–298`, `:376–379`: optional caller lower, supplied or near-clock upper. | Generic writer cannot certify caller lower against one view; tracked in conformance draft. |
| Conformance placed single/batch rejects | `Run/Live.hs:1019–1024`, `:1619–1621`: opening plus offset lower, window-capped upper. | Unguarded lower against acquired tip; separate draft. |
| Conformance hand-built retract | `Run/Live.hs:1831–1860`: phase-two opening lower and closing minus one upper. | Unguarded lower against acquired tip; separate draft. |
| Conformance outside-window retraction controls | `Run/Live.hs:1752–1764`: rewrite both bounds for before/after-phase-two controls. | Intended script refusals still need ledger-admissible placement; separate draft, no weakened expectation. |
| Conformance booking | `Run/Book.hs:351`: basic body, no validity setter. | No lower or upper bound. |
| Conformance boot | `Run/Cage.hs:390`: basic body, no validity setter. | No lower or upper bound. |
| Conformance funding, splitting and consolidation | `Run/Wallet.hs:143`, `:174`, `:248`, `:307`: basic bodies. | No lower or upper bound. |
| Conformance application controls | `Run/CaRows.hs:149`, `:749`: basic bodies. | No lower or upper bound. |
| Repair funding, naming and end controls | `journey/repair/Main.hs:346`, `:1510`, `:1552`, `:1759`, `:1925`, `:1970`, `:2033`, `:2073`, `:2123`, `:2156`. | No validity setter beyond the retract and fold already listed; source-only, unverified journey. |
| Register journey funding and naming constructions | `journey/register/Main.hs:1559`, `:2375`, `:2450`, `:2505`, `:2574`, `:2625`, `:3326`, `:3374`, `:3671`, `:3745`, `:3803`, `:3888`, `:3947`, `:4021`, `:4339`, `:4439`, `:4582`. | No own validity setter; source-only, unverified journey. |
| Recovery journey constructions | `journey/recovery/Main.hs:1668`, `:1714`, `:1897`, `:2039`, `:2214`. | No own validity setter; delegated intervals follow library; retained-source observation only. |
| Lifecycle naming journey constructions | `journey/lmlc/Main.hs:1189`, `:1245`, `:1290`, `:1391`, `:1460`, `:1514`. | No own validity setter; retained-source observation only. |
| Lifecycle insertion journey funding | `journey/li01/Main.hs:647`. | No own validity setter; retained-source observation only. |
| Lifecycle refusal journey constructions | `journey/li-refusals/Main.hs:628`, `:1604`, `:1793`. | No own validity setter; retained-source observation only. |
| Retirement journey constructions | `journey/retirement/Main.hs:2355`, `:2872`, `:2943`, `:3006`, `:3121`, `:3163`, `:3227`, `:3419`, `:3582`, `:3743`. | No own validity setter; delegated intervals follow library; retained-source observation only. |

The census excludes third-party transaction builders and fixture bodies in unit
specs. Imported builders are not declared verified by this source census. No
shell source in this tree supplied another validity-bound construction site.

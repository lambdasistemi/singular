# Permanent registration and termination: candidate evidence

As a participant, I create a new registry, register a key and terminate it
permanently. The fixed contract refuses every other registry edge. The ordinary
CLI selects the known new scripts and refuses unknown supplied code. Old
registries are abandoned, with no migration or compatibility recognition.

The broader model remains bound to base `464ed8674de626470396cc871f3af85a1d489477`.
The new law is `Singular.M1`, source SHA-256
`e94c1bbc502514a7be7083f56a52b595bd435050cbc868b61fe44a1fe7301a93`. Its audited statement manifest
and driver corpus carry all source and declaration digests; the broader generic
corpus and driver remain byte-identical. Naming and lifecycle corpus envelopes
are refreshed for the wider source inventory; their behavior is unchanged.

| Boundary | Actual evidence | Limit |
| --- | --- | --- |
| Bounded model | 10 audited declarations using standard axioms; 10 executed scenarios and 4 batches, 30 independently derived observations | Abstract model, not Cardano execution |
| Conformance transport | 10 scenario and 4 batch outputs match the bounded driver; broader-law and unknown-contract controls fire | No live consumer comparison receipt |
| Exported state/request/witness code | 57 component evaluations: 2 allowed edges, all 5 excluded edges, mixed batch, 6 malformed or alternate contexts, joined component contexts for every edge and four application booking/update/release contexts against both fixed and broader code | Fixture roots and witness policies; absent starting states are unreachable from genesis |
| Boundary checker fault | Replace the bounded exported state with the broader program; the same checker exits1 and names accepted terminal witnessing as a mismatch | Controlled artifact mutation, not a chain transaction |
| Script identity and size | Nix identity and publication-size checks passed, including their controls; state15,231 bytes under15,878 limit | Unapplied identities; application and witness instance pins are derived from the boot seed |
| Ordinary CLI handlers | 13 examples passed including lifecycle receipts and unknown-code refusal with final fixed script pins | Synthetic provider fixture |
| Extracted ordinary CLI journey | The complete existing package check passed: archive integrity, model stamp, script identity, connected registration, payload update with root unchanged, permanent termination, rejection, owner reclaim, capability/event and fault controls, and both retained archive commands | Owner execution on a disposable local devnet; no public-network acceptance or live bounded consumer comparison receipt |
| Ledger refusal controls | Two fresh keys on one fixed registry each satisfy 29 of 29 take clauses: duplicate Active insertion, stranger-signed update, release outside a fold and Terminal reinsertion are submitted without local evaluation and refused by the ledger, beside accepting controls and readbacks | Owner execution; the selected run covers 5 of 32 approved application cases, with 27 uncovered in that run |
| Repository boundaries | One aggregate invocation failed on a stale generated simulator identity; targeted repair passed. Separately canceled model and release checks passed; repaired documentation check passed, including computed evidence, source links and fault controls | Exact-head hosted outcomes are recorded separately in the PR and immutable handoff |
| Public conformance inventory | 47 rows, 46 owned; new bounded story remains uncovered; original broader rows retained | A component result never assigns an executed product status |

New state: `807d91e4dc360ab722ad2b3b47d6b3d000237992048f3333ae799aaa`. New unapplied witness: `4c87b7aa4c2f509c8de536243f98da7a44b48cfc5bb541e19c38f5a1`.
New unapplied application: `eeb82738115c80dc63d606513387b85bb93e35657744a34e318d3f03`. Its booking, payload-update and release guards are unchanged; its fixed state pin matches the new registry.
All four fixed scripts, compiler identity, parameter counts and byte digests are
recorded in `onchain/permanent-contract.json`. Every original broader compiled identity is unchanged. The simulator preserves those broader profiles and explicitly discloses that it has no playable bounded profile. The theorem inventory retains all prior declarations and adds the ten audited bounded statements: 136 obligations, 77 manifest-bound and 59 unclassified; integration coverage debt stays visible.

Reproduce the component boundary from a clean checkout:

```sh
nix build --no-link ./onchain#checks.x86_64-linux.permanent-boundary
nix build --no-link ./onchain#script-identity ./onchain#checks.x86_64-linux.reference-publication-size
nix run .#model-check
nix develop -c just model
nix run ./offchain#cage-tests -- --match Singular.CLI.CommandRun
nix run .#demo1-cli-check
nix run .#demo1-cli-attach-takes
```

The first check retains raw evaluated programs, context arguments, exits, output
and controlled-fault replay. The committed component and transport reports are
under `evidence/`. The [connected command receipt summary](evidence/packaged-lifecycle.json)
binds the extracted candidate `2a243ef03d556bd6c725e097d67d3d3e6ffdb442`, all four compiled script digests,
the bounded law source and individual command receipt hashes. The archive's
application model stamp is `de34300540223ccedf1ca85216b131fd09a148b4`, distinct from
the bounded registry law source digest above. Later reference-index and independent
CLI-control runner repairs leave these production CLI, model and script sources unchanged.

The connected receipts show an active registered leaf, an application update
with the same registry root and a 2,000,000-lovelace deposit still held, then a
terminal leaf without a live holding. Rejection returned 2,000,000 lovelace from
the request's 3,000,000 with the original 1,000,000 tip; owner reclaim returned
the whole locked value. The existing journey checks these amounts against signed
transaction outputs and node readback, with deliberate receipt and readback edits.
It also checks later registrations after both exits. Its 178 prepared submissions
across 12 journals name their actual observation capability; all eight commands
have execution receipts. This product execution does not assign an executed
status to the uncovered bounded public conformance story.

The first connected attempt exposed the old application's state pin at approval
minting. The separate fixed application now passes 66 controls and the complete
connected journey. The independent CLI refusal runner was also corrected to load
the same fixed scripts before exercising its ledger controls. No old deployed
recognition path was added.

The hosted `a0fc7fe5` cross-wallet recovery case stopped before signing because
the built fold was inside the existing 30-second deadline guard. Its requested
hold was never reached, so that recovery evidence is missing. Hosted served-preview
verification also failed temporary DNS. Both results remain retained and affected
acceptance held; the guard, processing window and expected recovery behavior are
unchanged. Performance work belongs to the separate owner. The final exact-head
hosted outcomes remain distinct from these local results.

These results establish their named boundary only. Existing timing
and protected-rejection discrepancies are not counted as passing behavior;
folding an update outside its processing window remains affected acceptance
held where the model and validator differ. KERI integration and broader uncovered
requirements remain visible. Protected rejection follows this carve through
#498/#495 under separate identities; this candidate does not close the first milestone.

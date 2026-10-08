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
| Ordinary CLI handlers | 13 examples passed including lifecycle receipts and unknown-code refusal | Synthetic provider fixture; final packaged script pins require the connected run |
| Extracted ordinary CLI journey | Archive assembly, checksums, source/model stamp, script identities and surface fault controls passed; first connected run booted and read the fixed registry, then exposed the old application pin at approval minting | Repaired application passes 66 component controls; completed connected lifecycle remains pending |
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
```

The first check retains raw evaluated programs, context arguments, exits, output
and controlled-fault replay. The committed component and transport reports are
under `evidence/`. They establish their named boundary only. Existing timing
and protected-rejection discrepancies are not counted as passing behavior;
folding an update outside its processing window remains affected acceptance
held where the model and validator differ. KERI integration and broader uncovered
requirements remain visible. Protected rejection follows this carve through
#498/#495 under separate identities; this candidate does not close M1.

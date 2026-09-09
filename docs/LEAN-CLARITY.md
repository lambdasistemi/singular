# Lean clarity record

The simulator derives behavior from the frozen `Singular.Model` definitions, `Singular.Statements` declarations, and the corrected Lean-generated corpus. Operator story intentions supply illustrative vocabulary and outcomes to explore. They do not override the executable model.

## Formal identities

| Artifact | SHA256 |
| --- | --- |
| Model.lean | `3bcb168f99be9ba920dd4136ee464577218bce8c96b67e877dbc87032c5fa3ce` |
| Statements.lean | `996d668f06f474d6ea3f33e5419d8be105bec58756e50d16b62ccbdedfde0138` |
| Main.lean | `cc1f1e8b1fc02b6fc8d1044b0d1e25f6a7d436609922832fa9a1016597595f65` |
| Corpus | `ad85b170ccd108952f0ab958618cd32088ee66fc43000ad928aa755c4db06675` |

Changing any bound input invalidates the current evidence. The initial corpus was superseded by the corrected 58-row export; final gates consume only that corrected identity.

## Decisions and model limits

| Point | Formal pointer | Treatment |
| --- | --- | --- |
| Name and address vocabulary | `Proposal.key`, `Output.datum`, `Resolution.address` | Key 42 and A=100/B=200 are illustrative numeric labels. No string-name encoding, DNS, or real address codec is inferred. |
| Change address versus retire | `step.evolve`, `foldOne` update arm | Evolve changes the address. Update completion produces `over`; it does not update the address. The UI says “Queue retirement (Update)”. |
| Competing Inserts | `step.createInsert`, `foldOne` occupied-key guard | Creation does not read registry occupancy. Both requests can queue; folding both in one batch refuses atomically. The successful story folds one and separately withdraws the other. |
| Cancellation and refund | `Commitment.withdraw`, `step.withdraw`, `Result` | Cancellation requires a recognized asset bound to registry, request, and exact refund. The result consumes the request but contains no payment flow. The UI does not claim a wallet received funds. |
| Supplied application evidence | `Approval`, `ReleaseEvidence`, `EvolutionEvidence`, `approved`, `step.release`, `step.evolve` | Accepted and witness booleans are modeled evidence, not verified scripts or signatures. No named stakeholder is granted extra privileges. |
| Diagnostic conformity | `Approval.conforms` comment; acceptance functions | `conforms` is not consulted by native checks. The model can accept diagnostic nonconformance; the simulator preserves that behavior. |
| Pending resolution | `resolve`, active entry with no matching application UTxO | Terminal release moves the NFT into request custody while the entry remains active. Resolution is pending until completion. |
| Identity reuse and batches | `representative`, `foldItems`, `sameNet` | Default identity reuse allows a Delete/reinsert logical burn and mint to cancel. The batch still needs its native spend witness. Batch order is explicit and failures never skip an item. |
| Numeric runtime boundary | Lean `Nat`/`Int`; simulator public validators | Inputs must be safe integers; all nested state/action/evidence/output fields are checked. Net sums use exact BigInt. Delete incarnation overflow is refused before returning a result. This is a simulator limit, not a Lean guard. |
| Refusal vocabulary | Explicit error strings in `foldOne` and `step` | Model reasons retain their Lean spelling and evaluation order. `invalid-nat`, `invalid-int`, and `invalid-shape` are extra runtime boundary reasons. |
| Seeded corpus states | `Main.cases` | Some corpus states deliberately vary registry entries and need not be reachable. Passing those rows does not instantiate a theorem requiring `Reachable`. |
| Free play and story parity | Finite corrected corpus | Only exact before/action matches have observed Lean parity. Story outcomes and free play use the same JS engine; no new Lean trace driver was compiled. |

No unresolved definition was silently filled in. These are explicit boundaries of the model or of the instrument. Additional deployment semantics must be supplied by the design owner through a new frozen model.

## Theorem coverage gaps

All 41 declarations remain STATED with admitted proof debt. The ledger contains 12 controlled finite consequent checks, 17 action exhibits only, and 12 gaps. Exact rows and pinned exhibit identities are in the repository’s [coverage ledger](https://github.com/lambdasistemi/singular/blob/feat/model-simulation-s1/simulator/coverage.json).

The following declarations have no executable nonvacuous exhibit in this candidate:

- `Singular.Statements.insert_commitment_injective`
- `Singular.Statements.action_domain_separation`
- `Singular.Statements.foldOne_insert_iff`
- `Singular.Statements.foldOne_terminal_iff`
- `Singular.Statements.sequential_fold_cons`
- `Singular.Statements.supply_conservation`
- `Singular.Statements.over_terminal`
- `Singular.Statements.over_no_representative`
- `Singular.Statements.request_single_spend`
- `Singular.Statements.approval_scope_checked`
- `Singular.Statements.resolve_address_iff`
- `Singular.Statements.resolve_pending_iff`

Reachability-dependent declarations have not been converted to checks over arbitrary seeded states. The 17 exhibits-only rows identify actions relevant to their declarations, but do not implement all quantified binders or both directions of an equivalence. They are not passing properties.

## Refusal coverage and reconciliation limits

The source inventory discovers 28 distinct Lean refusal names and records their source line sites. Seventeen have corpus or story exhibits. The eleven remaining names are `application-unavailable`, `evolution-representative`, `movement-net-not-zero`, `not-active`, `outsider-cannot-create-representative`, `registry-binding`, `representative-witness`, `terminal-output`, `unrecognized-action`, `utxo-id-reuse`, and `withdraw-tag`.

The hashed formal source, finite parity, and source-line refusal inventory do not establish complete conjunct-level coverage. This candidate does not contain a full bidirectional parser reconciling every prose atom and every guard conjunct to executed semantic evidence. That remains a named instrumentation limitation, alongside the theorem gaps above.

## Template adaptation

The page was started with the shared `page-template.mjs start` command and retains the exact template snapshot. Its first style block is unchanged. Shared DOM helpers and immutable tree primitives are retained verbatim in `template-generic.js`. Singular-specific panels and renderers replace checkpoint-specific controls, scenes, and value drawers. The added stylesheet is a second style block.

The machine-specific renderer port also changes the template’s generic page wiring and render orchestration to use Singular’s state and evidence shapes. A full generic-renderer identity check is not claimed. No prior MPFS or KERI model source was imported. The retained shared template is provenance, not formal authority.

## Verification boundary

The focused Node evidence covers 58 corpus rows, 32 story action steps, 41 exact theorem identities, 1,764 numeric-boundary probes, and 22 self-falsification controls. The incorrect-acceptance control preserves every genuine accepted transition and flips only refused transitions; it must fail at `S11c-terminal-withdraw-refused`.

Local real-DOM evidence and exact tested asset hashes are in `simulator/evidence/` in Git. Live publication and independent audit remain separate. Verification consumed **0/2 Lean compile invocations** and **0 full Nix gates**. This return is **SIMULATOR-CANDIDATE**, not proof, audit acceptance, or readiness.

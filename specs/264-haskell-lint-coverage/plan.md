# Haskell lint coverage plan

As a contributor, I run the current lint command and see defects in active
registry sources, while existing libraries and commands retain their names.

```mermaid
flowchart LR
    A[Cabal source directories] -->|inventory| B[Lint discovery]
    C[Direct GHC naming sources] -->|inventory| B
    B -->|source files| D[Fourmolu and HLint]
    E[Cabal components] -->|build| F[Existing CI carriers]
    D -->|result| G[Ticket evidence]
    F -->|result or gap| G
```

## Decisions

| Decision | Reason |
| --- | --- |
| Keep one maintenance slice for Cabal deduplication and lint discovery. | Both configuration changes are small and share the component inventory. |
| Review any layout-only source changes as a separate diff/commit. | It makes semantic changes visible and respects the source fence. |
| Use the existing lint executable for the negative control. | A source-name search does not establish that the executable rejects malformed input. |
| Keep the current exports and executable names as the compatibility baseline. | This ticket makes no public API or command migration. |

The implementation owner may change `offchain/singular-registry.cabal` and
`offchain/nix/checks.nix`. The owner may propose separately reviewed layout-only
edits in active executable or naming source files when the expanded lint finds
them. Excluded source trees receive no edits. No source, test, Conformance, Lean,
workflow, or validator changes are implied by this plan.

The owner must distinguish baseline failures from regressions, preserve actual
HLint semantics when handling hints, and produce a lint negative control in a
newly included active directory. The final owner receipt records the exact
source discovery and exclusions, Cabal declaration/export/name comparison,
component build commands/results, and actual lint results.

The active CI commands are copied verbatim into the frozen gate only after their
source closure is stated. Question Q-001 holds any claim that the root build
gate proves all off-chain components.

# Haskell lint coverage plan

As a contributor, I run the current lint command and see defects in active
registry sources, while existing libraries and commands retain their names.

```mermaid
flowchart LR
    A[Cabal source directories] -->|inventory| B[Lint discovery]
    C[Direct GHC naming sources] -->|inventory| B
    B -->|source files| D[Fourmolu and HLint]
    E[Cabal components] -->|classify and build supported set| F[New CI carrier]
    D -->|result| G[Ticket evidence]
    F -->|result or gap| G
```

## Decisions

| Decision | Reason |
| --- | --- |
| Keep one maintenance slice for Cabal deduplication, lint discovery and a classified supported-component carrier. | They share the component inventory; all 19 declarations retain a truthful row. |
| Review any layout-only source changes as a separate diff/commit. | It makes semantic changes visible and respects the source fence. |
| Use the existing lint executable for the negative control. | A source-name search does not establish that the executable rejects malformed input. |
| Keep the current exports and executable names as the compatibility baseline. | This ticket makes no public API or command migration. |

The implementation owner may change `offchain/singular-registry.cabal`,
`offchain/nix/checks.nix`, `offchain/flake.nix` and `.github/workflows/ci.yml`
under epic answer A-001. The initial all-component carrier was superseded by
A-005 after a direct `connected-verifier` RED. The classified
`component-build` carrier must close the supported set derived from live
required workflows and current supported command dependencies, with an
inventory row for every Cabal declaration; its CI step must run
`nix build --quiet .#component-build` from `offchain`. It builds but does not
execute tests or command journeys. Existing CI jobs and commands retain their
current meanings. The owner may propose separately reviewed layout-only
edits in active executable or naming source files when the expanded lint finds
them. Excluded source trees receive no edits. No source, test, Conformance, Lean,
or validator behavior changes are implied by this plan.

The owner must distinguish baseline failures from regressions, preserve actual
HLint semantics when handling hints, and produce a lint negative control in a
newly included active directory. The final owner receipt records the exact
source discovery and exclusions, Cabal declaration/export/name comparison,
component build commands/results, and actual lint results.

The active CI commands are copied verbatim into the frozen gate only after their
source closure is stated. The new `component-build` row is marked as a CI change
in this ticket and must be green on the pushed head. The root build gate never
stands for the off-chain component build.

## Coverage handoff

The `b69ecca` Gate S v11 and exact-head CI receipts measured 70 discovered
Haskell files in 22 directories, 68 Fourmolu files after the two A-003
independent verifier exclusions, and 57 HLint files in nine directories. The
remaining 13 files are outside HLint enforcement under 13 configured
debt-directory names. The 214 retained hints were measured at an earlier
candidate snapshot, while the intake survey measured 218; neither is a
current-head result for excluded files. These are visible gaps assigned to
[final epic integration #278](https://github.com/lambdasistemi/singular/issues/278),
not green lint evidence for those files. The final integration child must cover
repository code beyond off-chain Haskell too.

The initial all-component carrier included `connected-verifier` and failed on
an intake-era import of an unexported library symbol. Later attempts directly
failed at `recovery-rows` and `li01`. These remain RED evidence for those exact
members. The classified carrier built ten members and reports nine retained
commands as unverified. Its 19-declaration inventory, exclusions,
included-member failure control and exact `b69ecca` build received
independent review; its required pushed-head component-build CI job passed.
That establishes compilation and inventory of the included set, not execution
of commands or build success for the nine omitted members. The contributor
guide explains the commands and boundaries.

## A-011 release-instruction correction

The operator ruled the current release README outdated and chose a forward
correction on 2026-09-25. Correct the current archive README, release notes and
consumer guides to state which commands are verified under the integrated Lean
source and which legacy commands remain unbuildable or unverified. State that
already published archives cannot be rewritten. Preserve historical evidence,
component names and app names, while #172, #282 and #283 keep the repair work.
Inspect the deployment attach script's three legacy executable dependencies
against active required workflows and the carrier closure.

Make `check_release.py` enforce the corrected availability on the assembled
on-chain archive. Update `release_surface_control.sh` to mutate the new promise,
prove restored checksum integrity and fail specifically at that surface; wire
the control into the active `release-artifacts` boundary. Recut the gate with
the PR workflow's `release-check` and `release-artifacts` commands, obtain a
fresh independent gate and candidate audit, then run it on the exact clean
head. No current documentation correction is evidence that a legacy command
builds. Conformance remains excluded, and #278 owns full-repository lint and
format coverage.

At `b69ecca`, the reviewed Gate S v11 ran the assembled archive and four
checksum-valid negative controls GREEN. Local `release-check` remained
HOST-BLOCKED under A-012, and that exact pushed-head CI job passed. The
documentation correction at `e276bab` passed its own audit, Gate S v12 and
exact-head CI on main `2ae29b0`. Main has since advanced to `80eba16`, whose
accepted Lean source is `03fd9e0` and whose constitution is 1.10.0. Its #239
retraction admission changes no #264 tooling or bounded fold-journey claim;
the model checker and Conformance workflow changed on main and must pass with
this ticket's branch. The rebased candidate needs a fresh exact-head audit,
gate and pushed-head CI; older receipts are not inherited by the new SHA.

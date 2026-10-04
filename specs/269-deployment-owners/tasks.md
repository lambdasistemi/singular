# Delivery ledger for deployment owners

As an integrator, I need the PR's task stamps to point to source and receipts rather than imply that a green build proves attachment behavior.

## Work items

| Task | Completion evidence | Status |
| --- | --- | --- |
| intake-exact-lean-tree-declaration-export-caller | Intake, exact Lean tree, declaration/export/caller map, clean baseline, draft PR and frozen gate. | Done |
| owners-facade-committed-manifest-mirror-attach-own | Owners and facade committed: Manifest, Mirror and Attach each own their declarations once, the facade's export list is byte-identical, and the focused suite's library compile is green; the candidate component build first executes on the exact-head gate. | Implementation done; candidate gates pending |
| focused-format-diagnostic-rows-committed-their-local | Focused format and diagnostic rows committed with their local receipts; the first execution against the committed candidate (post-formatting head) is the exact-head gate. | Implementation done; candidate gates pending |
| attach-rows-committed-identity-step-wired-as | Attach rows committed and the identity step wired as a step of the required Build Gate context; the base probe executed the byte-identical script against the base library (runtime receipt r2), the candidate identity step executes on the exact-head gate, and the pushed-head Build Gate run remains the open receipt. | Wiring done; candidate and pushed-head gates pending |
| guide-module-haddock-api-links-navigation-curated | Guide, module Haddock, API links, navigation and curated speech shipped; rendered-docs check green on the pre-repair candidate; this truthfulness repair is prose-only and re-verifies on the exact-head gate. | Implementation done; candidate gates pending |
| declaration-map-speech-task-stamps-clean-candidate | Declaration map, docs and speech, task stamps, clean candidate and draft PR body are finalized before the exact-head gate. | Open |

Task stamps report implementation and integration work completed before the final gate. The exact-head gate, independent audit, pushed-head CI closure of `MISSING-CI-JOB`, ticket acceptance, epic merge and release are separate receipts; no task stamp can turn an unexecuted CI job into a pass.

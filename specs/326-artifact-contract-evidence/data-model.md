# #326 data model

- contract-case-name-kind-success-refusal-consistency Contract case: name, kind (success, refusal, consistency), and per adapter one result: passed, failed, or not-supported with its reason. Evidence class per run: `test-adapter` or `devnet` (generated or external leg); `public-chain` never appears.
- confinement-allowlist-entry-file-reason-it-composition Confinement allowlist entry: file and the reason it is a composition root or fixture startup. No entry names a consumer of journeys-deployment-insert-active-update-terminal-runners.
- release-model-revision-application-model-commit-release Release model revision: the application model commit the release maps to, carried in the archive and equal to the conformance evidence's model revision.
- evidence-state-per-requirement-executed-or-partial Evidence state per requirement: executed or partial (from a receipt for the current base), or uncovered, bound elsewhere, out of scope (from the plan, shown with requirement text). A state is never written by hand in the page.

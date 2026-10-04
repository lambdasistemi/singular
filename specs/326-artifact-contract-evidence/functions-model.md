# #326 functions model

Signatures are binding in shape; auxiliary names and placement within the modules model are the commit owner's.

- shared-adapter-contract-suite `contractSuite :: AdapterHarness -> Spec` — the shared case list over one adapter (contract-suite-module-under-offchain-test-owns, contract-case-name-kind-success-refusal-consistency). `AdapterHarness` carries the `Provider IO`, its evidence class and the chain controls the adapter supports.
- consumer-composition-roots Composition roots of journeys-deployment-insert-active-update-terminal-runners construct `Provider IO` and `SignedSubmitter` once and pass them down; no consumer function takes `NodeSession`, `NodeMode` or `Submitter` (consumers-depend-on-provider-view-signedsubmitter-one).
- verify-release `verify-release <tag>` (flake app) — exit 0 only when sums, archive members, separate-process journey and model revision agree (release-assembly-gains-model-revision-member-verification, v-release-publishes-singular-cli-archive-its).
- evidence-page-rendering Evidence page rendering takes `rows.json` and a receipts directory and produces the page; the check recomputes and compares (conformance-evidence-page-rendered-from-receipts-by, conformance-states-on-published-evidence-page-computed).

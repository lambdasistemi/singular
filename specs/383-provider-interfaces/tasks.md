# Deliver the provider-only registry commands

As a maintainer, I want a finite list of work that closes #383, with each task
owned and checked. The [plan](plan.md) fixes scope and baseline. Checked boxes
mean the stated action completed; source already on main is not marked tested.

## Establish the baseline

- [x] Preserve the prior branch and dirty work, then reset `feat/383-provider-closure` to main `6efe1f119a2332484e690b4c128c4bc5fd4d689b`. Owner: orchestrator. Backup and stash are recorded in `plan.md`.
- [x] Replace stale planning status in `specs/383-provider-interfaces/plan.md` and add this executable task list. Owner: orchestrator.
- [x] Record the initial `nix develop --quiet -c just ci` result. Owner: orchestrator. Model, application, simulator and browser checks passed; docs failed on the decisions-to-plan anchor removed during cleanup. Planning changed during this run, so it is not clean-main full-CI evidence. Log: `/tmp/e371-383-main-baseline.log`; GLM owns the link repair.

## Run every command through the provider

- [ ] Migrate retained callers in `offchain/` and `conformance/` from obsolete Provider/View/node APIs to the existing generic capabilities; preserve main's tracing, datum delivery and recovery behavior. Owner: Sol. Check: relevant Cabal targets compile.
- [ ] Remove `offchain/node-internal/` production read/indexer modules and obsolete `Provider`/`Services` wrappers; update `offchain/singular-registry.cabal`, `offchain/nix/component-inventory.nix`, `offchain/nix/checks.nix` and affected component declarations. Owner: Sol. Check: no retained production node adapter or unresolved retired import.
- [ ] Preserve required behavior in `offchain/test/` and `offchain/e2e-test/` while migrating fixtures; run pure provider composed reads/history/submission, pure trie proofs, local evaluation and pinned time comparisons, command receipts and bounded confirmation checks. Owner: Sol. Check: actual selected tests pass with command and counts recorded.
- [ ] Update node-confinement, component-inventory and signed-submission checks under `tools/` to the removed component layout, retaining their negative controls. Owner: Muse. Depends on Sol's final module layout. Check: each existing check and its controls pass.

## Keep the development-network journey running

- [ ] Reconcile `tools/demo1_cli_journey.sh` and relevant `.github/workflows/registry.yml` jobs with current main and migrated callers; preserve all-fact Unverified assertions, independent provider data and required Koios call coverage. Owner: Muse. Check: unchanged obligations have executable assertions; no weakened or skipped journey.
- [ ] Run the packaged Demo 1 journey against the actual private devnet facade, and the bounded registry journey; repair migration failures in the owning files. Owner: Muse with Sol for Haskell repairs. Depends on compiled candidate. Check: successful receipts and exit status on the integrated candidate.

## Ship accurate existing documentation

- [ ] Reconcile `specs/383-provider-interfaces/spec.md` and `decisions.md` with ticket scope and current model binding; preserve historical rulings without claiming obsolete status is current. Owner: GLM.
- [ ] Update existing node/provider ownership and API documentation under `docs/`, plus only required reference-generation/packaging paths (`tools/api_reference.py`, `nix/docs.nix`, `mkdocs.yml`). Owner: GLM. Depends on Sol's module layout; no new documentation project.
- [ ] Regenerate changed pages' speech companions and required narration using repository tools; verify docs/presentation against the actual candidate. Owner: GLM. Includes `plan.md` and `tasks.md`; never stamp stale speech as current.

## Integrate and finish

- [ ] Inspect and integrate each worker's scoped diff into `feat/383-provider-closure`; reject unrelated work and preserve the reset baseline's behavior. Owner: orchestrator. No worker pushes or merges.
- [ ] Run `nix develop --quiet -c just ci` and required offchain tests on the integrated candidate; fix failures and record exact commands, exits and commit. Owner: orchestrator with assigned workers.
- [ ] Update PR #460 using `.github/pull_request_template.md`, push the scoped candidate with the appropriate lease, and require the ticket's devnet journey jobs green on that PR head. Owner: orchestrator.
- [ ] Merge the verified PR, close #383, and stop its three worker panes. Owner: orchestrator. Check remote merge/issue state before reporting completion.

## Dependencies and parallel work

Sol's migration, Muse's script preparation and GLM's spec cleanup start in
parallel in separate worktrees. Muse's journey execution and GLM's final API
references depend on the integrated module layout. Only one expensive shared
build or devnet run is started at a time under the orchestrator. Final checks,
push, merge and closure follow integration in that order.

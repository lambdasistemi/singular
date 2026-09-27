# Extract active command responsibilities

As a contributor, I want one visible owner for each option, scenario step and deliberate control, so I can change a command without searching a thousand-line entry file or unintentionally changing another command's evidence.

## Delivery

1. Bind #270 and dependent issues, base/model, active workflow commands, command options and original CLI/JSON/narration/exit observations. Preserve the clean unrelated checkout. Open the draft PR before implementation.
2. Freeze a finite Gate S and execution budgets from the current workflow and its nested Nix commands. The approved GLM coder owns all implementation, tests, docs and commits; the approved Opus auditor independently reviews exact candidates. No other seat is commissioned.
3. Extract journey, insert-active, update-terminal and deployment in bounded command-local steps, preserving public entry paths and independent control ownership. Each moved declaration has one definition. Keep component source declarations and imports explicit. Do not migrate journey into the #202 driver.
4. Ship a contributor guide, module-purpose prose, diagrams, real caller/API links, navigation and speech with the code. Verify presentation and archive content as distinct claims.
5. Run the supported checkout journey and both extracted edge commands with positive and relevant refusal controls, capture before/after output and JSON shapes, run lint/component/focused/root CI and release checks, and obtain an exact-candidate audit. Handoff the draft PR to epic #272; do not merge or deploy.

## Evidence limits

The current registry workflow runs `nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint` then `REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#journey` from checkout. Its archive steps each run `nix run --quiet .#release-artifacts -- "$release_dir"`, extract outside `.git`, then invoke `.#insert-active` or `.#update-terminal` with `--observed`; the release assembler additionally invokes two blueprint builds. Off-chain CI runs lint, component-build and cage-tests; root CI runs docs and presentation. Each invocation is charged separately in the runtime ledger.

The supported command evidence establishes the cases it actually executes. `deployment-identity-check.sh` invokes `genesis-skey`; `deployment-attach-check.sh` names `genesis-skey` and `count`, but its retained-runner blockage under #172/#283 is only source reachability. The intake and final CLI inventory must include all four dispatch branches and both flag spellings; opening Haddock and usage text mention only deploy/verify and do not define the whole parser. These receipts do not establish an archive-extracted journey (#214), #202's future narration hook, live production deployment or every Lean edge. A setup failure is not a refusal witness.

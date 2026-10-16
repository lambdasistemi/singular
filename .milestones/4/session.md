# Milestone 4 session recovery

Session singular; singleton desk %1182 in singular-ms4-offchain-optimizations, runtime /tmp/projects/singular/milestone-4. Parent %706 in 0-projects:singular. Reuse surviving windows; do not recreate or reseat active/explicitly parked workers.

Desk launch: `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4`. Recreate only if absent with tmux new-window -d in session singular, then deliver resume/ms.md using send-pointer and require START in the restored desk STATUS.

The following sections are the owners' own recovery fragments. Their later checkpoints supersede earlier intake sections within each fragment. Use actual journals/current PRs before any resumed command.

## t104

# Ticket 104 checkpoint — blocked for desk re-cut disposition

Owner/implementer: Codex gpt-6-astra/high, pane %1185, singular:singular-ms4-t104-folder-loop. Parent desk %1182, runtime /tmp/projects/singular/milestone-4.
Launch: `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4/ticket-104`.
Worktree /code/singular-issue-104, branch feat/folder-loop, clean local HEAD572f26d706827b0159042eb6edd17b4038e4e2de. Remote draft PR https://github.com/lambdasistemi/singular/pull/113 at80c7b69d95d062d6545fcd19945b56f7f7a0bbcc, feat, paolino. Local follow-up is committed but not pushed after the stop condition was diagnosed.

Result: adaptive library/registry journey, real-node devnet test and CI, runbook/onboarding, merged #106 deployment interface and attached naming runner integration implemented. Fold-only mode supports a supplied fresh name on the existing deployment without rerunning fixed fixtures. No Lean/validator changes; no child seats/auditors; no shared-preprod submission, merge or release.

Evidence: repaired full E2E10/0, journey11/11, units106/0; missing-loop control failed the intended chain-drain assertion. Merged-interface adaptive test passed, full register-rows passed, two-process attached folder smoke passed at572f26d (persistent mirror reloaded and advanced; deployment verification8claims). Runtime evidence and exact identities are indexed in handoffs/verification.md. Remote adaptive CI passed at80c7b69.

Blocker Q-002-second-failure-recut: second behavioral verification failure is retirement CI N2 script-hash attribution. Derived Show FoldBuildFailure double-escapes the already-rendered reason, while the existing strict parser expects the previous shape. Main f558d0e Registry CI is green; this is an introduced regression. First failure was full E2E forecast-horizon rounding, repaired and reverified at252d17d. Brief requires return for re-cut after two failures. No third repair campaign started. Concrete un-applied patch handoffs/refusal-rendering-proposal.patch passes git apply --check, but has not been executed. Preserve strict refusal attribution; do not weaken expectations.

Next action: await desk disposition of Q-002, then perform only the authorized re-cut if resumed. Do not implicitly resume from a timing interval. Existing remote CI may finish independently; no local test remains running. No push of572f26d or additional repair/test campaign after diagnosis.

Independent Q-001 preprod condition remains pending: actual merged implementation/manifest revision/path, final accepted representative identity (#112 remains M1-owned), live registry identity, mirror matching confirmed chain/root/point, M1 explicit release with no write task/transaction in flight, desk assigns one writer. After verified handoff M4 already has authority; no extra user/project go. Use same deployment and existing signing identities/policy. Expected locators docs/preprod.json and adjacent preprod.mirror.json, socket /srv/prod-hot/cardano/preprod/ipc/node.socket, magic1, existing joiner key path from brief; these are not a handoff. Merge through merge-guard only after frozen acceptance/current-head green CI/desk sequencing; reuse existing release pipeline.

Acknowledgements: brief, A-001-preprod-window, NOTE-001-conditional-preprod-transfer (plus both referenced rulings), NOTE-001-deployment-merged-siblings, NOTE-002-follower-interface and ticket107 planned interface all read. #107 proposal preserves loadMirror/saveMirror and invalidates checkpoint on local saves; folder synthesizes no checkpoint. Final sibling integration only from accepted main.

Transport: Q-002 pointer sent once to desk %1182; 15-second acknowledgement wait timed out, with no durable desk acknowledgement observed before this checkpoint. No retry was sent. Local test sessions all completed (attached smoke, registration, adaptive test and root CI exit0); no local command remains running. The durable BLOCKED Q-002 event is the authoritative state.

## t107

# Ticket 107 session

- Runtime: /tmp/projects/singular/milestone-4/ticket-107
- Pane: %1192, singular window 8, owner and implementer, Codex gpt-6-astra/high.
- Launch: codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4/ticket-107
- Worktree: /code/singular-issue-107; branch feat/registry-follower.
- Accepted base: f558d0e8fc916eef494fffcef09cfe2ac5582b8e, freshly fetched origin/main.
- PR: https://github.com/lambdasistemi/singular/pull/116 (draft, feat, paolino).
- Stage: implementation; planning commit d51b004; baseline root CI, offchain shell and deployment package build passed.
- Next action: implement checkpoint persistence and chain replay; contract in handoffs/interface.md.
- Frozen acceptance: brief.md and sources/issue-107.json at parent runtime; no change to scope.
- New executable acceptance command: from offchain, nix develop --quiet -c just follower-e2e (planned recipe; not implemented or passed).
- Preprod: requires desk assignment following complete verified M1 window handoff; devnet may proceed independently.

## Current checkpoint (2026-09-14T15:38Z)

Local implementation is uncommitted; remote PR116 still contains only d51b004 planning. Added Follower.hs, checkpoint extension in Deployment.hs, deployment follow CLI, attachRebuilding calls in register/recovery/retirement, FollowerSpec with socket-aware existing bootstrap helper, follower-e2e recipe/CI job, onboarding/speech update. No Lean or validator changes.

Development build 8 compiled library, deployment, three runners and test; docs-check-1 passed. Live devnet run 1 exposed initial rollback-to-intersection loop, stopped with exit 143; raw node log retained at /tmp/s107-dev.22XFdG/cardano-e2e/node.log. Fix: rollback at replayPoint returns Progress, earlier rollback resets. Build 9 passed for updated deployment and E2E binary. Current live run 2: evidence/follower-devnet-2.log, .inputs, .exit (when finished), exec session 59679.

Next: read run 2, use its concrete result; then commit candidate and execute packaged `cd offchain && nix develop --quiet -c just follower-e2e`, full applicable offchain/root checks and one meaningful live-boundary failure control. Need preserve logs and actual exits, not call compilation acceptance. Q-001-preprod-window asks desk for verified M1 manifest/window; no preprod submission authorized until that assignment. Actual accepted base has no docs/preprod.json.

## t114

# Naming CLI recovery

Runtime: /tmp/projects/singular/milestone-4/naming-cli
Parent: milestone 4 desk %1182, /tmp/projects/singular/milestone-4
Pane: %1188; session singular; window singular-ms4-naming-cli
Identity: codex / gpt-6-astra / high; draft=NONE; no children.
Exact launch: codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4/naming-cli

Stage: source/API discovery. Read brief.md and NOTE-001 in full; START and NOTE acknowledgement recorded. Full existing lifecycle authorized by NOTE-001; issue/draft PR/implementation may proceed if coherent wrapper. Pricing choices remain separate: no inert price flag or invented semantics.
Worktree/branch: not yet created; intended /code/singular-naming-cli on feat/naming-cli. No existing lane found in git worktree list.
Issue/PR: none yet. No product edits/builds performed.
Observed canonical /code/singular main: fc2ad9e5987b171ca33a430f5bbe170ab6423fd5, clean.
Observed remote PR106: OPEN at acd3ab8cf132c60beb51a3322ff273e57d59dd6c. PR113: OPEN at 474f99df14fd6bc12d6be5516af2fcc9cd58a797. Refresh before integration.
Next: finish actual builder/Lean/manifest/folder source discovery; write issue-proposal.md and command-map.md; coordinate shared files and pricing timing through questions to desk; file bounded issue and draft PR if no semantic/API blocker.
Preprod remains conditional and has no new CLI writer slot. Development uses devnet.

## Current checkpoint after A-001

A-001 read in full and RESUMED recorded. Shared additive declarations authorized NOW; final acceptance consumes merged #106/#110/#104/#107. Separate deposit owner integrates pricing afterward; committed registration refund address is settled. No ongoing permission question.
Issue: https://github.com/lambdasistemi/singular/issues/114 (feat, paolino, milestone 4; Planning PVTI_lAHN3B7OAT-p6s4OuLJy, WIP).
PR: https://github.com/lambdasistemi/singular/pull/115 (draft, feat, paolino).
Worktree: /code/singular-naming-cli; branch feat/naming-cli.
Initial contract commit: 4cf415b (pushed; no executable yet).
Baseline: nix develop --quiet -c just ci, exit 0; evidence/baseline-ci.log. This is root CI only, not offchain build or CLI ledger evidence.
Frozen corrected issue: handoffs/issue-114-frozen.md and .sha256. Original filing retained separately; pricing correction was applied remotely after NOTE-003/A-001.
Next action: add new production CLI modules and executable/unit/devnet declarations; baseline accepted main lacks Deployment/FoldAll/Follow; retain dependency adapters as outstanding until merged API becomes available, not inert shipped flags.

## Current checkpoint, 2026-09-14 15:36Z (supersedes earlier stages)

Pane %1188; singular:singular-ms4-t114-naming-cli. Worktree /code/singular-naming-cli branch feat/naming-cli. #106 merged and integrated via merge 45a8c07ddd8d6a3b8ec95519cbf3257d95eed4fc. Local implementation commit 0e11d8f adds real wallet-free attach/inspect, parser tests, Nix package/read-devnet app and release blueprint inclusion. Remote branch currently only initial contract 4cf415b; local implementation not delivered yet.
Parser tests 10/10 and cabal build singular-naming -O0 pass through pinned offchain shell; evidence/cli-read-checked.log. Root baseline just ci passed before implementation; not current CLI acceptance.
Packaged read-devnet first attempt stopped before node: missing E2E_GENESIS_DIR. Fixed own harness. Second run active exec session 94092, log evidence/read-devnet-2.log, evidence/read-devnet-2. Final naming-cli-e2e does not exist yet; partial test deliberately named naming-cli-read-e2e.
Brief and A-001/A-002 read fully and STATUS acknowledged. NOTE001-007 read/acknowledged. Connected cancellation probe found 2 positive/2 expected failing Aiken tests on accepted fc2ad9e; no connected node claim. Repair report handoffs/connected-cancellation-repair.md + final hashes; parent NOTE006 commissioned separate owner %1194. Preserve connected register-then-cancel acceptance. Do not edit validators or invent refund representation.
Next: finish packaged read check, implement user-parameterized register/maintain/recover/retire/fold in NEW modules using generic builders and live evaluation. Existing private row construction inspected, must not use fixed test budgets/keys. Integrate accepted #110 representative identity, #104 batching, #107 follower and separate cancellation repair before full acceptance. #107 proposed API followDeployment manifest socket -> IO FollowResult; see ticket-107/handoffs/interface.md, not accepted yet. Mirror checkpoints follower-owned.
Remaining: full packaged lifecycle devnet and meaningful refusal, follower/batching integration, user runbook/navigation/CI, release archive install/run evidence; update PR body and push verified increments. Check inbox before expensive commands or freeze. No CLI preprod slot.

## deposit-model

# Naming deposit model owner resume

Exact launch: `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4/naming-deposit`.

Pane `%1189`, session singular, window singular-ms4-naming-deposit. Parent desk `%1182`, runtime `/tmp/projects/singular/milestone-4`. Single owner/implementer; draft=NONE; no children, auditors or replacement seats.

Runtime `/tmp/projects/singular/milestone-4/naming-deposit`; isolated worktree `/code/singular-naming-deposit`; branch `feat/naming-deposit`; fetched base/origin-main `fc2ad9e5987b171ca33a430f5bbe170ab6423fd5`. No issue, PR, commit, push, implementation edit, build or test yet. Read and acknowledged full brief, full ruling and NOTE-001. The original combined product ticket is superseded by a model-only first ticket.

Stage: source-bound proposal ready; deposit lock-point ambiguity Q-001 pending with desk. See `questions/Q-001-pending-deposit.md`, `handoffs/issue-proposal.md`, `handoffs/interface.md`. PR #106 at acd3ab8cf132c60beb51a3322ff273e57d59dd6c and #112 at e2f4fb5a831310872519ae907d64e0953e4ac50c were OPEN; neither changes Lean in the inspected file lists and neither blocks independent model work.

Next action: read/acknowledge desk answer and any inbox notes; incorporate the pending funding/cancellation ruling into one coherent model issue; file feat/paolino/milestone 4 and add to planner; rename this window singular-ms4-t<issue>-deposit-model; open draft PR before behavior edits. Then update Lean and its executable examples through existing `nix run .#model-check` / `lake exe lifecycle-corpus`, verify relevant fault control and applicable CI, push and report REVIEW-REQUESTED. Guarded merge only after desk sequencing authority. Stop at this model ticket; no production implementation follow-up is authorized.

Existing repository AGENTS/constitution preserve Lean authority and require actual semantic ambiguities to be escalated. The settled price/refund recipient are not being reopened; Q-001 concerns the previously unpriced pending Insert cancellation path.

## connected-cancellation

# Connected cancellation session

Owner pane %1194, window singular-ms4-t117-connected-cancellation; Codex gpt-6-astra/high; one implementer, no children/auditors.
Launch: `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4/connected-cancellation`
Runtime: /tmp/projects/singular/milestone-4/connected-cancellation
Worktree: /code/singular-connected-cancellation
Branch: fix/connected-cancellation
Accepted base: f558d0e8fc916eef494fffcef09cfe2ac5582b8e
Planning HEAD: 11f0d6b (pushed); additive baseline instrument uncommitted in offchain/journey/register/Main.hs, compiled successfully. Original validator/model bytes unchanged. Exact source/diff hashes in evidence/devnet-probe.sha256.
Issue: https://github.com/lambdasistemi/singular/issues/117
Draft PR: https://github.com/lambdasistemi/singular/pull/118
Planner: WIP/Other/Work, assignee paolino, bug label, milestone4.

Stage: baseline node reproduction running; bounded model correspondence clarification.
A-001/A-002 read and acknowledged. A-003 subsequently authorizes atomic pair/refund commitment, expected applied-native-request hash parameter, Active-only Maintain/Recover custody, controller-only creation authorization, existing request-owner Retract signer/window, and explicit old-deployment limit. No new production representation code yet.
Q-002 then identifies an additional exact model prerequisite: NamingLifecycleStatements.insert_attestation_alone_cannot_cancel asserts rejection; positive cancellationPending first executes distinct mintWithdraw in withCancellationApproval. The proposed single Insert burn cannot silently replace that attestation. Desk acknowledged both handoffs/cancellation-approval-model-binding.md and questions/Q-002-distinct-withdrawal-attestation.md at 15:37:54Z; affected cancellation implementation re-held pending the exact preserved approval mapping or operator amendment. Other A-003 technical choices remain authorized.

Evidence: original four Aiken contexts reproduced (2 pass/2 fail) in own runtime; preservation-probe-v2 executes 2/2 (pending Maintain moves Insert approval, mint needs no request owner). Earlier zero-test invocation excluded. Native OnChainRequest has no refund field. First devnet attempt compiled then failed before node startup due wrong cwd; corrected script runs from offchain. Own devnet created actual claim e20cb4326184b42df0e7b65796fc47f2cd94aa65e10304f6ecaba09e7efe994f#0 and request 457bb8106853b98014cb1075052a66c2e8fe55e1cee1ab5f57f739289587b248#0 and is waiting inside existing phase2 timing. Node/log under evidence/devnet-tmp and evidence/devnet-baseline.log; command evidence/run-devnet-probe.sh. Shell tool session 86516 owns this run. Await its exit and distinguish timing/harness failure from application PlutusFailure. No positive repaired result claimed.

Next: read new answers/inbox; finish baseline observation; preserve logs and source hashes, update PR/interface, commit the scoped instrument when verified; resolve distinct withdrawal-attestation mapping before dependent production cancellation changes. Do not reuse old devnet after shutdown or substitute fixture results for ledger acceptance.

Overlap: #110/PR112 remains unmerged; last desk head 64b005363f1f201a4593616d4b5420bbd96590ab. application.ak/tests, Naming/Register.hs/RegisterSpec.hs, register runner, identity/instantiation paths overlap. Freshly query and integrate accepted #110 before final acceptance; do not touch sibling worktree. #114 consumes production builder only after landing; handoffs/interface.md is provisional, not a ready API.
Constraints: no preprod writes, new deployment/migration, economic deposits, model expectation weakening, direct gh merge, extra ticket/campaign/seat. Desk sequencing plus merge-guard required before merge. Old deployments cannot receive new validator behavior in-place; dependent #114 acceptance remains open.


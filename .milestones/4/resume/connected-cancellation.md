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

# Naming registry management — milestone 4

As a naming-registry user, I want one installable command to manage my registry, rebuild its mirror from a node and drain oversized queues. The operator additionally requires a deployment-set registration deposit, refundable on Over to an address committed at registration. No new capability is released yet.
https://github.com/lambdasistemi/singular/milestone/4

## Product outcomes and artifact

The original outcome remains: a fresh checkout with only the deployment manifest rebuilds the mirror from a preprod node and drains a queue that cannot fit one transaction. #107 supplies reconstruction and #104 adaptive folding. The user-facing artifact is now singular-naming, tracked in #114, exposing existing naming actions individually rather than invoking a whole test journey. The deposit is a separate protocol extension: first an executable Lean model ticket, then a separate implementation ticket carrying the actual validator/builder/deployment/command support. Model evidence is not ledger implementation evidence.

## State and priority

| Work | Current owner and state | Next action and priority reason |
|---|---|---|
| Folder #104 / PR #113 | %1185, Codex gpt-6-astra/high; PR head 80c7b69d95d062d6545fcd19945b56f7f7a0bbcc pushed; verification continues | Connected register and attached smoke passed. Retirement CI at80c7b69 fails strict attribution due to derived Show escaping; A-002 re-cuts to one explicit Show repair in this lane, with strict controls retained. No acceptance/merge yet. |
| Follower #107 / draft PR #116 | %1192, Codex gpt-6-astra/high; START verified, isolated worktree at merged #106 main | Implement frozen follow/rebuild behavior and devnet check now; no preprod writer slot yet. |
| Naming command #114 | %1188, Codex gpt-6-astra/high; issue/planner recorded, baseline green, draft PR #115 open | Develop full existing-lifecycle wrapper in parallel. Integrate accepted #106/#110/#104/#107 before landing. |
| Connected cancellation repair #117 / draft PR #118 | %1194, Codex gpt-6-astra/high; START verified | A-003 permits checked refinement: existing signer rules, fixed applied request hash, atomic pair and Active-only custody. Old-deployment cancellation remains unresolved. |
| Deposit model, issue pending | %1189, Codex gpt-6-astra/high; model-only proposal ready, Q-001 blocked | Operator must settle lock at successful registration versus request submission; then file and implement model-only in parallel. No model edits/builds yet. |
| Deposit implementation | Uncommissioned follow-up owned by desk | After model lands, commission a separate protocol/CLI integration ticket; do not widen existing tickets. |
| M1 deployment #106 / representative #110 | M1 owns both; #106 MERGED at f558d0e8fc916eef494fffcef09cfe2ac5582b8e at 15:09:55Z; #112/#110 still open at last check | M1 completes its own ordering and preprod close. No takeover. |

https://github.com/lambdasistemi/singular/issues/104
https://github.com/lambdasistemi/singular/pull/113
https://github.com/lambdasistemi/singular/issues/107
https://github.com/lambdasistemi/singular/issues/114
https://github.com/lambdasistemi/singular/pull/115
https://github.com/lambdasistemi/singular/pull/106
https://github.com/lambdasistemi/singular/issues/110

All currently open milestone issues are mapped: #104 folder/journey, #107 follower/journey, #114 naming-command, #117 connected-cancellation. Deposit-model filing is pending; later deposit implementation is explicit unticketed work with the desk as owner. No exclusions. The external #106 enabler is not an additional M4 issue. #71 was superseded by #104.

## Rulings and interface ownership

The operator settled a deposit, amount as a deployment parameter, refundable on Over to an address committed at registration, and explicitly ordered model-only first in parallel. A source-derived pending-claim question remains: cancelled/losing claims never reach Over, so Q-001 asks when locking begins. Recommendation is lock at successful registration; the operator has not answered and this recommendation is not authority. Exact quotations and stage boundary: rulings/2026-09-14-naming-artifact-and-deposit.md. No economic default, fee, adjustable administrator, new deployment or legacy-manifest mutation is inferred. The initial broad deposit brief is superseded by briefs/naming-deposit-model-only.md before any issue/code.

registry.md names mirror/follower, request/folder, manifest/both and deposit-model/implementation/command interfaces. Enforcing checks for the new seams remain NONE until their already commissioned tests have evidence. No new assurance campaign is introduced. Model checks enforce only model claims; implementation requires its later real transaction evidence.

Naming CLI Q-001 was answered and RESUMED at 15:05:35Z. Its new modules and isolated additive singular-naming/naming-cli-e2e package/app/CI/release/navigation declarations may proceed now, preserving all sibling entries. Existing shared behavior remains with its owning lane until it lands. The CLI final acceptance consumes merged #106/#110/#104/#107. Deposit implementation is a separate subsequent diff and does not block the existing-lifecycle wrapper. Explicit pending claim/request pairing inputs are permitted if required by source; any conflict with the original manifest-only outcome must be raised, never hidden as reduced acceptance.

## Shared preprod window

Project A-001 conditionally authorizes M4 to take the SAME registry after verifying M1's actual merged interface/manifest revision and path, live identity, companion mirror and matching chain point/state, and explicit release with no M1 write task or transaction still in flight. No further operator/project go is needed. M4 sequences #104/#107 writers without overlap, checks compatibility using existing tooling and records taking/releasing the window. Incomplete or mismatched handoff blocks preprod only; devnet continues. No slot is taken yet. The new CLI/model grants do not authorize replacing the deployed registry or changing signing identities/policies.

Exact ruling in rulings/2026-09-14-shared-preprod-window.md; its exact bytes were appended to the current project ledger/resume in snapshot 7f8d5756a88fcf50dea6f8c896c85b99114aa347, accepted by project parent at 14:52:24Z. Ticket #104 acknowledged the conditional transfer at 14:50:40Z.

## Authority and recovery

One worker, one ticket, one PR, no child/auditor hierarchy. Frozen issue acceptance; new scope gets another ticket. Lean governs semantics. Desk owns asks, answers and sweeps, never code or merges. Owning lanes execute merge-guard after green CI and desk sequencing, using merge commits. Existing release pipeline supplies runnable artifacts. No comments/reviews/messages under the operator's name. Labels and paolino assignment on every issue/PR.

Desk %1182: /tmp/projects/singular/milestone-4, singular:singular-ms4-offchain-optimizations, Codex gpt-6-astra/high. Parent %706: /tmp/projects/singular, 0-projects:singular.
Folder %1185: ticket-104 runtime; /code/singular-issue-104 on feat/folder-loop; singular-ms4-t104-folder-loop.
Naming CLI %1188: naming-cli runtime; /code/singular-naming-cli on feat/naming-cli; singular-ms4-t114-naming-cli.
Deposit model %1189: naming-deposit runtime; singular-ms4-naming-deposit until issue rename; worktree /code/singular-naming-deposit on feat/naming-deposit; own blocked resume is preserved.
Follower %1192: ticket-107 runtime; /code/singular-issue-107, feat/registry-follower; singular-ms4-t107-registry-follower. Its START binds merged main f558d0e8fc916eef494fffcef09cfe2ac5582b8e and brief hash c0dac1b49a2d0a0077791266e6c979602e53853628add628526cbdd1420be194. session.md and resume/ contain exact launch/recovery records and worker-authored fragments. Preserve active processes and read journals before any recovery.

## Published product map

https://github.com/lambdasistemi/singular/wiki/Milestone-4
Register Milestone-4-Stories.json and page Milestone-4.md: eight stories, four groups, dependency stages only. Wiki commit 40ff67e1e8e6ebe50fe9c7cd1b3874dcc7def81e; register file SHA-256 2d6c905c1e43a5f43627b7263fd84d92b4dec7cba6f62298484a4f6bd1e62374. Renderer --check and presentation checks passed. The previous seven-story Gantt was browser-verified; this eight-story update passes generation and presentation checks. No calendar forecast or product acceptance is implied.

## Connected cancellation repair dependency

#117 / draft PR118 is owned by %1194 in singular-ms4-t117-connected-cancellation. The four-context probe has two valid controls and two Insert-only cancellation refusals. The latter is EXPECTED under NamingLifecycleStatements.insert_attestation_alone_cannot_cancel; it does not prove a model contradiction. The missing connected implementation must obtain the distinct withdrawal attestation, then cancel the actual registration pair. Evidence is component-only until the production devnet route runs.

A-003 authorizes checked technical refinement under constitution II: atomic co-created claim/request, immutable full refund, an application parameter pinning the actual applied native-request script, and Active-only Maintain/Recover matching Lean custody. No new request-owner creation signature. Prior operator Q-002 atomic-registration permission question was withdrawn as unnecessary after source binding, never answered by assumption. The separate deposit-model pending lock-point question is still open.

A-004 is a mandatory completion of that mapping: compose existing mintWithdraw then withdraw with an explicitly validated DISTINCT request/refund-bound certificate and existing issuer authority. Insert burn alone is insufficient. Preserve the negative theorem, actual refusal without the withdrawal certificate and post-consumption replay refusal. #117 acknowledged A-004 RESUMED at15:39:35Z and proceeds. No model predicates or expected results are weakened.

Old application scripts/approval tokens cannot gain this repair retroactively. #117 delivers corrected artifacts and isolated-devnet proof; #114 existing-deployment cancellation remains an unmet dependent outcome. No migration/new deployment/shared-preprod write is granted. Project parent acknowledged the compatibility handoff; the distinct-attestation correction is also delivered separately. #110 remains M1-owned and must be integrated after acceptance. CLI NOTE-009/010 carry the current boundaries.

Exact sources and dispositions are in child-notes/cancellation-refund-binding-refinement.md, cancellation-approval-model-binding.md and cancellation-A-003/A-004 files. Original question/answer history is retained there; the current state above supersedes earlier holds and incomplete proposals.

Naming CLI interface handoff read/acknowledged at POINTER-1789400477-3449817. #114 owns wrapper commands/output; dependencies remain #104 foldAll, #107 follower checkpoint, #110 representative API, #117 connected registration/cancellation with distinct withdrawal approval. The CLI must consume accepted interfaces, add no guessed token/refund representation or deposit option, and keep existing-deployment cancellation unresolved.

#107 preprod Q-001 read/acknowledged POINTER-1789401173-3643090. A-002 resumed owner with conditional transfer only: #106 merged, but M1 #110/release close and complete manifest/mirror/chainpoint/release handoff remain outstanding. Devnet/CI continue; no preprod writer assignment or submission.

Naming CLI Q-003 read/acknowledged POINTER-1789401321-3681423. A-012 authorizes bounded authenticated candidate lookup: Trie lookup is presence only; speculative deterministic representative candidates must reproduce the authenticated root. Unknown/ambiguous values refuse. No shared Trie/Deployment/follower/validator/deposit edits; accepted #110 required for final Active/Over semantics.

#107 review read/acknowledged POINTER-1789401588-3738146. Candidate112d20c/PR116 remains review-requested: local follower/full E2E and root-mismatch controls complete, remote CI queued/running. Concrete follower API forwarded to #104/#114 as draft only; preprod remains pending complete M1 handoff.

Connected cancellation interface refreshed/read/acknowledged POINTER-1789401708-3768382. Draft API exports connectedApplication/registerConnected/cancelConnected with public Registration receipt and distinct withdrawal-certificate inputs; forwarded to #114 as draft dependency. PR118/devnet not accepted, old deployment cannot retrofit, no preprod/migration grant.

#107 review updated/acknowledged POINTER-1789402134-3829165: exact112d20c now has 26 SUCCESS/2 SKIPPED remote CI and complete local evidence, making it audit-ready but not accepted. Independent gate/test audit required by M4 triggers for replay/checkpoint seam, cross-ticket lifecycle and mutation control. PR116 remains draft; no merge/release/preprod.

M1 NOTE-1614 read/acknowledged POINTER-1789402447-3893826. #106 f558d0e and #110/#112 b4a36ea verified merged on origin/main; #114 may consume accepted representative semantics. M1 preprod close has started but complete handoff/release is not yet supplied; CLI refreshes from b4a36ea with no preprod/new deployment grant.

#117 accepted #110 integration read/acknowledged POINTER-1789402512-3921315. Main b4a36ea verified; cancellation lane b2c14fb has Aiken11/11, but real Haskell/devnet acceptance remains unproven after collateral/minUTxO failures. Draft API forwarded to #114; independent audit and old-deployment/preprod constraints remain.

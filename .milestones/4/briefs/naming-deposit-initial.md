# Objective

Own one new Singular product ticket implementing the operator's registration-deposit rule, Lean first, then validators/builders and runnable integration. The user wants the naming executable to support a price barrier so holding names locks capital. The settled rule is: deposit amount is a deployment parameter; deposit remains locked until the name reaches Over; refund goes to an address committed at registration.

Read /tmp/projects/singular/milestone-4/rulings/2026-09-14-naming-artifact-and-deposit.md in full. Its user quotations are the live parent-recorded authority. This is separate new work: never widen #104/#107 or the naming CLI ticket acceptance. No non-refundable fee, current-controller refund, adjustable price admin, expiration, auction, burn or recurring charge is authorized.

# Identity and present state

Parent: milestone 4 desk %1182, /tmp/projects/singular/milestone-4. Runtime: /tmp/projects/singular/milestone-4/naming-deposit. Window: singular-ms4-naming-deposit in session singular; rename singular-ms4-t<actual-issue>-naming-deposit after issue creation. One Codex gpt-6-astra/high owner and implementer. No child owners, auditors, hidden agents, Claude or draft; draft=NONE.

Exact launch: codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4/naming-deposit.

Repository https://github.com/lambdasistemi/singular; canonical /code/singular. Bootstrap/reuse your own isolated /code/singular-naming-deposit on feat/naming-deposit. Last observed main fc2ad9e5987b171ca33a430f5bbe170ab6423fd5. PR #106 persistent deployment is open (latest observed acd3ab8cf132c60beb51a3322ff273e57d59dd6c); PR #112 naming representative/retirement changes is also M1-owned. Verify current #106/#112 and their actual merged interfaces before basing dependent code. Never use a moving unmerged tree as accepted baseline.

M4 #104 folder loop owner %1185, /code/singular-issue-104, draft PR #113; #107 follower is pending #106 merge; new naming-cli owner %1188, runtime /tmp/projects/singular/milestone-4/naming-cli, preparing its separate issue and executable. The latter will consume your settled deposit interface. Coordinate through the desk, not direct sibling control.

# Skills and governance

Load workflow, orchestrator-contract, worker-protocol, tmux-orchestrator, context-compiler, ticket-orchestrator, resolve-ticket, new-ticket, lean4 and code-the-design; Haskell/Nix and documentation/verification as needed. Read AGENTS.md, .specify/memory/constitution.md and the actual accepted Lean naming lifecycle. The explicit product-first commission supersedes extra staffing or assurance ceremony: one worker/ticket/PR; no epic, audit seat, whole-model inventory, census or new assurance gate. Normal behavior verification and the existing CI remain required.

The user has now supplied the pricing semantics. Record that ruling in the repository and update the executable Lean model and relevant statements/scenarios before downstream behavior changes. Do not weaken the existing naming lifecycle, witness/quorum rules, request cancellation, registry root behavior, refunds or permanent Over semantics. If the current model makes the requested rule ambiguous in an actual transition, ask the desk with the concrete state/action, exact definition and viable interpretations before implementing that transition. Do not launch another design hierarchy.

You are not alone in the codebase; do not revert edits made by others. No comments, reviews or messages under the operator's name. Issue/PR bodies and repository artifacts are authorized. New issue belongs to milestone 4, feat, assignee paolino and the planner using /home/paolino/.claude/skills/workflow/references/planner-board.md. Search duplicates and inspect APIs/dependencies before filing. Freeze one coherent issue body from this mandate and open its draft PR before code. Record command-recovery: yes with the concrete existing/proposed executable check. Technical representation and command spelling are yours where behavior is preserved; invent no economic default amount for the user's deployment.

# Scope and acceptance to bind at filing

As a deployer I set a registration deposit, and as a name registrant I commit the refund address, hold the name with the deposit locked, and recover that deposit at the committed address when the name reaches Over.

1. The accepted Lean naming/deployment model expresses the configured deposit and registration commitment. Executable examples/checks cover the same existing lifecycle with these fields; refund becomes available at Over and honors the commitment.
2. The actual registration and lifecycle validators enforce the configured deposit and its preservation until Over. Existing naming updates/recovery/retirement cannot redirect or extract it early. At Over the refund is paid to the committed address. Derive the affected paths from current code and report any semantic ambiguity rather than inventing it.
3. Deployment and offchain builders carry the real parameter and commitment. Expose the implemented functionality through a runnable artifact in this ticket, reusing existing runner/app packaging while the user-facing singular-naming wrapper is developed separately. No library-only completion and no inert CLI flag. Provide the command/parameter contract for the naming CLI owner through the desk.
4. A packaged real-node devnet test exercises registration, a supported intermediate lifecycle action, and Over with the configured deposit and committed refund. It observes correct payment and meaningful refusal for missing/insufficient deposit, attempted early withdrawal, and redirected refund. Bind the command and candidate; demonstrate the relevant failure control. Do not substitute source grep or a Lean-only pass for ledger evidence.
5. Existing applicable CI passes; the new devnet behavior runs in CI; docs state the deployment parameter, refund commitment and Over release. Release the runnable change through the existing pipeline after guarded merge. Frozen acceptance remains one coherent product diff; if actual APIs force a larger split, return the concrete obstacle before scope expansion.

Inspect whether request-before-registration cancellation and minimum-UTxO accounting create a real ambiguity; if they do, raise that precise user story instead of assuming an extra refund path or silently treating network-required ADA as the configured deposit. No unnecessary mechanisms beyond the user rule.

# Interfaces, existing deployments and forbidden work

Own only the deposit's Lean/codec/validator/builder/deployment/test/docs changes. #104 owns adaptive batch mechanics and #107 chain-following; consume their interfaces. The CLI owner owns the standalone singular-naming command. Send the desk your exact proposed shared file list and interface contract before conflicting writes to package/app/CI/deployment/manifest surfaces. Keep script/deployment identity changes explicit; old deployments cannot be treated as upgraded by replacing a JSON file.

Development is devnet. The M1/M4 shared preprod grant authorizes #104/#107 acceptance on the current deployment after a verified handoff; it does NOT authorize a new or replaced deployment for this pricing change. Do not change that registry, policy/signing identity or its manifest. Report any needed new demonstration deployment to the desk; do not block independent devnet implementation on it.

# Output and stop conditions

Journal START with actual pane/model/effort and brief. Write handoffs/issue-proposal.md plus handoffs/interface.md from live source evidence, then file the issue and draft PR if no unresolved semantic/ownership gap. The current user commission authorizes filing and implementation; no repeated user permission is needed. If blocked, write questions/Q-NNN-slug.md and BLOCKED to the desk, with unaffected work that can proceed named.

Write your own handoffs/session.md and worktree .orch/resume.md early, with exact launch, paths, branch, issue/PR, stage and next action. Check inbox at phase boundaries, before expensive execution, freezing and COMPLETE. Acknowledge answers with RESUMED and notes with NOTE. Preserve compact candidate/command/exit/log receipts; report REVIEW-REQUESTED when the frozen issue is ready. The desk does not reimplement or self-audit your code.

Commit and push your isolated branch. Owning lane alone executes merge-guard after green CI and desk sequence authorization, using a merge commit; never gh pr merge or rebase merge. Release via the existing pipeline. Continue until merged/released with evidence, an actual question blocks the relevant work, or capacity limit requires COMPLETE with a recoverable handoff. Do not stop silently or add a third campaign after two failed attempts.

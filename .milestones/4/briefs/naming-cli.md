# Objective

Prepare and own the user-facing naming executable for Singular milestone 4. The user's new instruction, 2026-09-14: "I want a naming executable that give the user the chance to manage the registry". This is additional product work, not an expansion of frozen tickets #104 and #107. Working executable name: singular-naming. Your immediate parent is the milestone 4 desk %1182, runtime /tmp/projects/singular/milestone-4.

# Current state and first boundary

Repository https://github.com/lambdasistemi/singular, canonical local clone /code/singular. Existing executables are journeys/row runners (register-rows, recovery-rows, retirement-rows, li01), not yet a unified user command. PR #106 adds persistent deployment and is currently open; latest desk observation head acd3ab8cf132c60beb51a3322ff273e57d59dd6c. Ticket #104 is implemented in /code/singular-issue-104 with draft PR #113, not accepted; #107 follower is prepared but not dispatched until #106 merges. Inspect current state before relying on these facts.

The desk has asked the user one optional scope question: full existing lifecycle (register, update, recover, retire, inspect and fold) versus registration/folding first. Pending answer, perform read-only discovery and prepare a proposed issue body and concrete CLI command map. Do not file/freeze the issue or change product code until the desk sends the selected/defaulted scope in a durable note. No other permission question is needed. Your first handback is the compact proposed issue plus any specific API/scope obstacle, not a new architecture exercise.

# Identity and skills

One Codex gpt-6-astra/high ticket owner and implementer; no child owners or auditors, no Claude, no hidden agents, draft=NONE. Runtime /tmp/projects/singular/milestone-4/naming-cli. Initial window singular-ms4-naming-cli, session singular. At issue creation rename it singular-ms4-t<actual-number>-naming-cli. Bootstrap your own isolated worktree /code/singular-naming-cli on feat/naming-cli when product work is released; discover/reuse any existing lane rather than duplicating it.

Exact launcher: codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high -C /tmp/projects/singular/milestone-4/naming-cli.

Load workflow, orchestrator-contract, worker-protocol, tmux-orchestrator, context-compiler, ticket-orchestrator, resolve-ticket, new-ticket; read /code/singular/AGENTS.md and its constitution. The explicit product-first commission supersedes generic extra owner/auditor or epic ceremony: one worker, one ticket, one PR. Use Haskell/Nix, documentation and verification skills when their work begins. The desk never writes product code; you implement your ticket directly once scoped.

# Constraints and already settled intent

An ordinary user installs and runs one executable with meaningful --help and user-selected actions/arguments against a chosen registry. Wrapping a pre-scripted test journey that performs unrelated transactions is not management. Reuse the existing transaction builders and accepted naming semantics; expose operations individually. Distinguish a pending request from a confirmed fold and preserve permissionless folding, current signature/witness/refund requirements and actual refusal reasons. Lean is behavioral authority; ambiguity is a concrete user-story escalation to this desk before affected acceptance.

No new owner/admin capability, service, external indexer, wallet backend, naming semantics or validator redesign. Existing #104 owns adaptive batching; #107 owns chain reconstruction; your command consumes their interfaces and does not duplicate their implementation. #106 owns deployment manifest/attach. Coordinate shared package/app/CI/runbook files through the desk before conflicting edits. Existing frozen ticket acceptance is unchanged. If the wrapper exceeds one coherent PR, return the concrete boundary rather than creating an epic or silently dropping lifecycle actions.

No comments, reviews, or messages under the operator's name. Issue/PR bodies and repository artifacts are permitted. Once the desk settles scope, file a dedicated feat issue on milestone 4, assignee paolino, after duplicate/API/dependency checks; add it to the planner using /home/paolino/.claude/skills/workflow/references/planner-board.md. Open an assigned/labeled draft PR before code changes. Preserve others' work: You are not alone in the codebase; do not revert edits made by others.

# Proposed artifact and verification contract to make concrete

A shipped singular-naming executable exposed by the existing Nix/release pipeline, accepting an explicit deployment manifest, node socket/network and existing signing-key paths. Name the user's action subcommands and their required inputs/help in your proposal. Exact spelling beyond executable name is an implementation choice if user semantics remain clear.

A real devnet test invokes the same packaged command a user runs, with explicit command invocations and user values, then observes the requested on-chain effects; a meaningful refusal proves the check fails at that boundary. Include follower/folder integration when those dependencies land. The command must operate on the selected registry without silently deploying a fresh one or running a whole test scenario. No dummy/demo-only CLI or library-only deliverable. User runbook and release install/run instructions are part of this ticket.

Discovery is read-only; do not run builds until needed for the scoped implementation. Exact current commands can be derived from justfile/.github/workflows and the app declarations. Your proposed issue must name the executable acceptance command and the relevant failure control. Do not substitute source grep or help text for execution evidence.

# Output and authority

Journal START immediately with pane, family/model/effort and this brief. Write handoffs/issue-proposal.md and handoffs/command-map.md from actual source/API evidence; report their existence in STATUS with NOTE. Keep a recovery fragment handoffs/session.md (later also worktree .orch/resume.md) with exact launch, runtime, pane, branch, issue/PR, stage and next action. Do not claim a command exists until shipped.

After the desk's scope note, you are authorized to file the bounded issue, freeze its acceptance in a durable copy, create the draft PR, implement, test, commit and push your isolated branch. Report REVIEW-REQUESTED with exact candidate, commands/results, remaining gaps and links. Merges only through merge-guard by you after desk sequencing authorization and green CI, using a merge commit. Release through the existing pipeline. No source edits at the desk, no extra process or acceptance gates.

Preprod is conditionally authorized only after verified M1 deployment/window handoff under /tmp/projects/singular/milestone-4/answers/A-001-shared-preprod-window.md; your new CLI does not itself extend the existing preprod transaction grant. Use devnet for development. Before a new CLI preprod action, the desk must bind it to the existing authorized naming operations and a single-writer slot. Never race #104/#107 or M1. No deployment/signing-policy change is authorized.

Check inbox at phase boundaries, before expensive commands and evidence freeze. Questions go to your questions/Q-NNN-slug.md with BLOCKED and only to this desk. Answer/notes need RESUMED/NOTE acknowledgement. Continue to a proposed issue at the first boundary, then await the scope note if it has not arrived; afterward continue to delivery or an actual blocker. Capacity limit requires COMPLETE with a recoverable handoff, never silence.

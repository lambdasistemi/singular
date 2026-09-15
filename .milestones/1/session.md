# Singular M1 session — tmux session `singular`

Restore from ledger.md; continue existing worktrees and runtime roots. Runtime roots are under /tmp/projects/singular/milestone-1 (desk root).

## window 1 — singular-ms1-onchain-keri — milestone desk (%988)
cwd /tmp/projects/singular/milestone-1. Launch: `claude --dangerously-skip-permissions --model claude-opus-5 --effort high`. Paste: "load milestone-orchestrator; read RESUME.md and the STATUS.md tail; continue finishing M1 per resume/ms.md".

## window 2 — singular-no-epic-t-presentation-naming — PR #105 (%1102) — Codex, out of credits until 2026-09-19
cwd /code/singular-e17-issue-77. Launch: `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen -m gpt-6-astra -c model_reasoning_effort=high --search -C /code/singular-e17-issue-77`. Runtime root: desk root/presentation-naming. Parked.

## window — singular-ms1-t102-close — M1 close lane (%1218)
cwd /code/singular-preprod-close. Launch (pi, GLM 5.3): `glm --approve`. Runtime root: desk root/t-close-2 (brief.md, answers/A-001, inbox/NOTE-001 pause). Resume paste: "read t-close-2/brief.md, answers/A-001-lost-fold-resume-the-claim.md and your STATUS.md tail; continue from the last journal line".

## window — singular-ms1-audit — blind commit auditor (%1525)
cwd /code/singular. Launch: `grok --always-approve -m grok-4.6 --cwd /code/singular`. Runtime root: desk root/t-audit. Resume paste: "read t-audit/brief.md and your STATUS.md tail; continue: live READY-FOR-AUDIT gate first, retroactive audits second".

## milestone-4 windows (singular-ms4-*) belong to the milestone-4 desk (%1182); not this desk's.

## budget-warden
One monitor (desk root/budget-warden/monitor.sh, ceiling 57%); do not run two. Claude weekly was 50% at 17:13Z on 2026-09-14.

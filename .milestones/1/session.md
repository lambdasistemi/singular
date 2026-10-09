# Singular M1 tmux session, rebuilt 2026-10-09T13:48Z after the host crash

Live panes now: desk z-singular-M1 %0 (claude --dangerously-skip-permissions --model claude-opus-5-5); z-singular-e371 %2 (#485 ticket owner, cwd /code/singular-issue-485, claude --dangerously-skip-permissions --model claude-sonnet-5-5 --effort xhigh) and %7 (e371 owner, parking); z-singular-t528 %3 (#528 ticket owner, cwd /code/singular-issue-528, Sonnet 5.5 xhigh); z-singular-e437 %4 (cwd /code/singular-issue-437, env TMPDIR=/code/.lanes-tmp/epic-437/opus-1, claude --dangerously-skip-permissions --model claude-opus-5-5 --effort high); z-singular-e521 %5 and z-singular-e498 %6 (Opus 5.5 high, cwd /code/singular and /code/singular-protected-rejection). Children panes are created by their owners. Each relaunch was a fresh seat pointed at inbox/NOTE-M1-20261009T1345Z-host-crash.md in its root. Lanes parked at the crash (e301 e396 e507 e520 e522) have no session; relaunch them with the launch lines below and a pointer to their RESUME.md when the desk releases them.

The blocks below are the pre-crash layout, kept for launch lines and roots.


Sessions are prefixed z- so they sort last. Every lane's runtime root is under /home/paolino/.orch-runtime/singular/m1 for the lanes opened 2026-10-09, and under /home/paolino/.orch-runtime/singular/epic-<N> for the older ones. Rebuild each window with the launch line below, then paste the pointer to its resume brief.

## z-singular-M1, window singular-ms1-m1-owner (the desk, one pane)
cwd /code/singular. Launch: claude --dangerously-skip-permissions --model claude-fable-5-1 --effort high
Root /home/paolino/.orch-runtime/singular/m1. Resume: read resume/ms.md from this ledger.

## z-singular-e301, singular-e301-owner (Demo 1 packaging and rehearsal)
cwd /code/singular. Launch: claude --dangerously-skip-permissions --model claude-opus-5-5 --effort high (previous session resumable with --resume 3a5e0134-c250-4b59-ab50-f16855287f88). Root /home/paolino/.orch-runtime/singular/epic-301.

## z-singular-e371, singular-e371-t485-managed-state (Bob joins independently)
Owner: cwd /code/singular, claude --model opus --effort high --dangerously-skip-permissions. Ticket owner for 485 in the same window. Muse implementation: cwd /code/singular-issue-485, env TMPDIR=/srv/lanes/singular-e371/485-managed-state RUNNER_TEMP=same /home/paolino/.local/bin/muse --approve. Root /home/paolino/.orch-runtime/singular/epic-371.

## z-singular-e396, singular-e396-owner (concurrent booking, one fold)
cwd /code/singular. Launch: claude --dangerously-skip-permissions --model claude-opus-5-5 --effort high. Root /home/paolino/.orch-runtime/singular/m1/epic-396; brief.md there; epic-map.md there.

## z-singular-e437, singular-e437-t471-restoration (restore missing references)
Owner: cwd /code/singular-issue-437, env TMPDIR=/code/.lanes-tmp/epic-437/opus-1 claude --dangerously-skip-permissions --model opus --effort high. GLM ticket owner: /code/llm-settings/pi/glm --approve. Muse implementation: /home/paolino/.local/bin/muse --approve. Roots /home/paolino/.orch-runtime/singular/epic-437-opus-1 and epic-301/to-471.

## z-singular-e498, opus-owner (protected rejection)
cwd /code/singular-protected-rejection. Launch: claude --model opus (handoff launched with acceptEdits and a read-only tool set; full permissions once the owner's ACK is on disk). Root /code/singular-protected-rejection/.orch/protected-rejection.

## z-singular-e507, singular-e507-edge-carve (bounded M1 contract)
Owner: cwd /code/singular, claude --dangerously-skip-permissions --model opus --effort medium. Codex on 505: codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-505 -m gpt-6.1-sol -c model_reasoning_effort=high. Root /home/paolino/.orch-runtime/singular/m1/epic-507.

## z-singular-e520, singular-e520-owner (Carl creates safely)
cwd /code/singular. Launch: claude --dangerously-skip-permissions --model claude-opus-5-5 --effort high. Root /home/paolino/.orch-runtime/singular/m1/epic-520.

## z-singular-e521, singular-e521-owner (forbidden actions refused)
cwd /code/singular. Launch as e520. Root /home/paolino/.orch-runtime/singular/m1/epic-521.

## z-singular-e522, singular-e522-owner (narration and recovery)
cwd /code/singular. Launch as e520. Root /home/paolino/.orch-runtime/singular/m1/epic-522.

Owner-authored fragments for the older lanes are in resume/ from earlier snapshots and are dated; the lanes opened 2026-10-09 have not written fragments yet. A resurrected owner reads each lane's STATUS.md tail before pasting any resume pointer.

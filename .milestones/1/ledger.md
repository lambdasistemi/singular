# Singular M1 milestone ledger

Snapshot 2026-10-09T19:50Z (paused). Desk: Claude Opus 5.5 at pane %0 (relaunched after the host crash; was Claude Fable 5.1 at %2706), window singular-ms1-m1-owner, session z-singular-M1, runtime root /home/paolino/.orch-runtime/singular/m1 (journal STATUS.md there). The operator moved the seat here on 2026-10-09; the previous desk's journal at /tmp/projects/singular/milestone-1/STATUS.md is history.

## Outcome and its test

M1 is the permanent two-edge registry for KERI plus Demo 1. The observable test: on a preprod registry created once from the bounded release, Alice and Bob, each with only the shipped executable, their own wallet, a Koios URL and the registry's public state token, register, update and terminate keys, fold each other's bookings, recover after an interrupted command, and see the chain refuse forbidden actions; the public page is rebuilt from chain by either of them. Review date 2026-10-22 (issue 261). Old registries are abandoned; no migration. The five other edges are M2; shared scripts and Demo 2 are M1.5; naming is M3.

## Epics and lanes

| epic | journey | children | lane | stage |
|---|---|---|---|---|
| 301 | Demo 1 packaging and rehearsal only | 300, 359, 481, 484 | z-singular-e301, Opus owner %2585 | waits on the journeys |
| 371 | Bob joins and operates Carl's registry independently | 389, 485, 381, 503, 492, 528 | z-singular-e371: owner %2720/%2717, Muse on 485 at %2712 | 485 in implementation; 381 PR 433 unfinished |
| 396 | several users book concurrently, one fold settles them | 518 then 519; defects 486, 487, 488 | z-singular-e396, Opus 5.5 owner %2722 | opened 2026-10-09; roster approved; 518 ticket owner to be dispatched |
| 437 | restore missing references and resume | 471, 502 | z-singular-e437: Opus owner %2715, GLM ticket owner %2719, Muse %2681 | 471 PR 516 draft, implementation live |
| 498 | protected rejection | 494, 495, 496, 497, 529; research 500 | z-singular-e498, Opus owner %2713 | 494 PR 508; 529 filed 2026-10-08 |
| 507 | bounded M1 contract, M2 preserved | 505, 506 (504 done) | z-singular-e507: Opus owner %2714, codex on 505 at %2703 | 505 in progress |
| 520 | Carl creates without a stranded partial run | 406, 478, 479, 491 | z-singular-e520, Opus 5.5 owner %2723 | opened 2026-10-09; roster approved |
| 521 | forbidden actions refused by the chain | 358 | z-singular-e521, Opus 5.5 owner %2725 | opened 2026-10-09; roster approved |
| 522 | live narration and safe recovery | 477, 493, 415, 526, 334, 335, 416, 483 | z-singular-e522, Opus 5.5 owner %2724 | opened 2026-10-09; mapping |

Child teams, by the operator's ruling of 2026-10-09 (Codex out, the operator is on credits): epic owners Claude Opus 5.5 high; ticket owners Claude Sonnet 5.5 xhigh; commit owners Muse through the pi harness; auditors GLM through the pi harness, and from 2026-10-09 14:00 UTC Codex gpt-6.1-sol high on every newly launched slice (operator: Codex is back; running GLM auditors finish their slice); gate authors the ticket owner and the auditor; one team per epic at a time; the Codex seat on #505 in e507 stays by explicit exception. Every epic owner journals PLAN-REVIEWED on a ticket owner's mandate before a coder runs (rulings/planning-quality-2026-10-09.md).

## Priority order and why

1. Hash-changing contract work before the one new preprod registry: 505, 494 and 495, 529, then 506. A registry created before them cannot be protected or bounded afterwards.
2. The four journeys the demo cannot do without: 528 (every journey builds against the library from now on), creation (520), independent join (485, 381), one fold for several bookings (518, 519), restored references (471, 502), then 496 and 497 through the packaged commands.
3. What makes it show well: 477, 493, 415, 526, 334, 335, 416, 492, 503, 358.
4. Packaging and rehearsal: 481, 300, 359.

Inversions on the record: the conformance-bible epic 209 left M1 for assurance on 2026-10-08 and its lane is closed; the CI speed-up lane (449, PR 515) is M4 work and no longer a desk lane.

## Rulings in force

- 2026-10-08: the Singular CLI is the registry only (create, fold, reject, reclaim, inspect); the open datum is its own executable linking the Singular library up to the command line so Singular's flags pass through; cardano-keri's ckeri is built the same way (issue 528).
- 2026-10-08: every request carries a tag minted by Singular's request policy; untagged outputs at the request address are spendable by anyone; every tagged request has an exit; the mint demands a bond and a rejection forfeits, sized against fold capacity (issue 529, under 498).
- 2026-10-09: the request keeps carrying its datum inline; no size cap; the application decides what rides in it. Fold capacity under preprod's execution budget is estimated at about nine requests, proof-bound; measuring and raising it is issue 530 in M4.
- Every ticket is searched and placed before filing (llm-settings a3b51c4).

## Parked decisions

- Settled 2026-10-09 by the operator: the rejection forfeit is burned as a treasury donation in the rejecting transaction (fallback: registry state output, if the balancer proof fails); expiry forfeits too (e498 A-002).
- Settled 2026-10-09 by the operator: #494 merges alone; the in-window rejection row is published unmet until #495 (e498 A-001).
- Whether a failed trace file warns on stderr (issue 483): one answer when e522 asks.
- The preprod registry creation authorization: given once, after priority group 1 lands.

## Standalone and cross-cutting

Issue 528 sits under 371 for ownership but every journey builds against it. Issue 530 (fold capacity) is M4 and feeds 396. No standalone ticket lane is open.

## Public projection

Live dashboard (tailnet only, refreshed every minute by a user timer, no model): http://100.85.229.71:8460/ . Wiki story register https://github.com/lambdasistemi/singular/wiki/Milestone-1 regenerated 2026-10-09 from Milestone-1-Stories.json (34 stories, 6 groups, every open M1 issue mapped); wiki commit c79ce6e, register sha256 adea44c3d762ffb5. Roadmap, demo path and October logbook pages updated 2026-10-08 (wiki commit 26914cd).

## Concurrency and merge rules in force

Two logic-changing lanes at a time plus one almost conflict-free lane; cleanup that moves code without changing behaviour takes the stage. Working now: the bounded contract (505), restoration (471), the negative host (358, conflict-free). Paused at a safe boundary: join (485, operator pause of 2026-10-08), concurrent booking, creation, recovery, protected rejection. Merges one at a time through a desk-granted slot: 485, 505, then the command-line split (528) in an exclusive window as a standalone desk lane, then 471, 518, 406/478, 477, 494/495, 529, 506. Full text in the desk root, rulings/merge-queue-2026-10-09.md.

## Host crash 2026-10-09 13:35 UTC and recovery (current state)

The host hard-reset at about 13:35 UTC; every tmux session and agent process died; worktrees, runtime roots and the dashboard services survived. GitHub over ssh was down until the operator reloaded the passphrase-protected key into the systemd ssh-agent (/run/user/1000/ssh-agent.sock) at about 14:20 UTC; lanes held pushes until the desk note NOTE-M1-20261009T1420Z-push-works.

Relaunched 13:46-13:48 UTC with a crash-resume note (inbox/NOTE-M1-20261009T1345Z-host-crash.md in each root), each acknowledged by a RESUMED line:

- #485 ticket owner (desk lane), session z-singular-e371 pane %2, Sonnet 5.5 xhigh: head 8a590de1 green on cage tests; commit owner relaunched for the controls rerun and one just-ci; holds the push until GitHub is back; next merge slot.
- #528 ticket owner (desk lane), session z-singular-t528 pane %3, Sonnet 5.5 xhigh: slice 2; commit owner resumed from its three uncommitted files, auditor answering review s2-002 on aaaf012e.
- e437 owner, session z-singular-e437 pane %4: the #471 writer resumes slice 2c-ii from 27 uncommitted files on 0dc580c7.
- e521 owner, session z-singular-e521 pane %5: #358 slice 1 (PR 533) lint-leg repair; local commit 8410b0af unpushed.
- e498 owner, session z-singular-e498 pane %6: #529 planning only; #494 and #495 parked READY-TO-CODE; Q-001 (in-window rejection row) still with the operator.
- e371 owner, session z-singular-e371 pane %7: told to park #381 (waiting for #485's rebased push) and itself, wake = desk note.

Stayed down, parked by intent with RESUME.md and a wake condition: e301 (paused, wakes at Demo 1 checkpoint 9), e396 (#518, #519 READY-TO-CODE), e507 (wakes when #529 merges), e520 (#406, #491 READY-TO-CODE), e522 (#477, #493 READY-TO-CODE). The research seat and the project owner seat are not desk lanes and were not relaunched.

## Since the crash (14:00-14:45 UTC)

- Landed: #485 (PR 525, merge 75f0708f, 14:42 UTC), exact-head hosted CI green including the split Demo 1 jobs. The ticket owner closes its lane.
- Landed: #358 slice 1 of 3 (PR 533, merge f733a048, 15:36 UTC) after one returned slot (the rebased head missed the module #485 added). No slot open. Main is red once on 75f0708f on an intermittent R299-05 clause (same insert after the lock is released comes back partial; tree identical to the green PR head); e371 reproduces it and files a signed bug. #381 and #528 rebased onto 75f0708f; #471 waits for #528. #528 slice 2 accepted (24dcb9b8); its auditor is now Codex. e498 parked with its pane closed.
- #529 PLAN-REVIEWED (662663f9) and parked READY-TO-CODE; #494, #495, #529 all planned.
- After a host reset the operator must reload two secrets by hand: the ssh key (`SSH_AUTH_SOCK=/run/user/1000/ssh-agent.sock ssh-add ~/.ssh/ed25519`) and the gpg signing passphrase (`export GPG_TTY=$(tty); echo unlock | gpg --local-user 20B19354D7919C8C5810F95A55DFD2E86F982261 --clearsign >/dev/null`). Without the second, no lane can commit.
- Wiki Milestone-1 updated: commit 7de61e3, register sha256 a073ec562663f7ed.

## Paused for the night, 2026-10-09 19:45 UTC (operator)

Every lane is paused by order PAUSE-M1-20261009T1940Z (in each lane's inbox), each seat journaled PAUSED with wake = desk RELEASE, nothing is armed, no pane or worktree was killed. Main is 7d76efb0. Landed today: #505 (e3c9ab01), #485 (75f0708f), #358 slices 1 and 2 (f733a048, 7d76efb0), #534 (5fb1d754). No merge slot is open.

Resume tomorrow: the desk sends a RELEASE note to each live lane's inbox and a pointer to its pane (panes kept: e371 %7, t528 %3, e437 %4, e521 %5, e301 %49). State to resume from: #528 slices 1 to 3 done, PR 535 head 8fae2935 pushed with its CI repair, next slice per its RESUME; #381 run four repairing review 4-001 (PR 433 red acknowledged, EXPECTED-RED at 67d595e8); #471 writer mid 2c-ii with 15 uncommitted files named in its RESUME; #358 slice 3 next. Queue when released: #528 in its exclusive window when merge-ready, #381, #471, then #518 PR 1. Open with the operator: the liveness-rule proposal (drafts/factory-liveness-rule.md in the desk root) and the fix owner for llm-settings#99 (wait-channels misses what landed before it was armed).

## State at 18:10 UTC

- Rulings since 15:36: #494 merges alone and publishes the in-window rejection row as unmet until #495 flips it (operator, A-001); #534 (the refusal-controls story's 45 s registry window leaves 15 s for a fold build, too little on slow runners; test harness only) is commissioned under e371 as the conflict-free lane and takes the next merge slot ahead of #381 and #528, with one DEMO1.md sentence in its fence (desk, A-015, A-016); #358's tamper and withdraw pairs are signed by Alice, one difference per pair, Bob's case being slice 1's pair (desk, A-005, reported to the operator).
- Working: #528 (rebased onto 75f0708f, lint repair 713faf55 under Codex review), #381 (auditor repairs), #471 (slice 2c-ii), #358 slice 2 (RED repair under Codex review), #534 fix (plan reviewed, writer on Backend.hs).
- Parked: e301, e396, e498 (pane closed 15:18; relaunch on coding release), e507, e520, e522. No merge slot open.

## Snapshot 2026-10-09T12:37:40Z (supersedes the stages above where they differ)

- Landed: #505 (PR 523, e3c9ab01, 10:16 UTC). e507 parked until #529 merges; #506 waits.
- Working: #485 (desk-managed, rebased on e3c9ab01, second GLM audit passed, heading to hosted CI, next merge slot); #381 stacked on it; #528 (desk lane z-singular-t528, Sonnet ticket owner, slice 2 of 6); #471 (restoration, writer mid-slice); #358 (negative host, conflict-free third).
- Planned and parked READY-TO-CODE: #518 (two PRs), #519 (four PRs), #406/#478, #491, #477, #493 (five PRs); touch lists committed in each spec folder.
- Planning: #494 and #495 (e498, owner relaunched at Opus 5.5 high). Operator decision pending: how the suite shows the in-window rejection between #494 and #495.
- Merge queue: #485, #528 (exclusive window), #471, #518 PR 1, #518 PR 2, #477, #493, then the Lean surface #494, #495, #529, #519 Lean PRs, #506.
- Rulings today: staffing (Opus 5.5 high epic owners, Sonnet 5.5 xhigh ticket owners, Muse coders, GLM auditors; Codex only on the finished #505); planning quality and plan-ahead with touch lists; desk answers A-003 (public replay partition), A-004 (corpus row flip), 528 A-001 (singular links no application code), #532 placed under #498.
- Desk tools: watcher in the milestone skill, tailnet dashboard http://100.85.229.71:8460/ refreshed by a user timer.

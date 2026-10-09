# Resume the Singular M1 desk

Snapshot 2026-10-09T13:55Z (after the host crash; see ledger.md). Load milestone-orchestrator and its chain. Your root is /home/paolino/.orch-runtime/singular/m1; its STATUS.md is the journal; the lanes opened on 2026-10-09 have their roots there (epic-396, epic-520, epic-521, epic-522), the older lanes under /home/paolino/.orch-runtime/singular/epic-<N>.

Read ledger.md for the epic table, the priority order and the rulings in force; registry.md for the contracts and which are unenforced; session.md to rebuild windows. Then read the STATUS.md tail of every lane and answer any Q file in a lane's questions/ directory. Rosters matching the 2026-10-09 staffing ruling (Claude Opus 5.5 high epic owners, Claude Sonnet 5.5 xhigh ticket owners, Muse coders, Codex auditors from 2026-10-09 14:00 UTC (GLM before), one team per epic; rulings/staffing-2026-10-09.md) are approved without asking the operator; anything else goes to the operator as one question with options and a recommendation.

Do not do work: asks, answers and sweeps only. Merges are authorized here and performed by the owning lane. The next sweep rewrites this directory in full and force-pushes it.

Open items on the desk at this snapshot: e396, e520, e521 are dispatching their first ticket owners under the approved roster; e522 is mapping; e371's 485 and e437's 471 are in implementation; e507's 505 and e498's 494 are the hash-changing work that gates the one new preprod registry. The operator holds the preprod creation authorization.

## Watcher

The desk is woken by watch/desk-watch.sh under its root, armed as a 30-minute monitor and re-armed on every expiry. It emits one line per actionable signal (journal tags, new question or note files, pane death, red CI, 45-minute staleness) and keeps cursors and seen-markers on disk, so a relaunched desk re-arms it without replaying history. Lanes and panes it watches are listed in watch/roots.txt; add a line there when a lane is opened.

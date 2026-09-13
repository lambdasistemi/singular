# RESUME — epic-16 owner (recovery record)

## Relaunch

```sh
cd /tmp/projects/singular/milestone-1/epic-16
/run/current-system/sw/bin/claude --dangerously-skip-permissions --model 'claude-opus-5' --effort high
```

Window `singular-e16-t19-mpfs-import` in session `mpfs-onchain-ms2`; owner pane
was `%876`. Parent: milestone owner, pane `%844`. Children panes `%877` (GLM)
and `%878` (Muse) are retired and killed.

## Load chain

`orchestrator-contract`, `epic-orchestrator`, `resolve-epic`, `worker-protocol`,
`tmux-orchestrator`, `worktrees`, then `verification` / `invariants` as needed.

## Durable state in this root

| file | what it is |
|---|---|
| `brief.md` | the commission (authoritative) |
| `mapping.md` | frozen R1–R7 source-to-destination mapping for #19 |
| `gate-frozen.sh` | owner-frozen file-identity gate, sha256 `923c63b6f74cbb89ed311353cc4ccb7e491bce195c11af1a0e7a6874072fa3d8` |
| `epic-map.md` | children, contracts, invariant ledger, release-path gap |
| `handoffs/19-handback.md` | the #19 handback |
| `questions/Q-001-push-and-pr-timing.md` | open question to the parent |
| `.archived/t19-copy`, `.archived/t19-inventory-gate` | retired contributor runs and their evidence |

## Stage

#19 is delivered and owner-accepted, **not pushed**:

- import commit `34d7abec6ee4830e17a725fa84239af46c3ee206` on
  `chore/import-mpfs-source`, parent `db7c42034b28f50210a648b91d61246f7c20a0ec`;
- worktree `/code/singular-e16-t19-import-1`, clean, `gate.sh` installed
  untracked;
- source frozen at `34a5bfbb8cca2cb1911b7060d0e61db28ba21e83`.

Issues #16 and #19 bodies carry the parallel-start authority; acceptance
criteria were not weakened.

## Exact next actions

1. Answer or escalate `Q-001` (push + PR, or hold local). Nothing else blocks on it.
2. Decompose the first runnable vertical slice of #16 that consumes **no** epic-15
   contract. Candidate: the epic artifact itself — a runnable epic-scoped entry
   point — plus the on-chain release/packaging path, which `epic-map.md` records
   as a first-order blocker because Singular's publication path is
   documentation-only today.
3. Keep 15-dependent functional slices parked. Pin the **actual accepted** 15
   release for final compatibility; 15 has 1/6 children done.
4. Still unanswered by the operator: who authorizes unfulfilled-claim withdrawal
   and who receives the locked funds. Do not invent economics; do not let it
   block independent work.

## Standing constraints

No auditor seats. GLM and Muse for mechanical work. `/code/singular` and
`/code/cardano-mpfs-onchain` are read-only. Do not touch epic 15's checkouts,
the Lean/simulator/docs surfaces or root build files without milestone
arbitration. No cross-sibling worker contact. No final #16 release tag until a
concrete complete release is reviewed through the milestone path.

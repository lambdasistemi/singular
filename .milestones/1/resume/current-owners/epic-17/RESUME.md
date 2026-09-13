# Epic 17 owner — resume record

Current as of 2026-09-13T02:56:54Z (UTC). Owner is Grok (`grok-4.6`,
pane `%913`, PID `568965`, runtime
`/tmp/projects/singular/milestone-1/epic-17/owner-grok-20260912`).
A005: finish E17 then E18, then stop. A006 / historical rival stay
in E18 independently.

Clean candidate `954928c7d3f0da866f00c972fc64b641ebb9982a` on
`e9d08c5` is **intermediate**, not epic-accept. NOTE-090: continue
connected Over/burn/reuse on `%990`; integrated
`lone_fork_insert_accepts_real_absence_witness` on `%995`. No new
seat, auditor, model, restart, or reset. No migration/release/merge
accept.

`ddfc4e9` five-field COMPONENT remains at `/code/singular-e17-accept`
(read-only). Uncommitted-ddfc, unmerged-`1a6074f`, and NOTE-014
“next” lines below are **superseded**.

## Seat

```
grok --always-approve -m grok-4.6 --cwd /tmp/projects/singular/milestone-1/epic-17
```

| field | value |
|---|---|
| my pane | `%913` (`singular:1.1`) |
| parent desk | Codex, pane `%988`, `singular:3.1` |
| runtime root | `/tmp/projects/singular/milestone-1/epic-17` |
| owner run | `/tmp/projects/singular/milestone-1/epic-17/owner-grok-20260912` |
| epic checkout | `/code/singular-e17` |
| staffing | inherited flat team: owner authors mandates/gates and accepts worker output; `%990` Muse and `%995` GLM own code. **No new seats, auditors, resets, or lost counters.** |

### Roster

| worker | pane | state |
|---|---|---|
| `ticket-77/commit-owner-2` | `%990` PID `3808876` | LIVE Muse. NOTE-029 then NOTE-030. Live `retirement-rows` PID `1457594` — do not abort. 092 Over-association first; LT04/LX01 claim bounds. **Do not relaunch.** |
| `ticket-81/commit-owner` | `%995` PID `72262` | GLM `83b359f` PROOF-COMPLETE (staging rm-then-copy + concat guard). Integrated 954928c close still needs re-integration. **Do not relaunch.** |

## Current candidate

`954928c7d3f0da866f00c972fc64b641ebb9982a` parent `e9d08c5` (includes
Fork `f285637`). Worktree clean at COMPLETE. Reader still has untagged
`findRecoverRedeemer` in `recoverContinuation`; name formula uses
`statePolicyOf` (`rePolicy`), not `positiveMintPolicy` (`repPolicy`).

## Next

1. `%990` NOTE-028: same Over journey, but completion must fold the
   pending request with burn/native-spend/consumer withdrawal and
   write authentic Over. Burn-only custody+mint is not LT04. No
   generic `onchain/` edit. No fixture Over.
2. `%995` NOTE-006: prove whether the failing integrated aiken path
   staged the patch; match hardcoded witness to producer evidence;
   repair the defect; do not weaken the test.
3. Final full hashes/widths/order/vectors mechanically, then through
   root before E18. Not this turn.

## Frozen

Design `13231f58833b8feb57f4b0f9b1117bfcfba0c07d` tree
`dd9e508bb11108c5c459fcf8e59e3dd1930eead6`. Consumer
`14a64a4681d3e429fab5877062b5c476c2a4bfe2`. Release PR67 held. #87
Blaster still M1 required / not established.

## SUPERSEDED current-instructions (do not follow)

Uncommitted-on-`ddfc4e9` debt, unmerged Fork `1a6074f` serial-merge,
and NOTE-014 “next” steps are historical. Fork is already in `e9d08c5`.
Keep original evidence. Historical Fork control table (pre-`e9d08c5`
merge; candidate then `1a6074f` / later `f285637`):

| control | artifact | result |
|---|---|---|
| patched ledger | `ticket-81/commit-owner/evidence/devnet-run2.log` | 8 examples, 0 failures; absence insert ✔; occupied-key ✔ |
| unpatched ledger | `…/devnet-run3-unpatched.log` | 8 examples, 2 failures; absence insert CekError hash `ce7615f6…`; occupied also fails during setup insert — **not** independent occupied-refusal |
| corrected unpatched aiken | `…/red2-unpatched-corrected.log` | exclusion arm FAIL; including PASS; control PASS |

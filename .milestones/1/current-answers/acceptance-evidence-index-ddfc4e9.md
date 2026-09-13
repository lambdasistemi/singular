# Acceptance evidence index — candidate `ddfc4e9`

Record reconciliation, not a rerun of #77. Every row names the exact command, the
binding it was run under, the current path, and its **actual** status. Failed
attempts keep their names and are listed as failed; nothing is renamed to look
like a success.

Candidate: `ddfc4e961d530ee4e62361aabbcc730a9b9809ed`
Acceptance root: `/code/singular-e17-accept` — **immutable detached checkout**,
`HEAD` and `git status` (0) verified before and after every leg. No worker can
write it.

## Terminal receipts — what each claim actually rests on

| # | instrument (sha256) | command | receipt | status |
|---|---|---|---|---|
| 1 | `supplement-77-S3.sh` `9e391fc3…` | `S3_TMPDIR=/tmp supplement-77-S3.sh /code/singular-e17-accept ddfc4e9… /tmp/s77-accept3` | `/tmp/s77-accept3/S3.log`, copied to `S3-console.log` for A2's console check; run evidence `/tmp/s77-accept3/run-20260912T182829Z-$/` | **RED at `verifier-exit` 126** — the frozen instrument's own store-path defect. `candidate-bound`, `blueprints-build`, `verifier-available`, `devnet-session`, `runner-executed` (exit 0) all PASS first |
| 2 | `amendment-77-A2-verifier-executable-path.sh` `cd569ffb…` | `A2 /code/singular-e17-accept <run dir> ddfc4e9… /tmp/s77-accept3` | **`/tmp/s77-accept3/A2b.log`**; verdicts `/tmp/s77-accept3/a2-20260912T183214Z-222102/verdicts.json` | **GREEN, 17/17 ESTABLISHED** |
| 2f | — | first attempt, same instrument | `/tmp/s77-accept3/A2.log` | **FAILED, retained** — `s3-runner-executed` fail-closed because my runner wrote the S3 console under a name A2 does not look for. Instrument correct, runner wrong |
| 3 | `amendment-77-A3-e001-cause-obligation.sh` `15bb4b50…` | `A3 <honest verdicts> <mutant verdicts> ddfc4e9… /code/singular-e17-accept` | **`/tmp/s77-accept3/A3-RETAINED.log`** — header pins both input digests, the instrument digest and the worktree binding | **GREEN** |
| 3f | — | runner's call with a mis-ordered argument list | `/tmp/s77-accept3/A3.log` | **FAILED, retained** — usage error, exit 1. This is the gap NOTE-059 named: the successful A3 had been run interactively and its output was never written to a file. Re-run above over the **same retained inputs**; no ledger or package work repeated |
| 4 | `fault-controls-77-S3-A2.sh` | `FC /code/singular-e17-accept <run dir> ddfc4e9… /tmp/s77-accept3` | `/tmp/s77-accept3/FC.log`, evidence dir beside it | **GREEN**, four faults each refuted |
| 5 | `supplement-77-S4-package-provenance.sh` v4 `9e973282…` | `S4 /code/singular-e17-accept ddfc4e9… /tmp/s77-accept3` | `/tmp/s77-accept3/s4-20260912T183639Z-237104/` | **GREEN**, every leg |
| 5f | v2 `27ec19cd…` / v3 | earlier attempts | `/tmp/s77-accept3/S4.log`, `/tmp/s77-accept3/S4-v3.log`, evidence dirs `s4-…-219113`, `s4-…-228645` | **FAILED and RED, retained** — v2/v3 credited exit 127 as a refusal (the checker never ran) and credited any non-git nonzero as a clean-PATH pass. v1's failure is under `/tmp/s77-accept2/`. All retained under their own names |
| 6 | `amendment-77-A1-v2-recovery-leg-env.sh` `82dbc1e2…` | `A1v2 /code/singular-e17-accept /tmp/s77-accept3/a1v2` | `/tmp/s77-accept3/A1.log`, evidence `/tmp/s77-accept3/a1v2/` | **GREEN**, clean-bound (`before`/`after` both `ddfc4e9… dirty=0`) |
| 7 | `gate-77-v3.sh` `7fa81cb7…` (frozen) | staged into the acceptance root at the ignored `./gate.sh`, digest verified, then `GATE_TMPDIR=/tmp/s77g3 GATE_EVIDENCE=/tmp/s77-accept3/gate-evidence ./gate.sh` | `/tmp/s77-accept3/gate.log`, 20 leg logs under `gate-evidence/` | **RED on 1 leg** — `recovery-preserved`, the A1 defect. 17 legs exit 0; both must-fail controls exit 1 after executing rows |
| 7f | — | first attempt from the runner | `/tmp/s77-accept3-console.log` (`GATE_EXIT=127`) | **FAILED, retained** — `gate.sh` is gitignored so `git worktree add` did not carry it. `RUNNER_EXIT=0` there is the orchestration shell's status and is **not** acceptance; the runner now aggregates step statuses |

## Superseded whole runs, retained

- `/tmp/s77-accept/` — the `617e434` campaign. It ended **INTERRUPTED / SUPERSEDED**
  and is NOT a whole-run acceptance claim: its gate leg 18 was terminated on the
  packaging finding, and its A1 run was contaminated by a dirty tree (adjudicated
  under NOTE-052). Keep its **per-leg** evidence only — S3's bound devnet run, A2's
  17/17, the fault controls, the leg logs — and cite no run-level verdict from it.
- `/tmp/s77-accept2/` — acceptance at `fe89e68`. Its gate run is **observed
  mixed, UNBOUND to a clean candidate**: `%990` committed `ddfc4e9` while it ran,
  and a leg ending before a commit does not prove the tree was clean during it.
  Retained in full, cited for nothing.

## Does any acceptance claim lack its executable receipt?

**No — as of this index.** The one that did was A3, named by NOTE-059 and closed
above by re-running only that bounded amendment over the same retained inputs.
Every other claim in my journal points at a file in the table.

Two honest qualifications that are not gaps:

- the `refusal.representative-policy` **mutant** input
  (`ticket-77/commit-owner-2/evidence/verdicts-mutant3.json`) was produced by the
  worker in its own worktree while that tree was dirty — its own log carries
  `warning: Git tree … is dirty`. It is a *discrimination control*, not a
  candidate-bound claim, and A3 treats it as such: it requires the mutant to
  record the foreign fold **accepted on chain**, which is a property of that run,
  not of the candidate;
- `supplement-77-S3` has never reached its own step 4 on any candidate. Its
  obligations are adjudicated by A2, which is why A2 carries S3's steps 4–5
  verbatim.

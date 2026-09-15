# Functions

Retroactive record, written 2026-09-15 from PR #109 merged at
`fc2ad9e5987b171ca33a430f5bbe170ab6423fd5`.

## Tool behaviour

No bodies here.

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `scan_files` | tracked tree | file list | Includes `*.sh` and `*.py` alongside the previous kinds. |
| rename steps | scanned files | rewritten tree | Unchanged semantics; only the covered kinds grow. |
| residual grep | rewritten tree | hits | Same grep the gate derives from; word-match, so underscored tokens stay invisible. |
| allowlist derivation | grep hits | allowed set | A file survives only if every hit sits on an upstream citation line. |
| `--gate-only` | tree | pass or named failure | Passes on a clean main; names the file carrying a planted stray. |

## Test behaviour

Cut a throwaway detached worktree from main; snapshot index plus
all tracked bytes; run twice and compare for the no-op; plant the
stray and require the gate-only failure; clean the worktree up on
exit. Materialize the `origin/main` ref when a depth-1 checkout
does not have one.

## Test surface

Run-1 completion with gate pass; run-2 byte-identical no-op with
gate pass; planted-stray gate-only failure naming the file;
pre-fix script failing at run 1; weakened derivation firing the
control.

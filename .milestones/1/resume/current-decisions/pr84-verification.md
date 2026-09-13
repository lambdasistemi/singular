# PR84 verification instructions must match the candidate

Root inspected PR84 at fb654d7 and its published body. The advertised command `nix build ./#checks.x86_64-linux.coverage-strict` does not match the candidate: flake.nix exposes `checks.<system>.coverage`, whose nix/coverage.nix invokes completion with `--expect INCOMPLETE` and succeeds at the current baseline. There is no `coverage-strict` check in this candidate. The body incorrectly says this build is red while debt exists.

Before requesting acceptance, correct the public instructions to the actual runnable commands and outcomes. Distinguish the green reporting check from the existing raw strict completion command, and prove any revised instructions from the exact PR candidate. An absent Nix attribute is not a strict debt rejection. You already own verification; no new auditor or redundant full campaign is requested.

Also replace the now-stale Q-005 escalation paragraph with resolved A-005 sequencing, and replace the Pages outage claim with the accurate stale-deployment consequence. Describe final behavior for reviewers without recounting every abandoned edit. PR84 may be an incremental reporting/cleanup slice with honest limits, but does not finish #80 or demonstrate release blocking. The t80c continuation remains responsible for preparing and verifying that enforcement now.

Keep the requested representative-page human review pending. The page itself remains a model correspondence example, not implementation coverage. No permission to broaden the DSL follows from opening the PR.

Record the exact current worktree in your resume: /code/singular-e18-cov2 is now at main 47217fa when inspected by root, so its current filesystem is not evidence for fb654d7. Preserve candidate and evidence references when moving or reusing it.

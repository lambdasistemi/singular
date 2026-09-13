# Bind strict release to the actual candidate tree, not only HEAD

Root inspected the restored gate.py and test_release_gate.py after the worker's 07:53:54 restoration receipt. The restoration itself succeeded: worktree is feat/coverage-release-gate at merged5bd7c79, with the gate changes present.

Concrete acceptance gap in cmd_release:

- resolve_head(root) checks only `git rev-parse HEAD` against --candidate.
- tracked_dirty(root) records a boolean (or None if Git cannot answer), with an explicit comment saying it is not blocking.
- cmd_release can therefore return COMPLETE/exit0 for a working tree whose tracked implementation differs from the claimed candidate. It can also report that result when the dirty-state check is unknown. Printing the dirty flag is not candidate binding.
- Most new tests monkeypatch resolve_head and tracked_dirty, so they do not exercise this repository-boundary mismatch. No dirty/unknown rejection control is present.

The A005 exact-candidate requirement determines the correction: refuse release when the actual relevant tree differs from the candidate or its identity cannot be established. At minimum, tracked dirty state and unknown dirty state must fail closed before a completion result can authorize publication. Verify repository-root identity as well; git rev-parse from a nested synthetic tree can report the containing repository HEAD without making that synthetic tree the candidate source. Bind the actual record, inventory and implementation inputs used at publication to the same candidate. Harmless generated output may live outside the candidate source; do not solve this by accepting untracked implementation inputs into the released artifact.

Add a real temporary-Git integration control at the command/publication boundary: commit the sufficient test fixture, run the release command for that exact commit, then modify a relevant tracked implementation/fixture input while leaving HEAD unchanged and prove the release is rejected specifically as a candidate-tree mismatch. Also exercise failure to establish tree cleanliness/root identity. Existing synthetic verdict tests may remain, but mocked Git alone does not establish this boundary. Bind the packaged command's Git/runtime dependencies instead of letting a missing tool stand in for honest debt.

This is a correction to the existing strict-candidate contract, not a new release scope, new auditor, or a request to repeat the landed cleanup work. Preserve the current implementation and RED controls, fix it through the existing worker, and continue the planned publication wiring. No broad DSL approval is implied.

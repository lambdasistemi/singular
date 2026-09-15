# Tasks

Retroactive record, written 2026-09-15 from PR #109 merged at
`fc2ad9e5987b171ca33a430f5bbe170ab6423fd5`.

The tasks are the PR's commits in order, each done with its sha.

- [x] T108-1 `a622ff72d45b320509d1e35cf7b09b062fb63e31`
  fix(tools): scan sh/py files and derive the rename gate
  allowlist (#108) — wider scan, derived allowlist, twice-run
  test with planted-stray control, `just ci` wiring.

## Slice

Rename gate that scans shells and derives its allowlist. Gate as
shipped: `just ci` green including `rename-registry-test`, both
falsification directions observed.

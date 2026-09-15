# Tasks

Retroactive record, written 2026-09-15 from PR #121 merged at
`454aec3858f0aa029d93928f09b5c4447bf49894`.

The tasks are the PR's commits in order, each done with its sha.

- [x] T120-1 `1f85239ddb5df15b9f0d5e9acd9865ad2f02892d`
  fix(release): publish version changes and usable archive
  instructions — rewritten stable text, changelog-section
  composition with loud refusal, extended publisher and archive
  checks with double-backed cases, README row update.

## Slice

Versioned release bodies with usable archive instructions. Gate as
shipped: `just ci` green, release-check cases green,
release-artifacts green, packaged publisher checks green,
negative controls refuse.

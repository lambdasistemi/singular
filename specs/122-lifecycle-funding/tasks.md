# Tasks

Retroactive record, written 2026-09-15 from PR #122 merged at
`6ab1093367e00290a4b74638f03f5ef44b3137e6`.

The tasks are the PR's commits in order, each done with its sha.

- [x] T122-1 `345658df4231bc2623e77c11ba50d86add03359c` fix: fund
  public naming lifecycles from live protocol parameters — new
  `Singular.Registry.Lifecycle` layer, `withNodeForPlannedFunding`,
  public-path wiring in the three runners, `--lifecycle` attach
  check, `LIFECYCLE.md`, aggregate-limit spec.
- [x] T122-2 `e4ae94111e02e87f766b75a220c1bad97a76c2ba` fix:
  preserve reserved lifecycle inputs during request funding —
  `fundingProvider` reserved-input filter, wrapped around
  `requestInsertImpl` in recovery and retirement, with its
  regression test.

## Slice

Public lifecycle funding and evaluation. Gate as shipped: `just ci`
green, `cage-tests` 109/0, `--lifecycle` attach check green, full
suite retained without the flag.

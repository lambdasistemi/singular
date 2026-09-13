# What this release is — and what it is not

This is the **epic-17 on-chain delivery** of Singular, published by the
repository's release pipeline from a version tag. It carries the
connected registry lifecycle through permanent retirement: claiming
with real representatives, recovery that preserves them, retirement
by controller or quorum into completion-only custody, permissionless
completion that burns the representative while folding the
retirement's own registry update, and the occupied-key refusal that
is Over — on top of the epic-16 cage/naming foundation and all
retained earlier rows. It is **not** the milestone artifact and
**not** the product artifact; nobody should mistake it for either.

## What it does not cover

- **Row evidence is finite.** Every claim, recovery, retirement,
  completion, occupied-key and mismatch row reproduced from this
  archive, plus the retained `LI`, `LM`, `WR` and `LC` rows, is a
  fixed fixture from the accepted contract, executed once on a
  devnet. That is
  evidence about those fixtures, and about nothing beyond them: it is not a statement about arbitrary transactions, not a universal decoder theorem, and not a general correctness proof of the validators.
- **Coverage debt is preserved, not discharged.** The live
  obligation population stands at 196 against the certified 196
  baseline (192 preserved only as the historical predecessor;
  mapping 196, implementation layer 196, findings 0, unclassified
  83, stale 0); the baseline ceremony belongs to the release owner,
  and this release neither rewrites it nor claims its verdict.
- **E18 conformance is a separate track.** Cross-contract review
  happens against the withheld ABI tuple through the owner, not
  from this artifact.
- **The consumer-conformance obligation is not discharged here.** This
  release *consumes* the accepted epic-15 contract (v0.2.0, asset
  sha256 `acbabdf54a271251bd73bf9d84ab2c901107045a7dd77d28a391f22cdd53b0e5`)
  rather than replacing it; issue #16's compatibility evidence pins
  that release.

## Provenance

This archive is assembled and published by the pipeline
(`.github/workflows/release.yml` builds it from the tagged commit with
Nix and uploads it; it is never built by a person and uploaded by
hand). Its checksum manifest is `SHA256SUMS` inside the archive, and
the release's `SHA256SUMS` covers the archive file itself. The applied
script identities a concrete instance carries on chain are derived
from the pinned unapplied identities at run time; the journey runner
asserts that derivation on every run.

# What this release is — and what it is not

This is the **epic 16 on-chain release** of Singular, published by the
repository's release pipeline from a version tag. It is
**epic-scoped**: it carries the on-chain work of epic 16 (the imported
MPFS cage partition and Singular's own naming partition, their compiled
scripts and pinned identities, the runnable journey and row runners,
and the contract fixtures). It is **not** the milestone artifact and
**not** the product artifact; nobody should mistake it for either.

## What it does not cover

- **Recovery and retirement belong to epic 17.** Nothing in this
  release claims, demonstrates or pins any recovery or retirement
  behaviour. Those lifecycle stages are future work with their own
  evidence, and this release must not be read as covering them.
- **The row evidence is finite fixture execution.** Every `LI`, `LM`,
  `WR` and `LC` row reproduced from this archive is a fixed fixture
  from the accepted contract, executed once on a devnet. That is
  evidence about those fixtures, and about nothing beyond them: it is not a statement about arbitrary transactions, not a universal decoder theorem, and not a general correctness proof of the validators.
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

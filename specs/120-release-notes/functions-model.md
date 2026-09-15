# Functions

Retroactive record, written 2026-09-15 from PR #121 merged at
`454aec3858f0aa029d93928f09b5c4447bf49894`.

## Publisher behaviour

No bodies here.

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| section extraction | manifest version, changelog | section text | Matches the version's `## [X.Y.Z]` heading; stops at the next version heading or end of file. |
| refusal | missing or empty section | loud failure | Message names the version; exits before any upload. |
| composition | section, stable text or override | notes file | Section followed by stable text; the packaged notes override replaces the stable part. |
| release creation | tag, notes file | GitHub release | Skipped when the release already exists; archives uploaded with clobber. |
| archive verification | downloaded archives | accept or refuse | Both archives present with valid checksums; identities verified; instructions equal the source. |

## Check behaviour

The publish check asserts the manifest version's changelog section
is non-empty and the stable text carries no forbidden wording,
then runs the real publisher Bash against Git and GitHub doubles
across the eleven cases and asserts the composed notes equal the
expected section plus stable text on every passing case. The
release check asserts shipped instructions equal the source and
refuses internal wording.

## Test surface

Eleven double-backed publisher cases plus the forbidden-phrase,
original-publisher and stable-only-body negative controls, with
the restored candidate passing.

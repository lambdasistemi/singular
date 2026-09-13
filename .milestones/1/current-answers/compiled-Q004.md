# Q-004 — known-good ddfc insert-fold vector (or diagnosis pointer) for an unexplained CEK refusal

**Status:** diagnostic impasse after exhaustive in-lane elimination, NOT a
missing toolchain input. The ddfc span is 2/3 green with three isolation
HALTs; the honest insert-fold ERRORs for no reason I can find. I am
committing the proven legs with explicit scope and asking for one vector.

## Observed (all in `blaster/SingularBlaster/DdfcSpan.lean`, green guards)

- HALT: state `Modify` (5-field datum, policy preserved, root advanced to
  the reused `NEW_ROOT`), rep `MintRepresentative` (+1 named, redeemer-map
  lookup decodes `Fold`), withdraw-`Fold` (shared prefix), `InsertApproval`
  mint (approval derivation through the real bytes), retire
  (`expected_rep_policy` + custody + quantities).
- ERROR (fast, identical at 500k/1M/2M steps): honest insert-`Fold`
  (state input + 0-value MPF request + claim, `Fold([repName])`,
  mint `{rep:+1, approval:-1}`, no signatories).
- ERROR as predicted: T1 (wrong name), T2 (no rep in mint), T3 (no rep in
  continuation), foreign-mint fold, altered-preservation state, malformed
  datum. The foreign leg is NOT claimed as E-001 evidence — with V1
  unexplained its attribution (rep-name line vs mint-quantity line) is
  unsound, and it is recorded that way.

## Eliminated mechanically (evidence in the turn transcript + file)

Budget (identical fast ERROR at 3 step counts); fixture transcription
(`DdfcParams` self-consistency: all lengths, constructions, re-derivation
and six CLI-verified hashes pass); program identity (ddfc-specific
`InsertApproval` arm HALTs; blueprint hashes match the handoff 16/16);
redeemer shape (rep leg decodes the same `Fold` bytes); shared fold prefix
(withdraw HALT on the same datum/claim shape); approval derivation
(mint HALT on the same triple); expected-policy lookup (retire HALT on the
same state input); MPF version (v2.0.0 both partitions, state HALT confirms
the reused root); branch dispatch (rep-name vs empty behaves).

## Missing input (exact)

ONE passing ddfc insert-fold's exact bytes — record datum, `Fold`
redeemer, mint field, claim value, continuation value — e.g. from the
`representative-minted-by-fold` gate leg's accepted transaction, to diff
field-by-field against `DdfcSpan.lean`'s `spanTxInfo`; or a diagnosis
pointer if the shape rings a bell (the prime suspect area is anything my
static reading of `fold()` lines 331-396 cannot see, since every line
there is covered by a passing leg except the rep-name equality and the
two `quantity_of` alls, which are pure applications of proven parts).

## Producer

Epic 17 #77 lane — owns green insert folds at `ddfc4e9`. A pointer to
retained evidence I can read (sibling read-only respected) is sufficient;
no new run is being asked for.

## Meanwhile (no park)

Committed: rep structEq, state/rep HALTs, three isolation HALTs,
preservation + malformed discrimination, T1/T2/T3 consistency set, budget
probe — all with explicit scope. C3/C4 stay UNDISCHARGED (no promotion of
partial legs). The foreign-mint ERROR stays unattributed. Snapshot/f3
lanes untouched at their own identities.

## Outcome (2026-09-12) — RESOLVED by A-004, no vector needed

A-004's diagnosis (descending policy map vs stdlib `dict.get` early-`None`,
verified in the pinned 2.2.0 source) was exact. Mechanical normalization
(computed ascending order both levels + per-build guards) turned the honest
triple to `(HALT,HALT,HALT)`; the foreign leg now attributes cleanly to the
mint-quantity check (E-001 evidence). A near-miss on the way is owned in
`DdfcSpan.lean`: the author "caught" `String.compare` misordering bytes on
a snapshot-vs-ddfc byte confusion of his own — the comparator agreed with
byte order on every in-play pair; the char-level version is kept for
construction-guaranteed exactness, not because a failure was shown.

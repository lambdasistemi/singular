# Owner wire source review — `0100012`, 2026-09-12

## Bound identities

- Candidate: `/code/singular-e18-exec` at
  `0100012b1afa318df3bae6cf40d6d9ee3507110e`, clean after review.
- Accepted Lean design: `13231f58833b8feb57f4b0f9b1117bfcfba0c07d`,
  tree `dd9e508bb11108c5c459fcf8e59e3dd1930eead6`.
- Lean source: `lean/Singular/NamingWireStatements.lean` and
  `lean/Singular/NamingWire.lean`.
- Property source SHA-256:
  `8b8751b22cbb753346fdb34d912b0d3746a6fc6126d545581426012bcf3d8c2c`.
- Fixed-vector story source SHA-256:
  `b246ac400a577c73375c2e9adf89023b31ffab13c1fb55caa14dab8b53d052bc`.
- Two-destination mutant `Naming/Datum.hs` SHA-256:
  `0474578c87bfd4b13a80f824cc23f86b1656abdafef15c1edbf946e2e6578f47`;
  its sole semantic diff adds acceptance of `Constr 1 (bytes : _)` beside
  the exact-one-field case.

## Clause and layer verdicts

- P2 / `naming_datum_tree_roundtrip_and_shape`: **partial, debt retained**.
  The Lean theorem has four conjuncts. The generated property exercises all
  four, while WD01 covers roundtrip and declared shape only; the story layer
  has no isolated control-address-byte or commitment-byte observations.
- P3 / `inline_datum_only`: **partial, debt retained**. Lean requires inline
  success, datum-hash refusal, and absent-attachment refusal. The Haskell
  `DatumAttachment` cannot represent absent; WD02 exercises only datum-hash
  refusal. The full theorem is not covered at both layers.
- P4 / `payment_destination_zero_or_one`: **owner-accepted at this bounded
  wire layer**. It is a one-clause theorem. The generated property invokes the
  real decoder over generated well-formed datums with a two-address option;
  WD03 separately invokes direct decode and the composed
  serialise/deserialise path over the pinned vector. Both go green on the real
  codec and red on the exact decoder mutant.
- P8 / `insert_request_malformed_and_redirect_refused`: **partial, debt
  retained**. Property and WR01 cover malformed refusal, redirected proposal
  standalone decode/non-match, and comparator reason. Neither executes the
  fourth Lean conjunct at `lifecycleStep`; cancellation with mismatched refund
  remains lifecycle-story debt.
- P9 / `datum_refusal_families`: **supporting property only**. It has no
  corresponding `NamingWireStatements` theorem/mapping and no distinct story
  layer. Its seven decoder refusal cases and arity mutant remain useful
  diagnostics but pay no obligation.

This review validates P4's already-recorded credit; it does not alter the
candidate board (`188/188/11`), repay another obligation, or turn the partial
rows into passes.

## Fresh execution

From `/code/singular-e18-exec`, one `nix develop ./offchain --quiet` shell ran:

1. `bash conformance/coverage/execution/wire-props/run-wire-props.sh` — exit 0,
   9 properties, 216 cases/assertions, P1-P9 all reported PASS.
2. `bash offchain/naming/run-suite.sh` — exit 0, 17/17 fixed-vector checks PASS.
3. `bash conformance/coverage/execution/wire-props/run-wire-props.sh /tmp/t80e-mutant-src`
   — exit 1; P4 alone failed with three named counterexamples, all other
   properties passed.
4. The fixed-vector test was compiled with mutant source first on the include
   path and executed — compile exit 0, run exit 1; exactly the two WD03
   direct/composed two-destination checks failed while the other 15 passed.

Aggregate owner control:
`property-green=0 story-green=0 property-mutant=1 story-mutant=1 mutant-compile=0`.

# Fork occupied assertion binds — apply at serial merge, not before

Root NOTE-077, 2026-09-12. `f28563786dd4bf37312d6faa62deee3b7a06a9cf` occupied
negative is confirmed: 1 example / 0 failures; `EvalFailure ConwaySpending`
index 2; `CekError` at stated budgets; `pwcScriptHash`
`fa90391a470d726da369275cc1ae1be9c35a6d1f3885107e4227794d`. Builder-evaluation,
not submitted ledger rejection. Retain
`ticket-81/commit-owner/evidence/occupied-eval-error.log` and the `f285637`
identity. Do not restart `%995`. No suite rerun for this note.

Apply both in the **same** serial-integration step into the producer, when
that coherent commit happens:

1. **Do not hardcode** `fa90391a…`. Derive expected state identity from the
   actual production-applied cfg/state bytes used by the run; keep
   provenance and parameter agreement. Do not copy a new hash literal.
2. **Do not** `shouldContain` that hex anywhere in `show` of the full
   `ErrorCall` (transaction data, values, and parameterized script bytes
   can contain the state policy). Match the failed witness's **named**
   `pwcScriptHash` field, or a typed failure identity if the builder
   exposes one. Retain spending-purpose target (`ConwaySpending` index of
   the state spend) and the near positive (absence insert/readback).

Not ticket-81/77/shared-candidate acceptance.

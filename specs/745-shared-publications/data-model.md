# Data for creating registries on shared script publications

Issue 745. Records the ticket introduces or changes, their fields and their rules. Placement is in
[the modules model](modules-model.md).

## Records

| Record | Fields | Rules |
| --- | --- | --- |
| Reference outcome | script role (state or application), expected hash, where it was taken from or published, and one of: reused, published, missing then published, spent then published, wrong script refused | one per script of a creation; the hash is computed from the script carried by the output, never read from the provider's claim |
| Measured transaction | step name, transaction identity, size in bytes, fee, reference outputs it creates (script hash, script size in bytes, ADA locked), outputs it spends and reads | every transaction of a leg, in submission order |
| Measurement leg | design (previous, candidate), revision, protocol parameters, workload (first creation, later creation), the measured transactions, totals | totals are computed from the transactions; locked ADA and fees are separate totals; the previous design's witness-publication transactions are named as such |
| Carrying attempt | the frozen transaction size limit and execution limits, the size of each script, the size of the creation transaction with and without the carried script, outcome (fits or does not) | read from the transaction and the parameters, not estimated |
| Reuse claim | the claim in words, the receipt it is read from, its state (covered by that receipt or uncovered, with the reason) | state is computed from receipts and never typed |

## State rules

- A reference output is live only if it is unspent and the script it carries hashes to the expected hash; the hash
  covers the language, the bytes and the applied parameters, so a different application policy or release has a
  different hash and is never reused.
- A creation that finds both live copies sends exactly one transaction and creates no reference output.
- A creation that finds one copy missing publishes exactly that script.
- Locked ADA of a reference output is its minimum ADA, kept apart from the fee of the transaction that created it.

# Retire ABI — affected expectations, recorded for rebind (NOTE-099)

**Nothing to execute now.** The ddfc component is unchanged and remains the input for the current
rival and Q-004 diagnostics. This records what changes *later*, so it is not rediscovered at rebind.

## The coming shape

Authorized after the recovery finding: recomputing from the **current** control breaks retirement
after recovery, so the binding must be to an **immutable key witness**.

- **Naming datum remains FOUR fields.**
- **`ApplicationRedeemer.Retire` = Constr 3, `[representatives, key_hash]`, in that order.**
- `key_hash` is **exactly 28 bytes** of the **creation-time** public payment-key hash.
- Checked against the **actual representative commitment** *and* the supplied authentic cage's
  **FULL asset identity**.
- Authorization comes from the **current recovered controller or the fixed quorum**.
- **Token name and value survive recovery.**

**What this is not:** trust in a caller-supplied label, and **not** a requirement for the old signing
secret. The creation-time hash is a public value; the authorization is separate and current.

## Consequences for epic 18

**Final `Retire` encodings WILL change, even for fresh claims.** So:

- **Do not transfer old byte or compiled receipts without rebind.** This is the coverage-is-not-
  inherited rule applied to `Retire` — a passing byte vector against the old encoding says nothing
  about the new one.
- **Keep old schema and version receipts at their own identities.** Supersede, never relabel.
- Producer must publish **exact actual SDK/Aiken bytes, cross-language vectors, and measured applied
  and unapplied identities** *before* any consumer migration. Migration waits on that, not on prose.

## Required final journeys — with a constraint worth noticing

- **claim → recover → controller-retire**
- **claim → recover → quorum-retire**

**Creation-key material must be obtainable through the supported public provenance/SDK path**, not
only from an in-memory test setup. A journey that fabricates the key in memory would demonstrate the
validator's arithmetic while proving nothing about whether a real integrator can retire at all.

Unchanged: four-field datum, ordinary maintenance, fixed quorum, nonempty final completion. Not
commissioned: any new indexer or service, an old-key signature, altered ownership, or a waived
spelling/key refinement.

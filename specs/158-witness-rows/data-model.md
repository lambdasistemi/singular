# #158 — data model

## The JSON report

One object per row:

```
{ "id": "WR03", "expected": "accept" | "refuse",
  "observed": "accept" | "refuse" | "skipped",
  "txIds": [...], "policyIds": {...}, "assetNames": {...},
  "attribution": { "script": "cage" | "witness" | "application" | null,
                   "trace": "read-non-terminal" | ... | null },
  "verified": true | false }
```

`verified` is false whenever `observed ≠ expected` or, for a refusal, the
attribution differs from #157's trace-label table. The run's exit status is
non-zero iff any row is not verified or is skipped.

## Evidence directory

```
evidence/witness-rows/<run-id>/
  report.json
  WR01.tx.cbor … WR12.tx.cbor      every submitted transaction, accepted or refused
  narration.log
```

## Actors on the devnet

| actor | role |
|---|---|
| Alice | controller of `alice`; retires it |
| Bob | destination of the first terminal token; the escrow's future reader |
| Carol | witnesses absence of `dave` and `erin`; refund address; retracts `erin` |
| Dave | controller of `dave`; books it from Carol's witness; tries to delete Carol's witness |
| the folder | permissionless; the runner itself |

## Names and keys

Keys are the naming spelling hashes as #157 fixes them; the asset name under
each token policy is the key.

# Public preprod read-only smoke, 7 October 2026

As a CLI user, I need a preview to name the evidence it used without submitting
a transaction. This run uses public Koios at
`https://preprod.koios.rest/api/v1`, schema `v1.4.2`, without a node socket,
signing key or bearer token. It does not complete #389's live acceptance.

## Observed results

The baseline is main `32bba1adc232fb3da5e84ea52e51ab95f670e8f1`.
Its packaged executable is recorded in `main-results.json`. The fix changes
only creation's public-address preview receipt: it adds the acquired scope's
`sessionReceipt` after reading wallet outputs and deriving the identity.
The fixed executable is recorded in `fixed-results.json`.

| Command | Result |
| --- | --- |
| Baseline inspect | Refused: `TrieState UndecodableRequest` |
| Baseline create preview | Success, but missing session evidence |
| Baseline insert preview | Refused: `TrieState UndecodableRequest` |
| Baseline update preview | Refused: `TrieState UndecodableRequest` |
| Baseline terminate preview | Refused: `TrieState UndecodableRequest` |
| Fixed create preview | Success in 1.341 seconds; Unbound session, one consumed AtAddress fact marked Unverified |

The refusal identifies transaction
`979bae00b3c0ae3e7003b335f2239b867a2fd35a07b203a860e9e4aae08ca0ad`,
with one action and zero decoded requests. It is not successful inspect or
preview evidence. The newer demo journal records a partial create, so it is
not substituted for a completed compatible registry with an active holding.

## Reproduce the repaired preview

Build the candidate with `cd offchain && nix build .#singular`.
Using a deployed blueprint and a funded public preprod address, run:

```sh
SINGULAR_LOG=create.phase.jsonl result/bin/singular registry create --preview \
  --registry /tmp/new-preview-target --wallet-address "$PUBLIC_ADDRESS" \
  --blueprint "$DEPLOYED_BLUEPRINT" \
  --koios-url https://preprod.koios.rest/api/v1 --network-magic 1 \
  --receipt create.receipt.json
jq -e '.sessionEvidence as $s
  | $s.binding == {kind:"Unbound"}
    and ($s.facts | length > 0)
    and ($s.facts | all(.session == $s.session and .binding == $s.binding
      and .verdict == "Unverified"))' create.receipt.json
```

The same predicate fails on the baseline receipt and passes on the repaired
receipt. The target directory remains absent. The saved source registry was
copied for the baseline run and remained byte-identical.

## Retained evidence and limits

[Evidence files](evidence/20261007/manifest.json) bind the receipt
and phase-log bytes by SHA-256. JSON receipts and line-delimited JSON phase
logs preserve the complete evidence.
`main-results.json` and `fixed-results.json` contain exact commands, wall times,
URLs, schema revision and exit statuses. Schema receipts retain retrieval time
and content hashes. The phase logs include each query duration and the insert
attempt's complete phase sequence; a refused insert has no successful build
phase to report.

The repaired create queried protocol parameters in 344.482 ms and wallet outputs
in 642.936 ms. Its `protocolMajorGuard` phase took 582.923 ms, an enclosing
measurement rather than an additional independent HTTP-call duration.

The scope receipt reports the creation preview's actual acquired scope; it does
not mix in earlier configuration scopes. These observations establish reporting
of provider evidence, not ledger verification, transaction submission, a fold,
or a successful lifecycle. Successful live inspect, insert, update and terminate
previews remain required before #389 can close.

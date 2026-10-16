# Tasks for submitting a bundle

## Slice: provider read and assembly

- [x] inclusion-read: the provider read for where a transaction sits on the chain, in the Koios provider, the synthetic ledgers and the devnet facade, with recorded fixtures.
- [x] assemble-signed: the signing export, the allowlist line and the export-freeze check.

## Slice: submission planner

- [x] witness-matching: pair witnesses with bodies by signature; different body and different key refused.
- [x] needed-keys-and-completeness: the needed key hashes per transaction still to send; missing and unneeded witnesses refused; witnesses for a transaction found on chain ignored.
- [x] expiry-and-skip: expired body refused with rebuild before any send; transactions found on chain skipped; order kept; uncertainty stops.

## Slice: submit verb

- [x] submit-verb: `singular submit` with witnesses, bundle, node settings and receipt file; no wallet option; documented flags equal `--help`.
- [x] chain-receipt: the receipt read from the chain after the run, the effect lines echoed as claims.
- [x] submit-documentation: the command reference, the recovery page and the narration clips.
- [x] devnet-submit-rows: the end-to-end rows over the real devnet capabilities and the offline packaged refusals.

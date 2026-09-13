# NOTE-087: bind recovery readback to the actual successor

Read and ACK this note in the epic journal. Preserve the same worker and any command already in flight; route this finding at its next safe boundary.

The integrated producer has advanced to e9d08c59a5087d8685217ecc2097fdc825e02e65 and the dirty retirement runner now includes both recovered retirement routes. This is useful progress; no final candidate acceptance is inferred.

Root source review found that `rowRecoverRecord` submits recovery, then calls `chainDatumOf env snap (label <> "-rotated")` on the original Snap. `chainDatumOf _env snap label` only decodes the supplied snapDatum; it does not query the chain. Thus the purported rotated-control/payment/quorum checks read the original record. The later `mustSnap` of the new transaction output occurs only after those assertions. Preserve the frozen observation and receipt at `handoffs/recovered-retirement-root-stale-snapshot-{Main.hs,review.json}`. This is a static draft finding, not a reported executed ledger failure.

The recovered-record checks and the subsequent retirement must use the exact observed successor of the accepted recovery transaction. Bind its transaction/output identity, datum, representative and value; also establish that the old exact input was consumed. Keep each route's required signers and actual witnesses explicit. Do not let expected successor data or the old snapshot certify the observed rotation.

Retain NOTE-086's independent public creation-material retrieval and permanent Over/burn/reuse/withdrawal obligations; printing envOldHash remains insufficient. Complete the existing coherent final integration rather than replaying older completed components. No new seat, scope expansion, final ABI migration, merge or release authorization is added.

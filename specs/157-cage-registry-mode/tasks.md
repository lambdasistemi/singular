# #157 — tasks

Checked by the ticket owner after the audited candidate is accepted, never by
the author. Order follows `plan.md`.

## Types and codec

- [ ] state-eight-fields-operation-read-request-destination — `State` eight fields; `Operation.Read`; `Request.destination`;
      `CageDatum.AbsentCustody`; blueprint regenerated; Haskell encodings follow
      (`blueprint-check` green).
- [ ] codec-helpers-in-lib-ak-decodestate-edgeof — codec helpers in `lib.ak` (`decodeState`, `edgeOf`,
      `deltaOf`, `approvalName`, `destinationMatches`) with their unit rows.

## The cage

- [ ] admissibility-seven-rows-accept-other-shape-refuses — admissibility: the seven rows accept, every other shape refuses
      with its own trace, before the proof (request-whose-value-bytes-not-x00-x01–refused-shape-folded-refused-its-own-trace).
- [ ] read-at-its-position-batches-reads — the read at its position; batches of only reads (insert-j-read-k-x02-insert-l, batch-reads-folded-accepted-root-unchanged).
- [ ] admission-by-bound-approval-reads-need-none — admission by bound approval; reads need none; pins preserved
      (A1–A4).
- [ ] delta-against-mint-per-key-three-policies — the delta against the mint, per key, all three policies
      (fold-insert-x01-k-mint-carries-two–any-fold-any-asset-moves-under-token).
- [ ] destinations-custody-custody-spending-path-r-ada — destinations and custody; the custody spending path; custody-lovelace-refund
      refunds with inserter ≠ booker (active-token-requested-destination–custody-spend-requires-consuming-fold).
- [ ] tip-coverage-in-cage-reads-retractable-v1 — tip coverage in the cage; reads retractable (V1, V2).
- [ ] consumer-ak-its-tests-pin-withdrawal-requirement — `consumer.ak`, its tests, the pin and the withdrawal
      requirement deleted in one commit.

## The token policies

- [ ] witness-kind-registry-three-instances-co-presence — `witness(kind, registry)`; three instances; co-presence with a
      `Modify`; terminal burn free; `representative.ak` retired (witness-kind-registry-for-kind-minted-or–fold-that-mints-under-token-policy-asset).

## Naming

- [ ] approve-arm-for-six-edges-per-r — `Approve` arm for the six edges per naming-approval-rules (N1–N5).
- [ ] fold-created-record-fold-cancel-claim-lifecycle — the fold-created record; `Fold`/`Cancel`/claim lifecycle
      removed (N7).
- [ ] retire-authorized-by-committed-recovery-key-or — `Retire` authorized by the committed recovery key or the
      quorum, never the current control key alone; co-mints the terminate
      approval and the completion request; completion folds
      `Update(0x01,0x02)` (N6, N8).
- [ ] destination-output-folded-booking-or-read-carries — the destination output of a folded booking or read carries at
      least the request's value minus the tip (request-deposit-returned).
- [ ] maintain-recover-rows-re-run-naming-ak — `Maintain`/`Recover` rows re-run; `naming.ak` loses its value
      vocabulary (N9, N10).
- [ ] just-test-just-script-identity-regen-in — `just test` and `just script-identity-regen` in both partitions;
      hashes in the handback.

## Consumers and docs

- [ ] conformance-re-baselined-contract-change-stated-old — conformance re-baselined; contract change stated with old and
      new fields side by side (X1).
- [ ] three-naming-updated-speech-restamped-just-check — the three naming docs updated; speech restamped;
      `just check-presentation` green (X2).
- [ ] trace-label-table-aiken-trace-lean-reason — the trace-label table `Aiken trace → Lean reason`, total.

## Gate-held, not a task

`nix develop --quiet -c just ci` exit 0 on the head and green GitHub CI on the
pushed head are the ticket gate's criteria. The PR targets #156's branch until
#156 merges, then `main`.

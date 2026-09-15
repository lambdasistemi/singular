# Singular M1 cross-boundary contract registry

Current 2026-09-14. One entry per seam; enforced names the check or is NONE.

## Registry producer ↔ cardano-keri consumer tuple
parties: singular-registry (producer), conformance runner / cardano-keri (consumer)
invariant: applied and unapplied script tuple, datum shapes and representative naming agree; the state carries the consumer pin
enforced: Conformance workflow on main (row receipts, CI) plus the downloaded-archive replay (v0.5.0: seven runners exit 0, candidateSource=release-commit)

## Authentic retirement completion
parties: naming application, registry state/request, representative policy, custody
invariant: only the exact representative under the configured policy completes retirement to Over; foreign-policy lookalikes refuse
enforced: focused Hook suite and generic rows CG* in CI since PR #90 (v0.4.0); #74 closed

## Nonempty processing and rejected requests
parties: registry fold, consumer
invariant: empty and surplus processing refuse; rejected-action refund floor holds
enforced: PARTIAL — refund-floor control and empty-batch refusal in CI (A-001); full two-layer correspondence is M1 assurance (#80)

## Authentic registry association
parties: registry, cardano-keri registration
invariant: the consumer targets its configured registry; copied or foreign registries are refused by name
enforced: PARTIAL — canonical authentication check in the conformance runner (#69); the three-variant substitution ledger run never executed; residual recorded, no ticket (operator: supply invariant covers resolution)

## Production-built invariant validation
parties: Lean model, compiled Aiken, Blaster
invariant: compiled validators satisfy the Lean obligations
enforced: NONE at M1 — moved to milestone M1 assurance (#87, #80, #92) by operator decision 2026-09-13; does not gate the product

## Obtainable release and onboarding
parties: release pipeline, new joiner
invariant: a fresh download verifies and replays the full journey with no checkout and no override
enforced: verify-published-release.sh + RELEASE-COMMIT in the archive (#91), v0.5.0 receipts; docs/consumer-onboarding.md (#78)

## Release tag ↔ pipeline
parties: release-please, release.yml publish job
invariant: merging the release PR produces the tag and the release with no manual step
enforced: NONE — tags pushed by hand for 0.4.0/0.5.0; chore unfiled, hand-tag rule in NOTE-005

## Preprod deployment manifest ↔ released artifact
parties: docs/preprod.json (deployment), released archive, preprod node
invariant: the manifest's script hashes equal the released blueprints and the node holds the reference scripts and the cage token
enforced: PENDING — `deployment verify` lands with #106; the close runs it from the downloaded archive

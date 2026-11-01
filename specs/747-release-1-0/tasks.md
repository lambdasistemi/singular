# Tasks for the 1.0 release from its installed artifacts

Issue 747. Grouped by pull request and slice of [the plan](plan.md#pull-requests-and-slices). A task is checked only after
the ticket owner accepts its slice.

## Binding

- [x] gate-synthesized: the ticket owner's and the auditor's gate tables joined once and frozen with both input hashes.

## Pull request 1: recognition

- [x] release-table-refilled: rows for the releases published since the table was filled, from their on-chain archives.
- [x] compatible-release-guidance: one answer for a known earlier contract, an unknown contract and an application upgrade, printed by every command.
- [x] old-registry-untouched: a write given such a registry sends nothing; the chain unchanged beside a passing control.

## Pull request 2: installed journey

- [x] bundle-journey: create, register, update, terminate, read and a discovered batch fold from the unpacked Linux bundle on a path with no Nix.
- [x] published-release-journey: the verifier runs the same journey from the downloaded bundle of its platform.

## Pull request 3: evidence and limits

- [x] decision-table: one table computed from the creation-cost and batch-limit receipts, with its altered-figure control.
- [x] batch-receipt-current: the batch receipt measured again against parameters recorded at release time, or its date kept and stated.
- [x] limits-stated: the four limits in the release notes and the documentation, and the check that fails when one is missing.

## Pull request 4: record and preparation

- [x] compatibility-record: the page computed from the release table, with its disagreement control.
- [x] release-preparation: the release notes for 1.0, the tag-run checklist for the epic owner.

## Pull request 5: refill after the tag

- [x] refill-after-tag: the row of the released version from its published archive, and the compatibility record regenerated from it.

## Fixes found while delivering

- [x] verified-release-clean-directories: the verified-release job starts from clean directories (pull request 798).
- [x] release-verifier-roots-builds: the release verifier keeps its archive builds alive until it finishes (pull request 808, which refers to issue 659).
- [x] macos-runner-image: the macOS jobs run on the macos-15 image (pull request 808, which closes issue 802).

## Close-out

- [x] residuals-mapped: every limit and gap mapped to a ticket or a non-goal before the ticket is handed back.

# What this release assumes and does not establish

As a reader deciding whether to rely on this release, you find here, in plain words, what the release takes for granted, what it leaves unproved, and where the evidence it does not yet have is listed.

## What the release takes for granted

The trie library's proofs are assumed sound.

The statements about the chain's history assume Cardano's rule for how scripts run, and that rule is not proved here.

## What the measurements do not show

The packaged development node cannot run the public test network's (preprod's) current protocol version, so the batch limits are evaluated under recorded protocol parameters and corroborated by the node, and are not submitted to that network.

The [release decision table](release-decision-table.md) gives each measurement with the date of the parameters it was taken under.

## What remains uncovered

The conformance rows that remain uncovered are published on the [conformance evidence page](conformance-evidence.md), whose count and rows are computed from the receipts.

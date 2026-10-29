# Tasks for folding a batch of registry requests

Issue 746. Grouped by pull request and slice of [the plan](plan.md#pull-requests-and-slices). A task is checked only after
the ticket owner accepts its slice.

## Binding

- [x] gate-synthesized: the ticket owner's and the auditor's gate tables joined once and frozen with both input hashes.

## Pull request 1: provider

- [x] policy-holdings-query: the policy query answered by the Koios provider, the devnet facade and the test providers, with rows and bytes and the contract rows.

## Pull request 2: discovery and fit

- [x] discover-pending: pending requests of one registry found from the approvals; skipped holders named; failure is unavailable.
- [x] fit-largest-batch: the order by the folder's take, the largest prefix that builds, the count left, the named-batch refusals.
- [x] fold-command-discovers: the fold command discovers, takes an optional limit, reports folded, skipped and left; help, parser rows, flags and recovery partition.

## Pull request 3: devnet

- [x] devnet-mixed-batch-journey: a wallet that booked none of the requests folds a discovered mixed batch; the change read from the chain.
- [x] devnet-batch-refusals: other registry, duplicate key and state-policy movement, each with its control.

## Pull request 4: measurement

- [x] batch-measurement: the receipt with the largest accepted batch for registrations, terminations and mixed batches.

## Pull request 5: evidence and words

- [x] conformance-and-documentation: the batch rows and the user page, limits generated from the receipt.

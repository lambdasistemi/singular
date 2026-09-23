# Retirement compared with the driver

The retirement story starts with an `insertActive` request, then submits
`updateTerminal` using the witness that registration delivered. It also
books an absent key and attempts to retire keys without the required active
state. The generic interpreter submits each request on a local Cardano devnet
and compares its result with the Lean driver. The receipt records each step,
including script-attributed refusals and their limits.

The retirement transaction declaration is
`Singular.Statements.update_terminal_transaction_row` at
`871c5df529d30357e4da7f6f9f141dc02c103bf6`. The model revision, chain
transactions, refusal evidence and exact run basis belong to the retained
receipts. The [book](../BOOK.md) renders the reader-facing chapter from those
receipts.

## Historical evidence

The [earlier structured run](retirement-run.json) records a narrower
per-theorem comparison on working-tree base `e512c7a`. Its successful
retirements and altered-observation controls remain useful provenance for
that former interpreter. They do not establish the current generic chapter.

## Limits

The receipt demonstrates only its listed steps and observed fields. A
script-attributed refusal identifies the rejecting script and the node's
reason; it does not establish that every malformed retirement reaches that
script. Other theorem consumers remain in the
[correspondence inventory](journey-correspondence.md).

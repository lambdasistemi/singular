# Responsibilities

M01: naming application authenticates pending claim cancellation, approval burn
and the committed refund; preserves existing fold and WithdrawApproval paths.
M02: naming offchain library owns the reusable production cancellation builder
consumed by the connected journey and the naming CLI. Exact placement and API
await coordination with #114's extraction.
M03: isolated devnet journey and CI observe CC01–CC06 through production builders
and real node queries. They distinguish ledger and builder refusals.

Data constraints are in data-model.md; API constraints in functions-model.md.

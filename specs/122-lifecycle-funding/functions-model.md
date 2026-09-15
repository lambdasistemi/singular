# Functions

Retroactive record, written 2026-09-15 from PR #122 merged at
`6ab1093367e00290a4b74638f03f5ef44b3137e6`.

New public functions in `offchain/lib/Singular/Registry/Lifecycle.hs`.
No bodies here.

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `lifecycleRequested` | `session`, `args` | `Bool` | True on a non-42 external node or with `--lifecycle`; devnet without the flag stays false. |
| `protocolFeeReserve` | `PParams`, `reference outputs` | lovelace | One maximum-size transaction plus the measured maximum over the actual reference scripts. |
| `minimumCoin` | `PParams`, `output` | lovelace | Ten percent above the live minimum, recomputed with the final coin width. |
| `fundedOutput` | `PParams`, `references`, `address`, `deposit` | output | Deposit plus fee allowance plus two minimum-coin margins. |
| `collateralOutput` | `PParams`, `references`, `address` | output | Live collateral percentage of the fee allowance, at least the live minimum. |
| `sizedOutput` | `lifecycle flag`, `PParams`, `output` | output | Resizes to the live minimum on the lifecycle path only. |
| `requestDeposit` | `PParams`, `config`, `token`, `address`, `spelling`, `operation`, `now` | lovelace | Actual locked ada for the request draft, not a fixture pool. |
| `verifyLifecycleBudget` | `lifecycle flag`, `PParams`, `transaction` | `IO ()` | No-op off the path; on the path the aggregate must fit the live limit before signing. |
| `fundingRequirement` | `PParams`, `outputs` | lovelace | Sum of output coins plus fee allowance plus minimum change. |
| `fundingProvider` | `reserved inputs`, `provider` | `provider` | Query results exclude reserved inputs, reference scripts and multi-asset outputs. |
| `fundLifecycle` | `provider`, `submitter`, `PParams`, `outputs` | funded references | Refuses with requirement versus spendable when short; submits, awaits and returns the confirmed outputs. |
| `checkExecutionLimit` | `live limit`, `per-purpose costs` | aggregate or refusal text | Sum must fit in both memory and steps; the refusal names both. |
| `prepareLifecycleTx` | `lifecycle flag`, `provider`, `PParams`, `references`, `witness count`, `transaction` | transaction | No-op off the path; on the path evaluates every redeemer with the node, replaces every declared budget, rebalances the fee from the final change output only, and converges within four rounds. |

## Node entry point (`offchain/lib/Singular/Registry/Node.hs`)

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `withNodeForPlannedFunding` | `session use` | result | Existing node-mode setup with no fixed funding floor; the lifecycle layer's own preflight decides. |

## Test surface (`offchain/test/Singular/Registry/LifecycleSpec.hs`)

Exact-boundary aggregate accept, two over-memory refusals, one
over-steps refusal, one refusal-text identity, and one
reserved-input exclusion case driving `fundingProvider` directly.

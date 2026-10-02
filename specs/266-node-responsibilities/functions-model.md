# Node callable contracts

As a caller, I want the same Node operations and diagnostics after their
definitions move.

```mermaid
flowchart LR
    Caller[Existing caller] --> Facade[Original Node API]
    Facade --> Owner[One focused implementation]
```

## Signature families

| ID | Existing callable family | Constraint |
| --- | --- | --- |
| node-mode-from-args | `nodeModeFromArgs`, `nodeModeFromEnvironment`, `runMode`, `nodeIsExternal`, `echoKoios` | Preserve argument, result, precedence and diagnostic contracts. |
| load-wallet | `loadWallet`, `walletForMode`, `funderAddr`, `funderSignKey`, `sessionMagic`, `bech32Address` | Preserve key bytes, address, network and logging behavior. |
| with-node | `withNode`, `withNodeForPlannedFunding`, `withNodeMode`, `withNodeSocket`, `devnetGenesis`, `awaitConnection`, `scriptStakeRegistered`, `currentTipSlot` | Preserve callback, resource, connection and cleanup behavior. |
| with-devnet-indexer | `withDevnetIndexer`, `followedProvider`, `adaptProvider`, `awaitIndexed`, `nodeAddressReads` | Preserve follower start, indexed versus node reads, genesis sweep and address-read guard. |
| await-tx | `awaitTx`, `awaitTxId`, `awaitTxWindow`, `awaitChain`, `confirmDeadline`, `txUpperBoundSlot`, `confirmationDelay` | Preserve confirmation observations, deadlines and named failures. |
| default-funding-floor | `defaultFundingFloor`, `checkFunding` | Preserve funding thresholds and error details. |

These are existing signatures and effects, not permission to add a new public
API. The complete before and after declaration map is a delivery receipt.

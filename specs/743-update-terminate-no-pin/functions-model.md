# Functions for updating a holding and terminating its key on the proved design

Issue 743. This page lists only new and changed signatures, with explicit argument names and types. Bodies are the
commit owner's. Types refer to [the data model](data-model.md) and to
[issue 742's data model](../742-create-register-no-pin/data-model.md).

## On-chain

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `termination_preimage` | `key: ByteArray`, `registry: RegistryIdentity` | `ByteArray` | the Plutus Data serialisation of the model's termination preimage |
| Singular fold, termination change | the existing `Terminate { request, key, proof }` change of the fold redeemer | accepted or refused | the change is decided by the same fold as a registration; no new validator parameter |
| Open-datum mint, termination booking | a new `ApplicationAction` constructor naming the holding input and the request output index | accepted or refused | the model's `bookTermination` |
| Open-datum spend, update | a new `SpendAction` constructor naming the successor output index | accepted or refused | the model's `liveUpdate` |
| Open-datum spend, termination booking | a new `SpendAction` constructor for the holding spent by a termination booking, naming the request output index | accepted or refused | agrees with the mint action of the same booking |
| Open-datum spend, termination fold | a new `SpendAction` constructor for the termination request | accepted or refused | the model's `terminationFold`; no signer |

## Off-chain

| Function | Arguments | Result | Effect |
| --- | --- | --- | --- |
| `terminationPreimage` | `key :: ByteString`, `registry :: RegistryIdentity` | `ByteString` | pure; equal to the on-chain encoder on every vector |
| `buildUpdate` | `session :: Session`, `holding :: TxIn`, `payload :: Datum` | a transaction | signed by the controller; reads the holding through the session |
| `buildBookTermination` | `session :: Session`, `holding :: TxIn` | a transaction | signed by the controller; donates the deposit to the treasury |
| the registration fold builder of issue 742 | gains termination requests among the pending requests it folds | a transaction | reads the state, the requests and the trie through the session, from chain data alone |

Where the aligned Lean models or issue 742's builders fix a different argument set, the mandate is versioned before the
slice that implements the function starts.

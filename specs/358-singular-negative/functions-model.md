# Host interfaces

As a coder, I want the new functions named with their arguments and results, so that the host and its judge are written against one contract and nothing is invented in the shared sources.

## Command surface

The host accepts `registry insert`, `update`, `terminate`, `withdraw`, `fold` and `inspect`, with the shared flag group unchanged: state directory, blueprint, state token, Koios URL, network magic, wallet key file, receipt file, funding limits. It adds three forms and no flag to any other command:

| Form | Meaning |
|---|---|
| `registry withdraw --key K` | spend the key's holding with the release redeemer outside any fold |
| `registry update … --tamper controller\|deposit\|token\|address\|datum` | an update whose continuation rewrites one protected field |
| `registry fold … --pay-short N` | fold the pending requests while paying the controller N lovelace less than owed |

`registry terminate` without `--fold` books the termination and stops at the pending request, as the ordinary command does. `create`, `reject` and `reclaim` are not host commands; the registry is created and a stranded booking reclaimed with the ordinary `singular`. `inspect` is the shared read, unchanged, since a read carries no bypass.

## New functions

Submission itself is the shared one: the host's handlers submit through the session module's `submitBuiltIn`, so the host adds no submit function of its own. It adds the record of the node's answer and the failed-script roles below, and its handlers return a receipt whose outcome is exactly one of accepted, refused (with the failed scripts), client refusal, encoding failure or setup failure.

| Function | Arguments | Result and constraints |
|---|---|---|
| `parseNegativeInvocation` | process environment, argument list | the shared parser's command for every ordinary spelling, or one of the three negative forms; refuses an unknown spelling exactly as the shared parser does; no file, node or key is touched |
| `runNegativeInsert` | session environment, entry arguments | books an insertion through the library builder and submits unevaluated; with `--fold` also folds; receipt JSON |
| `runNegativeUpdate` | session environment, entry arguments, optional tamper | builds the update for any signer, unevaluated; receipt JSON |
| `runNegativeTerminate` | session environment, entry arguments | books a termination for any signer; stops at the pending request unless `--fold` |
| `runNegativeWithdraw` | session environment, entry arguments | builds the release outside any fold; receipt JSON |
| `runNegativeFold` | session environment, fold arguments, optional short payment | folds the pending requests, paying the controller less than owed when asked; receipt JSON |
| `craftHoldingSpend` | attached registry, live holding, signer wallet, holding spend | the unsigned transaction for a controller update, stranger update, tampered update or release outside a fold; the holding spend is a closed set of those four shapes |
| `craftBooking` | attached registry, payer wallet, key, booking shape | the unsigned insertion or termination booking: honest, or by a stranger |
| `craftFold` | attached registry, folder wallet, pending requests, payment | the unsigned fold paying each controller exactly what is owed, or short by the named amount |
| `failedScripts` | registry, node answer | each failed script hash with its role in this registry (registry state validator, application spending contract, application at the fold), or no role when it is none of them |
| `readAround` | attached registry, key, wallet | the registry state output, the key's holding and the wallet's outputs, as one comparable record |
| `unchanged` | record before, record after | whether state root, holding output reference, value and datum, and wallet outputs are equal |

## Judge and arrangement contract

The judge is not a host function. It reads a pair's receipts only and, given the expected script role, answers per clause: refused by the expected script, refused by another script, client refusal, encoding failure, setup failure or accepted; and whether the reads before and after are equal. A typed result never enters a clause; a missing or altered receipt changes the verdict.

| Command | Contract |
|---|---|
| `negative-host-parts` | prints a nonempty JSON list of the pair parts delivered so far, read from the host's own table of pairs; starts no node |
| `negative-host-part PART` | for one discovered part: assembles the release archive, extracts it outside the checkout, builds the host and the node from the archive's own offchain flake, starts one fresh node, funds the wallets, runs the forbidden command and its control, judges every clause, and scans every receipt and output for the key bytes it generated; refuses an unknown part before starting a node |
| `negative-host-mutants` | for each mutant validator blueprint, runs the named pair and exits 0 only when its forbidden check reports failure and every other pair is unchanged |
| `negative-host-ordinary` | reads the built ordinary executables for host modules, with a positive control on the host, and checks the bypass spellings are refused as unknown |

## Constraints

No new function appears in the shared sources. The shared parser keeps its signatures. Exit codes follow the ordinary executable's classes and add one for a node refusal; a setup failure never exits as a refusal. A key is read from its file path and never printed, including in error text.

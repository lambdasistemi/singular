# Functions for registry writes that end in a bundle

Names, argument names and result types only. No bodies.

## Chained view module

- `chainedAnswer(staged, query, chainAnswer)`: the outputs the chain would answer to the query after the staged transactions landed, given the chain's own answer to the part of the query the staged transactions do not serve. Pure.
- `chainedHistory(staged, asset, tipHeight, range, chainBlocks)`: the asset's history blocks followed by one block per staged transaction that spends or creates an output holding it, numbered after `tipHeight` in build order, with the inclusive `range` applied over the whole answer. Pure.
- `chainedHistoryStream(staged, asset, tipHeight, range, chainStream)`: the same answer as a stream over the chain's range-limited stream; an upstream failure stays a failure.
- `chainedMintRecord(staged, asset, chainRecord)`: the mint record of the asset, from the staged transaction that mints it when there is one. Pure.
- `chainedSession(stagedNow, session)`: a session whose reads answer as if the staged transactions read by `stagedNow` at acquisition had landed; every read the staged list does not change goes to `session`.

## Write session module

- `withSession(env, dir, command, writeSettings, body)`: unchanged signature; the write settings carry the signer, and in the staged modes the run ends in the bundle.
- `bundleOfRun(command, networkMagic, stateToken, signerAddress, staged)`: the bundle of a staged run, transactions in build order. Pure.

## Receipt module

- `journalWaitingForSignatures(dir, bundleBytes, bundle)`: saves the bundle's bytes and every body, then appends one waiting line per transaction.
- `bundleMembers(entries)`: every identity a waiting line names, with its bundle's hash. Pure.
- `bundleStates(entries)`: each bundle hash with its state. Pure.

## Reconciliation module

- `reconcileBundles(command, dir, view)`: reads the inclusion of every unsettled member and the tip in `view`, appends landed and dead lines, and returns the bundle states.
- `refuseUnreconciled(reconciliation)`: unchanged signature; it also stops on a pending bundle with status 19.

## Submit command module

- `submitInMemory(env, settings, bundle, bundleBytes, witnesses)`: the receipt fields of submitting the bundle with those witnesses, or a named command failure; `submitBundle` reads the files and calls it.

## Sign command module

- `bundleWitnesses(bundle, signKey)`: the detached witness of every transaction of the checked bundle, or the refusal. Pure.

## Flag-group module

- `parseFlagGroup(missing, bad, unsafe, mkWrite, flags)`: unchanged arguments; `mkWrite` now receives the signer read from the flags in place of the key-file path.

## Managed-state module

- `resolveSignerDir(root, networkMagic, stateToken, signer)`: the partition for a key file, an address or a vault, by payment key hash.

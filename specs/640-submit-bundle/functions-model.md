# Functions for submitting a bundle

Names, argument names and result types only. No bodies.

## Provider module

- `inclusion(network, transactionIds)`: for each identity, found with chain point and confirmations, or not found; a named read failure otherwise.

## Signing module

- `assembleSigned(tx, witnesses)`: the signed transaction with the body bytes and identity of `tx` and exactly `witnesses`.

## Submit planner module

- `neededKeys(bundle, resolvedInputs)`: for each transaction, the key hashes needing a witness. Pure.
- `matchWitnesses(bundle, witnesses)`: each witness paired with the body it verifies against, or a named refusal. Pure.
- `planSubmission(bundle, witnesses, resolvedInputs, statuses, tipSlot)`: an ordered plan of sends and found transactions, or the first named refusal. Pure.

## Submit module

- `submitBundle(bundlePath, witnessPaths, receiptPath)`: reads, resolves, plans, sends in order, reads the chain again, writes the receipt; refuses with a named refusal.

## Command module

- `submitCommand(bundlePath, witnessPaths, nodeSettings, receiptPath)`: the parsed `submit` command; it accepts the node settings and refuses every wallet and vault option by name.

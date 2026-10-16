# Modules for submitting a bundle

Dependency direction runs from the command line down to the shared library. The write commands and their signing call sites are not touched.

## Changed responsibilities

- The provider module (shared local-services library) gains the read that answers where a transaction sits on the chain. Every implementation answers it: the Koios provider through its transaction status call, the synthetic ledgers and the devnet facade in tests.
- The signing module gains the export that assembles a signed transaction from a transaction and verified witnesses; the private constructor stays private.
- The submit planner module (shared local-services library, new) owns the decisions and is pure: from a bundle, the witnesses, the chain facts and the tip it returns either a named refusal or an ordered plan of transactions to send and transactions found.
- The submit module (native command-line library, new) reads the files, reads the chain, runs the planner, sends in order through the existing submission capability, reads the chain again and writes the receipt.
- The command module gains the `submit` verb with the node settings and no wallet option.

## Ownership

Files are read at the command boundary; the chain is read through the existing capabilities; sends use the existing bounded submission capability; nothing runs after the command; single-threaded. The command keeps no state.

## Not changed

Fold, fold rules, preparation, the write commands and their signing call sites, `--wallet-skey`, the vault, the bundle format.

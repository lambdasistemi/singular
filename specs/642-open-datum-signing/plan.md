# Plan for open-datum signing

Three pull requests. The first changes behaviour and is stacked on issue 641's branch; the second and third move pages and harnesses and keep behaviour. No on-chain code, script hash or Lean model changes: the model is silent on how a transaction is signed.

## Pull request 1: open-datum writes end in a bundle or sign from the vault

Branch `feat/642-open-datum-signing`, stacked on `feat/641-registry-bundles`. One writer, a persistent auditor, a gate of existing hosted commands. Each slice starts from the issue 641 checkpoint it needs.

### Slice 1: the command line names the signer

Base: issue 641's external-signer flags (head `5b18caea`). open-datum's parser stops refusing the address outside a preview on insert, update, terminate and fold when the bundle file is given, as the registry's fold, reject and reclaim do; the shared reader then refuses the mixtures. A preview, create's included, refuses the bundle file; inspect refuses it. Each of the four writes gets a usage line naming the external signer beside its key-file line. The settings table of the command reference extends the address and bundle-file rows to the four open-datum writes, with its speech and narration clip. A complete external line stops with the shared client refusal until staging lands.

### Slice 2: external mode

Base: issue 641's staging checkpoint (its slice 2b), and its create chain (its slice 3) for create. Mostly rows: insert, update, terminate and fold, alone and with the fold, each end in one bundle and status 19; refusals write no bundle; a pending bundle stops the next write. Code only where open-datum states a staged fact as done: its own receipt fields under expected and its own narration events marked staged, unless issue 641's mechanism already covers them. Create's rows and usage join when the registry's create stages.

### Slice 3: vault mode

Base: issue 641's vault checkpoint (its slice 5). Rows: the same commands with the vault land, one passphrase, no bundle file, receipts stated as fact once the whole bundle is found on chain. Usage and the settings table name the vault on the five writes.

## Pull request 2: Demo 1 on the devnet

Keeps behaviour. One writer, one review before the push. The Demo 1 journey and its run page move once, for both binaries (the registry's reject and reclaim steps included), to wallets from `singular wallet create` signed from the vault or externally; the closed-datum journey and the preprod walk-through follow. The devnet harness gains funding of a given address, so the pages need no devnet key. The sixteen numbered items of the run page keep their positions.

## Pull request 3: the guides; open-datum retires the key file

Keeps behaviour for every documented line. open-datum's usage drops the key-file flag; the command reference drops its row; the negative-host page, the integrator guide and the release archive's read-me move to the vault or the external signer. The documented-flags check stops finding the write commands by the key-file flag on their usage lines, unless an earlier change has done so.

## Neighbours and order

- Issue 641 slices 2b, 3 and 5 gate this pull request's slices 2 and 3. Issue 491's booking preparation lands before slice 2.
- Issue 672 retires the key-file flag from the registry commands and rebases on pull requests 2 and 3. Whichever change first drops the key-file flag from a binary's help updates the documented-flags check.
- keri-stub is not this ticket's.

## Gate and budget

Every gate row is a hosted workflow step's command, narrowed with the suite's filters, run inside a memory-capped, time-bounded scope; the aggregate local CI runs once on the final candidate. Slice 1 is bounded at 45 minutes of writer time, slices 2 and 3 at 90 minutes each.

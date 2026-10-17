# Modules for registry writes that end in a bundle

Dependency direction runs from the command line down to the shared library. The data model and the functions model name the values and signatures; this page names who owns what.

## New

- The chained view module (shared local-services library). Owns the answers a chain read gives after a list of staged transactions has landed, and the session that serves them over a real session. Pure answers; the session takes one snapshot of the staged list per acquisition, so one view stays consistent. It knows ledger transactions and provider reads, nothing of registries, journals or signers.
- The command-failure module (native command-line library). Owns the command-failure type with its reported mark, the two ways a command fails with fields, and the environment a command runs in. It sits below the write session, which re-exports it, so that the session can call the submit core and the reconciliation, both of which need it; its code moved unchanged from the write session.

## Changed

- The write session module (native command-line library). Owns the write mode of a run: the key-file path as today, or staging. In staging it decorates the run's reads with the chained view, stages each built body instead of signing and sending it, records each readback as the staged transaction's effect claims, and at the end of the run assembles the bundle, saves it, journals the waiting lines and then either writes the bundle file or signs from the vault and calls the submit core. The staged list is a resource of the run: one owner, the command's lifetime, single-threaded.
- The receipt module. Owns the new outcome and its status, the waiting, landed and dead lines, membership by identity, and the bundle state that admission and reporting share. Pure where it reads the journal.
- The saved-body module. Reads a waiting line's saved body as it reads a prepared one.
- The reconciliation module. Owns the partition by membership: the per-transaction recovery runs over non-members only; the bundle reconciliation reads the inclusion of unsettled members and the tip in one view, appends landed or dead lines, and admission refuses a pending bundle.
- The shared flag-group module. Its write-settings reader, the one both the singular and the open-datum parsers call, reads the signer: the key file, the address with the bundle file, or the vault with the passphrase descriptor; the three new flags join the common group, so the flag-group extent test keeps the two parsers equal. The open-datum and keri-stub commands therefore parse the new flags without documenting them until issue 642 does.
- The command module. Prints the signer modes in the four writes' usage; the vault flags stop being refused on them.
- The managed-state module. Resolves the partition from an address or a vault as from a key file.
- The attached-registry and create modules: only where the caller's key or address resolves the partition, the caller and admission.
- The submit command module (issue 640). Its core is separated from its file-reading front; behaviour unchanged.
- The sign command module. Exports the witnesses of an in-memory bundle as a pure function, used by `wallet sign` and the vault mode alike.
- The trace module. A staged transaction is traced as built and staged, never as signed, sent, confirmed or observed.

## Not changed

The builders and their validity bounds, the funding preparation, fold selection and rules, the bundle format, `wallet sign`'s behaviour, `submit`'s behaviour, the key-file path, the read-only commands, preview, the open-datum and keri-stub commands, the validators, the blueprint and the Lean model.

# Modules for signing a bundle

Dependency direction runs from the command line down to the shared library. Nothing here touches the write commands.

## Changed responsibilities

- The bundle module (shared local-services library, new) owns the bundle: its types, its JSON codec, the text envelopes of a transaction and of a witness, and the offline consistency check. It is pure: no files, no clock, no network, no age library.
- The signing module (shared local-services library) gains one helper that makes a detached witness for a body from a signing key. The opaque signed transaction and its private constructor are unchanged.
- The sign module (native command-line library, new) reads the bundle file, opens the vault through the existing vault and passphrase modules, runs the check, writes the witness files exclusively and prints the paths and the summary.
- The command module gains the `wallet sign` verb and its flag group; it accepts no provider option.

## Ownership

Witness files belong to the command that writes them for the length of that command. Passphrase and key live in memory for one command. No state is kept.

## Not changed

Fold, fold rules, preparation, session, lifecycle, the write commands, `--wallet-skey`, the vault format.

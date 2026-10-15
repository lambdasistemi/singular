# Modules for the wallet vault

Dependency direction runs from the command line down to the wallet module. The wallet module learns nothing about vaults.

## Changed responsibilities

- The wallet module (shared local-services library) gains two pure helpers: reading a signing key from the bytes of a key file, and building a wallet from a key and a network magic. `loadWallet` is rebuilt from them with unchanged behaviour.
- The vault module (native command-line library, new) owns the encrypted file: sealing a key, opening a vault, creating the file exclusively, and fresh key generation. It is the only module that links the age library.
- The passphrase module (native command-line library, new) owns reading a passphrase from a terminal or a descriptor.
- The command module gains the `wallet create` and `wallet address` verbs and their flag group. It composes the vault and passphrase modules at the command boundary; no other module reads a descriptor or the terminal.

## Ownership

- The vault file is owned by the command that creates it, for the length of that command; no state is kept after exit.
- Entropy and file creation are effects at the command boundary. Sealing and opening a vault are values computed from explicit inputs, except the random salt, drawn through the one effect the sealing function declares.

## Not changed

Write commands, the session, the lifecycle, `--wallet-skey`, fold and preparation modules.

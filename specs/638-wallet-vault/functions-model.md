# Functions for the wallet vault

Names, argument names and result types only. No bodies.

## Wallet module

- `parseSignKey(keyFileBytes)`: bytes of a key file to either an error text or a signing key. Same accepted spellings as `loadWallet` today.
- `walletFromSignKey(networkMagic, signKey)`: a wallet with the enterprise address of the key.

## Vault module

- `signKeyEnvelope(signKey)`: the text envelope bytes of a key. Pure.
- `sealVault(workFactor, passphrase, signKey)`: the vault bytes, or a refusal. Effect: draws the random salt.
- `openVault(passphrase, vaultBytes)`: the signing key, or the one opening refusal. Pure. Refuses a work factor above 18.
- `freshSignKey`: a signing key from 32 bytes of operating-system entropy. Effect: entropy.
- `createVaultFile(path, vaultBytes)`: creates the file exclusively with mode 0600 and writes the bytes; removes the file this call made if the write fails; refuses an existing path or symbolic link.
- `vaultWorkFactor`: the constant 18.

## Passphrase module

- `readPassphrase(confirmation, source)`: a passphrase or a refusal. `confirmation` asks twice on a terminal. A descriptor source reads one line and takes no confirmation.

## Command module

- `walletCreateCommand(vaultPath, networkMagic, passphraseSource)`: creates the vault, prints the address on one standard output line.
- `walletAddressCommand(vaultPath, networkMagic, passphraseSource)`: opens the vault, prints the address.

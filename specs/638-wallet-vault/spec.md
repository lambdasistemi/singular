# Create a wallet into an encrypted vault

Issue 638, first of five tickets under issue 490. This page records the story, the requirements and the refusals. The signing lane's later tickets (sign a bundle, submit, registry write commands, open-datum commands) are not part of it.

## Story

As Alice, I run `singular wallet create --vault alice.vault --network-magic 1`, type a passphrase twice, and see my address on one line. My key now exists only inside `alice.vault`, encrypted. I never installed `cardano-cli` and no plaintext key file was written. Later I run `singular wallet address --vault alice.vault --network-magic 1`, type the passphrase, and see the same address. A script gives the passphrase on an inherited file descriptor with `--passphrase-fd`.

## Requirements

- vault-holds-only-ciphertext: the vault file is an age file with a passphrase recipient; no key byte, hex spelling or key envelope appears in it in the clear.
- fresh-key-per-creation: every creation draws a new 32-byte key from the operating system's entropy.
- vault-never-overwritten: creating over an existing path, including a symbolic link, is refused and leaves that path's bytes unchanged.
- failed-creation-leaves-no-partial-file: when creation fails after the file was made, the file this run made is removed.
- vault-private-mode: the file is created readable by its owner only (mode 0600).
- address-from-key: the printed address is the enterprise address of the vault's key for the named network; it equals the address `loadWallet` derives from the same key, and a fixed test key yields a constant, independently derived address.
- address-stable-across-opens: `wallet address` prints exactly what `wallet create` printed for the same network.
- wrong-passphrase-refused: a wrong passphrase, a corrupt file and a file that is not a vault give one refusal that carries no secret and prints nothing on standard output.
- empty-passphrase-refused: creation and opening refuse an empty passphrase.
- vault-work-factor-bounded: creation uses scrypt work factor 18; opening refuses a vault whose work factor exceeds 18.
- passphrase-never-on-argv: no flag takes the passphrase itself; only a file descriptor number.
- no-secret-in-output: no output, error text or journal line carries the passphrase or any key byte.
- loadwallet-unchanged: `loadWallet` accepts the same files and derives the same address as before.
- no-forbidden-dependency: the command line links no `cardano-cli` and no node component, and the packaged control runs without `cardano-cli` on its path.

## Refusals

The command exits non-zero, prints nothing on standard output and names the cause on standard error: vault already exists; cannot open vault (wrong passphrase, corrupt, or not a singular vault); empty passphrase; passphrase descriptor unreadable.

## Observable success

Unit specs run in the hosted job that runs the focused off-chain suite. Packaged-binary controls run in the hosted job for documented command-line flags and refusal controls. The Lean model is silent on key custody, so there is no model binding.

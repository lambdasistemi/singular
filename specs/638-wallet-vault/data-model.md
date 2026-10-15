# Data for the wallet vault

## Vault file

A binary age file (header `age-encryption.org/v1`) with exactly one passphrase stanza. Plaintext: the key's text envelope, a JSON object with `type` `PaymentSigningKeyShelley_ed25519`, a `description`, and `cborHex` holding `5820` followed by the 32 key bytes in hex. Invariants: one key per vault; file mode 0600 at creation; work factor at most 18 on open.

## Passphrase

A non-empty byte string held only in memory for the length of one command. It has no textual rendering that shows its content.

## Refusal

Seven named refusals: the vault path exists; the file could not be created or written; the vault could not be opened; the passphrase is empty; the passphrase descriptor could not be read; the confirmation differs; the terminal is unavailable. Each carries the path or descriptor number it concerns and nothing secret.

## Command inputs

Vault path, network magic, and a passphrase source that is either the terminal or a descriptor number. The network magic selects mainnet at 764824073 and a test network otherwise, as the existing wallet loading does.

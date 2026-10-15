# Plan for the wallet vault

Issue 638. One pull request, two slices, each within 90 minutes of writing.

## Decisions

- Format: a binary age file with a passphrase (scrypt) recipient, work factor 18. Its content is the key's standard text envelope, the bytes `loadWallet` already reads. Any age tool opens it with the passphrase and yields an ordinary key envelope; `cwt` opens it too. The envelope holds no network, so the network comes from `--network-magic` at use.
- No public part is stored. `wallet address` decrypts. Later tickets identify external signers by address, which is public.
- Passphrase: a terminal prompt with echo off (asked twice on creation), or `--passphrase-fd N`. Never an argument, environment variable or file path.
- The age library comes from Hackage (already in the resolved plan through the cardano-tx-tools pin); entropy from `crypton`. The vault code lives in the native command-line library only; the shared local-services library gains two pure helpers and no age dependency.
- Lean position: Lean is silent. A fold's required signers are empty; key custody and the vault sit outside the model. No model binding, no correspondence row.

## Slices

- Vault core: pure key helpers in the wallet module, the vault and passphrase modules, and the unit specs.
- Command: the `wallet create` and `wallet address` verbs, documentation, the packaged-binary controls and their workflow step.

## Hosted evidence

- Unit specs: the existing required job that runs `cage-tests`.
- Packaged controls: a new step in the existing required job "Documented CLI flags and refusal controls". No new job context.
- Limit: the interactive terminal prompt is not executed in CI; it shares the passphrase parser with the descriptor path. The pull request body carries one manual transcript.

## Gate

Existing hosted commands, each as its workflow step runs it. In `offchain/`: `nix run .#cage-tests -- --match Vault`, `nix run .#lint`, `nix build .#component-build`. At the root: `nix run .#cli-flags-check`, `nix run .#cli-flags-controls`, `nix run .#wallet-vault-controls`. And `nix run ./offchain#registry-cli-build-graph-check`. The documentation check (`just ci`) runs once on the final candidate.

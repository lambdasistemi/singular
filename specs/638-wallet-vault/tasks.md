# Tasks for the wallet vault

## Slice: vault core

- [x] wallet-key-helpers: `parseSignKey` and `walletFromSignKey` in the wallet module; `loadWallet` rebuilt from them, existing specs unchanged.
- [x] vault-seal-and-open: seal and open with the age passphrase recipient; wrong passphrase, empty passphrase, corrupt file and work factor above 18 refused.
- [x] vault-created-exclusively: private mode, existing path and symbolic link refused unchanged, partial file removed on failure.
- [x] fresh-key-and-address: a new key per creation; the address equals the address `loadWallet` derives and the constant of a fixed test key.
- [x] passphrase-intake: terminal prompt with confirmation, descriptor line, empty refused.

## Slice: wallet command

- [ ] wallet-verbs: `singular wallet create` and `singular wallet address` with `--vault`, `--network-magic`, `--passphrase-fd`; documented flags equal `--help`.
- [ ] vault-documentation: command reference and a paragraph on the vault format so a user can open the file with an age tool alone.
- [ ] packaged-vault-controls: the real binary through a descriptor: create, address equal, second create refused with the file unchanged, wrong passphrase refused with empty standard output, no `cardano-cli` on the path; each control shown to fail against a planted defect.
- [ ] hosted-vault-controls: one step of the existing flags-and-refusals job runs the controls.

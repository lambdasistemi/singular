# Tasks for registry writes that end in a bundle

## Slice: chained view

- [x] chained-answers: the pure answers for every output query form, the asset history and the mint record; a property that they equal the synthetic chain's answers after the staged bodies are applied.
- [x] chained-session: the session decorator, one snapshot per acquisition, with its IO-ownership entry.

## Slice: staging and the external signer

- [x] write-mode: the signer in the write settings, the staged build, the effect claims and the bundle at the end of the run; nothing signed, journalled as prepared or sent while building.
- [x] external-signer-flags: the signer read by the shared flag group, the address and bundle-file flags on fold, reject and reclaim; the refusals; status 19; documented flags equal `--help`.
- [x] staged-receipt: the bundle summary and the command's fields under expected; the waiting lines and saved bytes.
- [x] staged-fold-reject-reclaim: per command, one bundle holding the preparation then the command's transaction, bodies equal to the key-file path's, accepted by the bundle checks and by `wallet sign`.

## Slice: create's chain

- [x] staged-create: create's whole chain in one bundle, its pending identity, its receipt; the same bodies as the key-file path.

## Slice: journal phase

- [ ] bundle-membership: membership by identity, the partition of the per-transaction recovery, legacy journals unchanged.
- [ ] bundle-state: landed, dead and pending from the journal; one state for admission and the report, with the property over member states.
- [ ] bundle-reconciliation: the inclusion and tip read, the landed and dead lines, expiry, the pending-bundle refusal with status 19, connected rows from the real producer.

## Slice: vault mode

- [ ] vault-signer-flags: the vault and passphrase-descriptor flags in the shared flag group, accepted on the four writes; the refusals; documented flags equal `--help`.
- [ ] submit-core: the submit core separated from its file-reading front, `submit` unchanged.
- [ ] vault-submission: the same bundle signed from the vault, sent through the core, journalled landed or dead, the receipt.

## Slice: devnet control and documentation

- [ ] packaged-bundle-control: on a fresh devnet, a create signed externally end to end and a fold signed from the vault, a pending bundle stopping a second write, an expired fold bundle reported dead; the harness tool that seals a devnet key into a vault; the hosted job on the required list.
- [ ] write-documentation: the command reference (signer modes, receipt, status 19, each command's window), the recovery page (the bundle phase and its three ways to die), their narration clips.

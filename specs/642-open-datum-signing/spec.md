# Open-datum commands and guides use the vault and external signing

Issue 642, fifth of five tickets under issue 490. This page records the story, the signer each open-datum write takes, the requirements, the refusals and the limits. The shared machinery (the signer in the shared flag group, the chained view, staging inside the shared submission routine, the journal phase of a bundle, the vault) is issue 641's; this ticket brings it to the open-datum commands and moves the guides off key files and `cardano-cli`.

## Story

As Alice, I insert an entry and fold it in one command with my vault: I name the vault file, type my passphrase once, and the command builds the whole run as one bundle (the preparation, the booking, the fold's preparation and the fold), signs it from the vault, sends it and prints a receipt read from the chain. As Bob, I update my entry naming only my address and a bundle file: nothing is signed or sent, the command exits with the outcome waiting-for-signatures, and I sign the bundle elsewhere and send it with `singular submit`. The guides show both ways, with wallets made by `singular wallet create`, and neither of us makes a key file with `cardano-cli`.

## Signer per command

The open-datum writes are create, insert, update, terminate and fold; insert and terminate also fold in the same command when asked. Each takes exactly one signer, read by the shared flag group:

- the external signer: the address and the new file the bundle is written to. insert, update, terminate and fold take it from this ticket's first slice; create takes it once the registry's create stages its chain (issue 641), because open-datum's create is the registry's.
- the vault: the vault file and, for scripts, the passphrase descriptor. All five writes take it once the registry's vault mode lands (issue 641).
- the key file, unchanged; issue 672 removes it from open-datum's usage together with the registry's.

inspect is read only: it takes the address to locate a journal, and refuses the bundle file and the vault.

## Requirements

- external-signer-accepted: insert, update, terminate and fold accept the address together with the bundle file outside a preview; until staging lands, such a run stops with the shared client refusal, and nothing is signed, sent or journalled and no bundle file is created.
- address-alone-names-its-partner: on those four writes, outside a preview, an address without a bundle file is refused naming the bundle file as required.
- preview-refuses-the-bundle: every preview, create's included, refuses the bundle file before anything is read.
- inspect-refuses-signers: inspect refuses the bundle file and the vault by name.
- create-follows-the-registry: open-datum's create accepts a signer exactly when the registry's create does.
- one-bundle-per-run: in the external mode, each write produces one bundle holding its whole chain in build order; insert or terminate with the fold holds the preparation, the booking, the fold's preparation and the fold; nothing else.
- bodies-equal-the-existing-builds: each bundle body is the transaction the key-file path builds when every earlier body has landed, validity bounds aside where the tip differs.
- external-mode-reads-no-key: the external mode opens no key file and no vault.
- refusals-write-no-bundle: every refusal before signing (a closed registry's update, a terminal entry, a missing key, an outlay over its ceiling, a pending bundle) leaves no bundle file and no journal line.
- pending-bundle-stops-the-next-write: a pending bundle stops the next open-datum write with the outcome waiting-for-signatures, status 19, through the shared admission.
- receipt-states-only-what-landed: open-datum's own receipt fields (the booking, the request, the fold deadline, the live output, the root) sit under expected until their bodies are found on chain by identity.
- narration-says-staged: the protocol events only open-datum emits (booked, updated, root seen) say a staged transaction is staged, never done, until it lands.
- vault-lands-the-same-bundle: with the vault, the same commands build the bundle the external mode writes for the vault's address, sign it with one passphrase, send it, and state the receipt as fact once the whole bundle is found on chain.
- usage-names-every-signer: each write's usage names the signers it accepts; documented flags equal what each command's help prints.
- guides-use-the-vault: the Demo 1 run page, the preprod walk-through, the integrator guide, the command reference and the negative-host page show the vault or the external signer, with wallets from `singular wallet create`, and no `cardano-cli` key generation; the sixteen numbered items of the Demo 1 run page keep their positions.
- key-file-retired-from-open-datum: moved to issue 672 (decision of 2026-10-17), which removes the key-file flag from open-datum's usage and its row from the settings table together with the registry's.
- existing-commands-unchanged: every command line accepted before behaves as before, and a refused one changes only its text where this page says so.
- committed-controls-bounded: every run command of a committed control is bounded in time and memory.

## Refusals

Before anything is read, a named refusal and nothing written: two signers together; an address without its bundle file outside a preview; a bundle file without an address; a bundle file or a vault on a preview or on inspect; an address that pays a script or is a bootstrap address; an existing bundle file, its bytes untouched; the passphrase descriptor without a vault. Before building: a pending bundle, status 19. Open-datum's own refusals (a closed registry's update, a terminal entry, the fold flag with a preview) come first, as today, and write no bundle.

## Limits recorded

- open-datum's own read-backs (an update's output carries the envelope it sent; the root did not move) run against the chained view in the new modes; the fact on chain is the body found by its identity. A registry moved by another writer between build and submit shows as a dead bundle, not as a stale state.
- A bundle submitted elsewhere and refused by the node dies by expiry in the writer's journal.
- The deadlines are the builders' own: an external insert with the fold expires at its fold's deadline, the request's processing deadline, ten minutes after booking at the default window.
- keri-stub parses the same signer flags through the shared group; its documentation and modes are not this ticket's.

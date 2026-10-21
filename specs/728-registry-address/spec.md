# Specification: a registry has an address in the style of a Cardano address

## The story

Alice creates a registry. The command shows her the registry's address, one word such as `singular_preprod1…`, together with the registry's asset id and its fingerprint, so she can also find the registry's token in a wallet or an explorer. She posts the address anywhere. Bob, on another machine, gives that address and a key to a command and reaches the key's state. If Bob mistypes the address, uses one made for another network, or runs a release of the programs whose on-chain contracts are not the ones that made the registry, he is refused in one sentence that says which, before anything is read from the chain; in the last case the sentence names the release that carries the right contracts and where to get it.

Today Bob must be told two separate settings that nothing ties together: the state token `POLICY.NAME` in hex and the network as a magic number. A wrong character reads as "not found", a token made on one network can be pointed at another, and a registry made by other contracts is refused without saying which release would read it.

## Two pull requests

| Merge order | Pull request | What the reader gets |
|---|---|---|
| first | the address | the address printed by `create`; `--registry` on every command that takes a state token; the address, asset id and fingerprint shown by `describe` and `inspect`; a command that makes the address of an existing registry; the table from contract hash to release, and the refusal that names the release |
| second | the key reached by its witness token | `inspect` with the address and a key finds the key's state from the key's own witness token |

The second is opened only after the first is merged. Its intake states in its pull request whether `inspect` already reaches a key this way or replays the registry's history. If it already does, that evidence goes into the first pull request and the second is not opened.

## Rules for both pull requests

- Nothing that works today changes. `--state-token` with `--network-magic` keeps working with the same output. New behaviour is a new option, a new command, a new receipt field, or a refusal that says more than it did.
- Off-chain only. No validator, no script hash and nothing in the formal model changes. If a change there seems needed, it is asked first.
- The address names a public token. It carries no secret and no key.

## The address

### What it holds

The registry is an NFT: its state token, of supply one, held at the state address, with the registry's state as its datum. The address is that NFT's asset identity and nothing else:

- the policy, 28 bytes: the hash of the state contract of the blueprint that made the registry, so it names the version of Singular's on-chain code;
- then the name, 32 bytes, derived from the registry's seed.

The body is these 60 bytes. Decoding an address gives back the state token `POLICY.NAME`, which any Cardano explorer shows as the NFT.

### Its spelling

bech32, with the original checksum and not the later variant, as Cardano addresses are, with the length limit lifted as Cardano does. It is printed in lower case. It is read in all lower case or all upper case, never a mixture. The encoder is the `bech32` package the build already depends on; nothing is written by hand.

### The networks

The prefix names the network.

| Network | Network magic | Prefix |
|---|---|---|
| mainnet | 764824073 | `singular` |
| preprod | 1 | `singular_preprod` |
| preview | 2 | `singular_preview` |
| the generated development network | 42 | `singular_devnet` |

Any other network magic has no prefix, and no generic prefix is made up. A command asked only for an address on such a network says so in one sentence and prints none. A command that does other work as well, such as `create`, does that work as it does today, prints no address, and says why on standard error.

### The asset id and the fingerprint

- The asset id of the registry is its state token, `POLICY.NAME` in hex, spelled as today.
- The fingerprint is the CIP-14 fingerprint of the NFT: blake2b with a 160-bit output over the policy followed by the name, in bech32 with the prefix `asset`. The hash is one the build already has. The unit tests check it against the vectors published in CIP-14.

### What the address does not say

What the NFT is for is answered by a blueprint. The application's blueprint derives the policies a registry of that application must pin (the application policy and the three witness policies, each applied to the registry's identity) and compares them with the NFT's datum on chain. The address says which NFT and on which network; which release of the contracts made it is answered by the table below.

## Reading an address

An address is read before anything else is done with it: before any chain read, any wallet, and any file other than the settings. Each refusal is one sentence that says which cause it is, with the exit status of a bad value:

| Order | Cause | What the sentence says |
|---|---|---|
| 1 | not a bech32 word, or upper and lower case mixed | the text is not an address |
| 2 | the checksum does not match | the checksum is wrong, so a character is mistyped |
| 3 | the prefix is not one of the four | the prefix is unknown, and the four are listed |
| 4 | the body is not 60 bytes | the body has the length it has, not 60 bytes |

The checks run in this order, so a prefix or a length is judged only on text whose checksum is right, and a word that fails an earlier check is never told a later cause.

`--registry` was once the name of `--state-dir` and is refused today as renamed, in the two places that read options. That refusal is removed, because the flag now takes an address. The first refusal of the table adds one clause saying that `--registry` once named the state directory and that it is `--state-dir` now.

## The registry given to a command

Every command of `singular`, `open-datum` and `keri-stub` that takes `--state-token` also takes `--registry ADDRESS`.

- It is a standing setting in the three forms of the earlier settings tickets: the flag `--registry`, the variable `SINGULAR_REGISTRY`, and the key `registry` of the settings file, with the settings layer's precedence: flag, then variable, then key.
- It gives both the state token and the network magic. A command given the address needs no `--state-token` and no `--network-magic`.
- With a `--state-token` that names another token, or a `--network-magic` that names another network, the command is refused in one sentence naming both values. With values that agree it is accepted. The comparison is between the final values, wherever each came from, so a stale `state-token` key of the settings file next to a new `registry` key is refused, and the sentence says what disagrees.
- A command given neither a registry nor a state token is refused as it is today.
- The network the address names is the command's network, exactly as `--network-magic` is today, for every later step. A provider that serves another network is not refused yet: no provider is asked which network it serves, and that check is issue 729 (https://github.com/lambdasistemi/singular/issues/729). Nothing of the provider layer changes here.
- The three programs read the registry through one shared function of the command library. None keeps its own copy.

## Contracts of another release

A program is given a blueprint, whose state contract has one hash. A registry whose policy is a different hash was made by other contracts, which this program cannot run against. That has always been refused (`state-token-foreign-release`), without saying which contracts they are. It is now refused by name.

### The table

Every release ships a table from the hash of Singular's state contract to the releases that carry it.

- It is one committed data file of the off-chain package. Each row holds a state-contract hash, 28 bytes in hex, and the tags of the releases whose blueprint has that state contract, oldest first. A hash appears in one row.
- It is packaged like the preprod network-time data, found by the programs the same way, from their own release, and shipped in every release bundle next to the blueprint.

### How it is filled

The rows of the released versions come from the published release assets, not from memory:

- for each release tag, the on-chain archive of the GitHub release (`singular-onchain-<version>.tar.gz`) is downloaded, and the blueprint `onchain/plutus.json` in it is read;
- the state-contract hash is computed from that blueprint by the same loading the programs use for `--blueprint`, and for the newest release it is checked against the policy of a registry that release made;
- the releases from 0.3.0 to 0.14.0 have an on-chain archive; 0.2.0 has none and is left out. A release whose blueprint the programs cannot load is left out too. The pull request and the table's own note name every release left out and why;
- the way the rows were filled is kept as a small script under `tools/`, marked as a tool, so anyone can fill them again and compare.

### How a program uses it

When the registry's policy, from the address or the state token, is not the state-contract hash of the blueprint the command was given, the command is refused before any chain read:

- if the table knows the hash, the sentence keeps the refusal's name, `state-token-foreign-release`, says that the registry was made by the contracts of the releases listed, and gives the URL of the newest of them, `https://github.com/lambdasistemi/singular/releases/tag/<tag>`, as where to get it;
- if the table does not know the hash, the sentence says the registry was made by contracts of no known release.
- if the table knows the hash but lists no release yet (contracts changed since the last release), the sentence says the registry was made by contracts not released yet.

### How continuous integration keeps it complete

A hosted check proves that the table holds the state-contract hash of the blueprint being built. A pull request that changes the contracts therefore cannot merge, and a release that changes them cannot ship, without a row for them. The check has a control that removes the row and sees it fail. A pull request that changes the contracts adds their row with no release yet; the release that first carries them adds its tag to that row when it is cut, and a release that keeps the contracts adds its tag to the existing row.

## What `create` prints

`create` of `singular` and of `open-datum`:

- Its receipt gains `registry`, the address (null on a network without a prefix), and `fingerprint`, wherever it already carries `stateToken`. `stateToken` is unchanged and is the asset id.
- On success one line on standard error gives the address, the asset id and the fingerprint.
- `--save-state-token` keeps working as it does.
- `describeCommand`, the next-step line of the receipt, is unchanged. Moving it to the address is a later change.

## A registry made before this change

`singular` gains the command `registry address`. It reads no chain and needs no provider.

- Given a registry, in any of the forms above, it prints one receipt: the address, the state token, the fingerprint and the network magic. Given a state token and a network magic it makes the address; given an address it shows what the address holds.
- Input that cannot be turned into an address, including a network magic without a prefix, is refused in one sentence with the exit status of a bad value.

## `describe` and `inspect`

`describe` and `inspect` of `singular`, and `inspect` of `open-datum`, include in their receipts the address, the state token and the fingerprint of the registry they read. The address is null on a network without a prefix.

## The key reached by its witness token

This is the second pull request. With the address and a key, `inspect --key` reaches the key's state by its witness token: the registry's active witness policy (or the terminal one), derived for this registry, with the key's bytes as the asset name, and the one output that holds that token. A key never registered is answered as today.

## Checks

- Unit: fixed addresses and fingerprints for the four networks; the CIP-14 published vectors; a round-trip property (decoding the address of any policy and name gives them back, any single changed character is refused, any other prefix or body length is refused with the right cause); every reading refusal in order; the agreement rules from each of the three forms; the table lookup for a known and an unknown hash.
- Through the packaged commands: every refusal above with nothing read from the chain; `create`, `describe`, `inspect` and `registry address` receipts.
- Hosted, on a private network, for the first pull request: a registry is created; the printed address is taken from the receipt alone; with no state token and no network magic anywhere, a key is booked, folded and inspected from a fresh state directory. Controls that could fail: an address of another network and an address with one character changed are each refused without a chain read.
- Hosted, for the table: the table holds the state-contract hash of the blueprint being built, with its control; and a program run from a release bundle finds its table, shown by the refusal that names a release.
- Hosted, for the second pull request: a key is reached by its witness token from the address and a fresh state directory.

## Documentation and the tutorial

A section of the node page says that the address is the registry's NFT, what it holds and why (the policy is the version of the on-chain code, the name comes from the seed), how a blueprint answers what the registry is for, the four prefixes, the table of releases and what the refusal that names a release means, and what the person does with the address. The settings tables gain the row for `--registry`. A note for the tutorial's owner lists the lines of the Demo 1 pages, at a named commit of the tutorial's repository, that carry the state token or the network, and what the address replaces. Nothing is pushed to that repository.

## Not in this ticket

Contracts found from the installed release (a default for `--blueprint`), public networks bringing their own connection, wallets by name, reclaim by key, a public registry page reached from the address, moving `describeCommand` to the address, and a provider refused when it serves another network than the address names (issue 729). They have their own tickets, with the same aim: a registry user is told only the address.

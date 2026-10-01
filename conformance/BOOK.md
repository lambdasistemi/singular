# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `b17037451ffc85219ae45f1495d821139194c0d1` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:7ce2f0ecec6d6310891f82a84c433f01eaa722f3ea346abd0e231827`.

Registration compared 7 requests: 4 accepted and 3 refused on chain.

Unsupported chain folds: 0.

The extra-signer registration was accepted on chain (transaction `a55ec11b581abf5f6cd9d881aef74d6028dba82595a3e199704f6fb39ce848a2`); the comparison detected the difference at `tx.signers`.

The insertActive was refused on chain (transaction `15a2a2aa90358f8068bf37f1587782875892f9f8973f5eae9a839c745f1e2820`); the model refused it for `key-exists`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `key-exists`.

The other-address insertActive was refused on chain (transaction `0440b93147649c08e317e2abcdff9480ade38b004db6374e3aa565bd502691eb`); the model refused it for `destination`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `destination`.

The short-by-one insertActive was refused on chain (transaction `331a52d7db1a49edad3e13e7c378ca3fcca98c686689341a52c61227d72b9f07`); the model refused it for `deposit-returned`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `deposit-returned`.

Code revision: `b17037451ffc85219ae45f1495d821139194c0d1` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:7ce2f0ecec6d6310891f82a84c433f01eaa722f3ea346abd0e231827`.

Occupied-key insertion compared 3 requests: 2 accepted and 1 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `93da10f383b6537b57382a1ba4b6867ac0f3e0fda9b8639c5d62cfa486fa8fae`); the model refused it for `key-exists`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `key-exists`.

Code revision: `b17037451ffc85219ae45f1495d821139194c0d1` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:7ce2f0ecec6d6310891f82a84c433f01eaa722f3ea346abd0e231827`.

Retirement compared 11 requests: 7 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The updateTerminal was refused on chain (transaction `53d30bd27599e24655b5b442ed23441d4232477556ddcfc921f953648e479df4`); the model refused it for `not-booked`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `not-booked`.

The updateTerminal was refused on chain (transaction `3bb2d269929a9b4a3a63259a475fa5b9ae028f7b7810887c517a2c69a302db66`); the model refused it for `key-unknown`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `key-unknown`.

The short-by-one deleteActive was refused on chain (transaction `5de7d06502ea2fb6a458808896e00544107e15af78303645667ecef60d093a6f`); the model refused it for `deposit-returned`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `deposit-returned`.

The other-address deleteActive was refused on chain (transaction `625b722327781fd16b209f4e72bb282be4e898a88064220c8fdb547531ecd248`); the model refused it for `deposit-returned`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `deposit-returned`.

Code revision: `b17037451ffc85219ae45f1495d821139194c0d1` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:7ce2f0ecec6d6310891f82a84c433f01eaa722f3ea346abd0e231827`.

Rejection and retraction compared 10 requests: 2 accepted and 8 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `f11761988b923bf35a7ba549cd76f9fb53b0bdfba23d8c89854915f63c26ab5c`); the model refused it for `deposit-returned`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `a3f6587ec48b611521c5fdc4f63b27df786666d18a36f135b3111711b63836eb`); the model refused it for `deposit-returned`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `deposit-returned`.

The short-by-one retract of insertActive was refused on chain (transaction `fba69094d86ac36497feb84e55a863409ea12584a8ae94c11fa6dadea3d36487`); the model refused it for `deposit-returned`. The traced replay of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b` (traced build `8e7782e1bb116900de43f5ddf893eb0e3a7627882990b1a149cb803a`) failed with `deposit-returned`.

The other-address retract of insertActive was refused on chain (transaction `c475074a8691db81561bb64155c896a941864d1f9c38ba7ecb1ddfcc0bf0c6ce`); the model refused it for `deposit-returned`. The traced replay of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b` (traced build `8e7782e1bb116900de43f5ddf893eb0e3a7627882990b1a149cb803a`) failed with `deposit-returned`.

The other-reference retract of insertActive was refused on chain (transaction `58f9d98bfd376d7f6b8e55c4bd4ae0496bac691fede97473c8e7b5256470c92e`); the model refused it for `deposit-returned`. The traced replay of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b` (traced build `8e7782e1bb116900de43f5ddf893eb0e3a7627882990b1a149cb803a`) failed with `deposit-returned`.

The state-spent retract of insertActive was refused on chain (transaction `36eb409aaa66bf8504f8b5a8d778b905d5e56112422f76eb28bc5d6106a20210`); the model refused it for `retract-state-spent`. The traced replay of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b` (traced build `8e7782e1bb116900de43f5ddf893eb0e3a7627882990b1a149cb803a`) failed with `retract-state-spent`. The traced replay of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428` (traced build `b82e3473ad2269ff90ed423626273bcd34d06aac7afa6fdc1bc1eec5`) failed with `missing-action`.

The retract of updateTerminal was refused on chain (transaction `3f19d9cd0e80c77bbfdc4df023e5441577739b498f2951093d41fdba937938ac`); the model refused it for `withdraw-insert-only`. The traced replay of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b` (traced build `8e7782e1bb116900de43f5ddf893eb0e3a7627882990b1a149cb803a`) failed with `withdraw-insert-only`.

The unsigned retract of insertActive was refused on chain (transaction `99a431c3fc7374f691f6c6991cd148d039db14412c58bc1300bbaa15bcdaa48d`); the model refused it for `retract-owner`. The traced replay of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b` (traced build `8e7782e1bb116900de43f5ddf893eb0e3a7627882990b1a149cb803a`) failed with `retract-owner`.

The exit chapter compared both admission refusals: the unsigned insertion retraction (transaction `99a431c3fc7374f691f6c6991cd148d039db14412c58bc1300bbaa15bcdaa48d`) was refused by the model for `retract-owner`, and the pending update retraction (transaction `3f19d9cd0e80c77bbfdc4df023e5441577739b498f2951093d41fdba937938ac`) for `withdraw-insert-only`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `60c782ed8098434dde0e8539c716df434aee79d1460758e0ed4a58d93dcd3537`.

Code revision: `b17037451ffc85219ae45f1495d821139194c0d1` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:7ce2f0ecec6d6310891f82a84c433f01eaa722f3ea346abd0e231827`.

Retraction window compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The before-phase-2 retract of insertActive was refused on chain (transaction `074c2383d3c8591ea5ddb6a2ba1c2b9c574e0c2b41c6be9d1beab083c3be4faa`); the model refused it for `not-phase2`. The traced replay of the deployed script `ea30ac572fc2fb9a8936cc3430c8c133e820d8e724edb517d6c8ac1a` (traced build `0a8af7a99fd1fb82322bfe1fb7ebf5487a910a09aba959d21631cfbe`) failed with `not-phase2`.

The after-phase-2 retract of insertActive was refused on chain (transaction `38803487497c7aeef6453f4dbf80181ce5bfeb53576cac62d7cb9d1f0356576b`); the model refused it for `not-phase2`. The traced replay of the deployed script `ea30ac572fc2fb9a8936cc3430c8c133e820d8e724edb517d6c8ac1a` (traced build `0a8af7a99fd1fb82322bfe1fb7ebf5487a910a09aba959d21631cfbe`) failed with `not-phase2`.

The window chapter compared both finite timing refusals: transaction `074c2383d3c8591ea5ddb6a2ba1c2b9c574e0c2b41c6be9d1beab083c3be4faa` before phase 2 and transaction `38803487497c7aeef6453f4dbf80181ce5bfeb53576cac62d7cb9d1f0356576b` after phase 2. The model refused both for `not-phase2`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `bc220005b7bddb7475a2211c841ee408b2134a5e6d17072dc995cd8c4c61d68a`.

Code revision: `b17037451ffc85219ae45f1495d821139194c0d1` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428 request:7ce2f0ecec6d6310891f82a84c433f01eaa722f3ea346abd0e231827`.

Unnamed sequence compared 8 requests: 8 accepted and 0 refused on chain.

Unsupported chain folds: 0.

## Register a key and receive its active token

A requester submits two distinct active registrations and then repeats one key. The delivery is then sent to another address, and paid one lovelace short, beside the same untampered request. Every step is compared with the executable registry model.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `83dd1fefbe6b00be6adcb57d84b4321b9507649b6566c79eecd9f6015551ecb4`.

### Registration delivers one active token to the requested recipient

- Submit **insertActive** for **alice** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

- Submit **insertActive** for **bob** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **bob**.

- Compare **bob** and its observation with the executable registry model.

- Submit **insertActive** for **alice** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

- Submit **insertActive** for **redirect** in **registration** with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

- Submit **insertActive** for **redirect** in **registration** with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

- Submit **insertActive** for **redirect** in **registration**, using the recipient wallet.

- Observe the complete registry, token, leaf and transaction boundary after **redirect**.

- Compare **redirect** and its observation with the executable registry model.

- Submit **insertActive** for **cosigned** in **registration** with one required signer the model does not require. The ledger accepts it; the comparison must report the difference in the transaction's signers.

- Observe the complete registry, token, leaf and transaction boundary after **cosigned**.

- Compare **cosigned** and its observation with the executable registry model.

## Insert on a key the registry already holds

In a registry of its own, a key is booked by an insertion and made active by an update, each accepted and compared with the executable registry model. The same insertion on that key must then be refused by the ledger and by the model.

- Submit **insertAbsent** for **occupied** in **occupied insert**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **occupied**.

- Compare **occupied** and its observation with the executable registry model.

- Submit **updateActive** for **occupied** in **occupied insert**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **occupied**.

- Compare **occupied** and its observation with the executable registry model.

- Submit **insertAbsent** for **occupied** in **occupied insert**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **occupied**.

- Compare **occupied** and its observation with the executable registry model.

## Retire a registration and burn its active token

The holder first registers a key in this run. Retirement must consume and burn that very token and change the key to Terminal. A never-registered key and a key recorded as Absent must be refused, each beside a successful retirement in the same registry. A deletion then owes its owner the deposit back: paid one lovelace short, and paid to another address, it must be refused beside the untampered deletion.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `83dd1fefbe6b00be6adcb57d84b4321b9507649b6566c79eecd9f6015551ecb4`.

### The holder receives the token that will be retired

- Submit **insertActive** for **alice** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

Formal specification: `Singular.Statements.update_terminal_transaction_row` @ `88957e41876911a993c5d9a338f8ab006c9f6843`. Statement digest: `8ea765f55d3a5187b8a9abc3430b3125406c5ce6c09407322443cc268dcd1079`.

### Retirement burns the holder's token and leaves the key Terminal

- Submit **updateTerminal** for **alice** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

- Submit **insertAbsent** for **never-active** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **never-active**.

- Compare **never-active** and its observation with the executable registry model.

- Submit **updateTerminal** for **never-active** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **never-active**.

- Compare **never-active** and its observation with the executable registry model.

- Submit **insertActive** for **control** in **comparison**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **control**.

- Compare **control** and its observation with the executable registry model.

- Submit **updateTerminal** for **control** in **comparison**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **control**.

- Compare **control** and its observation with the executable registry model.

- Submit **updateTerminal** for **never-registered** in **comparison**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **never-registered**.

- Compare **never-registered** and its observation with the executable registry model.

- Submit **insertActive** for **deleted** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **deleteActive** for **deleted** in **retirement** with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **deleteActive** for **deleted** in **retirement** with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **deleteActive** for **deleted** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

## A request that is never folded

A request can leave the queue without a fold. Once it may no longer be folded, a folder rejects it and must refund its owner the deposit, keeping the tip; while it is still retractable, its owner retracts it and must get back everything it held, deposit and tip, through an output whose inline datum is the retracted request's own output reference. Each refund paid one lovelace short or to another address, a return bound to another request, and a retraction spending the registry's state beside it must be refused, each beside the untampered exit of the same request.

- Reject the **insertActive** for **rejected** in **rejection** once it may no longer be folded with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Reject the **insertActive** for **rejected** in **rejection** once it may no longer be folded with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Reject the **insertActive** for **rejected** in **rejection** once it may no longer be folded, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner with its return bound to another request's output reference. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner spending the registry's state beside it. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **updateTerminal** for **pending-update** in **retraction** as its owner, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **pending-update**.

- Compare **pending-update** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner without requiring its owner's signature; the ledger and the model must refuse it, with the owner-signed retraction of that request as its control.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

- Retract the **insertActive** for **retracted** in **retraction** as its owner, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **retracted**.

- Compare **retracted** and its observation with the executable registry model.

## Retract only inside phase 2

Two insertion requests from the same owner are booked in one registry before either exits. The first is retracted before phase 2, then inside it; the second is retracted after its window closes. Both outside-window retractions must be refused, and the in-window retraction must be accepted. The second request shares the first's accepting control: once its own window is over it cannot have an in-window retry. The registry allows thirty seconds for processing and thirty more for retraction; waits follow each request's recorded submission time.

- Retract the **insertActive** for **window-first** in **retraction window** as its owner with a finite validity interval before phase 2; the ledger and the model must refuse it, with the same request retracted inside phase 2 as its control.

- Observe the complete registry, token, leaf and transaction boundary after **window-first**.

- Compare **window-first** and its observation with the executable registry model.

- Retract the **insertActive** for **window-first** in **retraction window** as its owner, using the owner wallet.

- Observe the complete registry, token, leaf and transaction boundary after **window-first**.

- Compare **window-first** and its observation with the executable registry model.

- Retract the **insertActive** for **window-second** in **retraction window** as its owner with a finite validity interval after phase 2; the ledger and the model must refuse it, with the earlier in-window retraction of its owner's other request as its control.

- Observe the complete registry, token, leaf and transaction boundary after **window-second**.

- Compare **window-second** and its observation with the executable registry model.

## A sequence no chapter names

This program uses the same live interpreter for each listed request. Each step records its own model and chain outcome; any unsupported result carries the reason observed at the booking or fold boundary.

- Submit **insertAbsent** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **updateActive** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **updateTerminal** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **insertActive** for **sequence-direct** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-direct**.

- Compare **sequence-direct** and its observation with the executable registry model.

- Submit **insertAbsent** for **sequence-absent** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-absent**.

- Compare **sequence-absent** and its observation with the executable registry model.

- Submit **deleteAbsent** for **sequence-absent** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-absent**.

- Compare **sequence-absent** and its observation with the executable registry model.

- Submit **witnessTerminal** for **sequence-active** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-active**.

- Compare **sequence-active** and its observation with the executable registry model.

- Submit **deleteActive** for **sequence-direct** in **sequence**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **sequence-direct**.

- Compare **sequence-direct** and its observation with the executable registry model.

## What these runs do not establish

Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none for a fold and the owner for a retraction, and the comparison reads them from the submitted transaction. The two-request batch allocation has no driver comparison: the driver evaluates one request per transaction, leaving Singular.Statements.fold_batch_claimed_mint_by_kind_key without this executable consumer. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The Absent retirement probe reaches the state script only after omitting an unfunded burn: the builder cannot fund burning a token that does not exist. Its refusal does not establish how a transaction with that burn would behave. The model admits a retraction only when the pending request inserts a key or reads a terminal one, its owner is among the transaction's required signers, and its validity interval lies inside phase 2. The interval starts no earlier than submission plus the processing time; its excluded upper bound may reach, but not pass, the end of the retraction time that follows. The model represents only finite validity bounds. Open validity intervals remain a named gap: the Aiken tests establish their not-phase2 refusal, but no live model comparison can represent them. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.

Refusal reasons come from traced re-evaluation. The deployed validators are compiled without traces, so the ledger names the script that refused but not why. Each refused transaction is evaluated again on the arguments the ledger built for it: once with the deployed bytes, and once with a build of the same source, compiler and parameters that keeps only the validators' own traces. A reason is admitted only when both evaluations fail and the traced one leaves exactly one trace; otherwise the receipt names the cause no reason was admitted. The receipt names both script hashes, and each refused request above prints what its replay recorded. Of the 18 refused requests in this run's chapters, 18 carry a reason their traced replay admitted, 0 name the cause their replay admits none, and 0 record no traced replay.

Refusals outside these chapters, by row. CS04, a redeemer at a wrong constructor index: live refusal reason not observed for the state and request scripts, whose failing path carries no user-defined trace; not compared, the behavior lies below the model's vocabulary (class C). CG09, a reject while the request is still in phase 1: the model admits it and the chain refuses it (class D); the validator's repair is pending (#320) and the consumer's requirement R9 is unmet. CG10, a fold against a superseded root: not compared, a stale proof is not an input of the model, and the validator's name for the refusal is imprecise (class C). CG11, an empty fold: the model refuses it for `empty-fold` as the consumer requires, but the driver has no batch question, so it is not compared (class D). CG12, surplus actions and a missing action: not compared, actions are not an input of the model, so it has no counterpart (class D). CG19, a crossed refund allocation and a two-request reject: not compared, the driver has no batch question (class D). The consumer correspondence of CG11, CG12 and CG19 (Q-002) remains unresolved; the three rows stay held. The two-key batch whose claimed mint disagrees per key: not run; live refusal reason not observed and not compared.

## Requirements inventory

The descriptions and planned statuses below are preserved from the committed inventory. The transaction evidence above belongs to this particular run; it does not rewrite planned statuses or discharge unrelated requirements.

### The canonical registry token name is SHA-256 of the canonical seed's outRef; a consumer recomputes it from the published seed and matches the on-chain state UTxO.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri: canonical seed-derived registry identity.

### A rival registry initialized from a second seed exists and is accepted by the ledger; canonical authentication rejects it on name.

Expected: rival accepted on chain; authentication rejects. Planned evidence status: uncovered.

Source: cardano-keri: canonical registry authentication distinguishes a rival seeded registry; issue #16.

### Negative control: an authenticator that checks only policy+address, not the derived name, accepts the rival.

Expected: control must fail. Planned evidence status: uncovered.

Source: Rival-registry authentication discrimination control (CA02).

### Applied and unapplied validator identity layers stay distinct and derived: applied address = apply(pinned unapplied hash, declared parameters); parameter count published.

Expected: accept. Planned evidence status: uncovered.

Source: blueprint identity discipline (onchain #34 pattern).

### A forged output at the canonical address carrying no registry token is not a registry: creating an output does not execute the receiving script.

Expected: authentication rejects; no script ran. Planned evidence status: uncovered.

Source: ledger output semantics.

### Generic Insert: request, fold, leaf present, root advances, read back from chain.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cardano-keri: registered-key consistency and registry leaves changing only through a fold.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: boots state and applies a request update

### Generic Update (OpUpdate old new) on an existing key folds; the root advances and the new value reads back from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec registry transitions.

### Generic Delete (OpDelete old) on an existing key folds; the key returns to absence, proved by a read from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec; issue #18 Delete preservation.

### After deleting a key, re-Insert the same key (reincarnation).

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec: Delete MUST permit a later Insert.

### Insert on a key that is already present.

Expected: refuse, attributed to the script that refused. Planned evidence status: uncovered.

Source: protocol spec: the fold MUST NOT accept Insert for an occupied key.

### Retract in phase 2 returns bond+tip, registry untouched.

Expected: accept; root unchanged. Planned evidence status: bound elsewhere.

Source: cardano-keri: retraction timing, unchanged registry state and the returned request value.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: retracts a phase-2 request

### Retract outside phase 2.

Expected: refuse the owner-signed retraction before phase 2 and after phase 2, with model reason not-phase2 and request-script attribution, beside the accepted owner-signed retraction inside phase 2. Planned evidence status: uncovered.

Source: Singular.Statements.retract_admitted_iff and Singular.Statements.retract_refusal_first_failing; cardano-keri retraction timing.

### Rejected when rejectable.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cardano-keri R9_reject_enabled.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: rejects a phase-3 request

### Rejected when not rejectable.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R9_reject_needs_rejectable.

### Stale fold against a superseded root.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R7_stale_fold_refused.

### Empty fold (Modify []).

Expected: observe and report. Planned evidence status: uncovered.

Source: cardano-keri R8_empty_fold_refused.

### Surplus actions beyond the matched request inputs.

Expected: observe and report. Planned evidence status: uncovered.

Source: cardano-keri audit 2026-09-03.

### Owner/hook pinning: a Modify that changes the state owner.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-pin transfer asserted authority that does not exist). Planned evidence status: bound elsewhere.

Source: cardano-keri R5_plugin_pinned.

### stake_script hook set: a fold carrying the matching withdrawal.

Expected: could-not-execute — superseded imported-partition material. Planned evidence status: uncovered.

Source: imported partition shared.ak, types.ak.

### stake_script hook set, withdrawal absent.

Expected: could-not-execute — superseded imported-partition material. Planned evidence status: uncovered.

Source: imported partition shared.ak, types.ak.

### Sweep of a non-legitimate UTxO, owner-signed.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-signed sweep asserted authority that does not exist). Planned evidence status: bound elsewhere.

Source: cage custody.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: sweeps malformed request-address UTxOs

### Sweep by a non-owner.

Expected: SUPERSEDED by operator ruling (registry has no owner role): observation preserved, claim withdrawn. Planned evidence status: uncovered.

Source: cage custody.

### End burns the state token and closes the cage.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cage custody.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: ends a cage by burning the state token

### Refund routing follows the request: processed value routes to the request's destination minus the folder's tip; refunds go to the refund address recorded in custody; a crossed allocation is refused by the state script (interface, registry mode: no hook). Rejected produces refund owners at the recorded floor.

Expected: observe and report — refused, with the consumer-model conflict unresolved (crossed allocation enforced by the state script); rejected-action refund-floor control separate. Planned evidence status: uncovered.

Source: cardano-keri R11_contribute_value, R11_retract_value; interface gist 2fb03c2e (registry mode).

### Every ToData/FromData instance in Singular.Registry.Types round-trips, and its constructor index and field order match the compiled blueprint's declared schema, not merely itself.

Expected: accept, byte-exact against the blueprint. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

### Datum bytes constructed in Haskell and submitted are read back from the chain identical.

Expected: accept, byte-compare submitted vs chain-observed. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

### Each UpdateRedeemer constructor (End 0, Contribute 1, Modify 2, Retract 3, Sweep 4) is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator.

Expected: partial: accept (Contribute 1, Modify 2, Retract 3 with executing witnesses); End 0 and Sweep 4 unexercised named residuals (no accepting path yet, issue #18 tracks completion). Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

### A redeemer at a wrong constructor index is refused by the compiled validator.

Expected: refuse, attributed to the script. Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

### Each RequestAction (Update 0, Rejected 1) and MintRedeemer (Minting 0, Burning 2) constructor is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator; Migrating 1 unconditional refusal recorded with wire constructor retained.

Expected: partial: accept (Update 0, Rejected 1, Minting 0 with executing witnesses); Burning 2 unexercised named residual; Migrating 1 explicit gap. Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

### Script parameter application: parameter count and encoding published, applied hash derived in Haskell equals the on-chain address for every parameterized script.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 parameter binding.

### Each ProofStep variant (Branch 0, Fork 1, Leaf 2) and Neighbor exercised by a fold the validator accepted.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 proof coverage.

### OnChainTokenState's six fields (root, maxFee, processTime, retractTime, repPolicy, consumerPin) survive a chain round trip with the representative policy varied Base versus AltRepPolicy.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 state round trip.

### Present: resolve the active registration's application UTxO from the authenticated canonical registry.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 1 (Singular side).

### The token: exact policy, quantity one, derived asset name.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 2 (Singular side).

### Zero candidates resolves to reject.

Expected: reject, fail closed. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 3 (Singular side).

### Several candidates impossible: a second live representative for one registered key cannot be created.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 4 (Singular side).

### Resolve while the representative sits in a pending terminal request: report pending, not a usable output.

Expected: pending. Planned evidence status: uncovered.

Source: cardano-keri consumer-checklist point 5 (Singular side).

### Bonds, poison, the juvenility window W and the signature threshold: the checkpoint machine's and the treasury's policy, not Singular's.

Expected: out of scope — recorded, never claimed. Planned evidence status: outside the registry's scope.

Source: cardano-keri consumer-checklist points 3-6 (cardano-keri side).

### Execution units (mem, cpu) and transaction size measured for every accepting row, against the devnet's Conway protocol maxima, with headroom stated.

Expected: recorded. Planned evidence status: uncovered.

Source: issue #18 acceptance: limits measured.

### The fold batch-size boundary: the largest Modify batch that succeeds and the smallest that fails, with the failure reason.

Expected: an actual observed boundary, N accepted and N+1 refused. Planned evidence status: uncovered.

Source: issue #18 acceptance: limits measured.

### Exact environment: cardano-node version, GHC, Aiken toolchain, blueprint hashes, and the environments explicitly not supported.

Expected: recorded from the running node and the pinned flakes. Planned evidence status: uncovered.

Source: issue #18 acceptance: limits measured.

### Hold a valid fold constant and remove only the state-owner required signer; the observation (accept or refuse) is recorded with its transaction — the regression property the independent verification specified.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; the no-owner-signer property is recorded history, not a live gate). Planned evidence status: bound elsewhere.

Source: Singular.Statements.fold_iff sufficiency direction (Lean); observation history: FAILED against the pre-#79 candidate (owner gate), ACCEPTED against the repaired candidate by execution.

### One `insertActive` request folds on the open registry and places exactly one `(activePolicy, key)` token in the output at the address and inline datum the request named. A second `insertActive` at the same known key is refused `key-exists`. A two-request batch at two DISTINCT keys whose claimed mint agrees per kind but disagrees per `(kind, key)` is refused `net-mint-mismatch`.

Expected: accept the fold; refuse the same-key duplicate `key-exists`; refuse the two-key wrong-distribution batch `net-mint-mismatch`; both refusals carry an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.insert_active_transaction_row and Singular.Statements.fold_batch_claimed_mint_by_kind_key (Lean 854f56f); issue #173; open application, distinct refusal fixtures and the published trace limit.

### On a real devnet, `insertActive` then `updateTerminal` at one key: the active witness the insert delivered is the exact input the retirement burns, exactly one `(activePolicy, key)` is destroyed, no output carries it afterwards, and the committed trie leaf becomes Terminal. `updateTerminal` on an Unknown key and on an Absent key are refused with their own named reasons, each against an accepting control.

Expected: accept the insert and the retirement; the active quantity goes 1 -> 0 with the exact keyed `-1` mint burned from its token-bearing source input and the committed leaf reading `Terminal`; refuse `updateTerminal` on an Unknown key `key-unknown` and on an Absent key `not-booked`, each with an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.update_terminal_transaction_row and Singular.Statements.update_terminal_inversion (Lean 871c5df); issue #177; connected retirement and distinct refusal controls.

### On a real devnet, a request that is never folded leaves the queue by a reject or a retract. A reject once the request may no longer be folded must refund its owner the deposit; a retract by its owner must return everything the request held, through an output whose inline datum is the retracted request's own output reference. Each refund or return one lovelace short or to another key, a return bound to another request, and a retract spending the registry state beside it are refused by the chain and by the model, each beside the untampered exit of the same request, which both accept. The live consumer for the rule that only a retract returns the tip is the reject that keeps the tip beside the retract that returns it; fold consumers are in the fold rows. The guarantee that retract obligations depend only on the request remains a named gap: Lean proves this for every request and registry state, while this live run covers one registry state and no executable consumer varies it.

Expected: refuse a reject refunding the owner one lovelace short and to another key, `deposit-returned`, beside the accepted untampered reject; refuse a retraction returning one lovelace short, to another key and bound to another output reference, `deposit-returned`, and one spending the registry state beside it, `retract-state-spent`, beside the accepted untampered retraction. Planned evidence status: uncovered.

Source: Singular.Statements.exit_settles_on_lovelace_received and Singular.Statements.no_exit_strands_the_deposit; issue #258; Singular.Statements.only_retract_owes_the_tip: consumed by the live reject that keeps the tip and retract that returns it; fold consumers are in the registration (CG21) and retirement (CG22) rows. Singular.Statements.obligations_read_only_the_request: named gap, proved in Lean for every request and registry state, but the live run covers one registry state and no executable consumer varies it.

## Appendix: checking the evidence machinery

The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.

Each refused request's traced replay was evaluated from a capture of the refused transaction, the outputs it spends, the protocol parameters and the era history:

Transaction `15a2a2aa90358f8068bf37f1587782875892f9f8973f5eae9a839c745f1e2820`: capture `ada014237d651366c38acc998a28abcdc2572820904d3071bc6eb8b806f79865` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `0440b93147649c08e317e2abcdff9480ade38b004db6374e3aa565bd502691eb`: capture `1640653d793790b8e7dc1e48e187df6b34b16bed4465b97d0195bd0700ddb822` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `331a52d7db1a49edad3e13e7c378ca3fcca98c686689341a52c61227d72b9f07`: capture `227498d5ee4abda4404b5367c1ced6871ce1fc8829d98ea87335491a6446555f` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `93da10f383b6537b57382a1ba4b6867ac0f3e0fda9b8639c5d62cfa486fa8fae`: capture `daac737776977b2309a63abd135700322836f5b0fbfa214924a4dd701d8677f0` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `53d30bd27599e24655b5b442ed23441d4232477556ddcfc921f953648e479df4`: capture `402dc89d5f815e231bdec10ed41f45f4c9ab76e45fe8562a0273ad95badf05ef` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `3bb2d269929a9b4a3a63259a475fa5b9ae028f7b7810887c517a2c69a302db66`: capture `81298d1698b91161ac362bb9b2b708ac546ec35c025982ded1614f8fc500c243` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `5de7d06502ea2fb6a458808896e00544107e15af78303645667ecef60d093a6f`: capture `ace446c6fa1b52f34f6329deb957b8813ca3d94ece8b8abc9cd162f391a20033` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `625b722327781fd16b209f4e72bb282be4e898a88064220c8fdb547531ecd248`: capture `a978523f1f0d380f91fa569c952f035d0440d514f6e186243a179237f1c0ef55` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `f11761988b923bf35a7ba549cd76f9fb53b0bdfba23d8c89854915f63c26ab5c`: capture `088272e768ff1402a7b20d3510bd6d5c7c757be67a7acbff8f316f97afcfa1f6` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `a3f6587ec48b611521c5fdc4f63b27df786666d18a36f135b3111711b63836eb`: capture `31a75da3214fdac767d926c21b7b89edf2f08298ddbdafd5e20c7d98a9ad9c33` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `fba69094d86ac36497feb84e55a863409ea12584a8ae94c11fa6dadea3d36487`: capture `ab5e9d34fc24cb980ca93ab5d2092b112caad7d1e3e56a810c87182f45941fb8` of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b`.

Transaction `c475074a8691db81561bb64155c896a941864d1f9c38ba7ecb1ddfcc0bf0c6ce`: capture `81f0c01575a5100f378d550e0d0ca8bde160721e91be9ba5ee0e8303e4dc76f6` of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b`.

Transaction `58f9d98bfd376d7f6b8e55c4bd4ae0496bac691fede97473c8e7b5256470c92e`: capture `21695c5be04328fec9f265a59549b0d278e878695c09f141acd784a5029e5727` of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b`.

Transaction `36eb409aaa66bf8504f8b5a8d778b905d5e56112422f76eb28bc5d6106a20210`: capture `74e4e3630057afb86179958670c7a5b549aee2a584e463b21acea48c430ec617` of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b`.

Transaction `36eb409aaa66bf8504f8b5a8d778b905d5e56112422f76eb28bc5d6106a20210`: capture `74e4e3630057afb86179958670c7a5b549aee2a584e463b21acea48c430ec617` of the deployed script `1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428`.

Transaction `3f19d9cd0e80c77bbfdc4df023e5441577739b498f2951093d41fdba937938ac`: capture `c60eb9b1575d4026ae91dc35a914a4cb848ef6238624c4fb8cf5742bf45873d8` of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b`.

Transaction `99a431c3fc7374f691f6c6991cd148d039db14412c58bc1300bbaa15bcdaa48d`: capture `ae2479e296258400b9210cb4d2ec6f8de7c61812b93195a25bcad9f61bde5acf` of the deployed script `8bffb4ea646b40eb8a1ad64ae1b2a855e72b19aa80977b584de49e2b`.

Transaction `074c2383d3c8591ea5ddb6a2ba1c2b9c574e0c2b41c6be9d1beab083c3be4faa`: capture `b0d91d533521d1eb82d5ca14baf5e533b4e6e03a30b74fa9c8995e4beda79a09` of the deployed script `ea30ac572fc2fb9a8936cc3430c8c133e820d8e724edb517d6c8ac1a`.

Transaction `38803487497c7aeef6453f4dbf80181ce5bfeb53576cac62d7cb9d1f0356576b`: capture `33f49a4c51657d74aa5daa5fb44f5c97afdf7cd7cd0c6389e8978a503d970f99` of the deployed script `ea30ac572fc2fb9a8936cc3430c8c133e820d8e724edb517d6c8ac1a`.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.

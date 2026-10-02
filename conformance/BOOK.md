# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `97cffe4a5fb33f01827ca41ab521c4636a81bee7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Registration compared 7 requests: 4 accepted and 3 refused on chain.

Unsupported chain folds: 0.

Batches submitted in one transaction: 1, 0 accepted and 1 refused on chain.

The extra-signer registration was accepted on chain (transaction `627f66743cf4a5db4d29921cc4b986f7e71f651f135112d9289d3956f9d7c29e`); the comparison detected the difference at `tx.signers`.

The insertActive was refused on chain (transaction `b761a6614562d559d735e271809df8529c1cedea093936c7593d1b0fb750a0cc`); the model refused it for `key-exists`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-exists`.

The other-address insertActive was refused on chain (transaction `f5b59655e9eff00eaf039680fa11567d42e2eb55dc1b9ec648cd7c0b01aab064`); the model refused it for `destination`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `destination`.

The short-by-one insertActive was refused on chain (transaction `49575cb845119a70bc70785962072470b1f6d23e6e923bb135808a3a614ce7d3`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The fold of 2 requests in one transaction, tampered mint-on-first-key, was refused on chain (transaction `c4581d063ee4a74f9b10cf09ee9876db58c687a9c6657b6ca30f0176f9f9689a`); the model's `foldBatch` refused it for `net-mint-mismatch`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `net-mint-mismatch`.

Code revision: `97cffe4a5fb33f01827ca41ab521c4636a81bee7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Occupied-key insertion compared 3 requests: 2 accepted and 1 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `2e7ed3e582a23ae1314a487a4f309c18841564ba23dfb807b892c9941e7b2a26`); the model refused it for `key-exists`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-exists`.

Code revision: `97cffe4a5fb33f01827ca41ab521c4636a81bee7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Retirement compared 11 requests: 7 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The updateTerminal was refused on chain (transaction `c78e381148f3f6bed799d9ca0c1175d00fda8f0f8e848f3643575864b1d589f3`); the model refused it for `not-booked`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `not-booked`.

The updateTerminal was refused on chain (transaction `0450885a8131a49b15084f20d7258de017faa4f2fb124fdf3b40b4a33e3429bc`); the model refused it for `key-unknown`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-unknown`.

The short-by-one deleteActive was refused on chain (transaction `f4bc96721ceccf523a77bd0229c63d12a550f5da1fa92f251fc96defc223375b`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address deleteActive was refused on chain (transaction `13608a82a535ac4ff9f6f7be5d1067aa03882c8da3bacf5ff4f47eb9f7dedae4`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

Code revision: `97cffe4a5fb33f01827ca41ab521c4636a81bee7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Rejection and retraction compared 10 requests: 2 accepted and 8 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `dee0311d9dcb7ceb9c90bfc93e8c07b0a595160ebb464fae8988439c9c9b6ce7`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `dc603cab791ae9e5f9286d5bb20e0bf4a5bfc821d8aeb883c7dfad80ec072608`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The short-by-one retract of insertActive was refused on chain (transaction `e647200319598615db45e8128b54cc3ceb8b69be8c0b3ce743818612c648029f`); the model refused it for `deposit-returned`. The traced replay of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61` (traced build `827c6d4388cb64b88bbe2744fd3803caefc8ad61557dad4af7670d59`) failed with `deposit-returned`.

The other-address retract of insertActive was refused on chain (transaction `99a791e76908201fecc6b5d312c0aaf0a9fd441a837ef12238379a85e897cbc0`); the model refused it for `deposit-returned`. The traced replay of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61` (traced build `827c6d4388cb64b88bbe2744fd3803caefc8ad61557dad4af7670d59`) failed with `deposit-returned`.

The other-reference retract of insertActive was refused on chain (transaction `6f9c9b5cf108b73381db770ca393f327fe6a351da158a8e24f83bb358ca69b71`); the model refused it for `deposit-returned`. The traced replay of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61` (traced build `827c6d4388cb64b88bbe2744fd3803caefc8ad61557dad4af7670d59`) failed with `deposit-returned`.

The state-spent retract of insertActive was refused on chain (transaction `408619b7e62a3e655f10bafc7c92ee51966b76f96d051433ee1b694b5cedde93`); the model refused it for `retract-state-spent`. The traced replay of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61` (traced build `827c6d4388cb64b88bbe2744fd3803caefc8ad61557dad4af7670d59`) failed with `retract-state-spent`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `missing-action`.

The retract of updateTerminal was refused on chain (transaction `ad78611d74c0715441fb9be7c4bf64ea67fc19cb7b8227e769829b5d7bf75858`); the model refused it for `withdraw-insert-only`. The traced replay of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61` (traced build `827c6d4388cb64b88bbe2744fd3803caefc8ad61557dad4af7670d59`) failed with `withdraw-insert-only`.

The unsigned retract of insertActive was refused on chain (transaction `25254d410de5ea48efa837a677645c9452265b4fde527db8d1a856ccfb538909`); the model refused it for `retract-owner`. The traced replay of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61` (traced build `827c6d4388cb64b88bbe2744fd3803caefc8ad61557dad4af7670d59`) failed with `retract-owner`.

The exit chapter compared both admission refusals: the unsigned insertion retraction (transaction `25254d410de5ea48efa837a677645c9452265b4fde527db8d1a856ccfb538909`) was refused by the model for `retract-owner`, and the pending update retraction (transaction `ad78611d74c0715441fb9be7c4bf64ea67fc19cb7b8227e769829b5d7bf75858`) for `withdraw-insert-only`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `3ac2f28b37a30e3ab3129ee3a285b8f0fa78b237244af29ed536e194a7d0ec26`.

Code revision: `97cffe4a5fb33f01827ca41ab521c4636a81bee7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Early rejection compared 6 requests: 2 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `4bd1154e916137027fa9b01b7772f75c391a1ab2942d951f6d498b1da7411266`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `05e77cf38308e1f9d4828f7713901cc6e78b1234885502b00444d82f2da82444`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The short-by-one reject of insertActive was refused on chain (transaction `d3943ebe5e6e9395c0d7309523b2ad27fa5f73d5b905f508387f5bf4646e2d05`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `1b0df9fc4901baa386fdc8e7b9196a4357fb8eeb897d8fe7c757100bd927a22b`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

Code revision: `97cffe4a5fb33f01827ca41ab521c4636a81bee7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Retraction window compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The before-phase-2 retract of insertActive was refused on chain (transaction `a6a4f66aefd697b1f8a82543d878598b1cb5cabaa8c0c97b1e1b46c3517a84b3`); the model refused it for `not-phase2`. The traced replay of the deployed script `732ae4bd54bf91d87fc709d6341b247d4b7c4a4e2c7dfe8b4d1de468` (traced build `228c4e523ecf52e733830d4f6b1778e27de08ba769a6095830b065d6`) failed with `not-phase2`.

The after-phase-2 retract of insertActive was refused on chain (transaction `831ffdc962d722c9df20785df8d9a089013e5bc8e66d069e47bd8693d7b33c31`); the model refused it for `not-phase2`. The traced replay of the deployed script `732ae4bd54bf91d87fc709d6341b247d4b7c4a4e2c7dfe8b4d1de468` (traced build `228c4e523ecf52e733830d4f6b1778e27de08ba769a6095830b065d6`) failed with `not-phase2`.

The window chapter compared both finite timing refusals: transaction `a6a4f66aefd697b1f8a82543d878598b1cb5cabaa8c0c97b1e1b46c3517a84b3` before phase 2 and transaction `831ffdc962d722c9df20785df8d9a089013e5bc8e66d069e47bd8693d7b33c31` after phase 2. The model refused both for `not-phase2`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `42748ee6e2b138c2aeefebe325cd49207e3010e7d7eb3a75b8b40780c6c759ca`.

Code revision: `97cffe4a5fb33f01827ca41ab521c4636a81bee7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

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

- Fold, in one transaction with every token the transaction mints moved onto the first request's key, **insertActive** for **minted-a**, **insertActive** for **minted-b** in **registration**, using the recipient wallet, the recipient wallet, and ask the executable registry model the same batch.

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

A request can leave the queue without a fold. After its owner's retraction window has closed, a folder rejects it and must refund its owner the deposit, keeping the tip; while it is still retractable, its owner retracts it and must get back everything it held, deposit and tip, through an output whose inline datum is the retracted request's own output reference. Each refund paid one lovelace short or to another address, a return bound to another request, and a retraction spending the registry's state beside it must be refused, each beside the untampered exit of the same request.

- Reject the **insertActive** for **rejected** in **rejection** after its owner's retraction window has closed with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Reject the **insertActive** for **rejected** in **rejection** after its owner's retraction window has closed with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **rejected**.

- Compare **rejected** and its observation with the executable registry model.

- Reject the **insertActive** for **rejected** in **rejection** after its owner's retraction window has closed, using the holder wallet.

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

## A folder rejects a request before its retraction deadline

A reject carries no admission: the model accepts it in every window, and the chain does too. Two insertion requests from the same owner are booked together in a registry of their own. The first is rejected while it can still be folded, the second while its owner can still retract it. In each window a reject refunding the owner one lovelace short, and one refunding another key, must be refused by both, leaving the request pending; the untampered reject of the same request must be accepted by both, refund the owner the deposit and leave the registry state as it was. Each reject's validity interval is checked to lie inside the window its step names before it is submitted.

- Reject the **insertActive** for **early-processing** in **early rejection** while the request can still be folded with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **early-processing**.

- Compare **early-processing** and its observation with the executable registry model.

- Reject the **insertActive** for **early-processing** in **early rejection** while the request can still be folded with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **early-processing**.

- Compare **early-processing** and its observation with the executable registry model.

- Reject the **insertActive** for **early-processing** in **early rejection** while the request can still be folded, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **early-processing**.

- Compare **early-processing** and its observation with the executable registry model.

- Reject the **insertActive** for **early-retraction** in **early rejection** while its owner can still retract it with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **early-retraction**.

- Compare **early-retraction** and its observation with the executable registry model.

- Reject the **insertActive** for **early-retraction** in **early rejection** while its owner can still retract it with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.

- Observe the complete registry, token, leaf and transaction boundary after **early-retraction**.

- Compare **early-retraction** and its observation with the executable registry model.

- Reject the **insertActive** for **early-retraction** in **early rejection** while its owner can still retract it, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **early-retraction**.

- Compare **early-retraction** and its observation with the executable registry model.

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

Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none for a fold and the owner for a retraction, and the comparison reads them from the submitted transaction. The registration chapter folds two registrations in one transaction that mints both tokens at the first request's key; it is compared on its outcome and, both refusing, on the reason. The model builds no transaction for a batch, so no other observation of a batch is compared. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The Absent retirement probe reaches the state script only after omitting an unfunded burn: the builder cannot fund burning a token that does not exist. Its refusal does not establish how a transaction with that burn would behave. The model admits a retraction only when the pending request inserts a key or reads a terminal one, its owner is among the transaction's required signers, and its validity interval lies inside phase 2. The interval starts no earlier than submission plus the processing time; its excluded upper bound may reach, but not pass, the end of the retraction time that follows. The model represents only finite validity bounds. Open validity intervals remain a named gap: the Aiken tests establish their not-phase2 refusal, but no live model comparison can represent them. The early rejections are compared in the processing window and the retraction window of one registry; a fold of an update in the retraction window is not compared there, because the validator refuses it while the model admits it, a separate tracked discrepancy. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.

Refusal reasons come from traced re-evaluation. The deployed validators are compiled without traces, so the ledger names the script that refused but not why. Each refused transaction is evaluated again on the arguments the ledger built for it: once with the deployed bytes, and once with a build of the same source, compiler and parameters that keeps only the validators' own traces. A reason is admitted only when both evaluations fail and the traced one leaves exactly one trace; otherwise the receipt names the cause no reason was admitted. The receipt names both script hashes, and each refused request above prints what its replay recorded. Of the 23 refused requests in this run's chapters, 23 carry a reason their traced replay admitted, 0 name the cause their replay admits none, and 0 record no traced replay.

Refusals outside these chapters, by row, recorded in the receipts of the conformance session rather than in this book. Three have no counterpart in the model, so their model comparison is unmet: each receipt carries the verdict unmet by ruling and shows what the traced replay of the refusal recorded. wrong-redeemer-constructor-index, a fold redeemer at a wrong constructor index: the model has no vocabulary for decoding a redeemer; the witness script names its refusal, while the state and request scripts fail on a path that carries no user-defined trace, so their live refusal reason is not observed (lambdasistemi/singular#347). fold-against-superseded-root, a fold whose proof was built against a root the registry has since superseded: the model takes no proof and no authenticated root and admits the insertion on that unoccupied key, so nothing compares with the chain's reason (lambdasistemi/singular#346). surplus-fold-actions, a fold carrying an action beyond its requests, and one missing an action: the model takes no action list (lambdasistemi/singular#345). The other refusals are compared with the model's batch questions, each against the reason the traced replay admits for the state script: empty-fold, an empty fold, with the fold batch over no request; request-value-and-refund-routing, two rejects whose refunds are crossed and two whose first refund is short, with the reject batch judged on the refunds the transaction pays; and reject-before-deadline-consumer-requirement's control, a reject refunding its owner one lovelace short, with the reject batch of that one request. reject-before-deadline-consumer-requirement itself, a reject while the request can still be folded, is accepted by the chain and by the model, while the consuming project requires it refused: that requirement stays unmet by ruling. Where a reject pays its owner, the chain and the model read the payment differently: the chain requires the output in each refund's position to pay that request's owner what it is owed, while the model credits an owner the sum of every output at its key. A reject paying its owner short in the refund's position and the rest in another output at the same key is refused by the chain and accepted by the model: reject-before-deadline-consumer-requirement's receipt records that disagreement from a devnet run, a known divergence and never a pass (lambdasistemi/singular#361). Every compared reject, here and in the conformance session, leaves no other output at its owners' keys, so their agreement holds for that shape only. Whether empty-fold and request-value-and-refund-routing meet the consuming project's requirements remains unresolved; the two rows stay held.

## Requirements inventory

The descriptions and planned statuses below are preserved from the committed inventory. The transaction evidence above belongs to this particular run; it does not rewrite planned statuses or discharge unrelated requirements.

### The canonical registry token name is SHA-256 of the canonical seed's outRef; a consumer recomputes it from the published seed and matches the on-chain state UTxO.

Expected: accept. Planned evidence status: uncovered.

Source: cardano-keri: canonical seed-derived registry identity.

Outside the model's vocabulary: the model has no seed, token name or registry address: the registry's address is a named unobservable and the model has no byte representation. The naming profile's consumer binding states a seed binding over abstract numbers, but it is not on the model driver's declared surface, so nothing is compared with the model.

Run in the authentication vocabulary, in the registry-identity session:

- Boot the canonical registry from the canonical seed; the ledger accepts it.
- Read the canonical registry's state output from the chain: its only name under the canonical policy is SHA-256 of the canonical seed's output reference, at quantity one, and the derivation of a fabricated reference does not appear.

The receipt cites the boot of the canonical registry.

### A rival registry initialized from a second seed exists and is accepted by the ledger; canonical authentication rejects it on name.

Expected: rival accepted on chain; authentication rejects. Planned evidence status: uncovered.

Source: cardano-keri: canonical registry authentication distinguishes a rival seeded registry; issue #16.

Outside the model's vocabulary: the model has no seed, token name or registry address: the registry's address is a named unobservable and the model has no byte representation. Booting a registry is not one of the model's exits, and authentication reads a token name the model does not have.

Run in the authentication vocabulary, in the registry-identity session:

- Publish the rival seed by splitting a wallet output in two.
- Boot the rival registry from the rival seed, with the canonical registry's configuration and only the seed changed; the ledger accepts it.
- Read the canonical registry's state output from the chain: its only name under the canonical policy is SHA-256 of the canonical seed's output reference, at quantity one, and the derivation of a fabricated reference does not appear.
- Read the rival registry's state output from the chain: its only name under the canonical policy is SHA-256 of the rival seed's output reference, at quantity one, and the derivation of a fabricated reference does not appear.
- The names of the canonical registry and the rival registry differ.
- The canonical registry's state output is the one its boot left: same output, value and datum.
- The consumer's authentication (canonical policy, the name derived from the canonical seed, quantity one), applied to the rival registry's state output, rejects it on the name.
- The consumer's authentication (canonical policy, the name derived from the canonical seed, quantity one), applied to the canonical registry's state output, accepts it.

The receipt cites the boot of the rival registry.

### Negative control: an authenticator that checks only policy+address, not the derived name, accepts the rival.

Expected: control must fail. Planned evidence status: uncovered.

Source: Rival-registry authentication discrimination control (rival-seed-authentication).

Outside the model's vocabulary: the model has no seed, token name or registry address: the registry's address is a named unobservable and the model has no byte representation. This row is a control over the authenticator itself; the model has no counterpart.

Run in the authentication vocabulary, in the registry-identity session:

- An authentication that checks only the policy and the address, applied to the rival registry's state output, accepts it.
- The consumer's authentication (canonical policy, the name derived from the canonical seed, quantity one), applied to the rival registry's state output, rejects it on the name.

The receipt cites the boot of the rival registry.

### Applied and unapplied validator identity layers stay distinct and derived: applied address = apply(pinned unapplied hash, declared parameters); parameter count published.

Expected: accept. Planned evidence status: uncovered.

Source: blueprint identity discipline (onchain #34 pattern).

Outside the model's vocabulary: the model has no seed, token name or registry address: the registry's address is a named unobservable and the model has no byte representation. Script hashes, parameter application and addresses are below the model; the derivation is checked off chain against the address the chain reports.

Run in the authentication vocabulary, in the registry-identity session:

- The published script manifest pins the state validator to this run's blueprint code and declares no parameters.
- The state address the production builder derives equals the address the chain reports for the canonical registry.
- The request validator applied to the canonical registry's parameters has an address different from the unapplied script's.
- A state script corrupted by one extra parameter application derives an address the same check refuses against the chain.

The receipt cites the boot of the canonical registry.

### A forged output at the canonical address carrying no registry token is not a registry: creating an output does not execute the receiving script.

Expected: authentication rejects; no script ran. Planned evidence status: uncovered.

Source: ledger output semantics.

Outside the model's vocabulary: the model has no seed, token name or registry address: the registry's address is a named unobservable and the model has no byte representation. Creating an output is not an operation of the model.

Run in the authentication vocabulary, in the registry-identity session:

- Pay an output to the canonical registry's address carrying its state datum and no token: no script witness, no script evaluated, accepted by the ledger and read back live; the same detector finds the script the canonical boot carried.
- The consumer's authentication (canonical policy, the name derived from the canonical seed, quantity one), applied to the forged output, rejects it: no token sits under the canonical policy.

The receipt cites the forged output's transaction.

### Generic Insert: request, fold, leaf present, root advances, read back from chain.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cardano-keri: registered-key consistency and registry leaves changing only through a fold.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: boots state and applies a request update

Run as an edge composition over the registry's operations, in the conformance session:

- Submit **insertAbsent** for **cg01-key** in **insertion**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg01-key**.

- Compare **cg01-key** and its observation with the executable registry model.

### Generic Update (OpUpdate old new) on an existing key folds; the root advances and the new value reads back from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec registry transitions.

Run as an edge composition over the registry's operations, in the conformance session:

- Submit **insertAbsent** for **cg02-key** in **update**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg02-key**.

- Compare **cg02-key** and its observation with the executable registry model.

- Submit **updateActive** for **cg02-key** in **update**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg02-key**.

- Compare **cg02-key** and its observation with the executable registry model.

### Generic Delete (OpDelete old) on an existing key folds; the key returns to absence, proved by a read from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec; issue #18 Delete preservation.

Run as an edge composition over the registry's operations, in the conformance session:

- Submit **insertAbsent** for **cg03-key** in **deletion**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg03-key**.

- Compare **cg03-key** and its observation with the executable registry model.

- Submit **deleteAbsent** for **cg03-key** in **deletion**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg03-key**.

- Compare **cg03-key** and its observation with the executable registry model.

### After deleting a key, re-Insert the same key (reincarnation).

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec: Delete MUST permit a later Insert.

Run as an edge composition over the registry's operations, in the conformance session:

- Submit **insertAbsent** for **cg04-key** in **reinsertion**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg04-key**.

- Compare **cg04-key** and its observation with the executable registry model.

- Submit **deleteAbsent** for **cg04-key** in **reinsertion**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg04-key**.

- Compare **cg04-key** and its observation with the executable registry model.

- Submit **insertAbsent** for **cg04-key** in **reinsertion**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg04-key**.

- Compare **cg04-key** and its observation with the executable registry model.

### Insert on a key that is already present.

Expected: refuse, attributed to the script that refused. Planned evidence status: uncovered.

Source: protocol spec: the fold MUST NOT accept Insert for an occupied key.

Run as an edge composition over the registry's operations, in the chapter "Insert on a key the registry already holds" above.

### Retract in phase 2 returns bond+tip, registry untouched.

Expected: accept; root unchanged. Planned evidence status: bound elsewhere.

Source: cardano-keri: retraction timing, unchanged registry state and the returned request value.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: retracts a phase-2 request

Run as an edge composition over the registry's operations, in the conformance session:

- Retract the **insertActive** for **cg06-key** in **retraction in phase 2** as its owner, using the owner wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg06-key**.

- Compare **cg06-key** and its observation with the executable registry model.

### Retract outside phase 2.

Expected: refuse the owner-signed retraction before phase 2 and after phase 2, with model reason not-phase2 and request-script attribution, beside the accepted owner-signed retraction inside phase 2. Planned evidence status: uncovered.

Source: Singular.Statements.retract_admitted_iff and Singular.Statements.retract_refusal_first_failing; cardano-keri retraction timing.

Run as a tamper of an edge's transaction, in the chapter "Retract only inside phase 2" above.

### Rejected when rejectable.

Expected: accept. Planned evidence status: bound elsewhere.

Source: cardano-keri R9_reject_enabled.

Existing evidence: offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs: rejects a phase-3 request

Run as an edge composition over the registry's operations, in the conformance session:

- Reject the **insertActive** for **cg08-key** in **rejection after the windows** after its owner's retraction window has closed, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg08-key**.

- Compare **cg08-key** and its observation with the executable registry model.

### Rejected when not rejectable.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R9_reject_needs_rejectable.

Run as a tamper of an edge's transaction, in the conformance session:

- Reject, in one transaction while the request can still be folded with the first request's refund 1 lovelace short, **insertAbsent** for **cg09-key** in **processing-window rejection**, using the owner wallet, booked **cg09-key** by the owner wallet with a deposit of 3000000 lovelace, and ask the executable registry model the same batch.

- Reject, in one transaction while the request can still be folded with the first request's refund 1 lovelace short in its own position and two ada more in another output at the same owner's key, **insertAbsent** for **cg09-key** in **processing-window rejection**, using the owner wallet, booked **cg09-key** by the owner wallet with a deposit of 3000000 lovelace, and ask the executable registry model the same batch.

- Reject, in one transaction while the request can still be folded, **insertAbsent** for **cg09-key** in **processing-window rejection**, using the owner wallet, booked **cg09-key** by the owner wallet with a deposit of 3000000 lovelace, and ask the executable registry model the same batch.

### Stale fold against a superseded root.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R7_stale_fold_refused.

Outside the model's vocabulary: a fold whose proof was built against a root the registry has since superseded. The model takes no proof and no authenticated root, so it has no reason to compare with the chain's refusal (lambdasistemi/singular#346). The conformance session runs the refusal and its accepting control on the devnet; the model comparison stays unmet by ruling.

### Empty fold (Modify []).

Expected: observe and report. Planned evidence status: uncovered.

Source: cardano-keri R8_empty_fold_refused.

Run as an edge composition over the registry's operations, in the conformance session:

- Fold, in one transaction, no request in **empty fold**, and ask the executable registry model the same batch.

- Submit **insertAbsent** for **cg11-key** in **empty fold**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg11-key**.

- Compare **cg11-key** and its observation with the executable registry model.

### Surplus actions beyond the matched request inputs.

Expected: observe and report. Planned evidence status: uncovered.

Source: cardano-keri audit 2026-09-03.

Outside the model's vocabulary: a fold carrying an action beyond its requests, and one missing an action. The model takes requests, not an action list, so it has no reason to compare with the chain's refusals (lambdasistemi/singular#345). The conformance session runs both refusals and an accepting control on the devnet; the model comparison stays unmet by ruling.

### Owner/hook pinning: a Modify that changes the state owner.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-pin transfer asserted authority that does not exist). Planned evidence status: bound elsewhere.

Source: cardano-keri R5_plugin_pinned.

Outside the model's vocabulary: a fold that changes the registry's owner. The registry has no owner role (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b) and the model has none either; the earlier observation is history and the claim is withdrawn.

### stake_script hook set: a fold carrying the matching withdrawal.

Expected: retired — the registry interface has no stake_script hook, so nothing runs this row. Planned evidence status: uncovered.

Source: imported partition shared.ak, types.ak.

Outside the model's vocabulary: a fold carrying a withdrawal under a stake_script hook. The registry interface has no stake_script hook (registry mode, no hook) and the model has no withdrawal; the row is retired and nothing runs it.

### stake_script hook set, withdrawal absent.

Expected: retired — the registry interface has no stake_script hook, so nothing runs this row. Planned evidence status: uncovered.

Source: imported partition shared.ak, types.ak.

Outside the model's vocabulary: the same fold with its withdrawal absent. The registry interface has no stake_script hook (registry mode, no hook) and the model has no withdrawal; the row is retired and nothing runs it.

### Sweep of a non-legitimate UTxO, owner-signed.

Expected: superseded — observation preserved, conformance claim withdrawn (registry has no owner role; owner-signed sweep asserted authority that does not exist). Planned evidence status: uncovered.

Source: cage custody.

Outside the model's vocabulary: an owner-signed sweep of an output that is not a request. The registry has no owner role and no sweep: its scripts refuse a sweep for every party (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b), and the model has no sweep. The earlier observation is history and the claim is withdrawn; no run sweeps a registry.

### Sweep by a non-owner.

Expected: SUPERSEDED by operator ruling (registry has no owner role): observation preserved, claim withdrawn. Planned evidence status: uncovered.

Source: cage custody.

Outside the model's vocabulary: a sweep by someone other than the owner. The registry has no owner role and no sweep (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b), and the model has no sweep; the earlier observation is history and the claim is withdrawn.

### End burns the state token and closes the cage.

Expected: superseded — claim withdrawn (the registry has no termination: End is refused for every party). Planned evidence status: uncovered.

Source: cage custody.

Outside the model's vocabulary: ending the registry by burning its state token. The registry has no termination: its state script refuses End for every party (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b), and the model has no termination exit. The claim that End is accepted is withdrawn; no run ends a registry.

### Refund routing follows the request: processed value routes to the request's destination minus the folder's tip; refunds go to the refund address recorded in custody; a crossed allocation is refused by the state script (interface, registry mode: no hook). Rejected produces refund owners at the recorded floor.

Expected: observe and report — refused, with the consumer-model conflict unresolved (crossed allocation enforced by the state script); the rejected-action refund-floor control runs in the same program. Planned evidence status: uncovered.

Source: cardano-keri R11_contribute_value, R11_retract_value; interface gist 2fb03c2e (registry mode).

Run as a tamper of an edge's transaction, in the conformance session:

- Reject, in one transaction after its owner's retraction window has closed with each owner refunded, in its refund's position, what the next request's owner is owed, **insertAbsent** for **cg19-key-a**, **insertAbsent** for **cg19-key-b** in **refund routing**, using the first owner wallet, the second owner wallet, booked **cg19-key-a** by the first owner wallet with a deposit of 4000000 lovelace, **cg19-key-b** by the second owner wallet with a deposit of 2000000 lovelace, and ask the executable registry model the same batch.

- Reject, in one transaction after its owner's retraction window has closed, **insertAbsent** for **cg19-key-a**, **insertAbsent** for **cg19-key-b** in **refund routing**, using the first owner wallet, the second owner wallet, booked **cg19-key-a** by the first owner wallet with a deposit of 4000000 lovelace, **cg19-key-b** by the second owner wallet with a deposit of 2000000 lovelace, and ask the executable registry model the same batch.

- Reject, in one transaction after its owner's retraction window has closed with the first request's refund 1000 lovelace short, **insertAbsent** for **cg19-rej-a**, **insertAbsent** for **cg19-rej-b** in **refund routing**, using the first owner wallet, the second owner wallet, booked **cg19-rej-a** by the first owner wallet with a deposit of 4000000 lovelace, **cg19-rej-b** by the second owner wallet with a deposit of 2000000 lovelace, and ask the executable registry model the same batch.

- Reject, in one transaction after its owner's retraction window has closed, **insertAbsent** for **cg19-rej-a**, **insertAbsent** for **cg19-rej-b** in **refund routing**, using the first owner wallet, the second owner wallet, booked **cg19-rej-a** by the first owner wallet with a deposit of 4000000 lovelace, **cg19-rej-b** by the second owner wallet with a deposit of 2000000 lovelace, and ask the executable registry model the same batch.

### Every ToData/FromData instance in Singular.Registry.Types round-trips, and its constructor index and field order match the compiled blueprint's declared schema, not merely itself.

Expected: accept, byte-exact against the blueprint. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

Outside the model's vocabulary: the model has no byte representation and no blueprint; the encodings are checked off chain against the compiled blueprint.

Run in the wire round-trip vocabulary, locally against the compiled blueprint:

- The Haskell encoding of a token identifier decodes back to itself and validates against the blueprint's types/TokenId, as constructor index 0.
- The Haskell encoding of an output reference decodes back to itself and validates against the blueprint's cardano/transaction/OutputReference, as constructor index 0.
- The Haskell encoding of a trie root decodes back to itself and validates against the blueprint's ByteArray, as plain bytes.
- A request's field at position 3 is its edge.
- A request's field at position 4 is its deposit.
- The Haskell encoding of a request on edge 0 decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request on edge 1 decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request on edge 2 decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request on edge 3 decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request on edge 4 decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request on edge 5 decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request on edge 6 decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request on edge 7 (an edge the registry refuses) decodes back to itself and validates against the blueprint's types/Request.
- The Haskell encoding of a request decodes back to itself and validates against the blueprint's types/Request, as constructor index 0.
- The Haskell encoding of a state decodes back to itself and validates against the blueprint's types/State, as constructor index 0.
- The Haskell encoding of a state with its active policy varied decodes back to itself and validates against the blueprint's types/State.
- The Haskell encoding of a request datum decodes back to itself and validates against the blueprint's types/CageDatum, as constructor index 0.
- The Haskell encoding of a state datum decodes back to itself and validates against the blueprint's types/CageDatum, as constructor index 1.
- The Haskell encoding of an absent-key custody datum decodes back to itself and validates against the blueprint's types/CageDatum, as constructor index 2.
- The Haskell encoding of the Minting redeemer decodes back to itself and validates against the blueprint's types/MintRedeemer, as constructor index 0.
- The Haskell encoding of the Migrating redeemer decodes back to itself and validates against the blueprint's types/MintRedeemer, as constructor index 1.
- The Haskell encoding of the Burning redeemer decodes back to itself and validates against the blueprint's types/MintRedeemer, as constructor index 2.
- The Haskell encoding of a migration record decodes back to itself and validates against the blueprint's types/Migration, as constructor index 0.
- The Haskell encoding of the Update action decodes back to itself and validates against the blueprint's types/RequestAction, as constructor index 0.
- The Haskell encoding of the Rejected action decodes back to itself and validates against the blueprint's types/RequestAction, as constructor index 1.
- The Haskell encoding of the End redeemer decodes back to itself and validates against the blueprint's types/UpdateRedeemer, as constructor index 0.
- The Haskell encoding of the Contribute redeemer decodes back to itself and validates against the blueprint's types/UpdateRedeemer, as constructor index 1.
- The Haskell encoding of the Modify redeemer decodes back to itself and validates against the blueprint's types/UpdateRedeemer, as constructor index 2.
- The Haskell encoding of the Retract redeemer decodes back to itself and validates against the blueprint's types/UpdateRedeemer, as constructor index 3.
- The Haskell encoding of the Sweep redeemer decodes back to itself and validates against the blueprint's types/UpdateRedeemer, as constructor index 4.
- A constructor at index 99 fails the blueprint's types/UpdateRedeemer.
- The Haskell encoding of a Branch proof step decodes back to itself and validates against the blueprint's aiken/merkle_patricia_forestry/ProofStep, as constructor index 0.
- The Haskell encoding of a Fork proof step decodes back to itself and validates against the blueprint's aiken/merkle_patricia_forestry/ProofStep, as constructor index 1.
- The Haskell encoding of a Leaf proof step decodes back to itself and validates against the blueprint's aiken/merkle_patricia_forestry/ProofStep, as constructor index 2.
- The Haskell encoding of a fork neighbour decodes back to itself and validates against the blueprint's aiken/merkle_patricia_forestry/Neighbor, as constructor index 0.
- A list of 3 elements fails the blueprint's Tuple<<ByteArray,ByteArray>>, a fixed tuple of 2.
- The blueprint's types/State lists the fields of State as root, tip, process_time, retract_time, application_policy, active_policy, absent_policy, terminal_policy, the Haskell record's order.
- The blueprint's types/Request lists the fields of Request as requestToken, requestOwner, requestKey, edge, deposit, submitted_at, destination, the Haskell record's order.
- The blueprint's types/Migration lists the fields of Migration as oldPolicy, tokenId, the Haskell record's order.
- The blueprint's types/TokenId lists the fields of TokenId as assetName, the Haskell record's order.
- The blueprint's cardano/transaction/OutputReference lists the fields of OutputReference as transaction_id, output_index, the Haskell record's order.
- The blueprint's aiken/merkle_patricia_forestry/Neighbor lists the fields of Neighbor as nibble, prefix, root, the Haskell record's order.
- The blueprint's aiken/merkle_patricia_forestry/ProofStep lists the fields of Branch as skip, neighbors, the Haskell record's order.
- The blueprint's aiken/merkle_patricia_forestry/ProofStep lists the fields of Fork as skip, neighbor, the Haskell record's order.
- The blueprint's aiken/merkle_patricia_forestry/ProofStep lists the fields of Leaf as skip, key, value, the Haskell record's order.

### Datum bytes constructed in Haskell and submitted are read back from the chain identical.

Expected: accept, byte-compare submitted vs chain-observed. Planned evidence status: uncovered.

Source: issue #18 serialization boundary.

Outside the model's vocabulary: the model has no byte representation: its transaction observation states whether an output's datum is inline or absent, and the reported form is written, not read, so datum bytes are below it.

Run in the wire round-trip vocabulary, in the serialization session on the devnet:

- Boot the registry **datum**.
- Submit a request for **datum-read-back-key** on insertActive in **datum**.
- Read back from the chain the state datum the boot of **datum** wrote: the bytes are the ones submitted.
- Read back from the chain the request datum written for **datum-read-back-key** in **datum**: the bytes are the ones submitted.

### Each UpdateRedeemer constructor (End 0, Contribute 1, Modify 2, Retract 3, Sweep 4) is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator.

Expected: partial: accept (Contribute 1, Modify 2, Retract 3 with executing witnesses); End 0 and Sweep 4 unexercised named residuals (no accepting path yet, issue #18 tracks completion). Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

Outside the model's vocabulary: the model has no redeemer (lambdasistemi/singular#347): its operations here are a fold and a retraction, but the claim is the constructor each transaction carries on the wire.

Run in the wire round-trip vocabulary, in the serialization session on the devnet:

- Boot the registry **modify**.
- Book **modify-witness-key** on insertActive in **modify** and fold it.
- The ledger accepted the fold of **modify-witness-key** in **modify**, which carries Modify (index 2) among the redeemers of the inputs it spends.
- The ledger accepted the fold of **modify-witness-key** in **modify**, which carries Contribute (index 1) among the redeemers of the inputs it spends.
- Boot the registry **retraction**, with one second of processing and thirty of retraction.
- Submit a request for **retract-witness-key** on insertActive in **retraction**.
- Once the retraction window opens, the owner retracts the request for **retract-witness-key** in **retraction**.
- The ledger accepted the retraction of **retract-witness-key** in **retraction**, which carries Retract (index 3) among the redeemers of the inputs it spends.

Coverage stays partial: End (index 0) is a named residual: the state script refuses End for every party under the ownerless-registry ruling (commit f3a68b1b removed its builder); no accepting path exists; Sweep (index 4) is a named residual: the request script refuses Sweep for every party under the ownerless-registry ruling (commit f3a68b1b removed its builder); no accepting path exists.

### A redeemer at a wrong constructor index is refused by the compiled validator.

Expected: refuse, attributed to the script. Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

Outside the model's vocabulary: a fold whose redeemer is retargeted to an index the validator does not name; the model has no vocabulary for decoding a redeemer, so it gives no reason to compare with the chain's refusal (lambdasistemi/singular#347).

Run in the wire round-trip vocabulary, in the serialization session on the devnet:

- Boot the registry **tampered**.
- Book **wrong-index-key** on insertActive in **tampered**, build its fold and retarget the modify redeemer to index 5, which the validator does not name, keeping its fields; the ledger must refuse it in phase two.
- The ledger refuses the tampered fold of **wrong-index-key** in **tampered** in phase two, and the refusal names the state script.
- Boot the registry **control**.
- Book **wrong-index-control-key** on insertActive in **control** and fold it.

The requirement is kept unmet by operator ruling 2026-10-02 (narrowed #287; model follow-up lambdasistemi/singular#347); Singular's Lean has no vocabulary for decoding a redeemer, so it gives no reason to compare with the chain's.

### Each RequestAction (Update 0, Rejected 1) and MintRedeemer (Minting 0, Burning 2) constructor is exercised by an accepting witness or an action-attributed phase-2 refusal witness with a sound index discriminator; Migrating 1 unconditional refusal recorded with wire constructor retained.

Expected: partial: accept (Update 0, Rejected 1, Minting 0 with executing witnesses); Burning 2 unexercised named residual; Migrating 1 explicit gap. Planned evidence status: uncovered.

Source: issue #18 constructor coverage.

Outside the model's vocabulary: the model has no redeemer (lambdasistemi/singular#347): its operations here are a boot, a fold and a rejection, but the claim is the constructor each transaction carries on the wire.

Run in the wire round-trip vocabulary, in the serialization session on the devnet:

- Boot the registry **update**.
- The ledger accepted the boot of **update**, which carries Minting (index 0) among the redeemers of the policies it mints under.
- Book **update-witness-key** on insertActive in **update** and fold it.
- The ledger accepted the fold of **update-witness-key** in **update**, which carries Update (index 0) among the request actions of its modify redeemer.
- Boot the registry **rejection**, with one second of processing and one of retraction.
- Submit a request for **reject-witness-key** on insertActive in **rejection**.
- Once both windows close, a folder rejects the pending request in **rejection**.
- The ledger accepted the rejection in **rejection**, which carries Rejected (index 1) among the request actions of its modify redeemer.

Coverage stays partial: Burning (index 2) is a named residual: no accepting path: End, which burned the state token, was removed with the owner role (commit f3a68b1b); Migrating (index 1) is an explicit gap: refused unconditionally under the ownerless-registry ruling, with no attributed witness and no discriminator; the wire constructor stays at index 1.

### Script parameter application: parameter count and encoding published, applied hash derived in Haskell equals the on-chain address for every parameterized script.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 parameter binding.

Outside the model's vocabulary: the model has no byte representation: parameters and script hashes are below it; the application is checked off chain against the compiled blueprint.

Run in the wire round-trip vocabulary, locally against the compiled blueprint:

- The blueprint's state.state declares no parameters.
- The blueprint's request.request declares exactly the parameters statePolicyId (#/definitions/cardano~1assets~1PolicyId), cageTokenName (#/definitions/cardano~1assets~1AssetName), in that order.
- The blueprint's staking.staking declares no parameter field.
- The hash of state.state's unapplied code equals the blueprint's pin.
- The hash of request.request's unapplied code equals the blueprint's pin.
- The hash of staking.staking's unapplied code equals the blueprint's pin, when the blueprint carries it.
- One extra parameter application changes state.state's hash.
- Applying the request validator's parameters changes its hash, and swapping the two parameters gives another.

### Each ProofStep variant (Branch 0, Fork 1, Leaf 2) and Neighbor exercised by a fold the validator accepted.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 proof coverage.

Outside the model's vocabulary: the model takes no proof and no authenticated root (lambdasistemi/singular#346).

Run in the wire round-trip vocabulary, in the serialization session on the devnet:

- Boot the registry **proof**.
- Book **cs07-fork-A** on insertAbsent in **proof** and fold it.
- The fold of **cs07-fork-A** in **proof** proves with no proof step, every fork's neighbour is well formed, and the chain's root equals the committed trie's.
- Book **cs07-fork-B1294** on insertAbsent in **proof** and fold it.
- The fold of **cs07-fork-B1294** in **proof** proves with the proof steps Leaf, every fork's neighbour is well formed, and the chain's root equals the committed trie's.
- Book **cs07-fork-C11** on insertAbsent in **proof** and fold it.
- The fold of **cs07-fork-C11** in **proof** proves with the proof steps Fork, every fork's neighbour is well formed, and the chain's root equals the committed trie's.
- Book **cs07-fork-D127** on insertAbsent in **proof** and fold it.
- The fold of **cs07-fork-D127** in **proof** proves with the proof steps Leaf, Fork, every fork's neighbour is well formed, and the chain's root equals the committed trie's.
- Book **cs07-fork-E400** on insertAbsent in **proof** and fold it.
- The fold of **cs07-fork-E400** in **proof** proves with the proof steps Leaf, Branch, every fork's neighbour is well formed, and the chain's root equals the committed trie's.
- Across the folds, every proof step constructor appears: Branch (index 0), Fork (index 1), Leaf (index 2).

### OnChainTokenState's eight fields (root, maxFee, processTime, retractTime, applicationPolicy, activePolicy, absentPolicy, terminalPolicy) survive a chain round trip with the active policy varied between two registries.

Expected: accept. Planned evidence status: uncovered.

Source: issue #18 state round trip.

Outside the model's vocabulary: the model states the eight state fields abstractly as its configuration observation, compared on every step of the registry programs; the byte round trip of the encoded state with one policy varied is below it.

Run in the wire round-trip vocabulary, in the serialization session on the devnet:

- Boot the registry **base**.
- Boot the registry **varied**, its active policy set to another value.
- Read **base**'s state back from the chain: each field equals the one its boot submitted.
- Read **varied**'s state back from the chain: each field equals the one its boot submitted.
- **base**'s state datum on the chain encodes 8 fields.
- The field **varied**'s variation names differs from **base**'s, and the application policy does not.
- The four policies **base**'s state pins are derived: none is a placeholder, and the three token policies are distinct.

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

Outside the model's vocabulary: a fold whose owner's required signer is removed. The registry has no owner role, so there is no owner signer to remove; that no fold requires a signer is compared on every fold the programs run, through the transaction's required signers.

### One `insertActive` request folds on the open registry and places exactly one `(activePolicy, key)` token in the output at the address and inline datum the request named. A second `insertActive` at the same known key is refused `key-exists`. A two-request batch at two DISTINCT keys whose claimed mint agrees per kind but disagrees per `(kind, key)` is refused `net-mint-mismatch`.

Expected: accept the fold; refuse the same-key duplicate `key-exists`; refuse the two-key wrong-distribution batch `net-mint-mismatch`; both refusals carry an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.insert_active_transaction_row and Singular.Statements.fold_batch_claimed_mint_by_kind_key (Lean 854f56f); issue #173; open application, distinct refusal fixtures and the published trace limit.

Run as a tamper of an edge's transaction, in the chapter "Register a key and receive its active token" above.

### On a real devnet, `insertActive` then `updateTerminal` at one key: the active witness the insert delivered is the exact input the retirement burns, exactly one `(activePolicy, key)` is destroyed, no output carries it afterwards, and the committed trie leaf becomes Terminal. `updateTerminal` on an Unknown key and on an Absent key are refused with their own named reasons, each against an accepting control.

Expected: accept the insert and the retirement; the active quantity goes 1 -> 0 with the exact keyed `-1` mint burned from its token-bearing source input and the committed leaf reading `Terminal`; refuse `updateTerminal` on an Unknown key `key-unknown` and on an Absent key `not-booked`, each with an accepting control. Planned evidence status: uncovered.

Source: Singular.Statements.update_terminal_transaction_row and Singular.Statements.update_terminal_inversion (Lean 871c5df); issue #177; connected retirement and distinct refusal controls.

Run as a tamper of an edge's transaction, in the chapter "Retire a registration and burn its active token" above.

### On a real devnet, a request that is never folded leaves the queue by a reject or a retract. A reject must refund its owner the deposit; a retract by its owner must return everything the request held, through an output whose inline datum is the retracted request's own output reference. Each refund or return one lovelace short or to another key, a return bound to another request, and a retract spending the registry state beside it are refused by the chain and by the model, each beside the untampered exit of the same request, which both accept. The live consumer for the rule that only a retract returns the tip is the reject that keeps the tip beside the retract that returns it; fold consumers are in the fold rows. The guarantee that retract obligations depend only on the request remains a named gap: Lean proves this for every request and registry state, while this live run covers one registry state and no executable consumer varies it.

Expected: refuse a reject refunding the owner one lovelace short and to another key, `deposit-returned`, beside the accepted untampered reject; refuse a retraction returning one lovelace short, to another key and bound to another output reference, `deposit-returned`, and one spending the registry state beside it, `retract-state-spent`, beside the accepted untampered retraction. Planned evidence status: uncovered.

Source: Singular.Statements.exit_settles_on_lovelace_received and Singular.Statements.no_exit_strands_the_deposit; issue #258; Singular.Statements.only_retract_owes_the_tip: consumed by the live reject that keeps the tip and retract that returns it; fold consumers are in the registration (register-active-key) and retirement (retire-active-key) rows. Singular.Statements.obligations_read_only_the_request: named gap, proved in Lean for every request and registry state, but the live run covers one registry state and no executable consumer varies it.

Run as a tamper of an edge's transaction, in the chapter "A request that is never folded" above.

### On a real devnet, a folder may reject a pending request before its owner's retraction deadline. A reject while the request can still be folded, and one while its owner can still retract it, are each accepted by the chain and by the model, refund the owner the deposit and leave the registry state as it was. In each window a reject refunding the owner one lovelace short or to another key is refused by the chain and by the model.

Expected: accept a reject while the request can still be folded and one while its owner can still retract it, each refunding the owner the deposit and leaving the registry state as it was; refuse, in each window, a reject refunding the owner one lovelace short and one refunding another key, `deposit-returned`. Planned evidence status: uncovered.

Source: Singular.exitStep and Singular.exitAdmission: a reject carries no admission; Singular.obligations for a reject; Singular.Statements.admitted_exit_is_the_exit and Singular.Statements.built_transaction_settles; issue #320.

Run as a tamper of an edge's transaction, in the chapter "A folder rejects a request before its retraction deadline" above.

## Appendix: checking the evidence machinery

The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.

Each refused request's traced replay was evaluated from a capture of the refused transaction, the outputs it spends, the protocol parameters and the era history:

Transaction `b761a6614562d559d735e271809df8529c1cedea093936c7593d1b0fb750a0cc`: capture `b8fc98aa6d8b3a5427a3f16d21f8d8016251235dfa89435085dae870cdfd35fa` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `f5b59655e9eff00eaf039680fa11567d42e2eb55dc1b9ec648cd7c0b01aab064`: capture `19fa6ebcc6ffa554fc090e84a215ed2d6d6116031ef773e281b9be5c6b15c892` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `49575cb845119a70bc70785962072470b1f6d23e6e923bb135808a3a614ce7d3`: capture `49649c66670bd9dbb480dfdeee56432b99b4f9fd6efd2c7d208ada975c2f7fdc` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `c4581d063ee4a74f9b10cf09ee9876db58c687a9c6657b6ca30f0176f9f9689a`: capture `398b7c4a8a8fee7cafc54d706309ff85fada1ed557794097f072e9f7995e3e35` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `2e7ed3e582a23ae1314a487a4f309c18841564ba23dfb807b892c9941e7b2a26`: capture `db747edf056dbac3270c034e088dcb3f7dd5972036601b1118ca2bcc72427f27` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `c78e381148f3f6bed799d9ca0c1175d00fda8f0f8e848f3643575864b1d589f3`: capture `6928b82244861a0697ede2782ab29c17007af868e47b1d3d2d5be0f4ed46f382` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `0450885a8131a49b15084f20d7258de017faa4f2fb124fdf3b40b4a33e3429bc`: capture `d1162f41d5b82f2d78f7f22b6b1d0e54fe55e8f1f86cfa4d562673e68c0ed6b0` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `f4bc96721ceccf523a77bd0229c63d12a550f5da1fa92f251fc96defc223375b`: capture `df4fd13fae7d2efb2d5649a0fb330c09aa41fbe54ed505f1f60f10b22209f610` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `13608a82a535ac4ff9f6f7be5d1067aa03882c8da3bacf5ff4f47eb9f7dedae4`: capture `5af8832a385568b801e7f0981923b1406c78b5f1c82def262836ffd1030495d1` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `dee0311d9dcb7ceb9c90bfc93e8c07b0a595160ebb464fae8988439c9c9b6ce7`: capture `adcfb22d898f0992fc6668ee5e4ce3dc8b78b0863419b6d36c609cd78fdc862c` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `dc603cab791ae9e5f9286d5bb20e0bf4a5bfc821d8aeb883c7dfad80ec072608`: capture `a72f5e3f26dfb1e7ebc2b15fa55d5b87fcdcb6f83fa88e45abbf6fd02fefdcef` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `e647200319598615db45e8128b54cc3ceb8b69be8c0b3ce743818612c648029f`: capture `632a58a657a03d1bf522952dfd4021a485eda9c49eb911c80fd08870fe27003e` of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61`.

Transaction `99a791e76908201fecc6b5d312c0aaf0a9fd441a837ef12238379a85e897cbc0`: capture `2de1ca0ac504e96a69128c2c5aa512c81a3129e36391dbfb44c5702800385993` of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61`.

Transaction `6f9c9b5cf108b73381db770ca393f327fe6a351da158a8e24f83bb358ca69b71`: capture `e335084442ba96cc80549cf6db6d737eed5307e9f9d5be9a1da04dae7f36aa48` of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61`.

Transaction `408619b7e62a3e655f10bafc7c92ee51966b76f96d051433ee1b694b5cedde93`: capture `1265251d86bfae86bd01cd40829fce6eca40ca6a1c5dbe6dcee1511925779c2b` of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61`.

Transaction `408619b7e62a3e655f10bafc7c92ee51966b76f96d051433ee1b694b5cedde93`: capture `1265251d86bfae86bd01cd40829fce6eca40ca6a1c5dbe6dcee1511925779c2b` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `ad78611d74c0715441fb9be7c4bf64ea67fc19cb7b8227e769829b5d7bf75858`: capture `105d6f80a24bd601068f9d74c7407b9ad1b316579e3a0d0174433e91ebe371f6` of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61`.

Transaction `25254d410de5ea48efa837a677645c9452265b4fde527db8d1a856ccfb538909`: capture `5e48be54a773d7cc16a0649cf51dac94f22b00529e54d2d2dfd68c9ca3685e23` of the deployed script `af8e7a68622a5e12a07149de326a4825360ba9e04f8aa7e80c89fd61`.

Transaction `4bd1154e916137027fa9b01b7772f75c391a1ab2942d951f6d498b1da7411266`: capture `7ea876e8df2bb96ce0af670ea16a39a404cd591fe851431adb633cdc4df99307` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `05e77cf38308e1f9d4828f7713901cc6e78b1234885502b00444d82f2da82444`: capture `acb73838405ec378ba2ab5c163d4f0c98fb69a6e7ffc192ae6aa785d3f9bffbb` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `d3943ebe5e6e9395c0d7309523b2ad27fa5f73d5b905f508387f5bf4646e2d05`: capture `15e7803a7ed99cd5e7da5be49467c3e0dbcbc77b9233ed60d7c0c16f573123a0` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `1b0df9fc4901baa386fdc8e7b9196a4357fb8eeb897d8fe7c757100bd927a22b`: capture `fcf9582f5bd77c87e189924fb5a27fca0038aeb3c0774fcfe7f3f192060d68c6` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `a6a4f66aefd697b1f8a82543d878598b1cb5cabaa8c0c97b1e1b46c3517a84b3`: capture `db1826f667d714e7cc90e4612b3f69a536d2df10a0ca1e937b57c589d3999681` of the deployed script `732ae4bd54bf91d87fc709d6341b247d4b7c4a4e2c7dfe8b4d1de468`.

Transaction `831ffdc962d722c9df20785df8d9a089013e5bc8e66d069e47bd8693d7b33c31`: capture `019175a59341a00b738b1e23aa90367f455b034bf318f1f5cd7b58bdc3b1c542` of the deployed script `732ae4bd54bf91d87fc709d6341b247d4b7c4a4e2c7dfe8b4d1de468`.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.

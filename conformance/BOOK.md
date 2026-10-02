# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `1a071c76e2f92346db18619ed8d8ab1d35706bda` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Registration compared 7 requests: 4 accepted and 3 refused on chain.

Unsupported chain folds: 0.

Batches submitted in one transaction: 1, 0 accepted and 1 refused on chain.

The extra-signer registration was accepted on chain (transaction `fde603558df69cd65b00f9e674d416336f992e9f8cac8039319a55c9891087a0`); the comparison detected the difference at `tx.signers`.

The insertActive was refused on chain (transaction `7971672b51514fd16473ad33533e545c3c7beeb7dc47a2cb5dceb96e46609e3b`); the model refused it for `key-exists`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-exists`.

The other-address insertActive was refused on chain (transaction `e35332e867ee60e7693cf302cd446e2cf2585bf768398db877139e6f36dfa5d5`); the model refused it for `destination`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `destination`.

The short-by-one insertActive was refused on chain (transaction `7a8f92689b4431e30560e5b70c223f563972b763062d871f8ac6c0f75ca60aa8`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The fold of 2 requests in one transaction, tampered mint-on-first-key, was refused on chain (transaction `6c13268eae743000e41b3de3a2702f214a7006fefc84a139baf157b54fbc281f`); the model's `foldBatch` refused it for `net-mint-mismatch`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `net-mint-mismatch`.

Code revision: `1a071c76e2f92346db18619ed8d8ab1d35706bda` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Occupied-key insertion compared 3 requests: 2 accepted and 1 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `6350663ed0d818a76997d0d1328b3df43380c60921b7af0c4cc6e4208eb91649`); the model refused it for `key-exists`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-exists`.

Code revision: `1a071c76e2f92346db18619ed8d8ab1d35706bda` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Retirement compared 11 requests: 7 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The updateTerminal was refused on chain (transaction `ccfc5f291f1b76f10e22a136d6e2d924fbce94ef04fbb72ca3887f2fcfcfd33d`); the model refused it for `not-booked`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `not-booked`.

The updateTerminal was refused on chain (transaction `6ddde664549c752f61f27aa906ccfac9b2b67c209cf6725429ce73d568a56bc1`); the model refused it for `key-unknown`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-unknown`.

The short-by-one deleteActive was refused on chain (transaction `cbd668cbbe23bb598d824e5b56a275fa8f3f96fdd3a643a763b3ed39691583c8`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address deleteActive was refused on chain (transaction `dc9bb02301fc5cc7bdde0d7437f58fa8350e747c2acafdc3dd16e8baea0d1be8`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

Code revision: `1a071c76e2f92346db18619ed8d8ab1d35706bda` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Rejection and retraction compared 10 requests: 2 accepted and 8 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `7b9436e1ed6e203e57263253caebcda2da50c93fb3e6a3b74d67911b95c3fb49`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `49279a1e4ba46333588fae7efd91f5aa865c2ad918178b2b6fbee492444db85f`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The short-by-one retract of insertActive was refused on chain (transaction `9c8bafdff1368692e1e065238ca1adc3a73b7bd419b8ef212c8acfb1988ec82a`); the model refused it for `deposit-returned`. The traced replay of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e` (traced build `951d566adb6c91c487797545470220022bdcc489832a0df2af7793b7`) failed with `deposit-returned`.

The other-address retract of insertActive was refused on chain (transaction `783d83ac4e82e42276777b852fd9ad16d9e43ea4f8ff8dca52918cff7ff5a41a`); the model refused it for `deposit-returned`. The traced replay of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e` (traced build `951d566adb6c91c487797545470220022bdcc489832a0df2af7793b7`) failed with `deposit-returned`.

The other-reference retract of insertActive was refused on chain (transaction `91883a20ef7da52541e3b54e3408a4454d48a0b98a0207e9204ec9a205cb8a8b`); the model refused it for `deposit-returned`. The traced replay of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e` (traced build `951d566adb6c91c487797545470220022bdcc489832a0df2af7793b7`) failed with `deposit-returned`.

The state-spent retract of insertActive was refused on chain (transaction `c347b8e6516dcbbc1150b872ef5c713d737f3d2720880f7e2f58a9a15ac8e725`); the model refused it for `retract-state-spent`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `missing-action`. The traced replay of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e` (traced build `951d566adb6c91c487797545470220022bdcc489832a0df2af7793b7`) failed with `retract-state-spent`.

The retract of updateTerminal was refused on chain (transaction `347f2a42c2c33401160a86f33b4f22bbc9cde5e8246240c5b379e2c56f462c69`); the model refused it for `withdraw-insert-only`. The traced replay of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e` (traced build `951d566adb6c91c487797545470220022bdcc489832a0df2af7793b7`) failed with `withdraw-insert-only`.

The unsigned retract of insertActive was refused on chain (transaction `04a141a4510bca72af41b01cda4fc8570a0437fb59e0b2d61163b5a070788926`); the model refused it for `retract-owner`. The traced replay of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e` (traced build `951d566adb6c91c487797545470220022bdcc489832a0df2af7793b7`) failed with `retract-owner`.

The exit chapter compared both admission refusals: the unsigned insertion retraction (transaction `04a141a4510bca72af41b01cda4fc8570a0437fb59e0b2d61163b5a070788926`) was refused by the model for `retract-owner`, and the pending update retraction (transaction `347f2a42c2c33401160a86f33b4f22bbc9cde5e8246240c5b379e2c56f462c69`) for `withdraw-insert-only`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `6375c9e84167cf4cc8521ac4c495386138d7bc0c0a2eb203e7f5858f5a83cf47`.

Code revision: `1a071c76e2f92346db18619ed8d8ab1d35706bda` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Early rejection compared 6 requests: 2 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `7b9aa3f8618d380fd0b39738e2800b0a82a83576df1d93f87f0c46eb1dc4cb8f`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `7336be9ac059b74a0cb1f9036b0ab30a6ae8bafb3673c94ff1226f8dbf06a00b`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The short-by-one reject of insertActive was refused on chain (transaction `574f59238165d12f714bc9a6e4a36f15badac2a7843684f6f15f15f4bf862892`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `b5ddcad5fc6277678d52782dadafd9055cfaab96a39cb59e6e31d5b4627c09fc`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

Code revision: `1a071c76e2f92346db18619ed8d8ab1d35706bda` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Retraction window compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The before-phase-2 retract of insertActive was refused on chain (transaction `69c76e095b1b6049c6e445ee9f77e139c3604e153e1d2d7dc8aa7e1e104e4f61`); the model refused it for `not-phase2`. The traced replay of the deployed script `e9d1656301ec42b10967c96e77e0fcd2d9964f8b9abf750946301c14` (traced build `870a23c0e3e2780c7bc2d6b93213596f8a9504b7a17bfac2a7c60224`) failed with `not-phase2`.

The after-phase-2 retract of insertActive was refused on chain (transaction `3d86db7940b1260409f8027041ad2528386f42c92995f6432577c7ede5cac675`); the model refused it for `not-phase2`. The traced replay of the deployed script `e9d1656301ec42b10967c96e77e0fcd2d9964f8b9abf750946301c14` (traced build `870a23c0e3e2780c7bc2d6b93213596f8a9504b7a17bfac2a7c60224`) failed with `not-phase2`.

The window chapter compared both finite timing refusals: transaction `69c76e095b1b6049c6e445ee9f77e139c3604e153e1d2d7dc8aa7e1e104e4f61` before phase 2 and transaction `3d86db7940b1260409f8027041ad2528386f42c92995f6432577c7ede5cac675` after phase 2. The model refused both for `not-phase2`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `622b22b13dab210ae5328cef60181dae03b9d56c3a6d349ed309755554d5f7b7`.

Code revision: `1a071c76e2f92346db18619ed8d8ab1d35706bda` (clean working tree).

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

### A rival registry initialized from a second seed exists and is accepted by the ledger; canonical authentication rejects it on name.

Expected: rival accepted on chain; authentication rejects. Planned evidence status: uncovered.

Source: cardano-keri: canonical registry authentication distinguishes a rival seeded registry; issue #16.

### Negative control: an authenticator that checks only policy+address, not the derived name, accepts the rival.

Expected: control must fail. Planned evidence status: uncovered.

Source: Rival-registry authentication discrimination control (rival-seed-authentication).

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

Transaction `7971672b51514fd16473ad33533e545c3c7beeb7dc47a2cb5dceb96e46609e3b`: capture `35a3e5df8d579763a52fca1e0c8f5386bd1e350fc3f3f0233d2fd047269cdaf6` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `e35332e867ee60e7693cf302cd446e2cf2585bf768398db877139e6f36dfa5d5`: capture `f31572583f20e8b2efa94046f9ef447a14a0f75bbcf888e0a61590a6ac2feff7` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `7a8f92689b4431e30560e5b70c223f563972b763062d871f8ac6c0f75ca60aa8`: capture `e420b1f2e9ba9d5991729c2121ff508b9d08045559a288d7b6cfab984ddd44ef` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `6c13268eae743000e41b3de3a2702f214a7006fefc84a139baf157b54fbc281f`: capture `6af3c989f694576e6cee473308f5d1e5251776863fa89f460db8e6943613f5e2` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `6350663ed0d818a76997d0d1328b3df43380c60921b7af0c4cc6e4208eb91649`: capture `d9a522a3db69107756a52c0e6865e3b1adfaa17a140cde089edc4d74bed78a9a` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `ccfc5f291f1b76f10e22a136d6e2d924fbce94ef04fbb72ca3887f2fcfcfd33d`: capture `080edb54a0293da23b5c55f48c7668e6e41705280cf4807a549cff7b8140545d` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `6ddde664549c752f61f27aa906ccfac9b2b67c209cf6725429ce73d568a56bc1`: capture `3781b8efd56e9185022f32324136dee6a28dc0006c30339dd9620bf6885f09f3` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `cbd668cbbe23bb598d824e5b56a275fa8f3f96fdd3a643a763b3ed39691583c8`: capture `878c0e738ef604eb2509963e4a9558f16bae1fc0ace612dc6897871f60bed66f` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `dc9bb02301fc5cc7bdde0d7437f58fa8350e747c2acafdc3dd16e8baea0d1be8`: capture `311cf2be524bde016cce0a98cdeddc196a9ada401339f64bf44e99593facc147` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `7b9436e1ed6e203e57263253caebcda2da50c93fb3e6a3b74d67911b95c3fb49`: capture `fdaa7f2ce19427211b648efa85799f2779fa475ae9be2be8d5a00364b53d6052` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `49279a1e4ba46333588fae7efd91f5aa865c2ad918178b2b6fbee492444db85f`: capture `090152b5c1dcab287acc9e21b237c50d9b95ffccb4eb1b5036addd1f200e73e7` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `9c8bafdff1368692e1e065238ca1adc3a73b7bd419b8ef212c8acfb1988ec82a`: capture `4db9598c3ae73d7ad03584a56e415b73197c01516057618cc20015891bcf1be0` of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e`.

Transaction `783d83ac4e82e42276777b852fd9ad16d9e43ea4f8ff8dca52918cff7ff5a41a`: capture `840045de220625f3c13eb8dff2aca345a6fa8e53c67a56b258b440d6f0a3857a` of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e`.

Transaction `91883a20ef7da52541e3b54e3408a4454d48a0b98a0207e9204ec9a205cb8a8b`: capture `35b672b48e13bf9ac01b95b46d471b1a44efac6ed82ffd08828d8df8d0b1c2ea` of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e`.

Transaction `c347b8e6516dcbbc1150b872ef5c713d737f3d2720880f7e2f58a9a15ac8e725`: capture `91b5d48b114aab6d8230a38b7c77c894b45a455b91052bcc6e8a58ef3e5cb8f6` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `c347b8e6516dcbbc1150b872ef5c713d737f3d2720880f7e2f58a9a15ac8e725`: capture `91b5d48b114aab6d8230a38b7c77c894b45a455b91052bcc6e8a58ef3e5cb8f6` of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e`.

Transaction `347f2a42c2c33401160a86f33b4f22bbc9cde5e8246240c5b379e2c56f462c69`: capture `76d450666404a17cc75a6d63c78d5c5da8155802e20c3edffaeca2fab10c507b` of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e`.

Transaction `04a141a4510bca72af41b01cda4fc8570a0437fb59e0b2d61163b5a070788926`: capture `e3d1981f24a5e66d1348a3ef0a311a143921116219a9bd7b691fbcdf139695ba` of the deployed script `83d205cc37fa7490ae5a9dae9346a606f34145bcca3e8cd3822ce94e`.

Transaction `7b9aa3f8618d380fd0b39738e2800b0a82a83576df1d93f87f0c46eb1dc4cb8f`: capture `234ebd2fe6c4df7c5f4597db1a1417067d90fc6bf356b8541e6d6888285d7bbd` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `7336be9ac059b74a0cb1f9036b0ab30a6ae8bafb3673c94ff1226f8dbf06a00b`: capture `45954430d90e1b991ac4c4559a53d04f7c32868c9a819e59248cd3a9cbeea07b` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `574f59238165d12f714bc9a6e4a36f15badac2a7843684f6f15f15f4bf862892`: capture `533a05520336dcaa901c3c767a60a2a407c9b2ead16a3af4f0ef9bb06e147a45` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `b5ddcad5fc6277678d52782dadafd9055cfaab96a39cb59e6e31d5b4627c09fc`: capture `5b393a1f9bd4465b5a936a8285cce68faad0f6f2d2e856c044e82a35a3d92c6b` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `69c76e095b1b6049c6e445ee9f77e139c3604e153e1d2d7dc8aa7e1e104e4f61`: capture `14b7ba67d05cce31c59035726f836e43fa79ffdf345719e863854ae023bab93e` of the deployed script `e9d1656301ec42b10967c96e77e0fcd2d9964f8b9abf750946301c14`.

Transaction `3d86db7940b1260409f8027041ad2528386f42c92995f6432577c7ede5cac675`: capture `e91af46eabcb6e0d2d5aef58a9508e05bf4802d17fab0b893da9f1c3073cca98` of the deployed script `e9d1656301ec42b10967c96e77e0fcd2d9964f8b9abf750946301c14`.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.

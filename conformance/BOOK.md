# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `d0f430938e016c74c5c9527d0e2d9ae44282882a` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Registration compared 7 requests: 4 accepted and 3 refused on chain.

Unsupported chain folds: 0.

Batches submitted in one transaction: 1, 0 accepted and 1 refused on chain.

The extra-signer registration was accepted on chain (transaction `c4a1fb869bf4addd449e64e893b916767b6f9258dec49df48cdaa046dd490cc9`); the comparison detected the difference at `tx.signers`.

The insertActive was refused on chain (transaction `59b468c31803de9a289005c80332ad393ab58b9f50490f9885b3d0bc2188842d`); the model refused it for `key-exists`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-exists`.

The other-address insertActive was refused on chain (transaction `54439edfa05076db07b0c34705af6562678da76accdabb5cbe2dc0c179a71660`); the model refused it for `destination`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `destination`.

The short-by-one insertActive was refused on chain (transaction `9c8614acf5b2126a57d3f302b9cde8b9073de4d6e3518815a9b1953bf74527da`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The fold of 2 requests in one transaction, tampered mint-on-first-key, was refused on chain (transaction `9f76b77ba4938122a3ecaee3a2a361b3339f0ff45539148200a15a766b1e1c87`); the model's `foldBatch` refused it for `net-mint-mismatch`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `net-mint-mismatch`.

Code revision: `d0f430938e016c74c5c9527d0e2d9ae44282882a` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Occupied-key insertion compared 3 requests: 2 accepted and 1 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `78c70c559aa1fba42ab5f29f322917be41355140ebc4cda795611f61bceaf350`); the model refused it for `key-exists`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-exists`.

Code revision: `d0f430938e016c74c5c9527d0e2d9ae44282882a` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Retirement compared 11 requests: 7 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The updateTerminal was refused on chain (transaction `9cab74cc09c4928a431a6b6f2b745ba7a53ea49f2822c5adabc56e673914d9c8`); the model refused it for `not-booked`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `not-booked`.

The updateTerminal was refused on chain (transaction `34e0aaaceaf066668835fc3fcce510e312c222d0cdcbda5ed265d1dde76aeb57`); the model refused it for `key-unknown`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `key-unknown`.

The short-by-one deleteActive was refused on chain (transaction `01d9556861cdf22c0d3275330f0564453404aeff6c042a28c43cbfdaed250e0c`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address deleteActive was refused on chain (transaction `282a9453944df00cb47062545702614bf40395ecf933369b4f105b0ce1c2a486`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

Code revision: `d0f430938e016c74c5c9527d0e2d9ae44282882a` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Rejection and retraction compared 10 requests: 2 accepted and 8 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `3a5384ec93d057efb74b01ba80beb2f9ab0840b69da77d469d782a5abc29d6c4`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `e23226d79d4b8950d6a9cfa9c3a6807361745d9a5bb6a0c9280d27821900c624`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The short-by-one retract of insertActive was refused on chain (transaction `c6a70611aea693cbf773de943663469fb8d9e0d5885eeca7426623c3052446f1`); the model refused it for `deposit-returned`. The traced replay of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c` (traced build `657c9fa9e652d6b4e75822a31f82b9aabd0080aaace8c3d4f9c88942`) failed with `deposit-returned`.

The other-address retract of insertActive was refused on chain (transaction `cd7764c7c9166b2efdd6e0f1d7da527136f5dd95022f6ba8daf99b8919771ade`); the model refused it for `deposit-returned`. The traced replay of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c` (traced build `657c9fa9e652d6b4e75822a31f82b9aabd0080aaace8c3d4f9c88942`) failed with `deposit-returned`.

The other-reference retract of insertActive was refused on chain (transaction `bc422bc36a6d61180617df77e9283724e5307a7c6ca5bc1c12727c52cc57b0c2`); the model refused it for `deposit-returned`. The traced replay of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c` (traced build `657c9fa9e652d6b4e75822a31f82b9aabd0080aaace8c3d4f9c88942`) failed with `deposit-returned`.

The state-spent retract of insertActive was refused on chain (transaction `9e3a49993f869891f64d400936ca28a13c51173abb155878ebeee15776a42cec`); the model refused it for `retract-state-spent`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `missing-action`. The traced replay of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c` (traced build `657c9fa9e652d6b4e75822a31f82b9aabd0080aaace8c3d4f9c88942`) failed with `retract-state-spent`.

The retract of updateTerminal was refused on chain (transaction `a582b14332680c9efdefc2e43ca2fe9c5621eaaa00a9e17d562eacf95e42150e`); the model refused it for `withdraw-insert-only`. The traced replay of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c` (traced build `657c9fa9e652d6b4e75822a31f82b9aabd0080aaace8c3d4f9c88942`) failed with `withdraw-insert-only`.

The unsigned retract of insertActive was refused on chain (transaction `6155f4513e8038d7be9d9382e7a61f54963157a438bd84a5a20f6b8183b7d936`); the model refused it for `retract-owner`. The traced replay of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c` (traced build `657c9fa9e652d6b4e75822a31f82b9aabd0080aaace8c3d4f9c88942`) failed with `retract-owner`.

The exit chapter compared both admission refusals: the unsigned insertion retraction (transaction `6155f4513e8038d7be9d9382e7a61f54963157a438bd84a5a20f6b8183b7d936`) was refused by the model for `retract-owner`, and the pending update retraction (transaction `a582b14332680c9efdefc2e43ca2fe9c5621eaaa00a9e17d562eacf95e42150e`) for `withdraw-insert-only`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `e9f43ba024248f229362895bf0848d86f8278cb7e83dde0455ed82916cdac99d`.

Code revision: `d0f430938e016c74c5c9527d0e2d9ae44282882a` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Early rejection compared 6 requests: 2 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `8de0e2fef69fee33c7e6d9efd3f5fcae83f0fa1ccaee0e05a5311e90386fcb03`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `099a7167b5230186907a8debf6a704799c64e9d77af6f53fdbff340c389f9c1d`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The short-by-one reject of insertActive was refused on chain (transaction `90e4d006fbd43a4514300566583cbf3b2d721de5a86b2ada65be726cc75d31e8`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `8040d18e776c822686a59bcf78e1089b09685d65575f94f3f7d9d49121db26ff`); the model refused it for `deposit-returned`. The traced replay of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c` (traced build `25ddcbca82750e381ae564b4839d134dac33d855af0669958be46573`) failed with `deposit-returned`.

Code revision: `d0f430938e016c74c5c9527d0e2d9ae44282882a` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c request:5203be8c0e949c878b4b84dbc729f12c50e45d6c67fb4c6d80370cd4`.

Retraction window compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The before-phase-2 retract of insertActive was refused on chain (transaction `67a8b61ddc0b9effb0efe54ebfaf17314d40aca6399a0d4e74395e84e15f7c24`); the model refused it for `not-phase2`. The traced replay of the deployed script `ee1f1ac36ae0681020c34822688932a3312944159ae096aa3138ede7` (traced build `20d3fd70b7b431c12f819085f9bab9c0e82e6b34ef7ac71b2405a131`) failed with `not-phase2`.

The after-phase-2 retract of insertActive was refused on chain (transaction `27f60abb65b4749bb8456f9ed5259c547bf60b87b25bc06f6b61cdf839a31f0b`); the model refused it for `not-phase2`. The traced replay of the deployed script `ee1f1ac36ae0681020c34822688932a3312944159ae096aa3138ede7` (traced build `20d3fd70b7b431c12f819085f9bab9c0e82e6b34ef7ac71b2405a131`) failed with `not-phase2`.

The window chapter compared both finite timing refusals: transaction `67a8b61ddc0b9effb0efe54ebfaf17314d40aca6399a0d4e74395e84e15f7c24` before phase 2 and transaction `27f60abb65b4749bb8456f9ed5259c547bf60b87b25bc06f6b61cdf839a31f0b` after phase 2. The model refused both for `not-phase2`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `7b1d1f864bc107f9b9fc83f10f4455df50c1b35b5bac9fc71ba211a3ba7cfdc3`.

Code revision: `d0f430938e016c74c5c9527d0e2d9ae44282882a` (clean working tree).

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

Refusals outside these chapters, by row, recorded in the receipts of the conformance session rather than in this book. Three have no counterpart in the model, so their model comparison is unmet; each receipt shows what the traced replay of the refusal recorded. CS04, a fold redeemer at a wrong constructor index: the model has no vocabulary for decoding a redeemer; the witness script names its refusal, while the state and request scripts fail on a path that carries no user-defined trace, so their live refusal reason is not observed (lambdasistemi/singular#347). CG10, a fold whose proof was built against a root the registry has since superseded: the model takes no proof and no authenticated root and admits the insertion on that unoccupied key, so nothing compares with the chain's reason (lambdasistemi/singular#346). CG12, a fold carrying an action beyond its requests, and one missing an action: the model takes no action list (lambdasistemi/singular#345). The other refusals are compared with the model's batch questions, each against the reason the traced replay admits for the state script: CG11, an empty fold, with the fold batch over no request; CG19, two rejects whose refunds are crossed and two whose first refund is short, with the reject batch judged on the refunds the transaction pays; and CG09's control, a reject refunding its owner one lovelace short, with the reject batch of that one request. CG09 itself, a reject while the request can still be folded, is accepted by the chain and by the model, while the consuming project requires it refused: that requirement stays unmet by ruling. Where a reject pays its owner, the chain and the model read the payment differently: the chain requires the output in each refund's position to pay that request's owner what it is owed, while the model credits an owner the sum of every output at its key. A reject paying its owner short in the refund's position and the rest in another output at the same key is refused by the chain and accepted by the model. No run submits that shape: every compared reject, here and in the conformance session, leaves no other output at its owners' keys, so their agreement holds for that shape only, and the decision is with the user. Whether CG11, CG12 and CG19 meet the consuming project's requirements remains unresolved; the three rows stay held.

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

### On a real devnet, a request that is never folded leaves the queue by a reject or a retract. A reject must refund its owner the deposit; a retract by its owner must return everything the request held, through an output whose inline datum is the retracted request's own output reference. Each refund or return one lovelace short or to another key, a return bound to another request, and a retract spending the registry state beside it are refused by the chain and by the model, each beside the untampered exit of the same request, which both accept. The live consumer for the rule that only a retract returns the tip is the reject that keeps the tip beside the retract that returns it; fold consumers are in the fold rows. The guarantee that retract obligations depend only on the request remains a named gap: Lean proves this for every request and registry state, while this live run covers one registry state and no executable consumer varies it.

Expected: refuse a reject refunding the owner one lovelace short and to another key, `deposit-returned`, beside the accepted untampered reject; refuse a retraction returning one lovelace short, to another key and bound to another output reference, `deposit-returned`, and one spending the registry state beside it, `retract-state-spent`, beside the accepted untampered retraction. Planned evidence status: uncovered.

Source: Singular.Statements.exit_settles_on_lovelace_received and Singular.Statements.no_exit_strands_the_deposit; issue #258; Singular.Statements.only_retract_owes_the_tip: consumed by the live reject that keeps the tip and retract that returns it; fold consumers are in the registration (CG21) and retirement (CG22) rows. Singular.Statements.obligations_read_only_the_request: named gap, proved in Lean for every request and registry state, but the live run covers one registry state and no executable consumer varies it.

### On a real devnet, a folder may reject a pending request before its owner's retraction deadline. A reject while the request can still be folded, and one while its owner can still retract it, are each accepted by the chain and by the model, refund the owner the deposit and leave the registry state as it was. In each window a reject refunding the owner one lovelace short or to another key is refused by the chain and by the model.

Expected: accept a reject while the request can still be folded and one while its owner can still retract it, each refunding the owner the deposit and leaving the registry state as it was; refuse, in each window, a reject refunding the owner one lovelace short and one refunding another key, `deposit-returned`. Planned evidence status: uncovered.

Source: Singular.exitStep and Singular.exitAdmission: a reject carries no admission; Singular.obligations for a reject; Singular.Statements.admitted_exit_is_the_exit and Singular.Statements.built_transaction_settles; issue #320.

## Appendix: checking the evidence machinery

The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.

Each refused request's traced replay was evaluated from a capture of the refused transaction, the outputs it spends, the protocol parameters and the era history:

Transaction `59b468c31803de9a289005c80332ad393ab58b9f50490f9885b3d0bc2188842d`: capture `61f28bcc3318e572c5f4204e1b74b294fb542bf22accd4b95ac106c1f5d726c2` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `54439edfa05076db07b0c34705af6562678da76accdabb5cbe2dc0c179a71660`: capture `3705403601f3525046ff8a370cd58223188b7b1dbe4d76b4beb3a6b06d614c71` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `9c8614acf5b2126a57d3f302b9cde8b9073de4d6e3518815a9b1953bf74527da`: capture `fc5a099e935da23da11f88417e97decf680deee81a4f41b1d403a6a7dc904246` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `9f76b77ba4938122a3ecaee3a2a361b3339f0ff45539148200a15a766b1e1c87`: capture `09e4463f4b9a13c1adeaf0b278f29af262305e6e1847d75f43c573e712826089` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `78c70c559aa1fba42ab5f29f322917be41355140ebc4cda795611f61bceaf350`: capture `d8fc29ac2dbe3253c8f5d7c450ae37eeef636ed1c946c818689d529574a38d01` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `9cab74cc09c4928a431a6b6f2b745ba7a53ea49f2822c5adabc56e673914d9c8`: capture `20080010bd026480d5eb74235d93d03124d33c839dae39bdc42569c09edba998` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `34e0aaaceaf066668835fc3fcce510e312c222d0cdcbda5ed265d1dde76aeb57`: capture `8368cb42af566f501531f09650a5ab357e89c7fed71341911326f5eb96446cc6` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `01d9556861cdf22c0d3275330f0564453404aeff6c042a28c43cbfdaed250e0c`: capture `a4a148516a6bb2f37a0d2e22fef217df99d1418648114b7cd6cb67355dbc58e6` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `282a9453944df00cb47062545702614bf40395ecf933369b4f105b0ce1c2a486`: capture `473764a70e49f967f758f1b2ef2ac57f9977f9a9b54ca9fcb7d7fdf5af2b0a11` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `3a5384ec93d057efb74b01ba80beb2f9ab0840b69da77d469d782a5abc29d6c4`: capture `b318eae187bf904f63862d2807390e4030cd66d7b1ad4e82a60d71df87202f77` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `e23226d79d4b8950d6a9cfa9c3a6807361745d9a5bb6a0c9280d27821900c624`: capture `2923e5d5330994e678e9f1ca2e9121b309806a6c7f898b4a85a4340cdfb278f4` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `c6a70611aea693cbf773de943663469fb8d9e0d5885eeca7426623c3052446f1`: capture `7bcebcd119b832814a09e303eed0a0d648129a98ba900f2cc609c8efedbbb572` of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c`.

Transaction `cd7764c7c9166b2efdd6e0f1d7da527136f5dd95022f6ba8daf99b8919771ade`: capture `ff8fc471de223dd29ad1d18bf49995e166d0befb372fad182c1347e2d8f7234a` of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c`.

Transaction `bc422bc36a6d61180617df77e9283724e5307a7c6ca5bc1c12727c52cc57b0c2`: capture `f994646dc868f698a4bcb91102296be6ac3846de3e840b4f95e412ac060c1b46` of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c`.

Transaction `9e3a49993f869891f64d400936ca28a13c51173abb155878ebeee15776a42cec`: capture `42173516eb2cd2b519bdd97d31f58314d5e36dd3dcb7e6180a555b7795eb3b5d` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `9e3a49993f869891f64d400936ca28a13c51173abb155878ebeee15776a42cec`: capture `42173516eb2cd2b519bdd97d31f58314d5e36dd3dcb7e6180a555b7795eb3b5d` of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c`.

Transaction `a582b14332680c9efdefc2e43ca2fe9c5621eaaa00a9e17d562eacf95e42150e`: capture `9fde17b26ad00ee64c8cc8a456dd8d72be47c0546af31a3198bfee6599503f47` of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c`.

Transaction `6155f4513e8038d7be9d9382e7a61f54963157a438bd84a5a20f6b8183b7d936`: capture `513f03cae4fbffcf4ebbdf9633f5474d999ece6ae20ef22739b1f0d5920b5f2b` of the deployed script `f93d1588050a8ee68b95ff756c461b79399fa0a88af8640239d7dc2c`.

Transaction `8de0e2fef69fee33c7e6d9efd3f5fcae83f0fa1ccaee0e05a5311e90386fcb03`: capture `7d2a995c14f489eaec29d3d1191227c3c54b07729fcdaa52f0f6a2471b237ff4` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `099a7167b5230186907a8debf6a704799c64e9d77af6f53fdbff340c389f9c1d`: capture `9fe6e2d60050a7e9df8eeeddb0ec32611eafbcf75d366fb3711ca008f9dd160d` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `90e4d006fbd43a4514300566583cbf3b2d721de5a86b2ada65be726cc75d31e8`: capture `b12a1d43db6377ac2ed3b5816113d818baabd34c0adff679f0aeb7958b1727d2` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `8040d18e776c822686a59bcf78e1089b09685d65575f94f3f7d9d49121db26ff`: capture `99bd5bd0ca2c5ab71380b056a05f9b028a583c40742367594a19017328f7ca42` of the deployed script `7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c`.

Transaction `67a8b61ddc0b9effb0efe54ebfaf17314d40aca6399a0d4e74395e84e15f7c24`: capture `cfd83a01b49aad128f8b0fdfca10c3b090f46923f4b0f010b7ddd5253c5e5dff` of the deployed script `ee1f1ac36ae0681020c34822688932a3312944159ae096aa3138ede7`.

Transaction `27f60abb65b4749bb8456f9ed5259c547bf60b87b25bc06f6b61cdf839a31f0b`: capture `72744affcdc2cc53ba43b2bf2d5e18d2deaecea088a3832ba6b1034e994caffb` of the deployed script `ee1f1ac36ae0681020c34822688932a3312944159ae096aa3138ede7`.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.

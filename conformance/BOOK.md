# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `a85b3156efdc08b216d13c52197c67102b273bd7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98 request:0b9f5376e0eaa477fca89b34be3fdb36ffa0c7436f405b46023bb944`.

Registration compared 7 requests: 4 accepted and 3 refused on chain.

Unsupported chain folds: 0.

Batches submitted in one transaction: 1, 0 accepted and 1 refused on chain.

The extra-signer registration was accepted on chain (transaction `5887699529eb7550c518a4d234ba9399cb63d54c62b4a474f2b23cab227c1999`); the comparison detected the difference at `tx.signers`.

The insertActive was refused on chain (transaction `039d29d386f4c2b3b67622447fd82ebf3ec0eb501f3c18cc3e81a310d33e4278`); the model refused it for `key-exists`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `key-exists`.

The other-address insertActive was refused on chain (transaction `2235a2fb0bf3f037dbf3ebd77ad7cddb6c27521d3e876f691c5aeeb0d6788fc1`); the model refused it for `destination`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `destination`.

The short-by-one insertActive was refused on chain (transaction `76b9e398603b48f77114e4dba17c702f544afe7c03679b9c2aeb0611b60b4470`); the model refused it for `deposit-returned`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `deposit-returned`.

The fold of 2 requests in one transaction, tampered mint-on-first-key, was refused on chain (transaction `fe5e14d4b7e76b99ec36c554b18e464949ea6fe29d39a876e64701657537ec4c`); the model's `foldBatch` refused it for `net-mint-mismatch`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `net-mint-mismatch`.

Code revision: `a85b3156efdc08b216d13c52197c67102b273bd7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98 request:0b9f5376e0eaa477fca89b34be3fdb36ffa0c7436f405b46023bb944`.

Occupied-key insertion compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The insertActive was refused on chain (transaction `9849da68a613a8a24375a338ad272874e7d3c7c321fee5e06a211400068f2a93`); the model refused it for `key-exists`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `key-exists`.

The updateActive was refused on chain (transaction `5093331094ca08d945e981cc3aaa69dd083eab1ae4408763e94e3b346f11529e`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

Code revision: `a85b3156efdc08b216d13c52197c67102b273bd7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98 request:0b9f5376e0eaa477fca89b34be3fdb36ffa0c7436f405b46023bb944`.

Retirement compared 11 requests: 6 accepted and 5 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `28007f700945c88912a5dc958dcf5268ee3408285009acdddc2404caef565980`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

The updateTerminal was refused on chain (transaction `42427531dd1c81fc271fbde4c87409540aadc59d8d541053f807daa63d35855f`); the model refused it for `key-unknown`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `key-unknown`.

The updateTerminal was refused on chain (transaction `910512fbe06a4732eb475eae100ec749d7a9faf7ee4f3d2cae9863b3d00a22ba`); the model refused it for `key-unknown`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `key-unknown`.

The deleteActive was refused on chain (transaction `0d012d2c27193ad58f21e6c42f7fc74b8098a814a8c8b5044691690fb6341df1`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

The insertActive was refused on chain (transaction `687789c31061c338e5982c05fb854d29bf6e3420e959844168b3c4df81b99ce0`); the model refused it for `key-exists`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `key-exists`.

Code revision: `a85b3156efdc08b216d13c52197c67102b273bd7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98 request:0b9f5376e0eaa477fca89b34be3fdb36ffa0c7436f405b46023bb944`.

unmet by ruling 2026-10-15: implementation follows the superseded rule; the ruled rule is not implemented (lambdasistemi/singular#495 and #496).

Rejection and retraction compared 10 requests: 2 accepted and 8 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `9014fcf6f40a487196f8710326f1a1db8c4108989f39ccd6648c266386e85319`); the model refused it for `deposit-returned`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `03d864c2e986cc6a5408f6a9553bda164f8e62453fa11876d2086fdbeb82b1e3`); the model refused it for `deposit-returned`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `deposit-returned`.

The short-by-one retract of insertActive was refused on chain (transaction `acc8cce81a3045767947a846c698c4e67e57c551b714d93276ba01ec7d809de8`); the model refused it for `deposit-returned`. The traced replay of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4` (traced build `b7c6ae5b8d06eff5c16cec7d96464de8f7043ebfb110a4554b4e7180`) failed with `deposit-returned`.

The other-address retract of insertActive was refused on chain (transaction `5a779168c55813cd122e08e663f05d3f50deb1edb3070b3e8659177427d5bf1a`); the model refused it for `deposit-returned`. The traced replay of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4` (traced build `b7c6ae5b8d06eff5c16cec7d96464de8f7043ebfb110a4554b4e7180`) failed with `deposit-returned`.

The other-reference retract of insertActive was refused on chain (transaction `b555853f9a38d93ffc304971ba4463691a9ea40c35ddd98d8c5c10f2ce0a2c0a`); the model refused it for `deposit-returned`. The traced replay of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4` (traced build `b7c6ae5b8d06eff5c16cec7d96464de8f7043ebfb110a4554b4e7180`) failed with `deposit-returned`.

The state-spent retract of insertActive was refused on chain (transaction `a394e26eee64f7f62b7fe3436c0b6352d618a3746aabae145f76df74c4d005fa`); the model refused it for `retract-state-spent`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `missing-action`. The traced replay of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4` (traced build `b7c6ae5b8d06eff5c16cec7d96464de8f7043ebfb110a4554b4e7180`) failed with `retract-state-spent`.

The retract of updateTerminal was refused on chain (transaction `e0aafe5aa35a091e1f7ec76e04133ac5cca3e8ad5dcdca0a264f2ffdd93e37c1`); the model refused it for `withdraw-insert-only`. The traced replay of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4` (traced build `b7c6ae5b8d06eff5c16cec7d96464de8f7043ebfb110a4554b4e7180`) failed with `withdraw-insert-only`.

The unsigned retract of insertActive was refused on chain (transaction `1d5d3d0c2730b3d67d56fe7ac7a6c91bd4710fbd637657261859a18993061d39`); the model refused it for `retract-owner`. The traced replay of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4` (traced build `b7c6ae5b8d06eff5c16cec7d96464de8f7043ebfb110a4554b4e7180`) failed with `retract-owner`.

The exit chapter compared both admission refusals: the unsigned insertion retraction (transaction `1d5d3d0c2730b3d67d56fe7ac7a6c91bd4710fbd637657261859a18993061d39`) was refused by the model for `retract-owner`, and the pending update retraction (transaction `e0aafe5aa35a091e1f7ec76e04133ac5cca3e8ad5dcdca0a264f2ffdd93e37c1`) for `withdraw-insert-only`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `f9960dedc692708710a4898cb21e4135230cd9ddcc3de9729c76f5d0608660be`.

Code revision: `a85b3156efdc08b216d13c52197c67102b273bd7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98 request:0b9f5376e0eaa477fca89b34be3fdb36ffa0c7436f405b46023bb944`.

unmet by ruling 2026-10-15: implementation follows the superseded rule; the ruled rule is not implemented (lambdasistemi/singular#495 and #496).

Early rejection compared 8 requests: 4 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `a4002474fc8ceb71501a5b974f6c22aa771dd64a85d5a84cb30471596204a0bc`); the model refused it for `deposit-returned`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `0e59a0198fae89f8acbe4e1a2ec8c290ecdc0cfeebbf65930790e965277e4165`); the model refused it for `deposit-returned`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `deposit-returned`.

The short-by-one reject of insertActive was refused on chain (transaction `3cb4590abd01d8d399dcb56515cecfcdf10f8de24e98478924ccd801712db825`); the model refused it for `deposit-returned`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `39502b0d361ccb7517cabd648d6d3c492745f54b908ea30238fcfcada4af4d18`); the model refused it for `deposit-returned`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `deposit-returned`.

Code revision: `a85b3156efdc08b216d13c52197c67102b273bd7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98 request:0b9f5376e0eaa477fca89b34be3fdb36ffa0c7436f405b46023bb944`.

Retraction window compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The before-phase-2 retract of insertActive was refused on chain (transaction `9072ef1ebc34460ee07f526b67f7ae8ab384933c2894cb09e4caa2de10d1ee04`); the model refused it for `not-phase2`. The traced replay of the deployed script `a7032eaf1ebc466c0419a3c49f29ea80f2860ffe5b0e9b1ca67086d6` (traced build `734987addb06cde6dcda810c3b5972f224ccdb3835056be02e53fd04`) failed with `not-phase2`.

The after-phase-2 retract of insertActive was refused on chain (transaction `05927c9e23f532e6868e119201d19cf2710acab3aff7629ca3c31e05df3cb0ed`); the model refused it for `not-phase2`. The traced replay of the deployed script `a7032eaf1ebc466c0419a3c49f29ea80f2860ffe5b0e9b1ca67086d6` (traced build `734987addb06cde6dcda810c3b5972f224ccdb3835056be02e53fd04`) failed with `not-phase2`.

The window chapter compared both finite timing refusals: transaction `9072ef1ebc34460ee07f526b67f7ae8ab384933c2894cb09e4caa2de10d1ee04` before phase 2 and transaction `05927c9e23f532e6868e119201d19cf2710acab3aff7629ca3c31e05df3cb0ed` after phase 2. The model refused both for `not-phase2`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `d22fce46d5df7d265119867ff0f95de50d1160d6500dfeb1e422303c80e98fb6`.

Code revision: `a85b3156efdc08b216d13c52197c67102b273bd7` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98 request:0b9f5376e0eaa477fca89b34be3fdb36ffa0c7436f405b46023bb944`.

Unnamed sequence compared 8 requests: 1 accepted and 7 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `c5590fcf86a1afd5df328affb4e55ecee6415964a5a6bc025d4194005ff2ef10`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

The updateActive was refused on chain (transaction `d013fb86be786f7ce52a35becd678f4c7c1f573d4a15d5250232f4d83e3545f5`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

The updateTerminal was refused on chain (transaction `5d7bfc65e0987e6e1ae0fa378fdff97d1ba48cecffbc88ef3820e5e7a13bfe03`); the model refused it for `key-unknown`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `key-unknown`.

The insertAbsent was refused on chain (transaction `4b38211bce5b6ccc0f7cd88930ca2168c22c594d825ede7d412e632f3aa5b9bd`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

The deleteAbsent was refused on chain (transaction `b413f5f4c8f592b8ae5be1b2f8fc7bb4f337b1a2dd2578250980a95afd058538`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

The witnessTerminal was refused on chain (transaction `7a1f127e7ed6f4c820867f9ca058a3fe73d734b621a40e14fd0044592dfe2379`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

The deleteActive was refused on chain (transaction `698893c7210fecdc1ed47612f44ccec72083203ba8315539c92c6e02fd8a3a5c`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` (traced build `69ab182d9e1507e3c74c64c001f5d8019338ebd43162f1837890bedc`) failed with `edge-inadmissible`.

## Register a key and receive its active token

A requester submits two distinct active registrations and then repeats one key. The delivery is then sent to another address, and paid one lovelace short, beside the same untampered request. Every step is compared with the executable registry model.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `b94da1eb79b528ea2d897998bb4c016fa6ad55444cf7b418581e7b05cffdb12b`.

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

A key is registered Active in this run. Registering that key again is refused beside its accepting control. The excluded updateActive encoding is also refused without changing the registration. Each result is compared with the executable registry model.

- Submit **insertActive** for **occupied** in **occupied insert**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **occupied**.

- Compare **occupied** and its observation with the executable registry model.

- Submit **insertActive** for **occupied** in **occupied insert**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **occupied**.

- Compare **occupied** and its observation with the executable registry model.

- Submit **updateActive** for **occupied** in **occupied insert**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **occupied**.

- Compare **occupied** and its observation with the executable registry model.

## Retire a registration and burn its active token

The holder registers a key in this run, then termination consumes and burns that very token and changes the key to Terminal. Unknown-key termination is refused beside a reached accepting control. Excluded insertion and deletion encodings are refused. After a refused deletion the same Active key can still terminate; its Terminal key cannot register again. The original broader Absent and deletion-refund requirements stay published as uncovered.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `b94da1eb79b528ea2d897998bb4c016fa6ad55444cf7b418581e7b05cffdb12b`.

### The holder receives the token that will be retired

- Submit **insertActive** for **alice** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

Formal specification: `Singular.Statements.update_terminal_transaction_row` @ `88957e41876911a993c5d9a338f8ab006c9f6843`. Statement digest: `eda5fcf4def9dc73ac7accf83704d6ac4a635cc141da664a058631c5935fd4f3`.

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

- Submit **deleteActive** for **deleted** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **updateTerminal** for **deleted** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

- Submit **insertActive** for **deleted** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **deleted**.

- Compare **deleted** and its observation with the executable registry model.

## A request that is never folded

2026-10-15: implementation follows the superseded rule; the ruled rule is not implemented. This chapter is unmet by ruling; its comparisons describe the legacy state-spending rejection. A request can leave the queue without a fold. After its owner's retraction window has closed, a folder rejects it and must refund its owner the deposit, keeping the tip; while it is still retractable, its owner retracts it and must get back everything it held, deposit and tip, through an output whose inline datum is the retracted request's own output reference. Each refund paid one lovelace short or to another address, a return bound to another request, and a retraction spending the registry's state beside it must be refused, each beside the untampered exit of the same request.

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

2026-10-15: implementation follows the superseded rule; the ruled rule is not implemented. This chapter is unmet by ruling; its comparisons describe the legacy state-spending rejection. A rejection with bound lifecycle mismatch evidence is admitted at once: the model and the chain accept it in every window. Two insertion requests from the same owner are booked together in a registry of their own and each is registered Active in this run. A second request for the same key is then rejected while it can still be folded (first key) and while its owner can still retract it (second key). In each window a reject refunding the owner one lovelace short, and one refunding another key, must be refused by both for the refund reason, leaving the request pending; the untampered reject of the same request, with lifecycle mismatch evidence, must be accepted by both, refund the owner the deposit and leave the registry state as it was. Each reject's validity interval is checked to lie inside the window its step names before it is submitted.

- Submit **insertActive** for **early-processing** in **early rejection**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **early-processing**.

- Compare **early-processing** and its observation with the executable registry model.

- Submit **insertActive** for **early-retraction** in **early rejection**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **early-retraction**.

- Compare **early-retraction** and its observation with the executable registry model.

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

## Permanent registration and termination

The following program requires the new permanent registry and bounded model evaluator. No live conformance receipt for it is attached to this book; its inventory row remains uncovered. Exported-code component checks and the ordinary packaged CLI journey are separate evidence boundaries. Earlier deployed registries are abandoned. Protected rejection follows this carve with its own identity change and remains required before the first milestone closes.

- Submit **insertActive** for **registered-key** in **permanent registry**, using the participant.

- Observe the complete registry, token, leaf and transaction boundary after **registered-key**.

- Compare **registered-key** and its observation with the executable registry model.

- Submit **updateTerminal** for **registered-key** in **permanent registry**, using the participant.

- Observe the complete registry, token, leaf and transaction boundary after **registered-key**.

- Compare **registered-key** and its observation with the executable registry model.

- Submit **insertAbsent** for **registered-key** in **permanent registry**, using the participant.

- Observe the complete registry, token, leaf and transaction boundary after **registered-key**.

- Compare **registered-key** and its observation with the executable registry model.

- Submit **updateActive** for **registered-key** in **permanent registry**, using the participant.

- Observe the complete registry, token, leaf and transaction boundary after **registered-key**.

- Compare **registered-key** and its observation with the executable registry model.

- Submit **deleteAbsent** for **registered-key** in **permanent registry**, using the participant.

- Observe the complete registry, token, leaf and transaction boundary after **registered-key**.

- Compare **registered-key** and its observation with the executable registry model.

- Submit **deleteActive** for **registered-key** in **permanent registry**, using the participant.

- Observe the complete registry, token, leaf and transaction boundary after **registered-key**.

- Compare **registered-key** and its observation with the executable registry model.

- Submit **witnessTerminal** for **registered-key** in **permanent registry**, using the participant.

- Observe the complete registry, token, leaf and transaction boundary after **registered-key**.

- Compare **registered-key** and its observation with the executable registry model.

- Fold, in one transaction, **insertActive** for **another-key**, **witnessTerminal** for **registered-key** in **permanent registry**, using the participant, the participant, and ask the executable registry model the same batch.

## What these runs do not establish

Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none for a fold and the owner for a retraction, and the comparison reads them from the submitted transaction. The registration chapter folds two registrations in one transaction that mints both tokens at the first request's key; it is compared on its outcome and, both refusing, on the reason. The model builds no transaction for a batch, so no other observation of a batch is compared. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The original Absent retirement and deletion-refund requirements remain published and uncovered. The current retirement chapter starts from a reached Active registration; excluded encodings create no Absent state, and their refusals receive no credit for those broader requirements. The model admits a retraction only when the pending request inserts a key or reads a terminal one, its owner is among the transaction's required signers, and its validity interval lies inside phase 2. The interval starts no earlier than submission plus the processing time; its excluded upper bound may reach, but not pass, the end of the retraction time that follows. The model represents only finite validity bounds. Open validity intervals remain a named gap: the Aiken tests establish their not-phase2 refusal, but no live model comparison can represent them. The early rejections are compared in the processing window and the retraction window of one registry, each for a key registered Active in the run and rejected at once with bound lifecycle mismatch evidence; a fold of an update in the retraction window is not compared there, because the validator refuses it while the model admits it, a separate tracked discrepancy. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.

Refusal reasons come from traced re-evaluation. The deployed validators are compiled without traces, so the ledger names the script that refused but not why. Each refused transaction is evaluated again on the arguments the ledger built for it: once with the deployed bytes, and once with a build of the same source, compiler and parameters that keeps only the validators' own traces. A reason is admitted only when both evaluations fail and the traced one leaves exactly one trace; otherwise the receipt names the cause no reason was admitted. The receipt names both script hashes, and each refused request above prints what its replay recorded. Of the 32 refused requests in this run's chapters, 32 carry a reason their traced replay admitted, 0 name the cause their replay admits none, and 0 record no traced replay.

Refusals outside these chapters, by row, recorded in the receipts of the conformance session rather than in this book. Three have no counterpart in the model, so their model comparison is unmet: each receipt carries the verdict unmet by ruling and shows what the traced replay of the refusal recorded. wrong-redeemer-constructor-index, a fold redeemer at a wrong constructor index: the model has no vocabulary for decoding a redeemer; the witness script names its refusal, while the state and request scripts fail on a path that carries no user-defined trace, so their live refusal reason is not observed (lambdasistemi/singular#347). fold-against-superseded-root, a fold whose proof was built against a root the registry has since superseded: the model takes no proof and no authenticated root and admits the insertion on that unoccupied key, so nothing compares with the chain's reason (lambdasistemi/singular#346). surplus-fold-actions, a fold carrying an action beyond its requests, and one missing an action: the model takes no action list (lambdasistemi/singular#345). The other refusals are compared with the model's batch questions, each against the reason the traced replay admits for the state script: empty-fold, an empty fold, with the fold batch over no request; request-value-and-refund-routing, two rejects whose refunds are crossed and two whose first refund is short, with the reject batch judged on the refunds the transaction pays; and reject-before-deadline-consumer-requirement's three batches, each with the reject batch of one foldable insertion: two refund tampers refused by both for different reasons (the model for `reject-not-expired`, the chain for `deposit-returned` with that reason in replay) and the untampered refused by the model for `reject-not-expired` and accepted by the chain, each recorded as a divergence for `lambdasistemi/singular#495`. reject-before-deadline-consumer-requirement itself, a reject of a foldable insertion while it can still be folded, is refused by the model and accepted by the chain, while the consuming project requires it refused: that requirement stays unmet by ruling. Where a reject pays its owner short in the refund's position and the rest in another output at the same key, the chain and the model read the payment differently (chain by position, model by sum): that split shape no longer diverges as `361` in-window while protected holds (the model refuses first for admission); its chain refusal for `deposit-returned` stays in replay, and `361` as a general refund-position conflict stays open. Every compared lawful reject, here and in the conformance session, leaves no other output at its owners' keys, so their agreement holds for that shape only; the unmet row's divergences hold for the same shape (owners receiving no change) and turn on admission. Whether empty-fold and request-value-and-refund-routing meet the consuming project's requirements remains unresolved. Dated qualification, 2026-10-15: empty-fold stays held; request-value-and-refund-routing is unmet by ruling because implementation follows the superseded rule; the ruled rule is not implemented. Its earlier unresolved consumer requirement remains open.

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

- Submit **insertActive** for **cg01-key** in **insertion**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **cg01-key**.

- Compare **cg01-key** and its observation with the executable registry model.

### Generic Update (OpUpdate old new) on an existing key folds; the root advances and the new value reads back from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec registry transitions.

Outside the model's vocabulary: The original broader update requirement remains uncovered. Its insertAbsent/updateActive success setup is excluded by the current two-edge law. No excluded-edge refusal certifies that requirement.

### Generic Delete (OpDelete old) on an existing key folds; the key returns to absence, proved by a read from chain.

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec; issue #18 Delete preservation.

Outside the model's vocabulary: The original deletion requirement remains uncovered: the current two-edge law refuses deletion and cannot return a key to absence.

### After deleting a key, re-Insert the same key (reincarnation).

Expected: accept. Planned evidence status: uncovered.

Source: protocol spec: Delete MUST permit a later Insert.

Outside the model's vocabulary: The original reincarnation requirement remains uncovered: the current two-edge law cannot reach its successful deletion prefix.

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

- Reject, in one transaction while the request can still be folded with the first request's refund 1 lovelace short, **insertActive** for **cg09-key** in **processing-window rejection**, using the owner wallet, booked **cg09-key** by the owner wallet with a deposit of 3000000 lovelace, and ask the executable registry model the same batch.

- Reject, in one transaction while the request can still be folded with the first request's refund 1 lovelace short in its own position and two ada more in another output at the same owner's key, **insertActive** for **cg09-key** in **processing-window rejection**, using the owner wallet, booked **cg09-key** by the owner wallet with a deposit of 3000000 lovelace, and ask the executable registry model the same batch.

- Reject, in one transaction while the request can still be folded, **insertActive** for **cg09-key** in **processing-window rejection**, using the owner wallet, booked **cg09-key** by the owner wallet with a deposit of 3000000 lovelace, and ask the executable registry model the same batch.

### Stale fold against a superseded root.

Expected: refuse. Planned evidence status: uncovered.

Source: cardano-keri R7_stale_fold_refused.

Outside the model's vocabulary: a fold whose proof was built against a root the registry has since superseded. The model takes no proof and no authenticated root, so it has no reason to compare with the chain's refusal (lambdasistemi/singular#346). The conformance session runs the refusal and its accepting control on the devnet; the model comparison stays unmet by ruling.

### Empty fold (Modify []).

Expected: observe and report. Planned evidence status: uncovered.

Source: cardano-keri R8_empty_fold_refused.

Run as an edge composition over the registry's operations, in the conformance session:

- Fold, in one transaction, no request in **empty fold**, and ask the executable registry model the same batch.

- Submit **insertActive** for **cg11-key** in **empty fold**, using the holder wallet.

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

Outside the model's vocabulary: The original retirement requirement remains uncovered because it also requires an Absent starting key. A separate current retirement story certifies Active to Terminal and excluded encodings, without claiming that unreachable prefix or the former deletion-refund chapter.

### On a real devnet, a request that is never folded leaves the queue by a reject or a retract. A reject must refund its owner the deposit; a retract by its owner must return everything the request held, through an output whose inline datum is the retracted request's own output reference. Each refund or return one lovelace short or to another key, a return bound to another request, and a retract spending the registry state beside it are refused by the chain and by the model, each beside the untampered exit of the same request, which both accept. The live consumer for the rule that only a retract returns the tip is the reject that keeps the tip beside the retract that returns it; fold consumers are in the fold rows. The guarantee that retract obligations depend only on the request remains a named gap: Lean proves this for every request and registry state, while this live run covers one registry state and no executable consumer varies it.

Expected: refuse a reject refunding the owner one lovelace short and to another key, `deposit-returned`, beside the accepted untampered reject; refuse a retraction returning one lovelace short, to another key and bound to another output reference, `deposit-returned`, and one spending the registry state beside it, `retract-state-spent`, beside the accepted untampered retraction. Planned evidence status: uncovered.

Source: Singular.Statements.exit_settles_on_lovelace_received and Singular.Statements.no_exit_strands_the_deposit; issue #258; Singular.Statements.only_retract_owes_the_tip: consumed by the live reject that keeps the tip and retract that returns it; fold consumers are in the registration (register-active-key) and retirement (retire-active-key) rows. Singular.Statements.obligations_read_only_the_request: named gap, proved in Lean for every request and registry state, but the live run covers one registry state and no executable consumer varies it.

Run as a tamper of an edge's transaction, in the chapter "A request that is never folded" above.

### On a real devnet, each key is registered Active before a second request for the same key is rejected at once with bound lifecycle mismatch evidence before its owner's retraction deadline. A reject while the request can still be folded, and one while its owner can still retract it, are each accepted by the chain and by the model, refund the owner the deposit and leave the registry state as it was. In each window a reject refunding the owner one lovelace short or to another key is refused by the chain and by the model for the refund reason.

Expected: register each key Active, then accept a second request for the same key rejected at once with lifecycle mismatch evidence while it can still be folded and while its owner can still retract it, each refunding the owner the deposit and leaving the registry state as it was; refuse, in each window, a reject refunding the owner one lovelace short and one refunding another key, `deposit-returned`. Planned evidence status: uncovered.

Source: Singular.exitStep and Singular.exitAdmission: a rejection with bound lifecycle mismatch evidence is admitted at once; Singular.obligations for a reject; Singular.Statements.admitted_exit_is_the_exit and Singular.Statements.built_transaction_settles; issue #320.

Run as a tamper of an edge's transaction, in the chapter "A folder rejects a request before its retraction deadline" above.

### A new permanent registry admits registration and permanent termination only; every caller is refused the other five registry transitions, including terminal witnessing without approval and an excluded member of a mixed batch. Its ordinary open-datum CLI journey registers a key, updates the application payload without moving the registry and terminates the key permanently.

Expected: accept registration and termination; refuse all other registry edges. Planned evidence status: uncovered.

Source: Operator bounded contract ruling of 8 October 2026; issues #505/#506; Singular.M1 and Conformance.Edge.Permanent.

### On a real devnet, registration delivers an Active token and termination burns that exact token, leaves no live holding and commits Terminal. Unknown-key termination and excluded insertion/deletion encodings are refused beside reached controls; an excluded deletion leaves the Active key able to terminate, and its Terminal key cannot register again.

Expected: accept registration and termination; refuse unknown termination, excluded encodings and Terminal reinsertion. Planned evidence status: uncovered.

Source: Singular.Model.refusal/applyEdge; Singular.Statements.update_terminal_transaction_row; A-004 conformance scope disposition.

Run as an edge composition over the registry's operations, in the chapter "Retire a registration and burn its active token" above.

### A booked registration is folded, before its processing deadline, by any wallet that holds only public chain data. The key's token reaches a new holding at the committed address that carries the registration's payload and exactly its deposit, and the folder receives the booked value above the deposit; no treasury is paid. Under the previous design the same fold gave the folder only the booking's tip and paid the registration cost to the treasury.

Expected: The fold is accepted and pays out as stated. Uncovered: no executable comparison with the application-held model exists yet. Planned evidence status: uncovered.

Source: OpenDatumApplicationHeld.Money.oldAllocation and OpenDatumApplicationHeld.Money.newAllocation for the registration fold, with the ruling noTreasuryAtFold.

Existing evidence: Separate evidence boundary, not a comparison with the model: the hosted jobs no-pin-registration-journey and no-pin-registration-refusals run the packaged commands on a development network and read the chain's own record. They establish what they run and nothing about agreement with the model.

### A booked registration is reclaimed by its controller, signing alone, between its processing deadline and the end of its reclaim window. Everything the booking held returns to the refund address and no folder is paid. Under the previous design the owner's retraction returned the same whole value; the window is now the one the booking itself records, from its processing deadline to its reclaim end.

Expected: The reclaim is accepted and pays out as stated. Uncovered: no executable comparison with the application-held model exists yet. Planned evidence status: uncovered.

Source: OpenDatumApplicationHeld.Money.oldAllocation and OpenDatumApplicationHeld.Money.newAllocation for the reclaim, with the phase conditions of OpenDatumApplicationHeld.RefundLifecycle.

Existing evidence: Separate evidence boundary, not a comparison with the model: the hosted jobs no-pin-registration-journey and no-pin-registration-refusals run the packaged commands on a development network and read the chain's own record. They establish what they run and nothing about agreement with the model.

### After the reclaim window of a booked registration has closed, any wallet may clean it up. The deposit returns to the refund address and the cleaner receives the booked value above the deposit. Under the previous design a folder rejected such a request after its retraction window, refunded the owner everything but the tip and kept the tip.

Expected: The cleanup is accepted and pays out as stated. Uncovered: no executable comparison with the application-held model exists yet. Planned evidence status: uncovered.

Source: OpenDatumApplicationHeld.Money.oldAllocation and OpenDatumApplicationHeld.Money.newAllocation for the cleanup, with the phase conditions of OpenDatumApplicationHeld.RefundLifecycle.

Existing evidence: Separate evidence boundary, not a comparison with the model: the hosted jobs no-pin-registration-journey and no-pin-registration-refusals run the packaged commands on a development network and read the chain's own record. They establish what they run and nothing about agreement with the model.

### A booked registration that can never be folded, because its key is already registered or for any other reason, is not rejected early. It stays pending until its refund address reclaims it inside the reclaim window, or until anyone cleans it up after that window and the deposit returns to the refund address. Under the previous design a folder could reject such a request at once, with evidence of the mismatch, while it could still be folded or retracted; the previous design's early-rejection requirements stay published as they are.

Expected: No early rejection exists: the registration waits for its reclaim window. Uncovered: no executable comparison with the application-held model exists yet. Planned evidence status: uncovered.

Source: OpenDatumApplicationHeld.Money.oldAllocation for the early rejection, which OpenDatumApplicationHeld.Money.newAllocation leaves empty, with the ruling threePhases.

Existing evidence: Separate evidence boundary, not a comparison with the model: the hosted jobs no-pin-registration-journey and no-pin-registration-refusals run the packaged commands on a development network and read the chain's own record. They establish what they run and nothing about agreement with the model.

## Appendix: checking the evidence machinery

The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.

Each refused request's traced replay was evaluated from a capture of the refused transaction, the outputs it spends, the protocol parameters and the era history:

Transaction `039d29d386f4c2b3b67622447fd82ebf3ec0eb501f3c18cc3e81a310d33e4278`: capture `86f62098cd5e9510c702180541edc404f7ec434addb96516871d91ae33cecbb3` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `2235a2fb0bf3f037dbf3ebd77ad7cddb6c27521d3e876f691c5aeeb0d6788fc1`: capture `6e0d88465b3cbd247273d8dab22336543d49ec23bd71329a210ecf137a1261d2` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `76b9e398603b48f77114e4dba17c702f544afe7c03679b9c2aeb0611b60b4470`: capture `0899ef9068da71348815c71d379ed29edcf05e9fbdeb34afe813940b273a2867` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `fe5e14d4b7e76b99ec36c554b18e464949ea6fe29d39a876e64701657537ec4c`: capture `7042b088b3a6c263bd8dcc9547b805838bb4a7b310f340b384c843db38eed38e` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `9849da68a613a8a24375a338ad272874e7d3c7c321fee5e06a211400068f2a93`: capture `cce9df75804116a859ae6a40cbae8dc04471a114717b863716c71094b6077d66` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `5093331094ca08d945e981cc3aaa69dd083eab1ae4408763e94e3b346f11529e`: capture `5449f22a3ea34d8916f4d8dccb81b38f2dccbf3dd80a9ab563aa69231664db03` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `28007f700945c88912a5dc958dcf5268ee3408285009acdddc2404caef565980`: capture `19bf61a3b40b0912149b932ff768b2d6ba251862ba94662e9c0f5b1a96e68bec` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `42427531dd1c81fc271fbde4c87409540aadc59d8d541053f807daa63d35855f`: capture `861ad259af952896eb93aa596daa0f7b31bfe4a8f2e082614e91e89f8953e01c` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `910512fbe06a4732eb475eae100ec749d7a9faf7ee4f3d2cae9863b3d00a22ba`: capture `a9a10ecb8dff45aaeca62ad56f3a1ade8291970cdd5bd8820a0a8c14837e4d7a` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `0d012d2c27193ad58f21e6c42f7fc74b8098a814a8c8b5044691690fb6341df1`: capture `8b0fbac5ae9cedbe46d4700f90fac275d7d3a3fc597cc8b18b17f7c1d7e7facf` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `687789c31061c338e5982c05fb854d29bf6e3420e959844168b3c4df81b99ce0`: capture `245a24ea51363d22ce72bdf3400942f8c70cf1d8c3f3315a809e8ae393efd782` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `9014fcf6f40a487196f8710326f1a1db8c4108989f39ccd6648c266386e85319`: capture `1f97d5d7e97ca3358abe3516e557b0ff5d147f2a95946e2210f62c8e016a2229` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `03d864c2e986cc6a5408f6a9553bda164f8e62453fa11876d2086fdbeb82b1e3`: capture `a202471da9ea6b13ff415e527526c5397d3eef399705fac215b4fcb5e5d6341f` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `acc8cce81a3045767947a846c698c4e67e57c551b714d93276ba01ec7d809de8`: capture `f68d109ce12bdcee630f49187f9a36cc09eaa9888ca861664f6e0d967173686c` of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4`.

Transaction `5a779168c55813cd122e08e663f05d3f50deb1edb3070b3e8659177427d5bf1a`: capture `b2f652db932b6aeeaee2951e3dea9147423ff97150d16dfb87c673eab21179ff` of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4`.

Transaction `b555853f9a38d93ffc304971ba4463691a9ea40c35ddd98d8c5c10f2ce0a2c0a`: capture `7ebc87c1fb7e02bb6901608b8c7f039625c3abf8626f8db4c33d185aba5f0699` of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4`.

Transaction `a394e26eee64f7f62b7fe3436c0b6352d618a3746aabae145f76df74c4d005fa`: capture `ced88fc4aa628d6729d9219247e3207d36812023a491c0160e1bf1584a88b979` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `a394e26eee64f7f62b7fe3436c0b6352d618a3746aabae145f76df74c4d005fa`: capture `ced88fc4aa628d6729d9219247e3207d36812023a491c0160e1bf1584a88b979` of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4`.

Transaction `e0aafe5aa35a091e1f7ec76e04133ac5cca3e8ad5dcdca0a264f2ffdd93e37c1`: capture `1bcac8a9745fd78e4cecb4ee01b010625414f27950fa5257b7215136bcd405a0` of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4`.

Transaction `1d5d3d0c2730b3d67d56fe7ac7a6c91bd4710fbd637657261859a18993061d39`: capture `4e12341f5b486f30175fa9b14f3b67050ff13ebae5c7f961dc4949427b9820cb` of the deployed script `07074963dc7c9e6f8de35acb286dddc2b072ebab41b7554e98ad97e4`.

Transaction `a4002474fc8ceb71501a5b974f6c22aa771dd64a85d5a84cb30471596204a0bc`: capture `506de87fb4c2703dd562f31091051da7072eff04dc1bb5a72e30da1b005c2336` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `0e59a0198fae89f8acbe4e1a2ec8c290ecdc0cfeebbf65930790e965277e4165`: capture `b42946f34d6f8c5235e5bdd06cd23e144039a3d79e7e3fe0354e3ec4fa012177` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `3cb4590abd01d8d399dcb56515cecfcdf10f8de24e98478924ccd801712db825`: capture `b34975c279fb93c5667db69ea5f7107201687c27a81af084689f417f460db825` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `39502b0d361ccb7517cabd648d6d3c492745f54b908ea30238fcfcada4af4d18`: capture `a2a605a116c41f29fc0e0984668c9bbec4d28525a13de1b535fc4060e4829b46` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `9072ef1ebc34460ee07f526b67f7ae8ab384933c2894cb09e4caa2de10d1ee04`: capture `e1ddcd677a991e76a10a953537df2394ac65d674fe07e773e424a0b881284c46` of the deployed script `a7032eaf1ebc466c0419a3c49f29ea80f2860ffe5b0e9b1ca67086d6`.

Transaction `05927c9e23f532e6868e119201d19cf2710acab3aff7629ca3c31e05df3cb0ed`: capture `b925d33f5acc190ac38ff4c0b0224b0d487e732af69f50d5e48a67c231410edd` of the deployed script `a7032eaf1ebc466c0419a3c49f29ea80f2860ffe5b0e9b1ca67086d6`.

Transaction `c5590fcf86a1afd5df328affb4e55ecee6415964a5a6bc025d4194005ff2ef10`: capture `f3525daf16d12c78346c6ccf53431cfc9298375feb455322946e6e3978028368` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `d013fb86be786f7ce52a35becd678f4c7c1f573d4a15d5250232f4d83e3545f5`: capture `b153c90eef2e2a2bd447eada3604c27454af7b5eb4660537823f904f7a36b4b8` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `5d7bfc65e0987e6e1ae0fa378fdff97d1ba48cecffbc88ef3820e5e7a13bfe03`: capture `4724e7f7e6a2f7a9764a4440d06c285ac307948c911bd32b2f79dc28e7f933b7` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `4b38211bce5b6ccc0f7cd88930ca2168c22c594d825ede7d412e632f3aa5b9bd`: capture `24d6f4fae3d4a73f0e1a89c33f998bc7fb32e00572bf4b073198d64001defd74` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `b413f5f4c8f592b8ae5be1b2f8fc7bb4f337b1a2dd2578250980a95afd058538`: capture `d254c64c8bb71c4243a829e7fee525cdfebe9f7bbe9e9b929e23c9384be8be4b` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `7a1f127e7ed6f4c820867f9ca058a3fe73d734b621a40e14fd0044592dfe2379`: capture `f4422b3085a034d7118f4470c3fa7d2752ef67445a8dcabe1edf0b456a07ba52` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

Transaction `698893c7210fecdc1ed47612f44ccec72083203ba8315539c92c6e02fd8a3a5c`: capture `2cd360a1f7cb483d49035547c2737cdeb770b6755bf45dc7cfc94e210017bcd5` of the deployed script `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98`.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.

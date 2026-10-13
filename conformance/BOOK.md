# The running registry book

These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.

## This run

Code revision: `a3afd12696ce40bd1be6df7333457e32b9be3663` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5 request:5daa275eaf32556a5527035996e37f11072c51b1b4acd64ca2bdd320`.

Registration compared 7 requests: 4 accepted and 3 refused on chain.

Unsupported chain folds: 0.

Batches submitted in one transaction: 1, 0 accepted and 1 refused on chain.

The extra-signer registration was accepted on chain (transaction `820fd6b23fdc75ea60e4301f11b685c5162e52003f373052bd8b869995ee6589`); the comparison detected the difference at `tx.signers`.

The insertActive was refused on chain (transaction `1af342591eca96f3ea344441f252e730615533339e4d8bc4c915a9c5b51d0d80`); the model refused it for `key-exists`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `key-exists`.

The other-address insertActive was refused on chain (transaction `f20c92473e6eee302fb5d651ed08e213b71a13134bda4e8120166a72783d7fa6`); the model refused it for `destination`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `destination`.

The short-by-one insertActive was refused on chain (transaction `13d19e07537d203c52f78ce664a02124b38a0cc6445c18bf211894dd67615d2a`); the model refused it for `deposit-returned`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `deposit-returned`.

The fold of 2 requests in one transaction, tampered mint-on-first-key, was refused on chain (transaction `482825c7cecbbb2f27eae7b3b4a9676e094d932666fbbfe96fd6fbe1643a77d4`); the model's `foldBatch` refused it for `net-mint-mismatch`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `net-mint-mismatch`.

Code revision: `a3afd12696ce40bd1be6df7333457e32b9be3663` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5 request:5daa275eaf32556a5527035996e37f11072c51b1b4acd64ca2bdd320`.

Occupied-key insertion compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The insertActive was refused on chain (transaction `f6205967ada58ad4681359292ea3a3c143330d8a952b0ffce2d7384e479c12ba`); the model refused it for `key-exists`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `key-exists`.

The updateActive was refused on chain (transaction `ef897c6c72ff96f1b424f0533a9ecf675d01fc648861b0eb0190846e184ba5d1`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

Code revision: `a3afd12696ce40bd1be6df7333457e32b9be3663` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5 request:5daa275eaf32556a5527035996e37f11072c51b1b4acd64ca2bdd320`.

Retirement compared 11 requests: 6 accepted and 5 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `117a624d4c8c8a184555b33ca8fa940114799cc0cefb1ddd0a6e286dc0f838a4`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

The updateTerminal was refused on chain (transaction `17c0b4a166f085fca719c1941b83f4cab92b30589fdfd14c4c8a8469881c6ea1`); the model refused it for `key-unknown`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `key-unknown`.

The updateTerminal was refused on chain (transaction `bd7f50b03b7d06a7cd7d8afe6dfbca4efdea6f887523c4cabb0e008c0bdc03ee`); the model refused it for `key-unknown`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `key-unknown`.

The deleteActive was refused on chain (transaction `499ecb4755dc10b573ccfc7c6d8ca0695ba9f7493037b81cd72ab111a0521dd1`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

The insertActive was refused on chain (transaction `3f1ecedec3c2898b39882d7e0d2c8d0c64594a6100f9caaa61df416e5281fdc1`); the model refused it for `key-exists`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `key-exists`.

Code revision: `a3afd12696ce40bd1be6df7333457e32b9be3663` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5 request:5daa275eaf32556a5527035996e37f11072c51b1b4acd64ca2bdd320`.

Rejection and retraction compared 10 requests: 2 accepted and 8 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `7c07fa93d6b1b8448e86994a66dc9f7a7fd59cb6cd2ceb46a86ec3545e5592fd`); the model refused it for `deposit-returned`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `95168adf62aeed69842afb6cfd37af40f5e9742dbefe9ed43f53300b3e9b010f`); the model refused it for `deposit-returned`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `deposit-returned`.

The short-by-one retract of insertActive was refused on chain (transaction `bdb6b3005c64834a637b9859f2dd89f989b2797779d93898a222b9089d03cc2d`); the model refused it for `deposit-returned`. The traced replay of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db` (traced build `3d4538e5838c84cd30ed610acbd0956c4ff1ea78fc01ba6afa5abc34`) failed with `deposit-returned`.

The other-address retract of insertActive was refused on chain (transaction `da13978e922d7d6d2d17b8e0a704cd04839cfeb0e56d2be546d7852eb9ea4584`); the model refused it for `deposit-returned`. The traced replay of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db` (traced build `3d4538e5838c84cd30ed610acbd0956c4ff1ea78fc01ba6afa5abc34`) failed with `deposit-returned`.

The other-reference retract of insertActive was refused on chain (transaction `121aa285473b37d9c1deb3db541f546cb490238f9fe0e8f2f1a5dacbe173ce75`); the model refused it for `deposit-returned`. The traced replay of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db` (traced build `3d4538e5838c84cd30ed610acbd0956c4ff1ea78fc01ba6afa5abc34`) failed with `deposit-returned`.

The state-spent retract of insertActive was refused on chain (transaction `6c8e319f09e0bc884902827f7607b177f83321dd41857c5017f208d4bf55be63`); the model refused it for `retract-state-spent`. The traced replay of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db` (traced build `3d4538e5838c84cd30ed610acbd0956c4ff1ea78fc01ba6afa5abc34`) failed with `retract-state-spent`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `missing-action`.

The retract of updateTerminal was refused on chain (transaction `01ba851813fe545cc623cbb608769e82492e5eafae5289a209f2cde89a54e756`); the model refused it for `withdraw-insert-only`. The traced replay of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db` (traced build `3d4538e5838c84cd30ed610acbd0956c4ff1ea78fc01ba6afa5abc34`) failed with `withdraw-insert-only`.

The unsigned retract of insertActive was refused on chain (transaction `57d5a82c099284e5330f78215358a61800cabf64834e428218aa714621597ad9`); the model refused it for `retract-owner`. The traced replay of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db` (traced build `3d4538e5838c84cd30ed610acbd0956c4ff1ea78fc01ba6afa5abc34`) failed with `retract-owner`.

The exit chapter compared both admission refusals: the unsigned insertion retraction (transaction `57d5a82c099284e5330f78215358a61800cabf64834e428218aa714621597ad9`) was refused by the model for `retract-owner`, and the pending update retraction (transaction `01ba851813fe545cc623cbb608769e82492e5eafae5289a209f2cde89a54e756`) for `withdraw-insert-only`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `aae3ded73d26b91fb5f4c738a21959c1bd2e2fc1ac592c45096792a2b7898e12`.

Code revision: `a3afd12696ce40bd1be6df7333457e32b9be3663` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5 request:5daa275eaf32556a5527035996e37f11072c51b1b4acd64ca2bdd320`.

Early rejection compared 8 requests: 4 accepted and 4 refused on chain.

Unsupported chain folds: 0.

The short-by-one reject of insertActive was refused on chain (transaction `5c6aee8c0886b668ee2df3cd84efa1f49591e98b2b25bca8808d675109061b8b`); the model refused it for `deposit-returned`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `4c8bdb36b82aba5ca50571e24feb93f5e20b971a78df90db47e80b27420edd09`); the model refused it for `deposit-returned`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `deposit-returned`.

The short-by-one reject of insertActive was refused on chain (transaction `49c68c545e3a1ab5cb9e438227bd247365c6e70cdf59ae236261bfc5dbfe0ae9`); the model refused it for `deposit-returned`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `deposit-returned`.

The other-address reject of insertActive was refused on chain (transaction `1fa9ae5c9af9e8761317dc80ec0a6c4eff5d1d6826aa34bac9a602d1c09462c6`); the model refused it for `deposit-returned`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `deposit-returned`.

Code revision: `a3afd12696ce40bd1be6df7333457e32b9be3663` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5 request:5daa275eaf32556a5527035996e37f11072c51b1b4acd64ca2bdd320`.

Retraction window compared 3 requests: 1 accepted and 2 refused on chain.

Unsupported chain folds: 0.

The before-phase-2 retract of insertActive was refused on chain (transaction `233e0bdbe6f53b251de2dac42323fa8c050ad2a2054e8d4a9d0dd35d5a7f9982`); the model refused it for `not-phase2`. The traced replay of the deployed script `a6fa919c1df60f9f6b7cc7e5cb7261162aaf75096de6ca6448e0f7ec` (traced build `a3835ace92f8a266ee01d45789c2a6343292b6fa3d1d7bad9080b98b`) failed with `not-phase2`.

The after-phase-2 retract of insertActive was refused on chain (transaction `b6f5c0c51c08666ee12d37f25ebd20ac33c59eeb5f280cfb3517515900087109`); the model refused it for `not-phase2`. The traced replay of the deployed script `a6fa919c1df60f9f6b7cc7e5cb7261162aaf75096de6ca6448e0f7ec` (traced build `a3835ace92f8a266ee01d45789c2a6343292b6fa3d1d7bad9080b98b`) failed with `not-phase2`.

The window chapter compared both finite timing refusals: transaction `233e0bdbe6f53b251de2dac42323fa8c050ad2a2054e8d4a9d0dd35d5a7f9982` before phase 2 and transaction `b6f5c0c51c08666ee12d37f25ebd20ac33c59eeb5f280cfb3517515900087109` after phase 2. The model refused both for `not-phase2`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `eb1deac8f7f10afa50360a4956c31454c84163fd5f5ea23d3676d4333a8626ae`.

Code revision: `a3afd12696ce40bd1be6df7333457e32b9be3663` (clean working tree).

Node: `cardano-node 10.7.0 - linux-x86_64 - ghc-9.6`. Compiled validators: `state:68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5 request:5daa275eaf32556a5527035996e37f11072c51b1b4acd64ca2bdd320`.

Unnamed sequence compared 8 requests: 1 accepted and 7 refused on chain.

Unsupported chain folds: 0.

The insertAbsent was refused on chain (transaction `d28c2fb3ca372b5f401a848410718303a2f94d56d1b188885ba14bed3952aca2`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

The updateActive was refused on chain (transaction `1ce457f2cca5de8998c3a22f7fda36944756189d70b18318277ef36f708a5004`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

The updateTerminal was refused on chain (transaction `f22fd6bf1592f9494dba70272c5bd1add9d6d5a65bdd18f341f93c9ef8ebeece`); the model refused it for `key-unknown`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `key-unknown`.

The insertAbsent was refused on chain (transaction `73f3dc3415e7623d587f6ca3a271955fe14b3102762e603d5d77d1aee61d1570`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

The deleteAbsent was refused on chain (transaction `80edc51d9bc22ebe38d8df3b39eca191b138518deec17cdbb3c3e5a70ed69d62`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

The witnessTerminal was refused on chain (transaction `981111590e20d4db833f332d8e21e4ab01b242cb7e9f1df7db6ebf51ff71d71d`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

The deleteActive was refused on chain (transaction `e2e37d0cdf2ae23a3d119645a33842f57831cf6307545f17565024cd1bcae94a`); the model refused it for `edge-inadmissible`. The traced replay of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5` (traced build `b1657324031148c2acc6bd07ed0566ca39582ea7a06e7c6e8f6af062`) failed with `edge-inadmissible`.

## Register a key and receive its active token

A requester submits two distinct active registrations and then repeats one key. The delivery is then sent to another address, and paid one lovelace short, beside the same untampered request. Every step is compared with the executable registry model.

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `3c8d7b9bd9092b29d2bbb58ebbca15b008dc9b9396899d9d67d55ea66e1f6070`.

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

Formal specification: `Singular.Statements.insert_active_transaction_row` @ `265c595edd72eab10f3b08a36cb010ad407cf48b`. Statement digest: `3c8d7b9bd9092b29d2bbb58ebbca15b008dc9b9396899d9d67d55ea66e1f6070`.

### The holder receives the token that will be retired

- Submit **insertActive** for **alice** in **retirement**, using the holder wallet.

- Observe the complete registry, token, leaf and transaction boundary after **alice**.

- Compare **alice** and its observation with the executable registry model.

Formal specification: `Singular.Statements.update_terminal_transaction_row` @ `88957e41876911a993c5d9a338f8ab006c9f6843`. Statement digest: `4806b33d0b74c975981c8905ceb8aab758efbe5d780eca50f59e68202ea2a4bf`.

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

A rejection with bound lifecycle mismatch evidence is admitted at once: the model and the chain accept it in every window. Two insertion requests from the same owner are booked together in a registry of their own and each is registered Active in this run. A second request for the same key is then rejected while it can still be folded (first key) and while its owner can still retract it (second key). In each window a reject refunding the owner one lovelace short, and one refunding another key, must be refused by both for the refund reason, leaving the request pending; the untampered reject of the same request, with lifecycle mismatch evidence, must be accepted by both, refund the owner the deposit and leave the registry state as it was. Each reject's validity interval is checked to lie inside the window its step names before it is submitted.

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

Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none for a fold and the owner for a retraction, and the comparison reads them from the submitted transaction. The registration chapter folds two registrations in one transaction that mints both tokens at the first request's key; it is compared on its outcome and, both refusing, on the reason. The model builds no transaction for a batch, so no other observation of a batch is compared. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The original Absent retirement and deletion-refund requirements remain published and uncovered. The current retirement chapter starts from a reached Active registration; excluded encodings create no Absent state, and their refusals receive no credit for those broader requirements. The model admits a retraction only when the pending request inserts a key or reads a terminal one, its owner is among the transaction's required signers, and its validity interval lies inside phase 2. The interval starts no earlier than submission plus the processing time; its excluded upper bound may reach, but not pass, the end of the retraction time that follows. The model represents only finite validity bounds. Open validity intervals remain a named gap: the Aiken tests establish their not-phase2 refusal, but no live model comparison can represent them. The early rejections are compared in the processing window and the retraction window of one registry, each for a key registered Active in the run and rejected at once with bound lifecycle mismatch evidence; a fold of an update in the retraction window is not compared there, and the model now refuses it as not-phase1 under the transaction's finite excluded upper bound; a dedicated live comparison remains separate. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.

Refusal reasons come from traced re-evaluation. The deployed validators are compiled without traces, so the ledger names the script that refused but not why. Each refused transaction is evaluated again on the arguments the ledger built for it: once with the deployed bytes, and once with a build of the same source, compiler and parameters that keeps only the validators' own traces. A reason is admitted only when both evaluations fail and the traced one leaves exactly one trace; otherwise the receipt names the cause no reason was admitted. The receipt names both script hashes, and each refused request above prints what its replay recorded. Of the 32 refused requests in this run's chapters, 32 carry a reason their traced replay admitted, 0 name the cause their replay admits none, and 0 record no traced replay.

Refusals outside these chapters, by row, recorded in the receipts of the conformance session rather than in this book. Three have no counterpart in the model, so their model comparison is unmet: each receipt carries the verdict unmet by ruling and shows what the traced replay of the refusal recorded. wrong-redeemer-constructor-index, a fold redeemer at a wrong constructor index: the model has no vocabulary for decoding a redeemer; the witness script names its refusal, while the state and request scripts fail on a path that carries no user-defined trace, so their live refusal reason is not observed (lambdasistemi/singular#347). fold-against-superseded-root, a fold whose proof was built against a root the registry has since superseded: the model takes no proof and no authenticated root and admits the insertion on that unoccupied key, so nothing compares with the chain's reason (lambdasistemi/singular#346). surplus-fold-actions, a fold carrying an action beyond its requests, and one missing an action: the model takes no action list (lambdasistemi/singular#345). The other refusals are compared with the model's batch questions, each against the reason the traced replay admits for the state script: empty-fold, an empty fold, with the fold batch over no request; request-value-and-refund-routing, two rejects whose refunds are crossed and two whose first refund is short, with the reject batch judged on the refunds the transaction pays; and reject-before-deadline-consumer-requirement's three batches, each with the reject batch of one foldable insertion: two refund tampers refused by both for different reasons (the model for `reject-not-expired`, the chain for `deposit-returned` with that reason in replay) and the untampered refused by the model for `reject-not-expired` and accepted by the chain, each recorded as a divergence for `lambdasistemi/singular#495`. reject-before-deadline-consumer-requirement itself, a reject of a foldable insertion while it can still be folded, is refused by the model and accepted by the chain, while the consuming project requires it refused: that requirement stays unmet by ruling. Where a reject pays its owner short in the refund's position and the rest in another output at the same key, the chain and the model read the payment differently (chain by position, model by sum): that split shape no longer diverges as `361` in-window while protected holds (the model refuses first for admission); its chain refusal for `deposit-returned` stays in replay, and `361` as a general refund-position conflict stays open. Every compared lawful reject, here and in the conformance session, leaves no other output at its owners' keys, so their agreement holds for that shape only; the unmet row's divergences hold for the same shape (owners receiving no change) and turn on admission. Whether empty-fold and request-value-and-refund-routing meet the consuming project's requirements remains unresolved; the two rows stay held.

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

## Appendix: checking the evidence machinery

The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.

Each refused request's traced replay was evaluated from a capture of the refused transaction, the outputs it spends, the protocol parameters and the era history:

Transaction `1af342591eca96f3ea344441f252e730615533339e4d8bc4c915a9c5b51d0d80`: capture `898011c0148059cb58738f2784b9b89e488478dd22f7d5e6f2e634ebc03f998e` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `f20c92473e6eee302fb5d651ed08e213b71a13134bda4e8120166a72783d7fa6`: capture `8eead83a0a79ff82d9539989a3b8f0b46d42cab0900f23bc84117276fd6a154c` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `13d19e07537d203c52f78ce664a02124b38a0cc6445c18bf211894dd67615d2a`: capture `6145071e527c361d245e729c3e3902200e0f40ede29e907deeb905cd4d518d17` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `482825c7cecbbb2f27eae7b3b4a9676e094d932666fbbfe96fd6fbe1643a77d4`: capture `6749e34ec5ba9748ec64bab58ddcf3d1960f25f6b51aa79c059738f8f93a5827` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `f6205967ada58ad4681359292ea3a3c143330d8a952b0ffce2d7384e479c12ba`: capture `a6039573754f07f5d9dbe0397cb6b1c4103806c0fcac5c442648d37363168883` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `ef897c6c72ff96f1b424f0533a9ecf675d01fc648861b0eb0190846e184ba5d1`: capture `4dae8de661e3ae3654fbb09b11503b1b6df8c4813fe88c5a8f32f2434f99b6b0` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `117a624d4c8c8a184555b33ca8fa940114799cc0cefb1ddd0a6e286dc0f838a4`: capture `34851373625be93a86ca05b11563e22bc9e46f4e38e9b3dcd8bb56fd5b3d3f6d` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `17c0b4a166f085fca719c1941b83f4cab92b30589fdfd14c4c8a8469881c6ea1`: capture `f94ac71384e7e73daa811ae7e42a08157a0c9d71cacaddff982f6280319cf874` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `bd7f50b03b7d06a7cd7d8afe6dfbca4efdea6f887523c4cabb0e008c0bdc03ee`: capture `43b99e13dbb9cd5e77eea1beaf0a51326740fdafa4603fa0501c6a96d1b45dc3` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `499ecb4755dc10b573ccfc7c6d8ca0695ba9f7493037b81cd72ab111a0521dd1`: capture `940902f41aae9448450227dbb6a9877e1a3ec8b3f16af080e98328045a8f36bc` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `3f1ecedec3c2898b39882d7e0d2c8d0c64594a6100f9caaa61df416e5281fdc1`: capture `a5db5acdb07d12880173f54d9e716d807d5a598356466c7633d52d94bbfa1808` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `7c07fa93d6b1b8448e86994a66dc9f7a7fd59cb6cd2ceb46a86ec3545e5592fd`: capture `bbc7969d1e32290b9b8e48eecc2298c9ad30b060808aa20e914ba00f6a66bb30` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `95168adf62aeed69842afb6cfd37af40f5e9742dbefe9ed43f53300b3e9b010f`: capture `2250e0be8344f206f602a32b11caaeac6a90f5ba414e390d4eb411ede6c24bcd` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `bdb6b3005c64834a637b9859f2dd89f989b2797779d93898a222b9089d03cc2d`: capture `803de619669c28992dcaadd54ec9fec2a3731746d4b8d831ed9babbb5da650e3` of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db`.

Transaction `da13978e922d7d6d2d17b8e0a704cd04839cfeb0e56d2be546d7852eb9ea4584`: capture `65e0145a1b36ae3bb272c1456d7f784d5dbde72b49006992f6946a14ce5b5d3b` of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db`.

Transaction `121aa285473b37d9c1deb3db541f546cb490238f9fe0e8f2f1a5dacbe173ce75`: capture `3872de0f5ca7485355e1dd0a9a24899600f0c57b79cd495b5c9d9f7a61a9c387` of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db`.

Transaction `6c8e319f09e0bc884902827f7607b177f83321dd41857c5017f208d4bf55be63`: capture `b53d55273d1975eb307a164660a336485549ade3f96f139b2b749c3c02c88ecd` of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db`.

Transaction `6c8e319f09e0bc884902827f7607b177f83321dd41857c5017f208d4bf55be63`: capture `b53d55273d1975eb307a164660a336485549ade3f96f139b2b749c3c02c88ecd` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `01ba851813fe545cc623cbb608769e82492e5eafae5289a209f2cde89a54e756`: capture `73361342cae5423d843e8ddb7413eabada98512b8bc607844d34789234219f28` of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db`.

Transaction `57d5a82c099284e5330f78215358a61800cabf64834e428218aa714621597ad9`: capture `251a2c30301f7c23d5ffa1c79208463bc3e278fc303cdc6b0ea92541358cce14` of the deployed script `c827edcccc6f1bd1a035cb4ab0c89023f6694dbeb6ca2e8a1fdbb1db`.

Transaction `5c6aee8c0886b668ee2df3cd84efa1f49591e98b2b25bca8808d675109061b8b`: capture `da9c755cf8d7e449601f60fecc7665f012513f5e1cfe83596c9fea2dff2ef2fb` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `4c8bdb36b82aba5ca50571e24feb93f5e20b971a78df90db47e80b27420edd09`: capture `0c95b8bf2d605a6d2ebe0ad652f716b7374cc65d2da53d57f7b7e1e3b4ab5746` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `49c68c545e3a1ab5cb9e438227bd247365c6e70cdf59ae236261bfc5dbfe0ae9`: capture `4b9b93fd8214aadb9fe6216727b91b42336bbc8a7d6e733e489551c2bec83344` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `1fa9ae5c9af9e8761317dc80ec0a6c4eff5d1d6826aa34bac9a602d1c09462c6`: capture `650ecf4d8d2d6bcdf08df7b0bceb640d95d5d484bf52f10f2077e4eacdd88581` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `233e0bdbe6f53b251de2dac42323fa8c050ad2a2054e8d4a9d0dd35d5a7f9982`: capture `59a8e4568ed82d0a43c7249ae1258fd743ca1c81eff336b692b2eabf6b791687` of the deployed script `a6fa919c1df60f9f6b7cc7e5cb7261162aaf75096de6ca6448e0f7ec`.

Transaction `b6f5c0c51c08666ee12d37f25ebd20ac33c59eeb5f280cfb3517515900087109`: capture `9b3285772df9b17580e8f0b26ffb90a31bda9dbfbe3739e40195daa74448a618` of the deployed script `a6fa919c1df60f9f6b7cc7e5cb7261162aaf75096de6ca6448e0f7ec`.

Transaction `d28c2fb3ca372b5f401a848410718303a2f94d56d1b188885ba14bed3952aca2`: capture `ca0470983c5615336c4fbb410a5063f4da4772d39acbec385f4ff1c940008de0` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `1ce457f2cca5de8998c3a22f7fda36944756189d70b18318277ef36f708a5004`: capture `d37702209d5815df8dfe6dea0faebe7f61ba8ce251470532273d99d0b75f5d5e` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `f22fd6bf1592f9494dba70272c5bd1add9d6d5a65bdd18f341f93c9ef8ebeece`: capture `0eb49ee2259c06c988ffdfb798d05d396269bb2a72d45c8016ba4365542fbdde` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `73f3dc3415e7623d587f6ca3a271955fe14b3102762e603d5d77d1aee61d1570`: capture `8391060bda0fcc6df34539a8d980570a858d96a33bad6d3d93b79e5b35e8c106` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `80edc51d9bc22ebe38d8df3b39eca191b138518deec17cdbb3c3e5a70ed69d62`: capture `2111c788206bde33ca0115c3645465601f7a3979caced995e22bc708491a2343` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `981111590e20d4db833f332d8e21e4ab01b242cb7e9f1df7db6ebf51ff71d71d`: capture `4396f634a0595744f678a89cd489c960c063d46041056897102a42d5eded7c5b` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

Transaction `e2e37d0cdf2ae23a3d119645a33842f57831cf6307545f17565024cd1bcae94a`: capture `f0bfc9a71a49d05480d3175dbf6e493ce7cc1128d0091204a5f54edce6e2601c` of the deployed script `68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5`.

The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.

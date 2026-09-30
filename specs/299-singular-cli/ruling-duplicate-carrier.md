# Duplicated token carrier: an approved case the live suite does not run

## The operator's ruling

Authority: direct operator answer, 30 September 2026.

> "Yes, record that limit and retain the model/validator tests."

The question put to the operator had three parts:

- record that the ledger keeps a transaction duplicating the key's token from ever reaching the open-datum application;
- keep the model and validator tests of that case;
- stop holding the command-line acceptance on a live test of it, saying clearly that it was not tested live.

The operator then asked how an impossible action can be proved. The answer is recorded below, with its limits. **This ruling proves nothing new.** It records a scope decision and the conditional argument behind it.

## The story it concerns

Alice holds one key in the Active state. Its one active token rides in the key's live holding at the application.

She tries an update whose continuation leaves that token in two outputs. Each output carries one token.

The approved case, "an update whose continuation duplicates the token's carrier", asks that the application refuse this. It bears on `OpenDatumApplication.Statements.update_preserves_custody`, which is PROVED in `applications/open-datum/ledgers.json` under statement digest `56a7b787884ab930d2ccb9524d13fb31a391f5c08aab2ac727080d39c4d498cc`.

## The argument, stated conditionally

**Pins.** The argument is read at main `24ecba3f02840424c65b68bf391fccb61b43ea2f`. On-chain sources and the Lean registry model last changed at `17df0cf3e4750a65b3f52418dbc26975967836d1`. The application model is at `de34300540223ccedf1ca85216b131fd09a148b4`. The command-line union changes none of them.

The argument runs in three steps.

1. **Start: one token per Active key.** The key starts with exactly one active token.
   - The registry model proves this for every reachable state in `Singular.Statements.biconditional_supply_sync`: a key's active supply is one if and only if its leaf is Active. That statement is PROVED in `lean/theorem-debt.json` under digest `7f1089607f7d6578eac69fb4b68bb4147853f29c6b6ac4067eb0db9e667f3f68`.
   - The application's invariant says each application output carries exactly one token of its own key. `OpenDatumApplication.Statements.reachable_consistent` (digest `f3d108992cbf8e634d136ae3104c2420cd2b31105f1052d7497b8bf59f5e7e59`) holds it over reachable worlds.
2. **The update mints no active token.**
   - The application's update and release paths mint nothing (`onchain/validators/open_datum.ak`, the spend handler).
   - The key's active policy is the registry's witness policy. It accepts a mint only in a transaction that spends the registry state as a fold (`onchain/validators/witness.ak`, `foldPresent`).
   - In a fold, the registry pins the mint to the fold's own delta (`onchain/validators/registry/modify.ak`, `mintMatches`). It adds one active token only for an insertion or an Absent-to-Active update (`onchain/validators/lib.ak`). It refuses an insertion of an occupied key (`onchain/validators/registry/fold.ak`).
3. **Conclusion: at most one output can carry the token.** The ledger conserves value. With one token among the inputs and none minted, it keeps a transaction with two one-token outputs from being valid. That transaction never reaches the application's script.

**Exact extent of the argument:**

- **Lean** proves the supply bound for its reachable model.
- **The validator interfaces** cited above were read in source and are exercised by the Aiken unit tests. Their universal enforcement by the compiled scripts on the ledger is not formally proved.
- **A transaction rejected before any script ran** would not establish the argument. It would not be a refusal by the application's script either.
- **No universal proof** that no compiled validator and ledger transaction can present two carriers is established by this work.

## The evidence that is kept, and what it shows

| evidence | what it shows | what it does not show |
|---|---|---|
| the Lean model's `updateStep` refuses `update-token` unless exactly one successor carries the key; `update_inversion` states the accepted case | the model's refusal of two carriers | a ledger could present them |
| the Aiken test `update_duplicated_carrier_refuses` (`onchain/validators/open_datum.tests.ak`) | the validator's refusal branch, for a transaction with one token in, two carrier outputs out and no mint | a ledger could present it, or refuse it at a script; the fixture would not balance on a ledger |
| the registry supply statement and the mint constraints above | the conditional argument | a universal compiled-validator result |

Both tests and the supply statement are unchanged.

## Alternatives considered

- **Submit such a transaction live.** The ledger would reject it for value conservation before any script ran. The controls count such a rejection as no refusal by the application, so it would test nothing about the application.
- **Keep the case as an open blocker.** Acceptance would then wait on a transaction that the argument above says cannot be made.
- **Record the limit and keep the model and validator tests.** This is what the operator chose.

## What changes, and what does not

The case stays in the approved matrix and in the published controls section. The live suite runs no transaction for it, so the section reports it as uncovered and cites this page.

- **Changes:** the case no longer blocks the command-line acceptance of #299.
- **Unchanged:** no live, covered or passing result is claimed for it, and every other acceptance requirement stands.
- **Unchanged:** Lean, the application model, the on-chain validators and the statement ledgers.

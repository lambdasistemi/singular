# Registration delivery checked against executable Lean

A requester registers a fresh key for a recipient. The recipient must receive
the active token that the Lean model says this registration produces.

`Edge.Register.story` receives an already-created registry and funded wallet.
Its delivery clause executes the real transaction builder and devnet submission.
The interpreter owns stable, separately typed wallet, policy and key mappings.
Context/actions allocate IDs; observations can only look up existing IDs.
Cardano bytes remain in Haskell. The Lean oracle uses abstract model identities.

`lean/RegistrationOracle.lean` calls `Singular.txOf`, projects its destination
outputs, and proves that projection using
`Singular.Statements.insert_active_transaction_row`. The theorem's statement
binding is `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737`
at `265c595edd72eab10f3b08a36cb010ad407cf48b`. The oracle is rebuilt from the
checkout's model, using the root flake's locked Lean toolchain.

## Observed run

The [captured structured evidence](registration-run.json) contains the exact
model inputs, identity mappings, oracle executable identity, actual transaction
IDs, observed deliveries and queried holdings for three separate devnets.
These are working-tree results based on `7db0341a17cb0f2e9c932b86437d72648e5b88d1`;
they do not claim exact-final-commit CI or acceptance.

| Run | Lean expected | Observation compared | Result |
|---|---|---|---|
| Normal | recipient 2, policy 2, key 1, quantity 1 | same, including queried holdings | exit 0 |
| Wrong quantity control | recipient 2, policy 2, key 1, quantity 1 | quantity 2 | exit 1 at Lean comparison |
| Wrong policy control | recipient 2, policy 2, key 1, quantity 1 | policy 1, quantity still 1 | exit 1 at Lean comparison |

Normal registration transaction: `415be32de685fdf9138240156d420577c8f897770b3089f0eadcdb06aac5095b`.
The normal run also passed its existing fresh-key, duplicate-key and two-key
batch controls. The deliberate controls change the observation presented to
the interpreter after a real accepted transaction; they are not rejected
on-chain transactions.

The public `conformance-tests -- --book ...` command passed: 131 appendix
examples with zero failures, followed by both live chapters (registration and
connected registration-to-retirement), with 2/2 run receipts accepted. The
[book](../BOOK.md) records those transactions. Root `just ci` and
`coverageGateSnapshot` passed. See [the runnable commands](../test/README.md).

## Limits

This comparison covers one delivery projection for a fresh empty registry.
It does not cover all conclusions of the registration theorem, all reachable
states, all project theorems, or the naming application's behavior. The other
live clauses retain their existing Haskell checks. BDD/resource-lifetime
abstractions and the theorem coverage census remain unfinished.

The old fixture-validation tests remain appendix evidence. No row state or
receipt wire format changed. This evidence does not establish merge, release
or independent acceptance. The book remains unpublished on the documentation
site (issue 218).

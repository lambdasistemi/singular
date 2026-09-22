# Retirement consumes executable Lean

The holder registers a key, then retires it using the token that registration
actually delivered. The story receives both registry contexts from its caller.
Registration and retirement each run under typed `theorem` / `clause` bindings.
Neither `Edge.Register` nor `Edge.Retire` retains `linkedTo` or `conjuncts`.
The registration text anchors have moved to the receipt appendix; batch still
uses legacy text anchors.

## Model and observation

The retirement declaration is `Singular.Statements.update_terminal_transaction_row`
at `871c5df529d30357e4da7f6f9f141dc02c103bf6`, statement digest
`3448ca20f33bba9c3b5092136124f4cb0bf196132f485cae8b1a44343523963b`.
The existing registration binding remains at
`265c595edd72eab10f3b08a36cb010ad407cf48b`.

`RegistrationOracle.lean` replays `step` from an empty registry through the
registration, then runs `step` and `txOf` for retirement. Its retirement
observation contains the before/after active-token counts, minted assets,
consumed witness assets and final leaf. `retirementView_agrees` proves those
effects using the original retirement theorem. A successful registration step
from `startingState` is reachable by `Reachable.next`; the oracle never seeds
an active token directly.

The Haskell interpreter verifies the concrete initial registry is empty and
that retirement starts from the actual post-registration root and configuration.
It reads the actual retirement request's edge, key, owner and destination and
requires those to match the model scenario. It reads the transaction's complete
mint, checks whether it spends the observed token-bearing input, and queries
holdings before and after. Wallet, policy and key identities reuse the same
per-run maps; observations only look up previously allocated IDs.

For this single-key history, the interpreter classifies the observed chain
commitment by rebuilding the possible absent, active and terminal tries with
the concrete key; an unrecognized root fails. It compares the resulting leaf
label with Lean's computed leaf. This keeps the Cardano hash encoding in
Haskell. The initial state must classify as active; the result is not labelled
terminal merely because a retirement was requested.

## Evidence

The adapter compiles and its axiom report contains only `propext`,
`Classical.choice` and `Quot.sound`. Changing the computed mint from minus one
to zero in the adapter makes its proof fail. Pairing `retirementEffect` with
the registration theorem fails Haskell compilation; the matching pair compiles.

The [structured run evidence](retirement-run.json) retains both successful
retirements and two deliberate comparison failures, linked to their preceding
registrations. In each control the real retirement succeeded and its unmodified
observation agreed with Lean. Substituting a zero burn failed; substituting the
observed pre-retirement active leaf for the final leaf also failed. Each run
exited 1 at `observation differs from Lean`. These controls test the comparison,
not rejection of a malformed transaction by the chain.

The public `conformance-tests -- --book BOOK.md` run exited 0: 133 appendix
examples passed, then registration and connected retirement chapters passed.
The two retirement comparisons used different concrete registries and different
model policy/key IDs. Root `nix develop --quiet -c just ci` and
`nix build --no-link .#coverageGateSnapshot` from `conformance/` also exited 0.
The final package compiled; its renderer reproduces the committed book from
the successful receipts. After the live book run began, the obsolete
`storyWithRemainingTokens` wrapper was removed without changing the normal
story; both controls ran the final package. The recorded base is `e512c7a`
with working-tree changes, not an exact-final-commit remote CI claim.

Each live retirement writes `retirement-lean-<transaction>.json`; registration
also retains per-transaction reports so the comparison context does not
overwrite evidence. See [the runnable examples](../test/README.md).

## Limits

This is a successful-retirement observation for an empty-registry registration
followed by retirement. It does not compare every field of the model transaction,
prove the JSON transport, exercise arbitrary prior registry histories, or prove
Cardano hash functions in Lean. The absent/unknown retirement refusals still use
Haskell checks with actual script rejection, not executable Lean comparisons.
Other theorem conclusions and global theorem-consumer coverage remain unverified.
Batch conversion, BDD/resource management and E2E-wide migration remain unfinished.

The [architecture review in the shared gist](https://gist.github.com/paolino/62f6422ea64df2b128047664c1f7d445)
calls for a generic driver over `step` and the complete `txOf` boundary,
with witness/mutant replay and a constitution-defined translation. This patch
still uses a per-theorem observation and agreement proof. It is an interim
check, not completion of that design. In particular, the standalone registration
oracle still computes delivery through `txOf` without executing `step`; the
retirement oracle does execute both connected steps. Translation controls for
unknown identities and model/chain refusal replay remain outstanding.

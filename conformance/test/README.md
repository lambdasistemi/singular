# Read the registry's promises

Start with [registration](../lib/Conformance/Edge/Register.hs). Its caller
supplies a fresh registry and funded recipient. The story names the Lean
theorem and runs a registration inside a readable clause.

`theorem` and `clause` come from the reusable
[`Story.Specification`](../lib/Conformance/Story/Specification.hs) library.
They are indexed by theorem (`thm`), action vocabulary (`act`), observation
(`obs`) and result (`res`). Singular supplies the bound declaration and the
check action; the generic library has no registry operations or Cardano types.
A clause for another theorem or observation type does not compile.

That clause executes the real transaction builder on a local Cardano devnet.
The interpreter maps actual wallet, policy and key identities to stable model
IDs, then asks the [model evaluator](../lean/DriverTransport.lean) about the
registry this run actually established — its own fee and timing pins travel with
the question. The evaluator calls `Singular.Driver.runSurface` and answers with
the complete declared boundary, and every one of those nine observations is
compared with what the chain did: configuration, custody, held tokens, leaf,
mint, payments, root, the resulting state and the transaction.

One leaf is deliberately not compared. A ledger makes every output carry a
minimum ada and the model says nothing about it, so an output's `lovelace` is a
logical zero; `outputMinimumAda` names that, it is removed from both sides
before the transaction is compared, and it is the only such leaf.

Signers sit in a transitional state worth stating exactly. The transaction's
`signers` **value** is compared like any other field — it is empty on both
sides today, and a check appends an element to it and requires the difference
to be reported, so the comparison cannot stop noticing it. What is still
missing is the **rule**: the model states no obligation about who must sign, so
`requiredSigners` remains a named unobservable and earns no pass. #228 is the
child that states and proves the signer rules from the validator's actual
behaviour and removes `requiredSigners` from that vocabulary.

[`RegistrationOracle.lean`](../lean/RegistrationOracle.lean) is no longer on the
registration path. It serves connected retirement, which replays a registration
in Lean before retiring it, until #223 moves that onto the same evaluator.

Run it from `conformance/`:

```sh
export REGISTRY_BLUEPRINT="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
nix run --quiet .#conformance -- example registration --receipts-dir /tmp/registration-example
```

The registration run also retains the existing fresh-key, duplicate-key and
batch-allocation controls. `registration-lean.json` records the exact mapping,
model input, expected result, chain observations and transaction identity.
These observations concern one delivery projection, not the entire theorem.

To demonstrate a failing comparison after a real transaction has landed:

```sh
CONFORMANCE_STORY_CONTROL=wrong-delivery nix run --quiet .#conformance -- \
  example registration --receipts-dir /tmp/registration-wrong-delivery
```

This deliberately increments the observed quantity supplied to the comparator;
the Lean expectation remains unchanged. `wrong-address` and `wrong-policy`
substitute other known identities, which must remain distinguishable.

The [retirement story](../lib/Conformance/Edge/Retire.hs) now checks its
registration and retirement through typed Lean clauses. Run it with
`nix run --quiet .#conformance -- example retirement --receipts-dir /tmp/retirement-example`.
The oracle replays registration, then computes the burn, witness consumption,
remaining holdings and terminal leaf. Each observation is retained in a
`retirement-lean-<transaction>.json` file. Registration observations also have
per-transaction files so the two contexts remain distinguishable.

`CONFORMANCE_STORY_CONTROL=wrong-burn` substitutes a zero burn in the observation
presented to the Lean comparison after a real retirement. `token-remains` and
`wrong-retirement-leaf` change the compared holdings and leaf respectively.

The [batch story](../lib/Conformance/Fold/KeyedMint.hs) and refusal checks retain
Haskell predicates; their executable Lean comparisons remain unfinished.
Other theorem consumers remain missing; see the
[correspondence inventory](../review/journey-correspondence.md).

[Support](Conformance/Support) contains the unchanged report-validation cases
and checks of the evidence machinery. These are the appendix, not evidence
that a new chain execution happened. Run them separately with
`nix run --quiet .#conformance-appendix-tests`.

Run both live chapters and the appendix, then render the successful run:

```sh
nix run --quiet .#conformance-tests -- --book BOOK.md
```

The book is written only after those checks pass. It remains a repository
artifact; publication to the documentation site is tracked in issue 218.

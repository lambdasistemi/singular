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
IDs, asks the [Lean program](../lean/RegistrationOracle.lean) for the expected
delivery, and compares both the accepted transaction output and queried holdings.
The Lean program's delivery projection is proved from
`Singular.Statements.insert_active_transaction_row`.

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

The [retirement story](../lib/Conformance/Edge/Retire.hs) and
[batch story](../lib/Conformance/Fold/KeyedMint.hs) use the existing live backend.
Their checks have not yet been converted to executable Lean comparisons.
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

# Read the registry's promises

A registry commits a map of keys to a root. A request asks to change a key;
a fold applies it. Active tokens witness active registrations. The suite says
what evidence must accompany those claims, and leaves missing evidence visible.

Start with [the rendered book](../BOOK.md). It includes every requirement from
`rows.json`, the unchanged evidence gaps, and the stories generated from the
same programs the tests execute. These are **receipt-validation stories**;
a green unit suite is not a new chain run.

Then read forward:

1. [Register an active key](Conformance/Edge/Register.hs): the `register`
   journey's request, fold and active witness; a repeated insert is refused.
   This asset binds `insert_active_transaction_row` and uses the open registry.
   The naming journey adds application approval behavior beyond this asset.
2. [Apply a batch at distinct keys](Conformance/Fold/KeyedMint.hs): totals can
   agree while tokens are allocated to the wrong keys. That distribution is
   refused. The producer is the conformance runner; a dedicated journey step
   for this subject is still missing.
3. [The correspondence and its gaps](../review/journey-correspondence.md): every
   statement and journey subject, including those without a conformance asset.
4. [The appendix](Conformance/Support): checks of our receipt, refusal and
   inventory machinery. Skipping it loses no product promise.

Cases say what changes and whether that observation is accepted or refused.
Their reasons distinguish the failure. Collections are programs, so nested
keys, mint entries, refunds, signers and configuration edits are part of both
the executed case and its rendered story.

To run the tests and regenerate the book, from `conformance/`:

```sh
nix run --quiet .#conformance-tests -- --book BOOK.md
```

The file is written only after the suite succeeds. No live receipt is supplied
by that command and no inventory state is promoted.

To add a subject, read the executable [story recipe](Conformance/Story/Usage.hs).
Keep its Lean binding in that subject's module; place edge subjects under
`Edge`, batch properties under `Fold`, and machinery under `Support`.
The current binding check covers exactly two constants. The missing population
check is tracked in [issue 213](https://github.com/lambdasistemi/singular/issues/213).

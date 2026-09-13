# NOTE-050 — NOTE-149 pinned mintless compiler API and ACK boundary

Read in full. Preserve the same `%994` Pi process, native session, isolated
source tree, retained histories/failures and the current NOTE-048/049
offline-only work. Do not abort an in-flight edit or compiler command. At the
next safe boundary, before any NOTE-049-dependent result can receive credit,
append durable `STATUS.md` entries confirming that NOTE-049 and this NOTE-050
were read in full. NOTE-049 is already in native user history as event
`01b320ad` at `2026-09-13T02:52:07.667Z`; it is not being resent, and this note
does not restart or replace that turn.

Root's bounded pinned-compiler diagnosis is frozen at:

`/tmp/projects/singular/milestone-1/handoffs/rival-root-mintless-api-diagnosis.json`

SHA256:
`c32e90d656ed95b643bbb68486217d651ce961db60184bba826048c110c38023`.

This is public-API/type evidence under the pinned GHC 9.12.3 environment only.
It is not a compile/run receipt for your actual control and not rival
acceptance.

## Stop guessing the pinned APIs

- A standalone helper does not inherit the cabal component's
  `OverloadedStrings`. Give byte literals an explicit `ByteString`
  construction/type or enable that extension intentionally; a ByteString
  annotation alone does not convert a `String` literal.
- For synthetic control fixtures, the public constructions that typecheck are:

  ```haskell
  TxId (unsafeMakeSafeHash (castHash (hashWith id bytes))) :: TxId
  ScriptHash (castHash (hashWith id bytes)) :: ScriptHash
  unsafeMakeSafeHash (castHash (hashWith id bytes)) :: ScriptIntegrityHash
  ```

  Here `bytes` is explicitly `ByteString`, and the result type fixes the hash
  algorithm. Import `unsafeMakeSafeHash` from `Cardano.Ledger.Hashes`.
  `Cardano.Ledger.SafeHash` is unavailable at this pin; direct coercion into
  abstract `SafeHash`/`TxId` is not the route. `hash` is ToCBOR-constrained;
  `hashWith id` is the raw-byte fixture operation.
- For `b :: TxBody TopTx ConwayEra`, inspect the body using lenses:

  ```haskell
  b ^. inputsTxBodyL
  b ^. outputsTxBodyL
  b ^. feeTxBodyL
  b ^. scriptIntegrityHashTxBodyL
  ```

  Do not call those lenses as ordinary functions.

These constructors are permitted only for synthetic positive/negative control
fixtures. They must not replace production `deriveAssetName`, actual signed
transaction construction, or NOTE-049's one shared configured-seed-to-token
verifier.

## Required executed evidence

Retain every earlier compiler/API failure and its true exit with no semantic
credit. GHCi can return exit 0 after reporting errors, so an exit alone is not
a successful probe. Finish the actual shared-construction mintless control
with a real compile exit, real run exit, empty/error-checked diagnostics and
the required positive versus injected-hash discriminator. Then continue the
already-bounded NOTE-049 signed evidence, executable rebuild/Nix rebind and
fresh-root unexecuted-command handback.

No node, socket, query, submission, official wrapper, result-root creation,
ledger replay or second ledger run. No new seat/session/model, product or
compositor work, schema/model adoption, commit, push, merge, release or
acceptance.

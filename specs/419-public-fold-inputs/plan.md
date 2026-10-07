# Public fold inputs: plan

Read the [spec](spec.md) for the stories and requirements and the [ruling](ruling.md) for
the decision. Base: main `7b255f96`.

## Strategy

The request carries the datum it names, as upstream MPFS requests carry their content.
Lean moves first and states the property; the cage and the off-chain wire then swap
together, because a request written in one wire cannot be read in the other; the
two-actor run closes the story on a development network. Each slice is pushed as soon
as its gate is green.

## Module rows

| Module | Responsibility after this ticket |
|---|---|
| `lean/Singular/Model.lean` | `Request` carries `datum`, the datum value or none; a delivered output and a holding carry a datum value; `PublicView` and `buildFold` state what a folder reads. |
| `lean/Singular/Statements.lean` | The three statements below, over all seven edges, replacing `delivered_datum_follows_request`. |
| `lean/Singular/Driver.lean`, `lean/driver-corpus.json`, `lean/corpus.json` | Request rows carry the datum value instead of `namesDatum`; protocol version and surface digest move. |
| `applications/open-datum/lean/` | Follows the root model's datum field. |
| `simulator/` | Byte mirror of `lean/` and its derived corpus. |
| `conformance/` | Driver transport, live translation and coverage records follow the model. |
| `onchain/validators/types.ak` | `Request.destination : (ByteArray, Option<Data>)`. |
| `onchain/validators/lib.ak` | Destination match by datum equality; the approval name's datum hash derived from the carried datum. |
| `onchain/validators/registry/` | Fold, duties and discharge read the new destination. |
| `naming-onchain/validators/naming.ak`, `retirement_custody.ak` | The request mirror follows the cage's wire. |
| `offchain/lib/Singular/Registry/Wire/Request.hs` and builders | Encode and decode the new destination; the fold builds the receiving output from the request's datum. |
| `offchain/lib/Singular/Application/OpenDatum/Book.hs` | Booking writes the envelope into the request. |
| `offchain/cli/src/Singular/CLI/Fold.hs` | Reads the envelope from the request the provider returns, never from the directory. |
| `offchain/cli/src/Singular/CLI/Preimage.hs` | Removed, with `preimages/` and every caller. |

## Data rows

- **Request destination (chain).** Address bytes, then `None` or `Some(datum)`. The
  datum hash used by the approval name is `blake2b_256(cbor.serialise(datum))` for
  `Some`, empty for `None`. Nothing else stores a hash.
- **Request datum (model).** `Request.datum : Option Nat`, an abstract datum value.
  `namesDatum` is removed.
- **Delivered output datum (model).** A transaction output carries `none` or
  `inline v` with its value; the receiving output of a delivering fold carries the
  request's datum.
- **Holding datum (model).** A holding records the datum value its delivery wrote; a
  witness input presents it.
- **Public view (model).** The registry state as its outputs show it, the holdings with
  their datums, and the pending requests as they sit at the cage. It has no other field.

## Function rows

| Name | Arguments | Result |
|---|---|---|
| Lean `publicView` | `s : RegistryState`, `pending : List Request` | `PublicView` |
| Lean `buildFold` | `view : PublicView`, `reference : Nat`, `lovelace : Nat` | `Except String Tx` |
| Aiken `lib.destinationMatches` | `destination: (ByteArray, Option<Data>)`, `out: Output` | `Bool` |
| Aiken `lib.datumMatches` | `expected: Option<Data>`, `datum: Datum` | `Bool` |
| Aiken `lib.destinationDatumHash` | `datum: Option<Data>` | `ByteArray` |

`lib.approvalName` keeps its signature over `(ByteArray, ByteArray)`; the cage feeds it
the address and `destinationDatumHash`.

## Lean statements

- `delivered_datum_is_request_datum`: every receiving output of an admitted fold carries
  exactly `r.datum`, over all seven edges.
- `fold_inputs_public`: for every state and request,
  `txOf s r lovelace = buildFold (publicView s [r]) r.reference lovelace`.
- `fold_refuses_foreign_datum`: an observed fold whose receiving output carries a datum
  other than `r.datum` is refused `destination`.

## Consumers of the model change

Each one is run locally before the first push of the Lean slice: `lean/driver-corpus.json`,
`lean/corpus.json`, `lean/Main.lean`, the theorem manifest and `docs/theorems.md`,
`tools/check_model.py`, `applications/open-datum`, the simulator mirror and its derived
output, `conformance/lean/DriverTransport.lean`, `Conformance.Run.Live`, the coverage
records under `conformance/coverage/`, and the constitution's `tx` row.

## Slices

1. **Model.** The datum value in request, output and holding; the three statements; every
   consumer above; constitution amendment for the `tx` row.
2. **Wire.** The cage, naming's mirror, script identities and vectors, the off-chain wire,
   booking and fold, in one change; `Preimage.hs` and `preimages/` removed.
3. **Two actors.** On a development network Alice books and Bob folds from a directory
   holding only `registry.json`, with Alice's directory unreadable; the trie is rebuilt
   from chain history (#411) and the envelope read from the request.

## Gate

The gate is the existing CI commands that exercise what each slice can break; the RED
commit is the failure control; `nix develop --quiet -c just ci` runs once on the final
candidate; hosted CI is the net. The frozen gate with its rows, commands and expected
exits is kept with the ticket's runtime records.

## Live boundary

No preprod write and no new registry. The two-actor run uses the CI development network.

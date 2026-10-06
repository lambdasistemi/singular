# Public fold inputs: stories and requirements

Issue [#419](https://github.com/lambdasistemi/singular/issues/419), child of epic
[#301](https://github.com/lambdasistemi/singular/issues/301). Read the
[ruling](ruling.md) for the design decision, the [plan](plan.md) for the module rows
and slices, and the [tasks](tasks.md) for the commit boundaries. Base: main `7b255f96`.

## User stories

As Bob, a folder unrelated to Alice, I fold Alice's pending insertion from what the
chain shows, so her request is processed without her staying online and without any
application running its own datum service.

As Alice, the booker of an insertion, I cannot create a request that names a datum
nobody else can read: the request carries the datum it names.

As a maintainer, I see the model fail to build whenever a fold needs an input that the
chain does not hold.

## The defect

A request named its delivered output's inline datum only by its BLAKE2b-256 hash
(`destination`, `onchain/validators/types.ak:359-373`). The datum itself lived in the
booker's registry directory (`offchain/cli/src/Singular/CLI/Preimage.hs`), so only the
booker could fold an insertion. Upstream MPFS requests carry their content inline; the
hash-only destination came with the registry-mode cage (#157, `240ede16`). The model
reduced the delivered datum to `Request.namesDatum : Bool`, so availability of the
fold's inputs was never stated.

## Requirements

- **Fold inputs are public.** Every fold the registry admits can be built by any party
  from chain data alone: the registry state output, the holdings it commits to, and the
  pending requests at the cage. No file from the booker is read.
- **The request carries its datum.** A request's destination is its address and the
  datum itself, or no datum. A request cannot name a datum it does not carry.
- **Delivered datum is the request's datum.** For `insertActive`, `updateActive` and
  `witnessTerminal`, the receiving output carries exactly the datum the request carries,
  and no datum when the request carries none. Any other datum is refused `destination`.
- **Approval binding unchanged.** An approval's asset name is `blake2b_256(edge ‖ key ‖
  owner ‖ address ‖ datum hash)` as before; the cage derives the datum hash from the
  carried datum (empty when none). The open and naming approval policies do not change
  their redeemers or rules.
- **Absent custody stays public.** `insertAbsent` locks its token under
  `AbsentCustody{refund}`, built from the request's own fields.
- **Reject and retract unchanged.** A reject refunds the owner with no datum; a
  retraction returns the request's value bound to its reference.

## Rejection behavior

- A fold whose receiving output carries a datum other than the request's is refused
  `destination`, on chain and in the model.
- A fold whose receiving output carries a datum when the request carries none, or none
  when it carries one, is refused `destination`.
- A booking whose datum makes its single-request fold larger than the ledger's maximum
  transaction size is refused by the command before submission.

## Observable success

- On a development network, Alice books an insertion from her directory and Bob folds
  it from a directory holding only the registry identity and trie state, with Alice's
  directory unreadable; the active token sits at Alice's destination under her datum.
- `Preimage.hs` and the `preimages/` directory are gone.
- The Lean statements below build in CI: `delivered_datum_is_request_datum`,
  `fold_inputs_public`, `fold_refuses_foreign_datum`.

## Non-goals

- Bob starting from an empty directory and rebuilding the trie from chain history is
  [#381](https://github.com/lambdasistemi/singular/issues/381)'s story.
- Existing registries (registry-go3 and the GO-2 registry) cannot be upgraded; they stay
  as they are. Creating a preprod registry from the new release needs its own operator
  authorization.

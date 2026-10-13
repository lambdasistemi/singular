# A write asks the wallet for what it costs: plan

Spec: spec.md. One pull request, one slice, about 180 writer minutes. Class:
behaviour change on client policy (a refusal rule), no on-chain code, no Lean
model change, no wire change.

## Decisions

- **Remove the floor from the session opening.** `withWritesObserved` becomes the
  provider read plus the body, with no wallet threshold. Rejected alternative: a
  threshold derived from the protocol parameters at session opening. Still not the
  operation's cost, and the same misclassification.
- **Judge where the cost is measured.** The outlay of a built booking already
  exists (`bookingOutlay`) and is already judged against `--max-outlay` at the one
  place each booking verb builds. The wallet judgement sits beside it, in the same
  turn, so preview and write cannot differ. Only a booking has a cost beyond its
  own transaction (the fold reserve), so only it needs the post-build judgement;
  for `update`, `reject` and `reclaim` the built body proves the wallet pays the
  fee. The same function is also called once before building with the fold
  reserve alone, which the parameters and the reference scripts give without a body, so a wallet that cannot
  cover even that is refused before anything is built.
- **One pure function, one effect.** `walletShortfall` (pure, beside `Outlay`)
  decides from the wallet's outputs and a required lovelace amount.
  `refuseUnderfunded` (beside `refuseOver`) raises the refusal, naming what the
  amount is (the fold reserve, or the measured outlay). No second copy of the
  arithmetic.
- **Outcome class.** The existing `client-refusal`, exit 10, with fields and the
  words "(client policy)". Rejected: a new outcome class. It would change the
  public outcome list in `Receipt.hs` and every conformance enumeration of
  outcomes, for no distinction a reader cannot already make from the fields.
- **Empty wallet before building.** `selectFunding` (already public) is called on
  the wallet's outputs before the builder, so that "no ada-only output" and
  "chosen output not the wallet's" are named refusals instead of the builder's
  uncaught error.
- **Wallet argument retained.** `withWrites` keeps its `Wallet` argument although
  nothing in it reads the wallet any more. Removing it ripples through `Session.hs`
  (`envWrites`) and nine other callers. Recorded as a residual, to remove after
  #518 pull request 3 merges.

## Slice: wallet judged on the measured outlay

Ordered, one pull request, no intermediate push.

1. Remove the floor call and its now unused imports from `Terminal.hs`.
2. Add `walletShortfall` to `Outlay.hs` and `refuseUnderfunded` to `Plan.hs`
   (re-exported by the open-datum `Plan`).
3. Call them in `Entry.hs` (`book`: empty-wallet check, fold-reserve check, then
   after the build the measured check beside `refuseOver`; `update`: empty-wallet
   check) and `Preview.hs` (`previewBooking` and the update arm), in the same order.
4. Document the rule in `docs/singular-node.md`; correct the module description in
   `Funding.hs` and `docs/offchain-node-ownership.md` (the fixed floor is the
   conformance runner's).
5. Tests (all in the open-datum test suite, hosted job `open-datum-tests`):
   - table rows for `walletShortfall`, expected values by arithmetic from the
     outlay's parts, boundary at exactly the amount and one lovelace under;
   - the 20 ada in two outputs wallet: preview and write both succeed, over the
     in-memory chain used by `WriteSpec`;
   - an underfunded wallet: preview and write both `client-refusal`, same
     `held`, `required`, `shortfall`; nothing signed or submitted on the write;
     one wallet under the fold reserve (refused before building) and one between
     the reserve and the measured total (refused after building);
   - an empty wallet and a foreign `--fund-input` on insert and update: refused
     before the builder runs;
   - session opening: a scripted provider with a 20 ada wallet opens `withWrites`
     and runs a body; the base refuses it (RED evidence).

## Failure modes this change alters

- A nearly empty wallet used to be stopped at session opening with a readable
  message. It is now stopped in the body with named fields (insert, terminate; the
  empty wallet for update) or by the verb's own builder message (the rest). The
  second group is the stated limit.
- A wallet the floor accepted is refused now only when it holds less than the
  measured outlay of a booking (a deposit of more than the wallet holds is the
  case). The test table includes a wallet at the old floor.

## Gate (budget about 30 minutes)

The hosted commands, narrowed by the suite's filters to this slice: the open-datum
test suite (`nix run --quiet .#open-datum-tests` from `applications/open-datum/offchain`),
fourmolu and hlint through `nix run --quiet .#lint` in the same directory and in
`offchain`, and `just docs-check` for the specs pages. One `just ci` on the final
head; hosted CI is the net.

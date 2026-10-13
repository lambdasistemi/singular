# A write asks the wallet for what it costs: touch list

The only files the writer may change. A file outside this list needs the milestone
owner's ruling before it is touched. Base: main af16bad4.

## Production

| File | Change |
|---|---|
| `offchain/koios-http/src/Singular/Registry/Terminal.hs` | Remove the `checkFunding` call in `withWritesObserved`, its imports and the stale comment. The `Wallet` argument stays (plan, "Wallet argument retained"). |
| `offchain/cli/src/Singular/CLI/Outlay.hs` | Add `walletShortfall`, pure. |
| `offchain/cli/src/Singular/CLI/Plan.hs` | Add `refuseUnderfunded` beside `refuseOver`. |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Plan.hs` | Re-export `refuseUnderfunded` as it re-exports `refuseOver`. |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Entry.hs` | Call the three checks in `book`; the empty-wallet check in the update path. |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Preview.hs` | The same calls in `previewBooking` and the update arm of `runPreview`. |
| `offchain/lib/Singular/Registry/Funding.hs` | Module and type descriptions only: the fixed floor belongs to the conformance runner. No code change. |

## Documentation

| File | Change |
|---|---|
| `docs/singular-node.md` | The wallet rule beside the outlay rule: what is judged, when, the refusal and its fields. |
| `docs/offchain-node-ownership.md` | The `Singular.Registry.Funding` row (line 62). |
| `specs/526-wallet-floor/*` | This mandate and its speech files. |

## Tests

| File | Change |
|---|---|
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/OutlaySpec.hs` | Rows for `walletShortfall`. |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/WalletShortfallSpec.hs` | New. Preview and write over the in-memory chain: the 20 ada wallet, the two refusals, the empty wallet, the foreign funding output; and `withWrites` over the scripted provider. |
| `applications/open-datum/offchain/open-datum.cabal` | One line in the `open-datum-tests` modules for the new spec. |
| `applications/open-datum/offchain/test/Main.hs` | The import and the `describe` of the new spec. |

Hosted job for every new test: `open-datum-tests` in `.github/workflows/ci.yml`
(`nix run --quiet .#open-datum-tests`). No new runnable file other than the spec.
No workflow, flake or script changes.

## Not touched, by name

`Session.hs`, `Receipt.hs`, `Reconcile.hs`, `Fold*.hs`, `Command.hs` and both
`CommandRunSpec.hs` (#518 pull request 3 and #503); `Create.hs`, `CLI/Registry.hs`,
`TxBuilder/Edges.hs`, `CreateFundingSpec.hs`, `tools/demo1_cli_journey.sh` (#406);
`Describe*.hs`, `Inspect.hs`, `offchain/singular-registry.cabal`,
`offchain/test/Main.hs` (#503); everything under `conformance/`; `Reject.hs`,
`Reclaim.hs` (plan: the built body proves the fee).

## Needs a ruling

| File | Why | Recommendation |
|---|---|---|
| `tools/demo1_cli_controls.sh` line 71 | A comment says the wallet is sized to pass "the write session's 100 ada funding floor". It will be false. | Replace the comment in this pull request (comment only; not on the #406 list). |
| `tools/demo1_cli_journey.sh` line 995 | The same comment, in the #406 lane's file. | Leave to the #406 owner, or a comment-only commit after that lane merges. |

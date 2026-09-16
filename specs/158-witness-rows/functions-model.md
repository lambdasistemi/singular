# #158 — functions model

Signatures only.

## Builders (`offchain/lib`)

| declaration | shape |
|---|---|
| `buildApprovalMint edge key owner destination signers` | a transaction minting one approval under the application policy |
| `buildRequest op key destination approval tip` | a request UTxO at the cage carrying the approval (none for `Read`) |
| `buildFold state requests proofs mints outputs` | a `Modify` with the per-key mint and the destination/custody outputs |
| `buildCustodySpend custody request` | the custody input beside its consuming request |
| `buildRetireWithCompletion record custody key` | `Retire` plus the co-minted terminate approval and the completion request |
| `buildFreeBurn token` | a burn under the terminal policy with no registry input |

## Journey (`offchain/journey/witness-rows/Main.hs`)

| declaration | shape |
|---|---|
| `main` | runs `setup`, then rows WR01…WR12 in order; writes the report; exits by `verified` |
| `setup` | boots or reuses a registry; registers `bob`; retires and completes `alice` (or reuses the supplied evidence) |
| `row :: RowId -> Expect -> IO Observation` | one per row; never catches a failure it cannot attribute |
| `attribute :: SubmitFailure -> Maybe (Script, Trace)` | parses the phase-2 failure into script hash and trace |
| `verify :: Observation -> Expect -> Bool` | as `data-model.md` |

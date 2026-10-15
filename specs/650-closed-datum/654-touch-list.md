# Closed mode: touch list

The only files the writer may change. A file outside this list needs a ruling
before it is touched. Base: main cfe78df1. The open branches of the
wallet-preparation work (`feat/491-prepare-application` at 0d1d184e and
`feat/491-wallet-output-preparation`) were read on 15 October 2026 for
collisions: their diff against the base names nine files, none of them below.

## Production

| File | Edit or create | Why | Collision |
|---|---|---|---|
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Value.hs` | edit | The mode, its titles, the application value for a mode and the closed value. The open constant keeps its name and every field. | None. |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Command.hs` | edit | `--closed` split out before the shared tokenizer, refused by name off create, carried as the create command's first field; the usage text. | None. |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Run.hs` | edit | The mode read, the following environment, the update refusal, and the mode's value for create, fold and inspect. | None. |

## Tests

| File | Edit or create | Why | Collision |
|---|---|---|---|
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/ClosedModeSpec.hs` | create | The unit tests of the change. | None. |
| `applications/open-datum/offchain/test/Main.hs` | edit | Register the new module with its tags. | None. |
| `applications/open-datum/offchain/open-datum.cabal` | edit | The new test module under `other-modules`. The library's module list does not change. | None. |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/CLISpec.hs` | edit | The four places that match `OpenCreate` take its new first field; usage assertions follow the help text if they name it. | None open. |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/CommandRunSpec.hs` | edit, one token | Line 560 matches `OpenCreate _`; it takes the new field. This is the open-datum file, not the registry command line's file of the same name that the wallet-preparation work edits; it is absent from that work's diff. | None open. |
| `applications/open-datum/offchain/test/Singular/Application/OpenDatum/FlagGroupExtentSpec.hs`, `ManagedStateSpec.hs` | edit only if red | They compare parser extent and the usage text. The writer touches them only where the new switch or help line turns them red, and says so. | None open. |

## Documentation

| File | Edit or create | Why | Collision |
|---|---|---|---|
| `docs/singular-node.md` | edit | A settings-table row for `--closed` on `open-datum create`: the documented-flags check requires every flag the help prints to be in this table. | None open; the merged vault change touched it. |
| `docs/singular-node.speech.json`, `docs/audio/` | regenerate | Speech by the extraction tool, never by hand; clips only for the segments that changed, with the standing narration authorization. | None. |
| `onchain-release/DEMO1.md` | edit | A paragraph on the closed registry and `open-datum create --closed`. It adds no numbered step, so the journey's page check is unchanged. | None open. |
| `onchain-release/DEMO1.speech.json` | regenerate | Speech by the extraction tool. | None. |
| `specs/650-closed-datum/654-spec.md`, `654-plan.md`, `654-tasks.md`, `654-touch-list.md` | create | This mandate. | None; issue 651 owns the unnumbered pages of the folder. |
| `specs/650-closed-datum/654-*.speech.json` | create | Stamped speech of each page, produced by the extraction tool. | None. |

## Read, and found to need no edit

| File | Why it needs none |
|---|---|
| `offchain/cli/src/Singular/CLI/Create.hs`, `Inspect.hs`, `Booking.hs`, `Attached.hs`, `Describe.hs`, `Session.hs`, `Registry.hs` | They load code through `envLoadRelease` and name the pin title only in the loader and in the create receipt. The mode reaches them through the application value or the environment. |
| `offchain/lib/Singular/Registry/StateToken.hs`, `Application.hs` | The resolution derives the policy from the loaded code and refuses on a mismatch; `findStateOutput` and `applyPin` are used as they are. |
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Root.hs`, `app/Main.hs` | The packaged runner ignores the application argument and calls the dispatch. |
| `applications/open-datum/negative/`, `conformance/` | They name the open constant, which keeps its name and value. |
| `.github/workflows/*`, `nix/*.nix`, `flake.nix`, `tools/*` | No new job and no new check name, so no ruleset change. The documented-flags and journey checks read the help, the table and `DEMO1.md`; they need no edit. |

## Not touched, by name

The registry library under `offchain/lib`, the `singular` commands and the
registry command line under `offchain/cli`, the on-chain code and its identity
records (issue 651), and all Lean. The files the wallet-preparation work changes:
the open-datum `Entry.hs`, `Plan.hs`, `Preview.hs` and `WalletShortfallSpec.hs`,
and the registry command line's `Prepare.hs`, `Plan.hs` and `CommandRunSpec.hs`.
The files the signing work changes: the wallet, vault, passphrase and
local-services files.

## Rulings taken

| Question | Ruling |
|---|---|
| How does `--closed` reach the parser without changing `singular`? | The open-datum parser splits it out before the shared tokenizer; the shared switch list is not edited. |
| Where is the title read, so that Entry need not change? | In the release loader alone, which the environment carries; the dispatch swaps the loader. |
| Does `CommandRunSpec.hs` need the wallet-preparation work's leave? | No: the file is the open-datum suite's, absent from that work's diff, and the edit is one token. |

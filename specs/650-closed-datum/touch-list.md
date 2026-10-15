# Closed datum: touch list

The only files the writer may change. A file outside this list needs a ruling
before it is touched. Base: main cfe78df1. Open pull requests were read on
15 October 2026 for collisions.

## Production

| File | Edit or create | Why | Collision |
|---|---|---|---|
| `applications/open-datum/onchain/validators/open_datum.ak` | edit, append only | The closed-datum validator after the last line. No existing line changes, no import changes. | None open. The eight mutant patches of the negative host point at lines far above the append and stay valid. |
| `applications/open-datum/onchain/validators/open_datum.tests.ak` | edit, append only | The closed-datum rows, beside the open rows they mirror. They print no boundary context line. | None open. |
| `applications/open-datum/onchain/script-identity.json` | edit | Three closed rows, generated from the built blueprint. The three open-datum rows are unedited. | None open. The negative host regenerates this file only in scratch copies. |
| `applications/open-datum/onchain/flake.nix` | edit | The merged blueprint check expects 17 validators, in the test and in its messages. The composed-suite check requires its log to name a closed refusal test and plants a copy whose closed `Update` arm accepts, which the suite must refuse. Comments that state the present count follow; the dated measurement comment stays as it is. | None open. |
| `tools/assemble_onchain_release.py` | edit | The merged manifest assertion and its message count 17; the comment above them follows. | None open. |
| `flake.nix` | edit | The `script-hash-comparison` app reads the declared additions, admits exactly those, and gains two plants. Its comments that state the present count follow. | Open pull request 597 edits this file near lines 846 and 935, and the merged vault change touched line 939. The comparison is near lines 1180 to 1380. A rebase is mechanical. |
| `specs/650-closed-datum/evidence/declared-additions.json` | create | The titles of the three declared closed-datum validators. | None. |

## Documentation

| File | Edit or create | Why | Collision |
|---|---|---|---|
| `specs/650-closed-datum/spec.md`, `ruling.md`, `plan.md`, `tasks.md`, `touch-list.md` | create | This mandate. | None. |
| `specs/650-closed-datum/*.speech.json` | create | The stamped speech of each page, produced by the extraction tool and never edited by hand. | None. |

## Read, and found to need no edit

| File | Why it needs none |
|---|---|
| `tools/check_release.py` | It names no validator title and no count. |
| `tools/m1_identity.py`, `applications/open-datum/onchain/permanent-contract.json`, `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Permanent.hs` | The generator selects the three open-datum titles exactly, so a fourth to sixth validator changes no output. Its check stays fresh. |
| `tools/m1_boundary.py` | It looks validators up by exact title and requires four application contexts; the new rows print none. |
| `tools/negative_host_mutants.sh` and the eight patches | The regeneration scope guard accepts any changed row whose title starts with `open_datum.`, which the closed rows do; patch hunks sit above the append. Proved by the negative-host jobs. |
| `onchain-release/verify-identities.sh` | Quantified over the blueprint's validators, so seventeen are checked without an edit. |
| `.github/workflows/*`, `nix/*.nix` | No new job and no new check name, so no ruleset change. |

## Not touched, by name

The registry contract under `onchain/`, the registry library under `offchain/lib`,
the `singular` commands under `offchain/cli`, the open-datum executable and its
tests including `Entry.hs`, `Plan.hs`, `Preview.hs`, `WalletShortfallSpec.hs`,
`Prepare.hs`, `CommandRunSpec.hs` (wallet preparation), the wallet, vault,
passphrase and local-services files (signing), the negative-host sources under
`applications/open-datum/negative`, every workflow, and `lean/`.

## Rulings taken

| Question | Ruling |
|---|---|
| Can the closed-datum validator live in its own file? | No: Aiken refuses a validator import outside a test module. It is appended to `open_datum.ak`, titled `open_datum.closed_datum.*`. |
| Where do the tests go? | In `open_datum.tests.ak`: a test module that imports a validator may not export `pub` items, so a second file cannot reuse the fixtures. |
| Where are the declared additions recorded? | In a new record under this folder, not in the merged base-hashes file. |

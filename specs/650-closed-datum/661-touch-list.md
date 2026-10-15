# Closed update refused by the node: touch list

The only files the writer may change. A file outside this list needs a ruling before it
is touched. Base: main 38c2e436. The open pull requests were read on 15 October 2026 for
collisions: draft 597 edits `.github/workflows/negative-host.yml` (in four places, one of
them next to the self-check job this change extends) and `flake.nix`; draft 662 (the journey of issue 660)
names the negative host, its workflow and `negative_host_*` tools as not touched, and
touches `onchain-release/DEMO1.md`, which this change does not.

## Production

| File | Edit or create | Why | Collision |
|---|---|---|---|
| `applications/open-datum/offchain/src/Singular/Application/OpenDatum/Run.hs` | edit | Export the two mode readers (`readModeFor`, `readModeForFold`) so the host reads the mode as the executable does. No body changes. | None open: the wallet-preparation work changes `Entry.hs`, `Plan.hs` and `Preview.hs`, not this file. |
| `applications/open-datum/negative/src/Negative/Run.hs` | edit | The five handlers that resolve a registry read the mode and pass the mode's application value and environment to the call that resolves it. | None open. |
| `applications/open-datum/negative/pairs.json` | edit | Add `closed-update`. | None. |
| `tools/negative_host_part.sh` | edit | The part list, the closed create flag, the pin comparison, the forbidden command, the control, and the judge's expectations. | None open. |
| `tools/negative_host_node_free_controls.sh` | edit | The membership control lists fourteen names; the header comment drops the number. | None open. |
| `applications/open-datum/negative/mutants/rules.json` | edit | Add the row of `closed-update-accepted`. | None. |
| `applications/open-datum/negative/mutants/closed-update-accepted.patch` | create | The one-line replacement in the closed spend's update arm. It is applied to a scratch copy by the runner; the tree's validator is never edited. | None. |
| `nix/negative-host.nix` | edit, one comment | The comment that carries the count of part names. | Draft 597 adds a different file next to it (`nix/result-cache.nix`); none in this file. |
| `.github/workflows/negative-host.yml` | edit | One added step in the mutant self-check job, running the no-patch control over `closed-update-accepted` beside the registry mutant's, and the comment that carries the count of part names. No job or job name changes, so no ruleset change. | Draft 597 edits four other places in this file; one of its hunks inserts a new job right after this job's last step, which is where the added step goes, so the later rebase keeps both texts. |

## Documentation

| File | Edit or create | Why | Collision |
|---|---|---|---|
| `docs/negative-host.md` | edit | The part and the mutant, and the counts they change (pairs, stories, mutants). | None open. |
| `docs/negative-host.speech.json`, `docs/audio/` | regenerate | Speech by the extraction tool, never by hand; clips only for the segments that changed, with the standing narration authorization. | None. |
| `specs/650-closed-datum/661-spec.md`, `661-plan.md`, `661-tasks.md`, `661-touch-list.md`, `661-gate.md` | create | This mandate and its frozen gate. | None; the folder's other pages belong to issues 651 and 654 and draft 662. |
| `specs/650-closed-datum/661-*.speech.json` | create | The stamped speech of each page, produced by the extraction tool. | None. |

## Read, and found to need no edit

| File | Why it needs none |
|---|---|
| `applications/open-datum/negative/src/Negative/Craft.hs`, `Read.hs`, `Submit.hs`, `Parse.hs`, `app/Main.hs` | They name the open value only for holding rules and the application address, which both modes share; the failing-script judge resolves the registry's own pin from the saved registry. |
| `applications/open-datum/negative/singular-negative.cabal`, `nix/negative-host.nix` (apart from its comment) | No module is added and no dependency changes. |
| `applications/open-datum/onchain/validators/open_datum.ak`, `.tests.ak`, the identity records | The validator is not edited; the mutant patches a scratch copy. |
| `tools/negative_host_mutants.sh` | Reads the table; the patch passes its hygiene unchanged (one file, one label removed). |
| `.github/workflows/*` apart from the one file above, `flake.nix` | The matrices discover parts and mutants from the tables; no job or name is added, so no ruleset change. |

## Not touched, by name

The registry library under `offchain/lib`, the `singular` commands and the registry
command line, the validator source and its identity records, and all Lean. The files the
wallet-preparation work changes: the open-datum `Entry.hs`, `Plan.hs`, `Preview.hs` and
`WalletShortfallSpec.hs`, and the registry command line's `Prepare.hs`, `Plan.hs` and
`CommandRunSpec.hs`. The files the signing work changes: the wallet, vault, passphrase and
local-services files. The journey's files (`tools/demo1_closed_*`, `registry.yml`,
`onchain-release/DEMO1.md`).

## Rulings taken

| Question | Ruling |
|---|---|
| Does the host copy the mode read? | No: the two functions the executable uses are exported and the host calls them. |
| Do Craft and Read change? | No: they use the holding rules and the address, which the two modes share. |
| Is a new job or a new required name needed? | No: the matrices read the tables and the ruleset lists the aggregators. The self-check job gains a step, and keeps its name. |
| Does the patch edit the validator? | No: the runner applies it to a scratch copy and regenerates the identity records there. |

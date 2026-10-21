# Payload written as plain JSON: plan

The story, the mapping and the refusals are in the [spec](spec.md). Shapes are in the
[modules model](modules-model.md), the [data model](data-model.md) and the
[functions model](functions-model.md); the task list is in [tasks](tasks.md).

## Strategy

One pull request, `Closes #719`; the intake found no independent part. The change keeps the chain
behaviour of every command, so the process is a behaviour change on the off-chain side only
(one commit owner, one persistent auditor) and a documentation part that gets no checkpoint.

The mapping is a pure library module, written test first. The commands then read every payload
file through one reader that takes the schema, and print every payload through one view. The
callers of the old behaviour inside this repository (shell journeys, the conformance backend, the
negative host sources) are moved in the same commit as the behaviour that breaks them, so each
commit builds and each hosted job stays green.

## Slices

Each slice builds and passes its gate on its own.

| slice | what it adds | where |
|---|---|---|
| plain mapping | the library module with the table in both directions, the digit limit, the refusals, the view; unit tests, the round-trip property and its generators | `offchain/lib`, `offchain/test` |
| payload schema on the commands | `PayloadSchema` in the entry arguments; the flag declared once; one reader for insert, update, previews, register and the negative host; the detailed-document refusal; help snapshots, parser corpora, the settings spec; every in-repository caller that writes a detailed file passes the setting | `offchain/cli`, `applications/*`, `tools`, `demo1`, `conformance` |
| printed payload | `payload` and `payloadSchema` from the shared inspect code and the update receipt; `dhPayloadJson` removed when nothing reads it; every in-repository reader of the printed payload moved | `offchain/cli`, `offchain/lib`, `applications/*`, `tools`, `demo1`, `conformance` |
| hosted evidence | the Demo 1 journey stores `{"answer": 42}` with no setting and reads it back; updates it; stores a detailed document with the setting; refuses a detailed file without it | `tools/demo1_cli_journey.sh` |
| documentation | the page with the table; the flag row; the pages that show payload files; speech and narration | `docs`, `mkdocs.yml`, `docs/audio` |

## Files that change with a payload flag or a printed payload

The commit owner starts from this list and from the compiler. Search again for `--payload`,
`applicationOutput.payload`, `.payload ==` and `dataFromJson` before the last slice.

| consumer | why it changes |
|---|---|
| `offchain/cli/src/Singular/CLI/Declared.hs`, `Command.hs`, `FlagGroup.hs` | the flag and the entry argument; the refused-flag lists name `--payload` |
| `applications/open-datum/offchain/src/.../Command.hs`, `Help.hs`, `Plan.hs`, `Preview.hs`, `Entry.hs`, `Run.hs` | parsing, help, and the four places that read a payload file |
| `applications/open-datum/negative/src/Negative/Run.hs` | reads a payload file by the detailed schema directly |
| `applications/keri-stub/offchain/src/.../Command.hs`, `Register.hs`, `Value.hs` | register reads the file; usage text; the holding view |
| `offchain/cli/src/Singular/CLI/Inspect.hs`, `applications/open-datum/.../Entry.hs` | the printed payload |
| help snapshots `applications/open-datum/offchain/test/fixtures/help/open-datum/{insert,update}.txt` | record with `HELP_SNAPSHOT_RECORD=1` |
| parser corpora `.../cli-corpus/open-datum.json`, `offchain/test/fixtures/cli-corpus/singular.json` | a changed line keeps `result` and gains `after`; one accepted line for each distinct result |
| `applications/open-datum/offchain/test` specs that run the commands; the application settings spec | refusal texts, the flag, the printed payload |
| `tools/demo1_cli_journey.sh`, `demo1_cli_prepare_funding.sh`, `demo1_closed_journey.sh`, `cli_recovery_controls.sh`, `negative_host_part.sh`, `negative_host_node_free_controls.sh`, `keri_stub_journey.sh`, `registry_bundle_control.sh`, `registry_two_actors.py` | payload files in the detailed schema get the setting; reads of `payload` follow the new print |
| `demo1/rehearsal/*` | the same, for the rehearsal scenes |
| `conformance/app-cli/Conformance/Cli/Backend.hs`, `conformance/lib/Conformance/Cli/Controls.hs` | writes detailed payload files; compares the update receipt with inspect |
| `docs/singular-node.md` (flag table), `docs/negative-host.md` and the pages that show payload files | the flags check reads them |

## Gate

The gate for a candidate is the existing hosted commands, narrowed by the suites' own filters to
what the slice can break. The hosted jobs are the net; none is rerun locally as a whole. Every
build or test runs under a systemd scope with a memory cap and a timeout.

| acceptance line | command, from the workflow | expected |
|---|---|---|
| plain mapping, round trip, refusals | in `offchain`, the "Run the focused off-chain suite" step of the registry workflow, `nix run --quiet .#cage-tests`, narrowed with `-- --match "PlainJson"` | exit 0 |
| open-datum commands read both schemas, refusals, printed payload | "Open-datum tests": `cd applications/open-datum/offchain && nix run --quiet .#open-datum-tests` narrowed with `-- --match <the specs the slice touches>` | exit 0 |
| keri-stub register and status | "Keri-stub tests": `cd applications/keri-stub/offchain && nix run --quiet .#keri-stub-tests` | exit 0 |
| Haskell formatting and lint | "Off-chain lint": `(cd offchain && nix run --quiet .#lint)`; the same in `applications/open-datum/offchain` and `applications/keri-stub/offchain`; `nix run --quiet .#negative-host-lint` when the negative host changes | exit 0 |
| help snapshots and parser corpora | the open-datum tests and the off-chain tests above, run in a writable copy of the fixtures | exit 0 |
| flags documented equal the help | "Documented CLI flags and refusal controls": `nix run --quiet .#cli-flags-check`, `nix run --quiet .#cli-flags-controls` | exit 0 |
| shell, python and workflows | "Development shell build": `nix develop --quiet -c just lint` whenever a script or workflow is in the diff | exit 0 |
| documentation | "Rendered documentation": `nix run --quiet .#docs-check`; `python3 tools/narrate.py --check` | exit 0 |

Hosted only, never rerun locally: "Demo 1 journey from the release archive" (the new plain and
detailed steps and refusals), "Closed-datum journey from the release archive", "Keri-stub
journey", the negative-host jobs, the conformance jobs and the two-actor jobs. Their
scripts change in this pull request, so the commit owner reads each changed script against the
`just lint` run and against `bash -n` before the first push.

The first run of every new test is made on the base to see it fail, and the failing output is
kept in the evidence folder.

## Checkpoints

The auditor is asked at the red tests of each of the first three slices, when the slice's
acceptance lines are green, and before the push. The documentation slice and the handoff get no
checkpoint.

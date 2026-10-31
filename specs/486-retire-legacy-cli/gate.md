# Gate for retiring the legacy command layer

Issue 486, remainder. This page is for the commit owner, the auditor and the reviewers: the census taken at intake, each
acceptance item, the hosted job and the verbatim command that proves it. The requirements are in
[the specification](spec.md) and the slice in [the plan](plan.md#slice). Every command is an existing hosted command. Hosted
checks on the pull request head are the net; the commands below run scoped to what the deletion can break.

## Census at intake

### Executables, commands and flags before the change

| Executable | Public commands (from the help snapshots) |
| --- | --- |
| `singular` | registry create, registry inspect, wallet create, wallet address, wallet sign, submit |
| `open-datum` | create, fold, insert, reclaim, cleanup, update, terminate, inspect |
| `devnet` | one process with its own flags; no source file of it is touched |

The other programs the package builds, the Koios recorder, the vault sealing helper and the local-services recorder, are
test tools, not release executables, and are not touched.

After the change the three tables are identical and so are all eighteen help snapshots. The only token that stops being
recognised is the combined fold switch. No help page lists it; today the open-datum and registry commands refuse it by name and the three wallet commands accept it and ignore it;
afterwards every command refuses it as an unknown flag.

### Code with no command line route

| Item | Where | Why it has no route |
| --- | --- | --- |
| the singular program's fold value and the arm that answers it with a failure | registry command parser and runner | no command line produces it |
| the open-datum insert, update and terminate booking values and their three arms that answer with a failure | open-datum parser and runner | the parser maps those words to the registry-booking, holding-update and holding-terminate values |
| the entry record with its fold flag, the fold record, the create record and the entry mode | registry command parser, re-exported by the open-datum parser | only the values above and each other use them |
| the fold switch in the shared switch list and in the open-datum switch list | shared flag list | accepted, then refused by every command |
| the booking, update and fold outlay helpers | outlay module | called only by their tests |

The compiler pass in step 2 of the plan extends this table; the commit owner appends what it finds to the pull request body.

### Consumers of the deleted code

| Consumer | What changes |
| --- | --- |
| the tokenizer test that pins the common switches, and the one that tokenizes the sibling program | the pinned list and one expectation lose the fold switch |
| the two parser corpora: 11 rows of the singular corpus and 294 rows of the open-datum corpus carry the switch | those rows are re-recorded (the corpus keeps a result and an `after` result per row; the recording switches of the corpus specification apply) as unknown-flag refusals; no other row changes |
| the open-datum tests of needed references, of the command run list and of the common-switch extent | lose the three booking values and the flag guards |
| the outlay specification of the open-datum tests | the cases of the deleted helpers go; a case that is the only evidence for a production outlay is ported |
| the help snapshots | none lists the switch or a deleted command: no change |
| the documentation pages | none names the switch or the deleted values: no change expected, confirmed by the documentation check |
| tools, flake checks, hosted workflows, harness legs | no workflow, script or harness leg names the switch or a deleted value in a command line; re-checked file by file as code is deleted |
| the declared checks census, the code inventory, the build graph check | a deleted source file leaves the inventory in the same commit |

No hosted job ran only deleted code at intake. If one does, the pull request body says so and the desk decides; no required
check is renamed, removed or edited by this ticket.

## Rows

| Row | Acceptance it proves | Hosted job | Verbatim command | Expected exit |
| --- | --- | --- | --- | --- |
| G1 | the off-chain package builds, lints and keeps application separation | `ci.yml` `offchain-component-build`, `offchain-lint` | `nix build --quiet .#component-build`; `nix run --quiet .#application-separation-check`; `(cd offchain && nix run --quiet .#lint)` | 0 |
| G2 | the open-datum package builds and lints | `ci.yml` `open-datum-component-build` | `cd applications/open-datum/offchain && nix build --quiet .#component-build`; `cd applications/open-datum/offchain && nix run --quiet .#lint` | 0 |
| G3 | the off-chain registry and command tests, including the help snapshots and the singular parser corpus | `registry.yml` `cage-tests` | `nix run --quiet .#cage-tests` | 0 |
| G4 | the open-datum tests, including its help snapshots and parser corpus | `ci.yml` `open-datum-tests` | `cd applications/open-datum/offchain && nix run --quiet .#open-datum-tests` | 0 |
| G5 | the packaged command still starts | `ci.yml` `open-datum-singular-smoke` | `nix run --quiet .#singular -- --help` | 0 |
| G6 | documented command lines and refusal controls | `registry.yml` `cli-flags` | `nix run --quiet .#cli-flags-check`; `nix run --quiet .#cli-flags-controls` | 0 |
| G7 | the command library build graph | `ci.yml` `registry-cli-build-graph` | `nix run --quiet ./offchain#registry-cli-build-graph-check`; `nix run --quiet ./offchain#registry-cli-build-graph-controls` | 0 |
| G8 | the code inventory classifies every source and the declared checks stay hosted | `ci.yml` `inventory`, `declared-checks-hosted` | `nix run --quiet .#inventory-check`; `nix run --quiet .#inventory-controls`; `nix run --quiet .#declared-checks-classify-controls`; `nix run --quiet .#declared-checks-hosted` | 0 |
| G9 | pages, diagrams and speech | `ci.yml` `rendered-docs` | `nix run --quiet .#docs-check`, run with only `nix` and `git` on the path | 0 |
| G10 | shell, YAML and Python lint | `ci.yml` `dev-shell` | `nix develop --quiet -c just lint` | 0 |
| G11 | input-output ownership and node confinement still hold | `ci.yml` `dev-shell-checks` | `nix develop --quiet -c just io-ownership-check`; `nix develop --quiet -c just io-ownership-controls`; `nix develop --quiet -c just node-confinement`; `nix develop --quiet -c just node-confinement-controls` | 0 |

Same-bytes observation for the census, not a hosted job: `git diff --exit-code origin/main -- offchain/test/fixtures/help applications/open-datum/offchain/test/fixtures/help` exits 0, and the corpus diff lists only rows that carried the removed switch. G3 and G4 are the proof that the real help output equals those unchanged files.

The devnet journeys and the command recovery partitions run the packaged commands unchanged; their hosted runs on the pull
request head are the net, and the gate does not rerun them locally.

## Budget

Each build or test runs in a named scope, `systemd-run --user --scope --unit=t486-<row>-<n> -p MemoryMax=24G timeout 3600
<command>`; long gates start with the background option and are read from their log. `just ci` runs at most once on the final
candidate, then the push. A hosted failure is one repair commit, not a local rerun of the hosted list.

# Closed-datum journey: the frozen gate

The gate is the continuous integration itself. Each row names the acceptance line, the
hosted job as it is named in the workflow, the verbatim command of that job with its
location at the base, the exit status CI asserts, and one real failed run that shows
the command can fail. A row with no hosted command is a missing job and is said so;
it is never replaced by a local check. Version 1, frozen on 15 October 2026 against
main f23370a7. The settled rows are not edited during the slice.

## How the gate was made

One independent gate author, working read-only at the base before any code, wrote a
table of every acceptance line, every one of the ninety-six required checks of the
repository ruleset, and every hosted command with its failed runs from the last two
hundred failing workflow runs. That table has 280 rows and is kept in the ticket's
runtime record (input hash `39eadc06dfdbd411b67dddf861206eb6c016a0cc01d4e96ad741f34ed5210fc3`).
The author of this plan combined it once and cut it to what this slice can reach, as
the test-running economy of the gate rules asks. The rows below are the union of the
author's acceptance rows that bind this change and the rows this plan adds, marked as
such. Every other required check is accepted by the one rule at the end of the table.

## The table

| Accepts | Hosted job | Verbatim command and location | CI asserts | A real failed run of the command |
|---|---|---|---|---|
| The story, end to end: create with the switch, insert, inspect, refused update with no transaction, terminate and fold, deposit read from the ledger | "Closed-datum journey from the release archive". **CI change in this ticket**: the job and the app do not exist at the base | `nix run --quiet .#demo1-closed-check`, the step this ticket adds to `.github/workflows/registry.yml` beside line 695 | exit 0 | The sibling command's failed run 38781949975, step "Run the Demo 1 singular journey from the extracted release archive". For this command itself: at any base without issue 654 the first `create --closed` fails, and the journey's own controls (the reads must differ across a submitting step) go red if the reads cannot see a submission |
| The open-datum job keeps passing | "Demo 1 journey from the release archive" | `nix run --quiet .#demo1-cli-check` (`registry.yml:695`) and `nix run --quiet .#demo1-cli-test-harness` (`registry.yml:697`) | exit 0 for both | Runs 38781949975 and 38571697835 |
| The open-datum job, app, journey and verifier script are unchanged | None: no hosted job compares sources. **Missing job, accepted as an owner check** | The diff of the pull request against main for `tools/demo1_cli_check.sh`, `tools/demo1_cli_journey.sh`, `tools/verify_release.sh` and the open job in `registry.yml`, read by the ticket owner before the push; the only change in the open path is the verifier wrapper's journey parameter in `flake.nix` | the diff is empty for the three scripts and the job | None: it is a read of a diff |
| The new app is hosted | "Declared checks are hosted" | `nix run --quiet .#declared-checks-classify-controls` (`ci.yml:369`), `nix run --quiet .#declared-checks-issue-states "$RUNNER_TEMP/issue-states.txt"` (`ci.yml:378`), `nix run --quiet .#declared-checks-hosted "$RUNNER_TEMP/issue-states.txt"` (`ci.yml:379`) | exit 0 | None found in the two hundred runs searched; the job's own classification controls run first |
| The new command resolves | "Workflow commands resolve and controls" | `nix run --quiet .#workflow-commands-resolve-controls` (`ci.yml:335`) | exit 0 | None found; the command plants a missing app and a missing package and requires both refused |
| The new scripts and the flake are formatted and lint-clean; the workflow parses and lints | "Development shell build" | `nix develop --quiet -c just lint` (`ci.yml:478`) | exit 0 | Run 38762813806, step "Run nix develop --quiet -c just lint" |
| The lint's own controls | "Development shell checks" | `nix develop --quiet -c just lint-controls` (`ci.yml:516`) | exit 0 | Run 38357384720 |
| The two new shell files are classified | "Code inventory" | `nix run --quiet .#inventory-check` (`ci.yml:305`), `nix run --quiet .#inventory-controls` (`ci.yml:310`) | exit 0 | Run 37763865424, step "Run nix run --quiet .#inventory-check" |
| The pages of this folder render and carry current speech | "Rendered documentation" | `nix run --quiet .#docs-check` (`ci.yml:453`) | exit 0 | Run 38119535187 |
| The pages keep their stories, diagrams and speech bound to their text | "Development shell checks" | `nix develop --quiet -c just check-presentation` (`ci.yml:509`) | exit 0 | Run 37808253758 |
| The run page's added paragraph introduces no undocumented flag | "Documented CLI flags and refusal controls" | `nix run --quiet .#cli-flags-check` (`registry.yml:1134`), `nix run --quiet .#cli-flags-controls` (`registry.yml:1136`) | exit 0 | Run 38792242304 |
| The release archive still assembles and verifies with the changed run page | "On-chain release assembly and artifact checks" | `nix run --quiet .#release-build-control` (`ci.yml:570`), `nix run --quiet .#release-artifacts -- "$RUNNER_TEMP/release"` (`ci.yml:571`), `nix run --quiet .#verify-release-controls -- "$RUNNER_TEMP/release"` (`ci.yml:580`) | exit 0 | Run 38781011583, step "Run nix run --quiet .#verify-release-controls -- "$RUNNER_TEMP/release"" |
| The release archive review still reproduces | "Release review archive reproduction" | `nix run --quiet .#release-review-check` (`ci.yml:608`) | exit 0 | Run 38238332736 |
| The new check name is required | None: the ruleset is applied by the desk at the merge grant. **Missing job, owner-prepared** | The ruleset JSON with the exact name "Closed-datum journey from the release archive", prepared by the ticket owner and journaled at merge-ready (hash `81a35b21555a5569cecd5ec515b9debdcf0608d439469d8020418cb9320a5a39`) | the applied ruleset lists the name | None |
| The docs note names the job | None: no hosted check reads the note. **Missing job, accepted as an owner read** | The ticket owner reads the added paragraph in `onchain-release/DEMO1.md` at acceptance and checks it names the job and the app | the paragraph names both | None |
| Every other required check | All ninety-six required checks of ruleset 22633401 | The exact-head hosted result of each, read with `gh run list` and `gh run view` | every required check green on the exact head, and the new check once the desk has applied the ruleset | The gate author's table gives, per check, the verbatim command and a cited failed run where one exists |

Two facts the gate author found are carried as limits, not rows:

- The presentation check scans the README, the documentation folder, the protocol
  specification and the preprod delivery specification. It does not scan
  `onchain-release/`, so the run page's speech companion is checked by neither hosted
  job. The writer regenerates it with the extraction tool and the ticket owner reads
  the output; nothing hosted proves the tool produced it.
- No hosted job asserts that a documentation note names a given job.

## Local legs and budgets

The candidate gate, run on every committed candidate, is the narrowest subset that the
change can break: `just lint` and its controls, the three declared-checks commands, the
workflow-commands command, the inventory check and the documented-flags check. Budget:
twenty minutes in total. Each command runs inside a memory-capped scope with a timeout,
for example
`systemd-run --user --scope --quiet -p MemoryMax=12G -p MemorySwapMax=0 -- timeout 900 <command>`,
with standard input from `/dev/null`.

The documentation check runs once on the committed pages before the first push.

The journey itself runs locally at most once, on the final candidate, with
`timeout 3600` in the same kind of scope. Every other hosted job is read from CI, never
repeated locally.

## Per-class falsification

| Class the change can reach | Shown able to fail by |
|---|---|
| The journey passes while the update was not refused | The refusal step demands the refusal receipt and exit status; on an open registry the update succeeds and the step fails |
| The no-transaction reads cannot see a submission | The same reads must differ across the termination booking; equal reads there fail the journey |
| The mode comparison is vacuous | The closed and open previews of one seed must differ, and the recorded hash must equal the closed one and not the open one |
| A renamed helper in the open journey silently breaks the closed one | The closed journey checks every helper name it reads is defined before a node starts |
| Lint and format | The lint job's recorded failed run, and its own controls |

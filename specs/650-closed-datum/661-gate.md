# Closed update refused by the node: the frozen gate

The gate is the continuous integration itself. Each row names the acceptance line, the
hosted job as the workflow names it, the verbatim command with its location at the base,
the exit status CI asserts, and one real failed run that shows the command can fail. A
row with no hosted command is a missing job and is said so; it is never replaced by a
local check. Version 1, frozen on 16 October 2026 against main 38c2e436. The settled
rows are not edited during the slice.

## How the gate was made

One independent gate author, working read-only at the base before any code, wrote a table
of every acceptance line, every one of the ninety-six required checks of the repository
ruleset, and every hosted command that the touched files can reach, with a failed run for
each command where the history has one (input hash
`01741cd0b2c505275aafd38df4b2cb9f9e57aece3bc90f8a7974db1c56618203`, 183 rows, kept in the
ticket's runtime record). The owner of this ticket combined it once with the plan's own
list of what the change can break, and cut it to the rows this slice can reach. Every
other required check is accepted by the one rule at the end of the table.

## The table

Location is `file:line` at the base. Exit is the status the step asserts.

| Accepts | Hosted job | Verbatim command and location | Exit | A real failed run of the command |
|---|---|---|---|---|
| The part is discovered | "Negative host pair parts" | `printf 'parts=%s\n' "$(nix run --quiet .#negative-host-parts)" >> "$GITHUB_OUTPUT"` (`negative-host.yml:59`) | 0 | None cited for the discovery step itself; its table is the one this ticket extends |
| The part: closed registry from the release archive, honest controller update refused by the closed application's spend, accepting termination of the same key. **CI change in this ticket**: the matrix leg `closed-update` does not exist at the base | "Negative host pair from the release archive: closed-update", under "Negative host pairs" | `nix run --quiet .#negative-host-part -- 'closed-update'` (`negative-host.yml:83`); the aggregator asserts `[ "$PARTS" = success ] && [ "$PART" = success ]` (`negative-host.yml:230`) | 0 | Run 38726293214, matrix leg `stranger-terminates-the-key`, step "Run the selected pair from the release archive", and the aggregator step "Every pair part passed". For this part itself, the mutant row below is the proof that it can fail |
| The mutant is discovered | "Negative host mutant list" | `mutants="$(nix run --quiet .#negative-host-mutants -- --list)"` (`negative-host.yml:105`) | 0 | Run 38163827068, step "Discover every mutant from the host table" |
| The mutant flips the part and its control still passes. **CI change in this ticket**: the leg `closed-update-accepted` does not exist at the base | "Negative host mutant: closed-update-accepted", under "Negative host mutants" | `nix run --quiet .#negative-host-mutants -- 'closed-update-accepted'` (`negative-host.yml:131`); the aggregator asserts `[ "$MUTANTS" = success ] && [ "$MUTANT" = success ]` (`negative-host.yml:244`) | 0 | Run 38726293214, leg `release-no-fold`, step "Run the pairs the mutant refuses", and "Every mutant passed" |
| The mutant's self-check: with no patch the part's forbidden command is refused and nothing flips. **CI change in this ticket**: the job runs the registry mutant only | "Negative host mutant self-check" | At the base `nix run --quiet .#negative-host-mutants -- --control-noop registry-accepts-a-taken-key` (`negative-host.yml:218`). This ticket adds a second step with `nix run --quiet .#negative-host-mutants -- --control-noop closed-update-accepted` | 0 | Run 38726293214, step "Run the mutant self-check over the registry mutant". The job ran 18.73 minutes in run 38810196855 against a 45 minute timeout; one more pair is added |
| The thirteen existing parts and eight existing mutants keep their result | the same two matrices | the same two commands, one leg per table entry | 0 | The same runs |
| The part list has fourteen names and a dropped name fails | "Negative host parser, dispatch and handler controls" | `nix run --quiet .#negative-host-node-free-controls` (`negative-host.yml:199`) | 0 | Run 38232474246, step "Run the node-free parser, dispatch and handler controls". The handler legs in it also keep the host's provider failure at exit status 10 |
| The host's Haskell compiles warning-free, is formatted and passes hlint | "Negative host sources: format and lint" | `nix run --quiet .#negative-host-lint` (`negative-host.yml:169`) | 0 | Run 38351734223, step "Format and lint the host sources" |
| The ordinary executables still cannot reach the bypass | "Ordinary executables cannot reach the bypass" | `nix run --quiet .#negative-host-ordinary` (`negative-host.yml:150`) | 0 | None cited in the history searched |
| The dispatch module still compiles with its new exports; the open-datum suites pass | "Open-datum component build"; "Open-datum tests" | `cd applications/open-datum/offchain && nix build --quiet .#component-build` (`ci.yml:160`); `... nix run --quiet .#lint` (`ci.yml:161`); `... nix run --quiet .#open-datum-tests` (`ci.yml:182`) | 0 | Run 38805366399 (lint), run 38740830095 (tests) |
| The whole tracked Haskell tree stays formatted | "Conformance Haskell format and lint check" | `nix run --quiet .#format-controls` (`conformance.yml:98`) | 0 | Run 38805366231 (a whole-tree baseline failure) |
| Shell, workflow and other lint of the changed runner, node-free script and workflow | "Development shell build" | `nix develop --quiet -c just lint` (`ci.yml:478`) | 0 | Run 38762813806; the lint's own controls: run 38357384720, `nix develop --quiet -c just lint-controls` (`ci.yml:516`) |
| The page `docs/negative-host.md` renders, with current speech and clips | "Rendered documentation"; "Documentation release checks" | `nix run --quiet .#docs-check` (`ci.yml:453`); `nix run --quiet .#release-check` (`ci.yml:536`) | 0 | Run 38119535187, step "Run nix run --quiet .#docs-check" |
| The page keeps its story, diagrams and speech bound to its text | "Development shell checks" | `nix develop --quiet -c just check-presentation` (`ci.yml:509`) | 0 | Run 37808253758 |
| The page introduces no undocumented flag | "Documented CLI flags and refusal controls" | `nix run --quiet .#cli-flags-check` (`registry.yml:1134`); `nix run --quiet .#cli-flags-controls` (`registry.yml:1136`) | 0 | Run 38808080947, step "Documented singular flags equal its --help" |
| Changed sources stay classified; no host effect site is unrecorded | "Code inventory"; "Development shell checks" | `nix run --quiet .#inventory-check` (`ci.yml:305`), `nix run --quiet .#inventory-controls` (`ci.yml:310`); `nix develop --quiet -c just io-ownership-check` (`ci.yml:514`), `... io-ownership-controls` (`ci.yml:515`) | 0 | Run 37763865424 (inventory); runs 38797777615 and 38398972027 (effect sites) |
| The release archive still assembles and verifies; the part and mutant jobs build from it | "On-chain release assembly and artifact checks" | `nix run --quiet .#release-build-control` (`ci.yml:570`); `nix run --quiet .#release-artifacts -- "$RUNNER_TEMP/release"` (`ci.yml:571`); `nix run --quiet .#verify-release-controls -- "$RUNNER_TEMP/release"` (`ci.yml:580`) | 0 | Run 38781011583, step "Run nix run --quiet .#verify-release-controls -- \"$RUNNER_TEMP/release\"" |
| Every other required check | all ninety-six required checks of ruleset 22633401 | The exact-head hosted result of each, read with `gh run list` and `gh run view` | every required check green on the exact head | The gate author's table gives, per check, the verbatim command and a cited failed run where one exists |

The ruleset lists the aggregators and not the matrix legs, so the two new legs create no new
required name and no ruleset change is prepared.

## Rows with no hosted command

| Accepts | Why no hosted job runs it | What takes its place |
|---|---|---|
| The diff names only files of the touch list, no fenced file, no attribution in the pushed range, and the final tree equals the last approved checkpoint tree | No hosted job compares a diff with a touch list | The owner reads the diff before the push; the auditor's last checkpoint names the tree |
| The hash binding of the stamped speech of this folder's pages | The presentation check lists the folders it scans and this one is not among them; the rendered documentation check reads only the presence and headings of the speech | The extraction tool writes the companions; the owner reads its output. The same state holds for the pages of the two earlier tickets of the folder |
| That the companions were produced by the extraction tool | No hosted check compares a companion with the tool's output | The tool is run in the writer's shell; the owner reads the result |
| That the page names the part and the mutant with the right counts | No hosted check reads the wording | The owner reads the changed paragraphs and tables at acceptance |

## Local legs and budgets

The candidate gate, run on every committed candidate, is the narrowest subset that the
change can break. Budget: twenty-five minutes in total, each command inside a
memory-capped scope with a timeout, for example
`systemd-run --user --scope --quiet -p MemoryMax=12G -p MemorySwapMax=0 -- timeout 900 <command>`,
with standard input from `/dev/null`.

- the host compiles: the incremental build of the host in the application's dev shell,
  once per edit; no repeated Nix compile;
- `nix run --quiet .#negative-host-lint`;
- `nix run --quiet .#negative-host-node-free-controls`, once after the Haskell and the
  list edits;
- `nix run --quiet .#negative-host-parts` and
  `nix run --quiet .#negative-host-mutants -- --list`, which must print fourteen and nine
  names;
- `nix develop --quiet -c just lint`;
- the extraction tool over the changed pages, then `nix develop --quiet -c just check-presentation`,
  once, and `nix run --quiet .#docs-check` once on the committed pages before the first push;
- `nix run --quiet .#cli-flags-check` and `nix run --quiet .#inventory-check`, once.

The new part runs locally at most once, on the final candidate, with `timeout 3600` in the
same kind of scope. The mutant, the self-check and every other hosted job are read from CI,
never repeated locally.

## Per-class falsification

| Class the change can reach | Shown able to fail by |
|---|---|
| The update is refused by the wrong script, or accepted | The mutant turns the part red by making the closed spend accept an update; the part's judge requires the refusal to name the registry's own pin in the spending role |
| The registry is not closed, or the pin is not closed-datum's | The part stops with a setup error when the create receipt does not name `open_datum.closed_datum`, or when the recorded pin equals the open pin of the same seed |
| The control proves nothing | The control is a termination of the key the forbidden command named; it is accepted by the node and leaves the key terminal; a broken registry fails it too |
| A host handler loads the wrong code for a registry | The part itself: a host that kept the open code stops at the registry's pin refusal and never reaches a ledger refusal, so the judge fails |
| A list misses the part | The node-free membership loop prints a failure for the name and exits 1; the part runner's whitelist exits 2 for an unknown name |
| The mutant patch is wider than its rule | The runner's hygiene exits as a setup failure when the patch touches more than the label line of the closed spend, and a flip is never credited then |
| Lint and format | The lint jobs' recorded failed runs, and their own controls |

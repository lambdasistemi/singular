# Closed datum: plan

The story, the requirements and the rulings are in the specification and the
ruling page. This page records the decisions, the order of work, the invariants
and the hosted checks that accept the work. Issue 651, one pull request, one
slice, about three hours of writing. Base: main cfe78df1.

## Class and team

The change adds an on-chain validator to the release, so it changes behaviour:
the full process applies. One commit owner writes the slice. A persistent
auditor, which is silent toward the writer, answers the checkpoints. Two
independent gate authors wrote the table of hosted checks below before any
coding, and the author of this plan combined them once. No part of the change is
Haskell, Lean or a workflow.

## Decisions

- **The entry point is a second validator appended to `open_datum.ak`.** The
  existing validator block, every helper and every import stay byte-identical;
  the diff is lines added after the last line of the file. Alternatives and the
  measurement are in the specification.
- **The spend refusal is the only difference.** The closed-datum mint handler is
  open-datum's mint handler called with the same arguments. The spend handler
  matches the redeemer: `Update` is refused with the trace label
  `closed-datum-update`, `Release` goes to open-datum's spend handler. `else`
  fails.
- **The suite's own check proves the closed rows ran and can fail.** The
  application flake already runs the composed suite, requires its log to name an
  open-datum test, and plants a wrong expected digest to show the suite can fail.
  The same check gains two lines of the same kind: the log must name a closed
  refusal test, and a planted copy whose closed `Update` arm accepts must make
  the suite fail naming that test. Rejected: relying on a green suite alone, which
  stays green if the closed rows are never collected.
- **The tests join `open_datum.tests.ak`.** The closed rows sit beside the open
  rows they mirror, built from the same private fixtures. A closed refusal is
  always paired, in the same file, with open-datum's acceptance of the same
  context.
- **The declared additions are a separate record.** The comparison's base file
  `specs/528-registry-cli-split/evidence/base-hashes.json` belongs to a merged
  ticket and stays byte-identical. A new file
  `specs/650-closed-datum/evidence/declared-additions.json` lists the titles of
  the three declared closed-datum validators. The comparison takes each declared
  title's expected hash from the application's identity manifest, so the hash is
  written in one place that the identity job already ties to the build. The
  expected set is the base set plus the declared titles; the base entries are
  compared exactly as before. Rejected: rewriting the base file (it is a merged
  ticket's evidence), and listing hashes in the new record (a second place to
  edit every time open-datum's code moves, because closed-datum's hash moves with
  it).
- **The plants name their validator.** In the merged deployment blueprint the
  declared validators sort before every other title, so an existing plant that
  changes `validators[0]` would now change a declared validator. Every plant
  selects the validator it plants by title and checks that it applied to the
  intended one.

## Order of work

One slice, in this order. Each step leaves the tree green for the jobs it can
reach.

1. Append the closed-datum validator to `open_datum.ak`.
2. Append the closed-datum tests to `open_datum.tests.ak` and run the suite.
3. Build the application blueprint and generate the three closed rows of
   `script-identity.json` with the repository's own recipe from that blueprint.
4. Change the count from 14 to 17 in the application flake's merged blueprint
   check and in the release assembler, and add the closed witness and the closed
   plant to the flake's composed-suite check.
5. Add the declared-additions record and extend the comparison in the root
   `flake.nix`, with its two new plants.
6. Run the cheap local legs listed below, fold fixes into the one patch, and
   hand the candidate over for review.

The pull request is a stacked patch series: one patch for these pages, one patch
for the code. No journey commits are pushed.

## Invariants and what makes them fail

Each name is stable and appears in the tasks.

| Invariant | Fails when | Proved by |
|---|---|---|
| `closed-spend-refuses-every-update` | the closed spend returns true for an update of any payload in the suite's list | application Aiken suite |
| `closed-refusal-is-the-closed-rule` | the paired open-datum acceptance of the same context is red | application Aiken suite |
| `closed-release-follows-open-release` | a release the registry also accepts is refused, or a release open-datum refuses is accepted | application Aiken suite |
| `closed-booking-follows-open-booking` | an insertion or termination booking is refused, or a refused booking is accepted | application Aiken suite |
| `closed-else-refuses` | the closed handler accepts another script purpose | application Aiken suite |
| `closed-refusal-test-can-fail` | the suite stays green with the closed `Update` arm planted to accept, or its log names no closed test | the application Aiken check's own witness and plant |
| `open-datum-identity-unmoved` | an open-datum row of the manifest differs from main | identity job and the append-only check outside the repository |
| `closed-identity-pinned-from-the-build` | a closed row differs from the built blueprint, or a built validator has no row | identity job |
| `seventeen-validators-in-the-release` | the merged blueprint or the release holds a different count | blueprint job and release assembly job |
| `base-hash-comparison-admits-only-what-is-declared` | an undeclared extra validator, a moved declared hash or a moved base hash is accepted | comparison, with its plants |
| `application-boundary-contexts-unchanged` | the permanent boundary receives other than its four open-datum application contexts | application Aiken suite (permanent boundary check) |
| `negative-host-patches-apply-to-the-appended-file` | a mutant patch no longer applies, or no longer flips its pair | negative-host jobs |
| `registry-untouched` | a file outside the touch list changes | the file-list check outside the repository |

The permanent boundary collects application contexts from trace lines that the
open-datum tests print; it requires exactly four. The new rows must not print
such a line, and they must not call the helper that prints it.

## Hosted checks that accept the work

The gate is the continuous integration itself: each row names the job and the
verbatim command. The local leg is the cheap command run before the push; the
hosted jobs run once on the pushed head, and no hosted job is repeated locally.

| Accepts | Hosted job | Command | Local leg |
|---|---|---|---|
| closed rules, formatter, boundary | Application Aiken unit and property suite passes | `nix flake check` in `applications/open-datum/onchain` | same command |
| identity rows | Application script identity matches the manifest | `nix build --quiet --no-link --print-out-paths .#script-identity` in `applications/open-datum/onchain` | same command |
| seventeen validators | Application blueprint builds first | `nix build --quiet --no-link --print-out-paths .#plutus-blueprint` then `.#open-datum-blueprint` in `applications/open-datum/onchain` | same commands |
| comparison and plants | Compiled script identity matches the manifest, step "Compare the split blueprints against the base hash set" | `nix run --quiet .#script-hash-comparison` | same command |
| release holds seventeen | On-chain release assembly and artifact checks | `nix run --quiet .#release-build-control`, `nix run --quiet .#release-artifacts -- "$RUNNER_TEMP/release"`, `nix run --quiet .#verify-release-controls -- "$RUNNER_TEMP/release"` | hosted only |
| mutants still apply | Negative host mutant list, Negative host mutants, Negative host mutant self-check, Negative host pairs | `nix run --quiet .#negative-host-mutants -- '<mutant>'` and `-- --control-noop registry-accepts-a-taken-key` | hosted only |
| pages and speech | Rendered documentation; Documentation release checks | `nix run --quiet .#docs-check` | speech extraction and the presentation check on these pages |
| tools formats | Off-chain lint; Development shell checks | `just lint` for the touched families | same command |

The synthesis of the two independent gate tables, with the cited red runs, is
kept in the ticket's runtime record. A line without a hosted command is a missing
job and is raised as a question, never replaced by a local check.

## Two checks outside the repository

Two checks belong to the author of the change, not to the repository, and are run before the push
from the runtime record: the diff names only files in the touch list, and the
diff of `open_datum.ak` against main has no deleted line and a single hunk after
the old last line. The product proof of the second is the unmoved hash.

## Not touched, by name

The registry contract under `onchain/` and its script hashes, the registry
library, the `singular` commands, the open-datum executable and its Haskell
sources including the files other open work is changing (wallet preparation and signing),
`tools/check_release.py` (it names no titles), `tools/m1_identity.py` and the
generated permanent records (they select the three open-datum titles exactly),
the negative-host sources, every workflow, and all Lean.

## Residuals this change leaves, written before the work

- The compiled closed-datum code is not run over the permanent boundary's
  ledger-shaped contexts here; the node's refusal is the negative-host ticket.
- The write-once rule has no Lean statement, by ruling.
- The compiled closed-datum validator is pinned and carried but not selectable by
  a person until the executable ticket lands.

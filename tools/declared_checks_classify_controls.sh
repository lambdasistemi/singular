#!/usr/bin/env bash
# declared-checks-classify-controls: the table-driven test for the census.
#
# One case per classifier rule, each a fixture of the classifier's plain
# inputs with the expected exit and the expected named verdict. The
# classifier reads no flake, no git tree, no network and no clock, so its
# cases run in milliseconds with no nix evaluation; the extraction case
# drives the resolver over a fixture workflow, likewise without
# evaluation. The closing integration case evaluates an offline fixture
# flake (no network, no registry), which dominates the runtime: the whole
# command costs about two seconds with a warm evaluation cache and about
# twenty seconds cold.
#
# Each case captures the subject's full output, checks its status, then
# matches: no verdict check reads from a pipeline ending in grep or head.
# A failed case determines the nonzero verdict. The classifier path honours
# CLASSIFY_BIN (used once, with /bin/true, to prove this test can fail:
# every red-expecting case must then fail).
#
# Exit 0: every case held. Exit 1: a case broke. Exit 2: setup failure.
set -euo pipefail

tools="$(cd "$(dirname "$0")" && pwd)"
classify="${CLASSIFY_BIN:-$tools/declared_checks_classify.sh}"
collect="${COLLECT_BIN:-$tools/declared_checks_collect.sh}"
resolver="$tools/workflow_commands_resolve.sh"

work="$(mktemp -d)" || {
  echo "classify-controls: SETUP: cannot create a scratch directory" >&2
  exit 2
}
trap 'rm -rf "$work"' EXIT

[ -f "$classify" ] || {
  echo "classify-controls: SETUP: no classifier $classify" >&2
  exit 2
}
[ -f "$resolver" ] || {
  echo "classify-controls: SETUP: no resolver $resolver" >&2
  exit 2
}
[ -f "$collect" ] || {
  echo "classify-controls: SETUP: no integration layer $collect" >&2
  exit 2
}

held=0
broken=0
classify_status=0

# Run the classifier over the fixture files in $work, capturing its full
# output; the exit lands in classify_status in this shell.
run_classifier() {
  if [ "$#" -eq 0 ]; then
    if bash "$classify" "$work/declared" "$work/hosted" "$work/list" "$work/jobs" >"$work/last.out" 2>"$work/last.err"; then
      classify_status=0
    else
      classify_status=$?
    fi
  else
    if bash "$classify" "$work/declared" "$work/hosted" "$work/list" "$work/jobs" "$@" >"$work/last.out" 2>"$work/last.err"; then
      classify_status=0
    else
      classify_status=$?
    fi
  fi
}

expect() {
  local name="$1" want_exit="$2" want_fragment="$3"
  if [ "$classify_status" -ne "$want_exit" ]; then
    echo "CONTROL FAIL: $name: exit $classify_status, want $want_exit" >&2
    echo "--- stdout ---" >&2
    cat "$work/last.out" >&2
    echo "--- stderr ---" >&2
    cat "$work/last.err" >&2
    broken=$((broken + 1))
    return 0
  fi
  if grep -F -q -- "$want_fragment" "$work/last.out" "$work/last.err"; then
    held=$((held + 1))
  else
    echo "CONTROL FAIL: $name: exit $classify_status as wanted but no line names '$want_fragment'" >&2
    echo "--- stdout ---" >&2
    cat "$work/last.out" >&2
    echo "--- stderr ---" >&2
    cat "$work/last.err" >&2
    broken=$((broken + 1))
  fi
}

expect_absent() {
  local name="$1" fragment="$2"
  if grep -F -q -- "$fragment" "$work/last.out" "$work/last.err"; then
    echo "CONTROL FAIL: $name: fragment '$fragment' present but must be absent (no verdict on a setup failure)" >&2
    broken=$((broken + 1))
  else
    held=$((held + 1))
  fi
}

write_jobs() {
  cat >"$work/jobs" <<'EOF'
browser
coverage
inventory
release-archive
EOF
}

# 1. The clean case: every declared entry hosted, no list entries.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
.|check|model
EOF
cat >"$work/hosted" <<'EOF'
run . docs-serve
check . model named-check-build
EOF
cat >"$work/list" <<'EOF'
# no declared-not-hosted entries on the clean tree
EOF
write_jobs
run_classifier
expect "clean tree passes" 0 "declared-checks-classify: PASS"

# 2. An unhosted declared app with no entry fails, named.
cat >"$work/declared" <<'EOF'
.|app|demo
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
run . docs-serve
EOF
cat >"$work/list" <<'EOF'
# none
EOF
run_classifier
expect "unhosted app is refused" 1 "app demo of flake . is declared and named by no workflow step"

# 3. An unhosted declared check with no entry fails, named.
cat >"$work/declared" <<'EOF'
.|check|model
.|check|unit
EOF
cat >"$work/hosted" <<'EOF'
check . model named-check-build
EOF
cat >"$work/list" <<'EOF'
# none
EOF
run_classifier
expect "unhosted check is refused" 1 "check unit of flake . is declared and named by no workflow step"

# 4. Checks the integration resolved from a flake-check run need no
# entries, and the table shows how they are hosted.
cat >"$work/declared" <<'EOF'
onchain|check|aiken-suite
onchain|check|script-identity
onchain|app|runner
EOF
cat >"$work/hosted" <<'EOF'
check onchain aiken-suite flake-check builds every check of the flake
check onchain script-identity flake-check builds every check of the flake
run onchain runner
EOF
cat >"$work/list" <<'EOF'
# none
EOF
run_classifier
expect "flake-check hosts every check" 0 "flake-check builds every check"

# 5. An exception without a reason fails.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing hosts docs-serve
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|
EOF
run_classifier
expect "reasonless entry is refused" 1 "no reason"

# 6. A stale exception (attribute no longer declared) fails.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing
EOF
cat >"$work/list" <<'EOF'
.|retired-thing|app|retired: classified unverified in offchain/nix/component-inventory.nix under #172
EOF
run_classifier
expect "stale entry is refused" 1 "no declared app retired-thing in flake . (stale entry)"

# 7. An exception for an entry that is in fact hosted fails.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
run . docs-serve
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server|nix/docs.nix
EOF
cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|nix/docs.nix marked names
EOF
: >"$work/citations"
run_classifier "$work/toolmarkers" "$work/citations"
expect "hosted-but-listed entry is refused" 1 "app docs-serve of flake . is in fact hosted (stale entry)"

# 8. A hosted-under-another-name entry whose job id does not exist fails.
cat >"$work/declared" <<'EOF'
.|check|browser
EOF
cat >"$work/hosted" <<'EOF'
# nothing hosts the check by name
EOF
cat >"$work/list" <<'EOF'
.|browser|check|hosted under another name: the no-such-job job runs this checker
EOF
run_classifier
expect "dead job id is refused" 1 "the reason names no declared job identifier"

# 8b. A dead identifier that contains a live one fails: `no-such-browser`
# holds `browser` as letters but matches no declared job identifier.
cat >"$work/list" <<'EOF'
.|browser|check|hosted under another name: the no-such-browser job runs this checker
EOF
run_classifier
expect "dead identifier containing a live one is refused" 1 "the reason names no declared job identifier"

# 9. A retired entry without its citation fails.
cat >"$work/declared" <<'EOF'
offchain|app|old-runner
EOF
cat >"$work/hosted" <<'EOF'
# nothing
EOF
cat >"$work/list" <<'EOF'
offchain|old-runner|app|retired: an old journey runner nobody runs
EOF
run_classifier
expect "uncited retired entry is refused" 1 "a retired reason cites the classification"

# Retired replay wiring no longer grants an exception to a missing hosted step.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|pending wiring: #565, no hosted carrier
EOF
run_classifier
expect "retired pending-wiring exception is refused" 1 "the reason must start with"

# 15. A duplicate entry fails.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|retired: classified unverified in offchain/nix/component-inventory.nix under #172
.|docs-serve|app|retired: classified unverified in offchain/nix/component-inventory.nix under #172
EOF
run_classifier
expect "duplicate entry is refused" 1 "duplicate entry for . docs-serve (app)"

# 16. An empty declared extent is exit 2.
cat >"$work/declared" <<'EOF'
# the integration found no apps and no checks
EOF
run_classifier
expect "empty declared extent is setup failure" 2 "the declared extent is empty"

# 17b. A tool entry with no handed tool sources is a setup failure,
# never a verdict when the tool sources are absent.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server|nix/docs.nix
EOF
run_classifier
expect "missing tool sources are setup failure" 2 "a tool entry needs the tool-marker source"
expect_absent "missing tool sources carry no verdict" "declared-checks-classify: PASS"

# 18a. A marked, uncited tool passes, is counted, and is named in the
# output.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing runs either
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server|nix/docs.nix
EOF
cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|nix/docs.nix marked names
EOF
: >"$work/citations"
run_classifier "$work/toolmarkers" "$work/citations"
expect "a marked uncited tool passes" 0 "declared-checks-classify: PASS"
expect "the tools are printed by name" 0 "tools, marked and never cited as evidence: . docs-serve"
expect "the tool count is printed" 0 "; 1 tools"

# 18b. A tool entry whose file carries no marker line is refused.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server|tools/unmarked.sh
EOF
cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|tools/unmarked.sh unmarked nameless
EOF
: >"$work/citations"
run_classifier "$work/toolmarkers" "$work/citations"
expect "an unmarked tool file is refused" 1 "carries no 'Tool, not a guarantee:' marker line"

# 18c. A tool entry whose file is missing is refused; so is a file the
# marker source does not answer for (fail closed).
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server|tools/gone.sh
EOF
cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|tools/gone.sh missing nameless
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a missing tool file is refused" 1 "the file that defines the tool, tools/gone.sh, does not exist"

cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|tools/other.sh marked names
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "an unanswered tool file is refused" 1 "no tool-marker line was handed for . docs-serve (tools/gone.sh)"

# 18d. A tool cited in the published text is refused, each citation
# form named: the command form, the path of the defining file, and the
# tool's own file citing its command form.
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server|nix/docs.nix
EOF
cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|nix/docs.nix marked names
EOF
cat >"$work/citations" <<'EOF'
.#docs-serve|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a command-form citation is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as .#docs-serve)"

cat >"$work/citations" <<'EOF'
nix/docs.nix|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a defining-file-path citation is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as nix/docs.nix)"

cat >"$work/citations" <<'EOF'
.#docs-serve|nix/docs.nix
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a tool cited by its own file is refused" 1 "cited as evidence or guarantee in nix/docs.nix (as .#docs-serve)"
: >"$work/citations"

# 18f. A tool cited by a quoted or dot-slashed spelling of its command
# form is refused, each spelling named.
cat >"$work/citations" <<'EOF'
'#docs-serve|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a quoted citation is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as '#docs-serve)"

cat >"$work/citations" <<'EOF'
./#docs-serve|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a dot-slashed citation is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as ./#docs-serve)"
: >"$work/citations"

# 18g. A tool of another flake is cited only by its flake-qualified
# spellings, each refused and named.
cat >"$work/declared" <<'EOF'
sub/dir|app|helper
EOF
cat >"$work/hosted" <<'EOF'
# nothing runs it
EOF
cat >"$work/list" <<'EOF'
sub/dir|helper|app|tool: a helper that stays local|sub/dir/tool.sh
EOF
cat >"$work/toolmarkers" <<'EOF'
sub/dir|helper|sub/dir/tool.sh marked names
EOF
cat >"$work/citations" <<'EOF'
sub/dir#helper|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a flake-qualified citation is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as sub/dir#helper)"

cat >"$work/citations" <<'EOF'
./sub/dir#helper|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a dot-slashed flake citation is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as ./sub/dir#helper)"

# 18h. A same-named reference aimed at another flake is never
# misattributed to the tool: the unqualified command form and another
# flake's qualified form both stay green.
cat >"$work/citations" <<'EOF'
.#helper|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "an unqualified same-named citation is not misattributed" 0 "declared-checks-classify: PASS"
expect "the unattributed tool still prints by name" 0 "tools, marked and never cited as evidence: sub/dir helper"

cat >"$work/citations" <<'EOF'
other#helper|docs/getting-started.md
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "another flake's qualified citation is not misattributed" 0 "declared-checks-classify: PASS"
: >"$work/citations"

# 18i. A marked file outside the entry's own flake directory cannot
# certify the tool, even when it carries the marker and names it.
cat >"$work/list" <<'EOF'
sub/dir|helper|app|tool: a helper that stays local|tools/stranger.md
EOF
cat >"$work/toolmarkers" <<'EOF'
sub/dir|helper|tools/stranger.md marked names
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a marker outside the flake directory is refused" 1 "lives outside the flake sub/dir"

# 18j. A marked file that does not name the attribute it certifies
# cannot define the tool.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server|tools/stranger.md
EOF
cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|tools/stranger.md marked nameless
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a marked file that names no attribute is refused" 1 "does not name the attribute docs-serve"

# 18k. A malformed tool-marker source is a setup failure, never a
# verdict.
cat >"$work/toolmarkers" <<'EOF'
.|docs-serve|nix/docs.nix marked
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a malformed tool-marker line is setup failure" 2 "malformed tool-marker"
expect_absent "malformed tool markers carry no verdict" "declared-checks-classify: PASS"

# 18e. A tool entry without its fifth field, a non-tool entry with one,
# and the retired developer-utility class are each refused.
cat >"$work/list" <<'EOF'
.|docs-serve|app|tool: the local documentation site server
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a tool entry without its marker file field is refused" 1 "a tool entry carries, as its fifth field, the path of the file that holds its marker"

cat >"$work/list" <<'EOF'
.|docs-serve|app|retired: classified unverified in offchain/nix/component-inventory.nix under #172|nix/docs.nix
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "a non-tool entry with a fifth field is refused" 1 "only a tool entry carries a fifth field"

cat >"$work/list" <<'EOF'
.|docs-serve|app|developer utility: the local documentation site server
EOF
run_classifier "$work/toolmarkers" "$work/citations"
expect "the retired developer-utility class is refused" 1 "the developer-utility class was retired by the tool class"

# 18. The shared extraction maps working directories, cd targets and
# flake-check runs onto flake directories. The static lines are the
# positive control: the same run proves the method detects presence, so
# the dynamic cd line emitting nothing is meaningful absence.
mkdir -p "$work/root/.github/workflows" "$work/root/offchain" "$work/root/onchain"
cat >"$work/root/.github/workflows/fixture.yml" <<'EOF'
jobs:
  vectors:
    steps:
      - name: Run the vectors check
        working-directory: offchain
        run: nix run --quiet .#contract-tests
      - name: Compare the manifest
        working-directory: onchain
        run: nix build --quiet --no-link --print-out-paths .#script-identity
      - name: Run the onchain suite
        working-directory: onchain
        run: nix flake check
      - name: Move into the flake first
        run: cd offchain && nix run --quiet .#lint
      - name: Dynamic scratch directory
        run: cd "$RUNNER_TEMP/extracted" && nix run --quiet .#contract-tests
EOF
if bash "$resolver" --emit-references "$work/root" "$work/root/.github/workflows/fixture.yml" >"$work/emit.out" 2>"$work/emit.err"; then
  classify_status=0
else
  classify_status=$?
fi
if [ "$classify_status" -ne 0 ]; then
  echo "CONTROL FAIL: emit mode exits $classify_status on the fixture, want 0" >&2
  cat "$work/emit.out" "$work/emit.err" >&2
  broken=$((broken + 1))
elif grep -F -q -- "run offchain contract-tests" "$work/emit.out" \
  && grep -F -q -- "build onchain script-identity" "$work/emit.out" \
  && grep -F -q -- "flake-check onchain -" "$work/emit.out" \
  && grep -F -q -- "run offchain lint" "$work/emit.out"; then
  if grep -F -q -- '$' "$work/emit.out"; then
    echo "CONTROL FAIL: emit mode leaked a dynamic reference into the hosted set" >&2
    cat "$work/emit.out" >&2
    broken=$((broken + 1))
  else
    held=$((held + 1))
  fi
else
  echo "CONTROL FAIL: emit mode missed a static fixture reference" >&2
  cat "$work/emit.out" "$work/emit.err" >&2
  broken=$((broken + 1))
fi

# 22. The shared extraction credits an invocation, not printed command
# text. A fixture repository declares one app, widget, in its sub flake
# beside one check, probe; the clean workflow runs widget and
# flake-checks the sub flake, green. Each non-invocation plant (echo,
# printf, a quoted argument, a heredoc body, a YAML comment) leaves
# widget unhosted and the census red, and an echo-planted flake check
# leaves probe unhosted the same way; each real invocation form stays
# hosted. Every plant is seen red first, then green again on restore.
invroot="$work/inv-root"
mkdir -p "$invroot/.github/workflows" "$invroot/sub" "$invroot/tools"
cat >"$invroot/flake.nix" <<'EOF'
{
  outputs = _: {
    apps.x86_64-linux = {};
    checks.x86_64-linux = {};
  };
}
EOF
cat >"$invroot/sub/flake.nix" <<'EOF'
{
  outputs = _: {
    apps.x86_64-linux.widget = {
      type = "app";
      program = "/bin/echo";
    };
    checks.x86_64-linux.probe = builtins.derivation {
      name = "probe-check";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" ": > $out" ];
    };
  };
}
EOF
cat >"$invroot/tools/declared_checks_not_hosted.list" <<'EOF'
# no declared-not-hosted entries in the fixture
EOF
clean_inv_step() {
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: nix run --quiet .#widget
        working-directory: sub
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
}
run_inv_census() {
  if bash "$collect" "$invroot" >"$work/last.out" 2>"$work/last.err"; then
    classify_status=0
  else
    classify_status=$?
  fi
}
clean_inv_step
mkdir -p "$work/no-hooks"
inv_git() {
  env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c user.name=census -c user.email=census@example.org -c commit.gpgsign=false -c core.hooksPath="$work/no-hooks" -c init.templatedir="$work/no-hooks" "$@"
}
if inv_git -C "$invroot" init -q >>"$work/inv-setup.log" 2>&1 \
  && inv_git -C "$invroot" add -A >>"$work/inv-setup.log" 2>&1 \
  && inv_git -C "$invroot" commit -qm fixture >>"$work/inv-setup.log" 2>&1; then
  run_inv_census
  expect "the clean invocation fixture is green" 0 "hosted app sub widget"

  # Plant: the blocking scenario, the run line echoing its command text.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: echo 'nix run --quiet .#widget -- --help'
        working-directory: sub
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "an echoed command is not an invocation" 1 "app widget of flake sub is declared and named by no workflow step"
  clean_inv_step
  run_inv_census
  expect "the restored invocation is green" 0 "hosted app sub widget"

  # Plant: printf printing its command text.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: printf '%s\n' 'nix run --quiet .#widget'
        working-directory: sub
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "a printed command is not an invocation" 1 "app widget of flake sub is declared and named by no workflow step"
  clean_inv_step
  run_inv_census
  expect "the restored invocation is green" 0 "hosted app sub widget"

  # Plant: the command text as a quoted argument to another command.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: true "nix run --quiet .#widget"
        working-directory: sub
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "a quoted command string is not an invocation" 1 "app widget of flake sub is declared and named by no workflow step"
  clean_inv_step
  run_inv_census
  expect "the restored invocation is green" 0 "hosted app sub widget"

  # Plant: the command text in a heredoc body the step never executes.
  # (printf, not a heredoc here: the indented EOF the fixture needs
  # would trip SC1039 on this file.)
  printf '%s\n' \
    'jobs:' \
    '  widget-job:' \
    '    steps:' \
    '      - name: Fixture preamble' \
    '      - run: |' \
    '          cat <<EOF' \
    '          nix run --quiet .#widget' \
    '          EOF' \
    '        working-directory: sub' \
    '      - run: nix flake check' \
    '        working-directory: sub' \
    '      - name: Fixture trailer' \
    >"$invroot/.github/workflows/fixture.yml"
  run_inv_census
  expect "a heredoc body is not an invocation" 1 "app widget of flake sub is declared and named by no workflow step"
  clean_inv_step
  run_inv_census
  expect "the restored invocation is green" 0 "hosted app sub widget"

  # Plant: the run line as a YAML comment. Comments never credited, so
  # this plant is red before and after the repair: it locks the behavior.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      # - run: nix run --quiet .#widget
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "a commented run line is not an invocation" 1 "app widget of flake sub is declared and named by no workflow step"
  clean_inv_step
  run_inv_census
  expect "the restored invocation is green" 0 "hosted app sub widget"

  # Plant: the flake-check line echoing its command text. The probe
  # check loses its carrier the same way the app did above.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: nix run --quiet .#widget
        working-directory: sub
      - run: echo 'nix flake check'
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "an echoed flake check is not an invocation" 1 "check probe of flake sub is declared and named by no workflow step"
  clean_inv_step
  run_inv_census
  expect "the restored invocation is green" 0 "hosted app sub widget"

  # Real forms stay hosted: the dashed run key.
  run_inv_census
  expect "the dashed run key stays hosted" 0 "hosted app sub widget"

  # Real forms stay hosted: the bare run key under a named step.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - name: Run widget
        working-directory: sub
        run: nix run --quiet .#widget
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "the bare run key stays hosted" 0 "hosted app sub widget"

  # Real forms stay hosted: a cd prefix on the same line.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: cd sub && nix run --quiet .#widget
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "the cd prefix stays hosted" 0 "hosted app sub widget"

  # Real forms stay hosted: the command on a later block line.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: |
          echo starting
          nix run --quiet .#widget
        working-directory: sub
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "a later block line stays hosted" 0 "hosted app sub widget"

  # Real forms stay hosted: a parenthesized cd prefix.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: (cd sub && nix run --quiet .#widget)
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "the parenthesized cd stays hosted" 0 "hosted app sub widget"

  # Real forms stay hosted: an environment assignment prefix.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: OUTDIR="$RUNNER_TEMP/x" nix run --quiet .#widget
        working-directory: sub
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "the assignment prefix stays hosted" 0 "hosted app sub widget"

  # Real forms stay hosted: the invocation inside a substitution.
  cat >"$invroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  widget-job:
    steps:
      - name: Fixture preamble
      - run: printf 'parts=%s\n' "$(nix run --quiet .#widget)" >> "$RUNNER_TEMP/out"
        working-directory: sub
      - run: nix flake check
        working-directory: sub
      - name: Fixture trailer
EOF
  run_inv_census
  expect "the substitution stays hosted" 0 "hosted app sub widget"

  # The closing green: the clean fixture again.
  clean_inv_step
  run_inv_census
  expect "the clean invocation fixture is green" 0 "hosted app sub widget"
else
  echo "classify-controls: SETUP: invocation fixture setup failed" >&2
  cat "$work/inv-setup.log" >&2
  exit 2
fi

# 19. A bare build of a same-named legacy package does not host the
# check. The fixture flake declares checks.unit beside an unrelated
# legacy package unit and no packages.unit, with a workflow step running
# `nix build .#unit`. Installable identity refuses the credit (exit 1
# naming unit); the old no-package branch credited it (exit 0), so this
# case is red on the old integration layer and green on the repaired one.
shadow="$work/shadow-root"
mkdir -p "$shadow/.github/workflows" "$shadow/tools" "$work/no-hooks"
cat >"$shadow/flake.nix" <<'EOF'
{
  outputs = _: {
    checks.x86_64-linux.unit = builtins.derivation {
      name = "unit-check";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" ": > $out" ];
    };
    legacyPackages.x86_64-linux.unit = builtins.derivation {
      name = "unit-legacy";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" ": > $out" ];
    };
  };
}
EOF
cat >"$shadow/.github/workflows/fixture.yml" <<'EOF'
jobs:
  shadow:
    steps:
      - name: Build the unit derivation
        run: nix build --quiet .#unit
EOF
cat >"$shadow/tools/declared_checks_not_hosted.list" <<'EOF'
# no declared-not-hosted entries in the fixture
EOF
# Fixture git runs independent of the author's ambient configuration:
# no system or global config, fixed identity, no signing, no hooks and no
# init template.
setup_git() {
  env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c user.name=census -c user.email=census@example.org -c commit.gpgsign=false -c core.hooksPath="$work/no-hooks" -c init.templatedir="$work/no-hooks" "$@"
}
if setup_git -C "$shadow" init -q >>"$work/shadow-setup.log" 2>&1 \
  && setup_git -C "$shadow" add -A >>"$work/shadow-setup.log" 2>&1 \
  && setup_git -C "$shadow" commit -qm fixture >>"$work/shadow-setup.log" 2>&1; then
  if bash "$collect" "$shadow" >"$work/shadow.out" 2>"$work/shadow.err"; then
    shadow_status=0
  else
    shadow_status=$?
  fi
  if [ "$shadow_status" -ne 1 ]; then
    echo "CONTROL FAIL: shadowed bare build: exit $shadow_status, want 1" >&2
    cat "$work/shadow.out" "$work/shadow.err" >&2
    broken=$((broken + 1))
  elif grep -F -q -- "check unit of flake . is declared and named by no workflow step" "$work/shadow.out" "$work/shadow.err"; then
    held=$((held + 1))
  else
    echo "CONTROL FAIL: shadowed bare build: exit 1 as wanted but unit unnamed" >&2
    cat "$work/shadow.out" "$work/shadow.err" >&2
    broken=$((broken + 1))
  fi
else
  echo "classify-controls: SETUP: shadow fixture setup failed" >&2
  cat "$work/shadow-setup.log" >&2
  exit 2
fi

# 20. The tool class through the real integration layer: a fixture
# repository whose one declared app is a tool. Each plant is seen red
# first, then green again; the closing run is the clean tree with its
# tool, green and printing the tool by name'
# summary slot.
toolroot="$work/tool-root"
mkdir -p "$toolroot/.github/workflows" "$toolroot/tools/declared_tools" "$toolroot/docs"
cat >"$toolroot/flake.nix" <<'EOF'
{
  outputs = _: {
    apps.x86_64-linux.local-helper = {
      type = "app";
      program = "/bin/echo";
    };
  };
}
EOF
cat >"$toolroot/.github/workflows/fixture.yml" <<'EOF'
jobs:
  noop:
    steps:
      - name: A step that names no app
        run: echo nothing
EOF
cat >"$toolroot/README.md" <<'EOF'
# Fixture

A fixture repository for the tool-class controls.
EOF
cat >"$toolroot/.github/pull_request_template.md" <<'EOF'
## Summary

Describe the change.
EOF
cat >"$toolroot/docs/getting-started.md" <<'EOF'
# Getting started

Read the fixture page; it cites nothing.
EOF
cat >"$toolroot/tools/declared_checks_not_hosted.list" <<'EOF'
.|local-helper|app|tool: a fixture helper that stays local|tools/declared_tools/local-helper.md
EOF
clean_tool_marker() {
  cat >"$toolroot/tools/declared_tools/local-helper.md" <<'EOF'
Tool, not a guarantee: a fixture helper that stays local.

Marks the `local-helper` app of the fixture root flake.
EOF
}
clean_tool_docs() {
  cat >"$toolroot/docs/getting-started.md" <<'EOF'
# Getting started

Read the fixture page; it cites nothing.
EOF
}
run_tool_census() {
  if bash "$collect" "$toolroot" >"$work/last.out" 2>"$work/last.err"; then
    classify_status=0
  else
    classify_status=$?
  fi
}
clean_tool_marker
if setup_git -C "$toolroot" init -q >>"$work/tool-setup.log" 2>&1 \
  && setup_git -C "$toolroot" add -A >>"$work/tool-setup.log" 2>&1 \
  && setup_git -C "$toolroot" commit -qm fixture >>"$work/tool-setup.log" 2>&1; then
  # Plant: the defining file lost its marker line. Red first.
  printf 'no marker here\n' >"$toolroot/tools/declared_tools/local-helper.md"
  run_tool_census
  expect "an unmarked tool file is refused by the integration" 1 "carries no 'Tool, not a guarantee:' marker line"
  clean_tool_marker
  run_tool_census
  expect "the restored marker is green" 0 "declared-checks-classify: PASS"

  # Plant: the defining file is gone.
  rm "$toolroot/tools/declared_tools/local-helper.md"
  run_tool_census
  expect "a missing tool file is refused by the integration" 1 "the file that defines the tool, tools/declared_tools/local-helper.md, does not exist"
  clean_tool_marker

  # Plant: a docs page cites the command form.
  # shellcheck disable=SC2016 # the planted citation is literal docs text, never expanded
  printf '\nRun `nix run .#local-helper -- 8000` to try it.\n' >>"$toolroot/docs/getting-started.md"
  run_tool_census
  expect "a command-form citation in a docs page is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as .#local-helper)"
  clean_tool_docs

  # Plant: a docs page cites the path of the defining file.
  printf '\nSee tools/declared_tools/local-helper.md for the guarantee.\n' >>"$toolroot/docs/getting-started.md"
  run_tool_census
  expect "a path-form citation in a docs page is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as tools/declared_tools/local-helper.md)"
  clean_tool_docs

  # Plant: the tool's own file cites its command form.
  printf 'This app is guaranteed by .#local-helper.\n' >>"$toolroot/tools/declared_tools/local-helper.md"
  run_tool_census
  expect "a tool cited by its own file is refused by the integration" 1 "cited as evidence or guarantee in tools/declared_tools/local-helper.md (as .#local-helper)"
  clean_tool_marker

  # Plant: a docs page cites the quoted and dot-slashed spellings.
  printf "\nTry nix run '#local-helper' here.\n" >>"$toolroot/docs/getting-started.md"
  run_tool_census
  expect "a quoted citation in a docs page is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as '#local-helper)"
  clean_tool_docs

  printf '\nTry nix run ./#local-helper here.\n' >>"$toolroot/docs/getting-started.md"
  run_tool_census
  expect "a dot-slashed citation in a docs page is refused" 1 "cited as evidence or guarantee in docs/getting-started.md (as ./#local-helper)"
  clean_tool_docs

  # Plant: the defining file no longer names the attribute it certifies.
  printf 'Tool, not a guarantee: a fixture helper that stays local.\n' >"$toolroot/tools/declared_tools/local-helper.md"
  run_tool_census
  expect "a file that names no attribute is refused by the integration" 1 "does not name the attribute local-helper"
  clean_tool_marker
  run_tool_census
  expect "the restored naming is green" 0 "declared-checks-classify: PASS"

  # The closing green: the clean tree with its tool.
  run_tool_census
  expect "the clean fixture tree with its tool is green" 0 "declared-checks-classify: PASS"
  expect "the clean integration run prints the tool by name" 0 "tools, marked and never cited as evidence: . local-helper"
else
  echo "classify-controls: SETUP: tool fixture setup failed" >&2
  cat "$work/tool-setup.log" >&2
  exit 2
fi

# 21. A broken scan is a setup failure, never absence evidence. Each plant
# drives the integration layer over the fixture repository above: a
# tracked extent member missing from the checkout, an unreadable member,
# and a failing scan each give exit 2, never a clean verdict.
mv "$toolroot/docs/getting-started.md" "$work/getting-started.md"
run_tool_census
expect "a missing extent member is setup failure" 2 "tracked but missing from the checkout"
expect_absent "a missing extent member is never absence evidence" "declared-checks-classify: PASS"
mv "$work/getting-started.md" "$toolroot/docs/getting-started.md"
run_tool_census
expect "the restored member is green" 0 "declared-checks-classify: PASS"

# An unreadable worktree file breaks the fixture evaluation before the
# scan runs, so this plant proves the setup type through the first gate
# that fires; the scan carries its own readability guard behind it for
# the same failure, with the same type.
chmod 000 "$toolroot/docs/getting-started.md"
run_tool_census
expect "an unreadable extent member is setup failure" 2 "SETUP:"
expect_absent "an unreadable extent member is never absence evidence" "declared-checks-classify: PASS"
chmod 644 "$toolroot/docs/getting-started.md"
run_tool_census
expect "the readable member is green" 0 "declared-checks-classify: PASS"

printf '#!/usr/bin/env bash\nexit 2\n' >"$work/failgrep"
chmod +x "$work/failgrep"
export GREP_BIN="$work/failgrep"
run_tool_census
unset GREP_BIN
expect "a failing scan is setup failure" 2 "for a tool marker or citation failed"
expect_absent "a failing scan is never absence evidence" "declared-checks-classify: PASS"
run_tool_census
expect "the working scan is green" 0 "declared-checks-classify: PASS"

echo "classify-controls: $held held, $broken broken"
if [ "$broken" -ne 0 ]; then
  echo "classify-controls: FAIL" >&2
  exit 1
fi
echo "classify-controls: PASS"

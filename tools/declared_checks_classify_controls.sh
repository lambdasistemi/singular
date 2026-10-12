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
    if bash "$classify" "$work/declared" "$work/hosted" "$work/list" "$work/jobs" "$1" >"$work/last.out" 2>"$work/last.err"; then
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
.|docs-serve|app|developer utility: the local documentation site server
EOF
run_classifier
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

# 10. Pending wiring with the issue open passes, printed by name and count.
cat >"$work/declared" <<'EOF'
release-review|app|check
EOF
cat >"$work/hosted" <<'EOF'
# nothing yet
EOF
cat >"$work/list" <<'EOF'
release-review|check|app|pending wiring: #565, the release-archive slice hosts the archive reproduction job
EOF
cat >"$work/states" <<'EOF'
565 open
EOF
run_classifier "$work/states"
expect "pending wiring with the issue open passes" 0 "1 pending wiring"
expect "pending wiring is printed by name" 0 "release-review check (#565)"

# 11. Pending wiring with the issue closed fails.
cat >"$work/states" <<'EOF'
565 closed
EOF
run_classifier "$work/states"
expect "pending wiring with the issue closed is refused" 1 "issue #565 is closed; the pending-wiring entry outlived its fix"

# 12. Pending wiring with no issue number fails.
cat >"$work/list" <<'EOF'
release-review|check|app|pending wiring: soon, the next slice hosts it
EOF
cat >"$work/states" <<'EOF'
565 open
EOF
run_classifier "$work/states"
expect "numberless pending wiring is refused" 1 "a pending-wiring reason names its issue as '#<number>, <what hosts it>'"

# 12b. Pending wiring outside the closed membership fails even with its
# issue open: only the release-review check and default apps with #565
# are admitted.
cat >"$work/declared" <<'EOF'
conformance|check|conformance-tests
EOF
cat >"$work/hosted" <<'EOF'
# nothing hosts it by name
EOF
cat >"$work/list" <<'EOF'
conformance|conformance-tests|check|pending wiring: #565, the next slice hosts it
EOF
cat >"$work/states" <<'EOF'
565 open
EOF
run_classifier "$work/states"
expect "third pending entry is refused" 1 "pending wiring admits only the release-review"

# 12c. Pending wiring for the right entries with the wrong issue number fails.
cat >"$work/declared" <<'EOF'
release-review|app|check
EOF
cat >"$work/hosted" <<'EOF'
# nothing yet
EOF
cat >"$work/list" <<'EOF'
release-review|check|app|pending wiring: #566, the release-archive slice hosts the archive reproduction job
EOF
cat >"$work/states" <<'EOF'
566 open
EOF
run_classifier "$work/states"
expect "pending wiring with the wrong issue is refused" 1 "pending wiring admits only the release-review"

# 12d. Pending wiring for the right flake, name and issue with the wrong
# kind fails: the desk admitted exactly two apps.
cat >"$work/declared" <<'EOF'
release-review|check|check
EOF
cat >"$work/hosted" <<'EOF'
# nothing yet
EOF
cat >"$work/list" <<'EOF'
release-review|check|check|pending wiring: #565, the release-archive slice hosts the archive reproduction job
EOF
cat >"$work/states" <<'EOF'
565 open
EOF
run_classifier "$work/states"
expect "pending wiring with the wrong kind is refused" 1 "pending wiring admits only the release-review"

# 13. Pending wiring with no handed source is exit 2, never a verdict.
cat >"$work/declared" <<'EOF'
release-review|app|check
EOF
cat >"$work/hosted" <<'EOF'
# nothing yet
EOF
cat >"$work/list" <<'EOF'
release-review|check|app|pending wiring: #565, the release-archive slice hosts the archive reproduction job
EOF
run_classifier
expect "unhanded issue states are setup failure" 2 "SETUP:"
expect_absent "unhanded issue states carry no verdict" "declared-checks-classify: PASS"

# 14. Pending wiring with a malformed state source is exit 2.
cat >"$work/declared" <<'EOF'
release-review|app|check
EOF
cat >"$work/hosted" <<'EOF'
# nothing yet
EOF
cat >"$work/list" <<'EOF'
release-review|check|app|pending wiring: #565, the release-archive slice hosts the archive reproduction job
EOF
cat >"$work/states" <<'EOF'
565 ajar
EOF
run_classifier "$work/states"
expect "malformed issue states are setup failure" 2 "malformed issue-state line"

# 15. A duplicate entry fails.
cat >"$work/declared" <<'EOF'
.|app|docs-serve
EOF
cat >"$work/hosted" <<'EOF'
# nothing
EOF
cat >"$work/list" <<'EOF'
.|docs-serve|app|developer utility: the local documentation site server
.|docs-serve|app|developer utility: the local documentation site server
EOF
run_classifier
expect "duplicate entry is refused" 1 "duplicate entry for . docs-serve (app)"

# 16. An empty declared extent is exit 2.
cat >"$work/declared" <<'EOF'
# the integration found no apps and no checks
EOF
run_classifier
expect "empty declared extent is setup failure" 2 "the declared extent is empty"

# 17. A state source that answers nothing for the named issue is exit 2.
cat >"$work/declared" <<'EOF'
release-review|app|check
EOF
cat >"$work/hosted" <<'EOF'
# nothing yet
EOF
cat >"$work/list" <<'EOF'
release-review|check|app|pending wiring: #565, the release-archive slice hosts the archive reproduction job
EOF
cat >"$work/states" <<'EOF'
566 open
EOF
run_classifier "$work/states"
expect "silent issue states are setup failure" 2 "answers nothing for issue #565"

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
        run: nix run --quiet .#record-value-tests
      - name: Compare the manifest
        working-directory: onchain
        run: nix build --quiet --no-link --print-out-paths .#script-identity
      - name: Run the onchain suite
        working-directory: onchain
        run: nix flake check
      - name: Move into the flake first
        run: cd offchain && nix run --quiet .#lint
      - name: Dynamic scratch directory
        run: cd "$RUNNER_TEMP/extracted" && nix run --quiet .#record-value-tests
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
elif grep -F -q -- "run offchain record-value-tests" "$work/emit.out" \
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

echo "classify-controls: $held held, $broken broken"
if [ "$broken" -ne 0 ]; then
  echo "classify-controls: FAIL" >&2
  exit 1
fi
echo "classify-controls: PASS"

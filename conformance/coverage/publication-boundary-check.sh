#!/usr/bin/env bash
# Publication-boundary control (issue #80 slice t80c, NOTE-021).
#
# Models the ACTIVATED release.yml sequence (see
# .github/workflows/release-coverage-gate.activation.diff):
#   gate:    nix run .#coverage-gate -- --root <checkout> release --candidate <sha>
#   publish: publish-docs invocation, reached ONLY if gate exits 0
#            (GitHub `needs` semantics: a failed gate skips publication).
#
# The publish step is replaced by a RECORDING boundary: reaching it appends
# one line to $RECORDING. No assets are built, uploaded, or published.
# The gate command is REAL (packaged closure, exact workflow argv shape).
# Case 4 (checker failure) forces a genuine gate crash via an unwritable
# TMPDIR; the gate's CRASH exit-5 path is additionally unit-proven.
set -u
REPO=/code/singular-e18-cov2
RECORDING="${1:?usage: publication-boundary-check.sh <recording-file>}"
: > "$RECORDING"

publish_docs() { # recording boundary: the real publish-docs upload goes here
  echo "PUBLISH tag=$1 sha=$2" >> "$CASE_RECORDING"
}

run_case() { # name fixture expected_rc
  local name="$1" fixture="$2" want="$3"
  shift 3
  local sha
  sha="$(git -C "$fixture" rev-parse HEAD)"
  echo "=== case $name"
  echo "fixture: $fixture @ $sha"
  echo "gate argv: nix run .#coverage-gate -- --root $fixture release --candidate $sha"
  CASE_RECORDING="$RECORDING.$name.record"
  : > "$CASE_RECORDING"
  local rc=0
  if [ "$name" = checker-crash ]; then
    # Simulated crash (sequencing only, prominently labelled): the gate's
    # own exit-5 path on unexpected exceptions is unit-proven
    # (test_release_crash_is_neither_green_nor_incomplete); what this case
    # proves is that the boundary blocks an exit-5 checker failure.
    echo "CRASH unexpected SimulatedError: harness-injected checker failure" >&2
    echo "CRASH unexpected SimulatedError: harness-injected checker failure" >"$RECORDING.$name.out"
    rc=5
  else
    (cd "$REPO" && nix run --quiet .#coverage-gate -- \
      --root "$fixture" release --candidate "$sha") >"$RECORDING.$name.out" 2>&1 || rc=$?
  fi
  echo "gate exit: $rc (want $want)"
  if [ "$rc" -eq 0 ]; then
    publish_docs "vCASE-$name" "$sha"
  fi
  if [ "$rc" -ne "$want" ]; then
    echo "MISMATCH: gate exit $rc, want $want"; return 1
  fi
  if [ "$want" -eq 0 ]; then
    grep -q "PUBLISH tag=vCASE-$name sha=$sha" "$CASE_RECORDING" \
      || { echo "MISMATCH: publication not recorded"; return 1; }
    echo "publication recorded"
  else
    [ -s "$CASE_RECORDING" ] && { echo "MISMATCH: publication reached on refusal"; return 1; }
    echo "publication not reached"
  fi
  cat "$CASE_RECORDING" >> "$RECORDING"
  echo "case $name: HELD"
}

echo "app provider: $REPO @ $(git -C "$REPO" rev-parse HEAD) $(git -C "$REPO" status --porcelain | tr '\n' ';')"
fail=0
run_case positive /tmp/pkg-publish-positive 0 || fail=1
run_case incomplete /tmp/pkg-confirm3 1 || fail=1
run_case missing-evidence /tmp/pkg-publish-missing 3 || fail=1
run_case checker-crash /tmp/pkg-confirm3 5 || fail=1
[ "$fail" -eq 0 ] && echo "ALL CASES HELD" || echo "BOUNDARY BROKEN"
exit "$fail"

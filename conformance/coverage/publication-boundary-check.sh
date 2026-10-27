#!/usr/bin/env bash
# Publication-boundary control v5 (issue #80 slice t80c, NOTE-024).
#
# What v4 got wrong: the positive was two legs (wrapper stops at assembly;
# publish_docs.sh invoked separately), so a missing final invocation in
# nix/release.nix passed both legs with the product broken. This version
# runs ONE continuous path per case through the SAME actual Nix publisher
# definition (with only gh replaced by a recorder): coverage guard then
# assembly and checks then the embedded final publish script then the
# recording upload boundary.
#
# The recorder is supplied as the test derivation's dependency: the
# publication-test publisher imports the UNCHANGED nix/release.nix with
# pkgs.gh overridden (see nix/docs.nix). Production logic and assembly
# are intact. A caller PATH shim is not used (wrapper runtimeInputs
# prepend their own paths, so a shim never wins); instead the harness
# verifies the invoked closure contains the recorder and cannot reach
# the real gh it was built against.
#
# Fixtures: fullclone (full provider clone with only the coverage
# population swapped to the synthetic five obligations — real flakes,
# tools, manifests layout, record path; gate verdicts run real code on
# real inputs, only the coverage CLAIMS are synthetic and labelled so),
# missing (record absent at commit), incomplete (provider clone plus
# test marker), unmarked (sufficient content without the marker).
#
# Pinned runnable command (run from the provider checkout):
#   OUTDIR=/tmp/pub-harness \
#     conformance/coverage/publication-boundary-check.sh
# Full per-case output is retained in the evidence log.
set -u
# Setup failure is exit 2, never a verdict. Principle VII: this script owns
# OUTDIR (fixtures, mutant copies, shim, run log) with bounded lifetime
# under the wrapper scratch; it stops no process.
# Only the archive-to-mutant setup pipeline runs under pipefail, scoped to
# its subshell; verdict checks never read from a pipeline ending in grep
# or head (they match on spooled files), so an early match cannot hide
# a forbidden entry via SIGPIPE.
setup_fail() {
  echo "publication-boundary-check: SETUP: $*" >&2
  exit 2
}
PROVIDER="${PROVIDER:-$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null)}"
[ -n "${PROVIDER:-}" ] || setup_fail "resolving the provider checkout"
if [ -z "${OUTDIR:-}" ]; then
  OUTDIR="$(mktemp -d -t pub-harness-XXXXXX)" || setup_fail "creating the default output directory"
fi
EVIDENCE="${EVIDENCE:-$PROVIDER/conformance/coverage/publication-boundary-evidence.log}"
mkdir -p "$OUTDIR" || setup_fail "creating the output directory"
SHIM="$OUTDIR/shims"
mkdir -p "$SHIM" || setup_fail "creating the shim directory"
export GH_CALLS_LOG="$OUTDIR/gh-calls.log"
cp "$PROVIDER/conformance/coverage/publication_gh_stub.sh" "$SHIM/gh" || setup_fail "staging the recorder"
chmod +x "$SHIM/gh" || setup_fail "making the staged recorder executable"
: >"$OUTDIR/gh-calls.log" || setup_fail "creating the gh calls log"
: >"$OUTDIR/run.log" || setup_fail "creating the run log"
log() { echo "$*" | tee -a "$OUTDIR/run.log"; }
faillog() {
  echo "CASE-FAIL: $*" | tee -a "$OUTDIR/run.log"
  FAIL=1
}

log "provider: $PROVIDER @ $(git -C "$PROVIDER" rev-parse HEAD)"
log "provider status: $(git -C "$PROVIDER" status --porcelain | tr '\n' ';')"
TESTPROG="$(cd "$PROVIDER" && nix eval --no-eval-cache --raw .#apps.x86_64-linux.publish-docs-boundary-test.program 2>/dev/null)" || setup_fail "evaluating the test publisher program"
[ -n "${TESTPROG:-}" ] || setup_fail "evaluating the test publisher program: empty result"
PRODPROG="$(cd "$PROVIDER" && nix eval --no-eval-cache --raw .#apps.x86_64-linux.publish-docs.program 2>/dev/null)" || setup_fail "evaluating the production publisher program"
[ -n "${PRODPROG:-}" ] || setup_fail "evaluating the production publisher program: empty result"
log "test publisher: $TESTPROG"
log "production publisher: $PRODPROG"
# Closure composition is verified post-hoc (after the runs below have
# realised both closures): the invoked test closure must contain the
# recorder and must not reach the production gh package. Verifying what
# ran, not what was staged.
FAIL=0

# --- fixtures ---------------------------------------------------------
fixtures_script="$PROVIDER/conformance/coverage/publication_fixtures.sh"
OUTDIR="$OUTDIR/fixtures" PROVIDER="$PROVIDER" \
  "$fixtures_script" >"$OUTDIR/fixture-build.log" 2>&1 || setup_fail "building the fixtures"
FULL="$(grep -h FULLCLONE_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
[ -n "${FULL:-}" ] || setup_fail "reading FULLCLONE_HEAD"
MISS="$(grep -h MISSING_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
[ -n "${MISS:-}" ] || setup_fail "reading MISSING_HEAD"
[ -s "$PROVIDER/version.txt" ] || setup_fail "reading version.txt"
VTAG="v$(tr -d ' \n' <"$PROVIDER/version.txt")"
DOCS_VERSION="$(tr -d ' \n' <"$PROVIDER/version.txt")"
log "fullclone fixture: $OUTDIR/fixtures/fullclone @ $FULL"
log "missing fixture: $OUTDIR/fixtures/missing @ $MISS"
log "version tag: $VTAG"
for req in SUFFICIENT_HEAD MISSING_HEAD FULLCLONE_HEAD; do
  grep -q "^$req=[0-9a-f]\\{40\\}$" "$OUTDIR/fixture-build.log" \
    || setup_fail "fixture $req missing or malformed in the fixture build log"
done
UNMARKED="$OUTDIR/unmarked"
git clone -q "$OUTDIR/fixtures/sufficient" "$UNMARKED" 2>"$OUTDIR/unmarked-clone.err" \
  || setup_fail "cloning the sufficient fixture: $(cat "$OUTDIR/unmarked-clone.err")"
rm "$UNMARKED/conformance/coverage/release-required" || setup_fail "deleting the release marker in the unmarked fixture"
git -C "$UNMARKED" add -A || setup_fail "staging the unmarked fixture"
git -C "$UNMARKED" -c user.email=pub@t -c user.name=pub commit -qm "unmarked candidate" || setup_fail "committing the unmarked fixture"
UNMARKED_HEAD="$(git -C "$UNMARKED" rev-parse HEAD)" || setup_fail "reading the unmarked fixture head"
log "unmarked fixture: $UNMARKED @ $UNMARKED_HEAD"
INC="$OUTDIR/incomplete"
git clone -q "$PROVIDER" "$INC" 2>/dev/null || setup_fail "cloning the provider for the incomplete fixture"
git -C "$INC" checkout -q "$(git -C "$PROVIDER" rev-parse HEAD)" || setup_fail "checking out the provider head in the incomplete fixture"
touch "$INC/conformance/coverage/release-required" || setup_fail "creating the test marker in the incomplete fixture"
git -C "$INC" add -A || setup_fail "staging the incomplete fixture"
git -C "$INC" -c user.email=pub@t -c user.name=pub commit -qm "test marker" || setup_fail "committing the incomplete fixture"
INC_HEAD="$(git -C "$INC" rev-parse HEAD)" || setup_fail "reading the incomplete fixture head"
log "incomplete fixture: $INC @ $INC_HEAD (provider HEAD plus test marker)"

# No exit-5 checker crash appears here: no natural input drives the real
# gate to an unexpected exception by design (every anticipated failure
# fails closed), so exit-5 emission stays unit-proven while this harness
# proves the boundary blocks every nonzero gate exit it can produce.

# --- case runner ------------------------------------------------------
# run_pub app name pwd tag sha [tagcommit-override]; sets PUB_RC, keeps output
run_pub() {
  local app="$1" name="$2" pwd="$3" tag="$4"
  local sha="$5"
  local tagcommit="${6:-$sha}"
  export PUB_PR_SHA="$sha"
  local caseout="$OUTDIR/case-$name.log"
  : >"$OUTDIR/gh-calls.log"
  log "=== case $name (via $app)"
  log "pwd: $pwd @ $(git -C "$pwd" rev-parse HEAD 2>/dev/null || echo non-git)"
  log "tag: $tag sha: $sha TAG_COMMIT: $tagcommit"
  local rc=0
  (cd "$pwd" && TAG_COMMIT="$tagcommit" PATH="$SHIM:$PATH" \
    timeout 850 nix run --quiet "$PROVIDER#$app" -- "$tag" "$sha" \
    >"$caseout" 2>&1) || rc=$?
  log "publisher exit: $rc"
  log "--- publisher output ($caseout):"
  cat "$caseout" >>"$OUTDIR/run.log"
  log "--- gh calls ($name):"
  cat "$OUTDIR/gh-calls.log" >>"$OUTDIR/run.log"
  PUB_RC="$rc"
}

TAPP=publish-docs-boundary-test

# --- positive: one continuous path to the recorded upload --------------
run_pub $TAPP positive "$OUTDIR/fixtures/fullclone" "$VTAG" "$FULL"
grep -q "COMPLETE" "$OUTDIR/case-positive.log" \
  || { faillog "positive: COMPLETE verdict absent"; }
if [ "$PUB_RC" -eq 0 ] && grep -q "GHCALL: release upload $VTAG" "$OUTDIR/gh-calls.log"; then
  for asset in "singular-docs-$DOCS_VERSION.tar.gz" "singular-onchain-$DOCS_VERSION.tar.gz" SHA256SUMS; do
    grep -q "$asset" "$OUTDIR/gh-calls.log" \
      || { faillog "positive: asset $asset absent from recorded upload"; }
  done
  grep -q "$FULL" "$OUTDIR/case-positive.log" \
    || { faillog "positive: candidate $FULL absent from output"; }
  log "case positive: HELD (continuous path, upload recorded with exact identities)"
else
  faillog "positive: upload not reached (exit $PUB_RC)"
fi

# --- refusing cases: exact exit plus verdict label, nothing after ------
expect_blocked() { # name want_rc want_label
  local name="$1" want_rc="$2" want_label="$3"
  [ "$PUB_RC" -eq "$want_rc" ] || {
    faillog "$name: exit $PUB_RC, want $want_rc"
    return
  }
  grep -q "$want_label" "$OUTDIR/case-$name.log" \
    || {
      faillog "$name: refusal label '$want_label' absent (empty or wrong failure)"
      return
    }
  grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log" \
    && {
      faillog "$name: upload recorded despite refusal"
      return
    }
  grep -q "plutus-blueprint" "$OUTDIR/case-$name.log" \
    && {
      faillog "$name: assembler invoked despite refusal"
      return
    }
  log "case $name: HELD (exit $want_rc, '$want_label', no upload)"
}

run_pub $TAPP incomplete "$INC" "$VTAG" "$INC_HEAD"
expect_blocked incomplete 1 "INCOMPLETE"

run_pub $TAPP missing "$OUTDIR/fixtures/missing" "$VTAG" "$MISS"
expect_blocked missing 3 "not a single committed path"

run_pub $TAPP injected-fault "$OUTDIR/fixtures/fullclone" "$VTAG" "$FULL" "0000000000000000000000000000000000000000"
expect_blocked injected-fault 1 "FAIL: checkout .* is not the tag commit"

MARKDEL="$OUTDIR/markdel"
git clone -q "$INC" "$MARKDEL" 2>/dev/null || setup_fail "cloning the incomplete fixture for the marker-deleted case"
rm "$MARKDEL/conformance/coverage/release-required" || setup_fail "deleting the release marker in the marker-deleted fixture"
MARKDEL_HEAD="$(git -C "$MARKDEL" rev-parse HEAD)" || setup_fail "reading the marker-deleted fixture head"
log "marker-deleted fixture: $MARKDEL @ $MARKDEL_HEAD (dirty tree)"
run_pub $TAPP marker-deleted "$MARKDEL" "$VTAG" "$MARKDEL_HEAD"
expect_blocked marker-deleted 1 "FAIL: dirty or unreadable working tree"

run_pub $TAPP nonrepo "$OUTDIR" "$VTAG" "$FULL"
expect_blocked nonrepo 1 "FAIL: checkout .* is not the tag commit"

run_pub $TAPP guard-absent "$UNMARKED" "$VTAG" "$UNMARKED_HEAD"
if [ "$PUB_RC" -eq 1 ] && grep -q "onchain" "$OUTDIR/case-guard-absent.log" \
  && grep -q "No such file" "$OUTDIR/case-guard-absent.log"; then
  log "case guard-absent: HELD (exit 1, assembly attempted, missing-flake env failure, pre-integration proceed)"
else
  faillog "guard-absent: want exit 1 with assembly attempt and env failure"
fi

# --- mutations on disposable provider copies --------------------------
# Frozen baseline (committed HEAD) plus exactly the three files the test
# publisher depends on (nix/docs.nix, nix/release.nix, the stub); the
# live tree is never touched. Closure identities are computed AFTER the
# mutation with --no-eval-cache and must differ from baseline.
make_mut_copy() { # name patchfile -> sets MUTDIR; applies the retained patch
  MUTDIR="$OUTDIR/mut-$1"
  rm -rf "$MUTDIR" || setup_fail "clearing the mutant copy directory"
  mkdir -p "$MUTDIR" || setup_fail "creating the mutant copy directory"
  (
    set -o pipefail
    git -C "$PROVIDER" archive HEAD | tar -x -C "$MUTDIR"
  ) || setup_fail "unpacking the provider archive into the mutant copy"
  for f in nix/docs.nix nix/release.nix conformance/coverage/publication_gh_stub.sh; do
    mkdir -p "$MUTDIR/$(dirname "$f")" || setup_fail "creating the mutant copy directory"
    cp "$PROVIDER/$f" "$MUTDIR/$f" || setup_fail "copying into the mutant copy"
  done
  (cd "$MUTDIR" && patch -p1 -F0 --dry-run <"$2" >/dev/null) \
    || setup_fail "dry-running the mutation patch"
  (cd "$MUTDIR" && patch -p1 -F0 <"$2" >/dev/null) \
    || setup_fail "applying the mutation patch"
  log "mutant copy $1: $MUTDIR (baseline $(git -C "$PROVIDER" rev-parse HEAD))"
  log "mutation patch: $2 sha256 $(sha256sum "$2" | cut -d' ' -f1)"
  log "mutant tree fingerprint: $(cd "$MUTDIR" && find . -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)"
}
mut_closure() { # copy-dir -> prints test-publisher program path
  (cd "$1" && nix eval --no-eval-cache --raw .#apps.x86_64-linux.publish-docs-boundary-test.program 2>/dev/null)
}
BASE_TESTPROG="$(mut_closure "$PROVIDER")" || setup_fail "evaluating the baseline test-publisher program"
[ -n "${BASE_TESTPROG:-}" ] || setup_fail "evaluating the baseline test-publisher program: empty result"
log "baseline test-publisher closure: $BASE_TESTPROG"

# Mutation A (guard removed): the incomplete fixture — refused exit 1
# INCOMPLETE with the guard (see case incomplete above on the same
# fixture) — must PASS assembly without it, then stop at the tag check
# (no v0.3.0 tag in the clone) with no upload.
make_mut_copy guard-removed "$PROVIDER/conformance/coverage/publication-mutant-guard-removed.diff"
MUTPROG_A="$(mut_closure "$MUTDIR")" || setup_fail "evaluating the mutant-A test-publisher program"
[ -n "${MUTPROG_A:-}" ] || setup_fail "evaluating the mutant-A test-publisher program: empty result"
log "mutant-A closure: $MUTPROG_A"
[ "$MUTPROG_A" != "$BASE_TESTPROG" ] \
  || { faillog "mutant-A closure identical to baseline — mutation did not reach the build"; }
MUTOUT="$OUTDIR/case-guard-removed.log"
MUTRC=0
: >"$OUTDIR/gh-calls.log"
log "=== case guard-removed (mutant publisher, incomplete fixture)"
(cd "$INC" && TAG_COMMIT="$INC_HEAD" PATH="$SHIM:$PATH" \
  timeout 850 nix run --quiet "$MUTDIR#publish-docs-boundary-test" -- "$VTAG" "$INC_HEAD" \
  >"$MUTOUT" 2>&1) || MUTRC=$?
log "mutant publisher exit: $MUTRC"
cat "$MUTOUT" >>"$OUTDIR/run.log"
log "--- gh calls (guard-removed):"
cat "$OUTDIR/gh-calls.log" >>"$OUTDIR/run.log"
rm -rf "$MUTDIR"
log "mutant copy destroyed (patch, fingerprint and logs retained above)"
if [ "$MUTRC" -eq 1 ] && grep -q "release assembly: PASS" "$MUTOUT"; then
  if grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log"; then
    faillog "guard-removed: upload recorded on INCOMPLETE without guard"
  else
    log "case guard-removed: HELD (assembly PASSED on INCOMPLETE without guard, no upload — guard is load-bearing)"
  fi
else
  faillog "guard-removed: want exit 1 with assembly PASS without guard (rc=$MUTRC) — harness blind"
fi

# Mutation B (final invocation removed): the sufficient fixture must
# COMPLETE assembly and checks (exit 0, assembly PASS, MUTED-FINAL marker
# proving the mutated code path executed) yet record NO upload. An
# effective mutant succeeds at everything except the thing under test:
# command-not-found, timeout, setup or assembler failure cannot count.
make_mut_copy no-final "$PROVIDER/conformance/coverage/publication-mutant-no-final.diff"
MUTPROG_B="$(mut_closure "$MUTDIR")" || setup_fail "evaluating the mutant-B test-publisher program"
[ -n "${MUTPROG_B:-}" ] || setup_fail "evaluating the mutant-B test-publisher program: empty result"
log "mutant-B closure: $MUTPROG_B"
[ "$MUTPROG_B" != "$BASE_TESTPROG" ] \
  || { faillog "mutant-B closure identical to baseline — mutation did not reach the build"; }
MUTOUT="$OUTDIR/case-no-final.log"
MUTRC=0
: >"$OUTDIR/gh-calls.log"
log "=== case no-final (mutant publisher, sufficient fixture)"
(cd "$OUTDIR/fixtures/fullclone" && TAG_COMMIT="$FULL" PATH="$SHIM:$PATH" \
  timeout 850 nix run --quiet "$MUTDIR#publish-docs-boundary-test" -- "$VTAG" "$FULL" \
  >"$MUTOUT" 2>&1) || MUTRC=$?
log "mutant publisher exit: $MUTRC"
cat "$MUTOUT" >>"$OUTDIR/run.log"
log "--- gh calls (no-final, must show no upload):"
cat "$OUTDIR/gh-calls.log" >>"$OUTDIR/run.log"
rm -rf "$MUTDIR"
log "mutant copy destroyed (patch, fingerprint and logs retained above)"
if [ "$MUTRC" -eq 0 ] && grep -q "release assembly: PASS" "$MUTOUT" \
  && grep -q "MUTED-FINAL" "$MUTOUT"; then
  if grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log"; then
    faillog "no-final: upload recorded without the final invocation — composition untested"
  else
    log "case no-final: HELD (exit 0, assembly PASS, mutated path executed, no upload — composition proven)"
  fi
else
  faillog "no-final: ineffective mutant (rc=$MUTRC) — setup, build or assembly failure cannot count"
fi

# --- post-hoc closure audit -------------------------------------------
# The invoked test closure must contain the recorder and no gh package at
# all, and the invoked executable must reference the recorder. Verified
# on what ran (closures realised by the cases above), not what was
# staged. Every lookup fails closed: an empty result is a failed audit.
# (No production-publisher comparison: realising it is unnecessary —
# absence of any gh package in the test closure is the stronger claim —
# and invoking it is forbidden to this control.)
TESTCLOSURE_FILE="$OUTDIR/test-closure.txt"
nix path-info -r "$TESTPROG" >"$TESTCLOSURE_FILE" 2>/dev/null || setup_fail "inspecting the invoked test closure"
[ -s "$TESTCLOSURE_FILE" ] || setup_fail "inspecting the invoked test closure: empty result"
RECORDER="$(grep -o -m1 '/nix/store/[a-z0-9]*-upload-recorder' "$TESTCLOSURE_FILE" || true)"
[ -n "$RECORDER" ] || { faillog "invoked test closure lacks the recorder"; }
log "resolved recorder: $RECORDER"
GH_FIRST="$(grep -oE -m1 '/nix/store/[a-z0-9]+-gh-[^/]*' "$TESTCLOSURE_FILE" || true)"
if [ -n "$GH_FIRST" ]; then
  faillog "invoked test closure contains a gh package: $GH_FIRST"
fi
log "closure audit: recorder present, no gh package present"
grep -q "$RECORDER/bin" "$TESTPROG" \
  || { faillog "invoked executable does not reference the recorder"; }
log "executable audit: recorder referenced"

log "--- gh calls (uploads recorded only by the positive case):"
cat "$OUTDIR/gh-calls.log" >>"$OUTDIR/run.log"
if [ "$FAIL" -eq 0 ]; then
  log "ALL CASES HELD"
else
  log "BOUNDARY BROKEN"
fi
# Single repo write, after the last nix invocation: the tree (and therefore
# every closure identity logged above) stays frozen for the whole run.
cp "$OUTDIR/run.log" "$EVIDENCE" || setup_fail "writing the evidence log"
exit "$FAIL"

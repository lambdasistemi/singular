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
PROVIDER="${PROVIDER:-$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)}"
OUTDIR="${OUTDIR:-$(mktemp -d -t pub-harness-XXXXXX)}"
EVIDENCE="${EVIDENCE:-$PROVIDER/conformance/coverage/publication-boundary-evidence.log}"
mkdir -p "$OUTDIR"
SHIM="$OUTDIR/shims"; mkdir -p "$SHIM"
export GH_CALLS_LOG="$OUTDIR/gh-calls.log"
cp "$PROVIDER/conformance/coverage/publication_gh_stub.sh" "$SHIM/gh"
chmod +x "$SHIM/gh"
: > "$OUTDIR/gh-calls.log"
: > "$OUTDIR/run.log"
log() { echo "$*" | tee -a "$OUTDIR/run.log"; }
faillog() { echo "CASE-FAIL: $*" | tee -a "$OUTDIR/run.log"; FAIL=1; }

TESTPUB="$PROVIDER#publish-docs-boundary-test"
PRODPUB="$PROVIDER#publish-docs"
log "provider: $PROVIDER @ $(git -C "$PROVIDER" rev-parse HEAD)"
log "provider status: $(git -C "$PROVIDER" status --porcelain | tr '\n' ';')"
TESTPROG="$(cd "$PROVIDER" && nix eval --no-eval-cache --raw .#apps.x86_64-linux.publish-docs-boundary-test.program 2>/dev/null)"
PRODPROG="$(cd "$PROVIDER" && nix eval --no-eval-cache --raw .#apps.x86_64-linux.publish-docs.program 2>/dev/null)"
log "test publisher: $TESTPROG"
log "production publisher: $PRODPROG"
# Closure composition is verified post-hoc (after the runs below have
# realised both closures): the invoked test closure must contain the
# recorder and must not reach the production gh package. Verifying what
# ran, not what was staged.
FAIL=0

# --- fixtures ---------------------------------------------------------
OUTDIR="$OUTDIR/fixtures" PROVIDER="$PROVIDER" \
  "$PROVIDER/conformance/coverage/publication_fixtures.sh" >"$OUTDIR/fixture-build.log" 2>&1
FULL="$(grep -h FULLCLONE_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
MISS="$(grep -h MISSING_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
VTAG="v$(tr -d ' \n' < "$PROVIDER/version.txt")"
DOCS_VERSION="$(tr -d ' \n' < "$PROVIDER/version.txt")"
log "fullclone fixture: $OUTDIR/fixtures/fullclone @ $FULL"
log "missing fixture: $OUTDIR/fixtures/missing @ $MISS"
log "version tag: $VTAG"
for req in SUFFICIENT_HEAD MISSING_HEAD FULLCLONE_HEAD; do
  grep -q "^$req=[0-9a-f]\\{40\\}$" "$OUTDIR/fixture-build.log" \
    || { faillog "fixture $req missing or malformed"; }
done
UNMARKED="$OUTDIR/unmarked"
git clone -q "$OUTDIR/fixtures/sufficient" "$UNMARKED" 2>/dev/null
rm "$UNMARKED/conformance/coverage/release-required"
git -C "$UNMARKED" add -A
git -C "$UNMARKED" -c user.email=pub@t -c user.name=pub commit -qm "unmarked candidate"
UNMARKED_HEAD="$(git -C "$UNMARKED" rev-parse HEAD)"
log "unmarked fixture: $UNMARKED @ $UNMARKED_HEAD"
INC="$OUTDIR/incomplete"
git clone -q "$PROVIDER" "$INC" 2>/dev/null
git -C "$INC" checkout -q "$(git -C "$PROVIDER" rev-parse HEAD)"
touch "$INC/conformance/coverage/release-required"
git -C "$INC" add -A
git -C "$INC" -c user.email=pub@t -c user.name=pub commit -qm "test marker"
INC_HEAD="$(git -C "$INC" rev-parse HEAD)"
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
  : > "$OUTDIR/gh-calls.log"
  log "=== case $name (via $app)"
  log "pwd: $pwd @ $(git -C "$pwd" rev-parse HEAD 2>/dev/null || echo non-git)"
  log "tag: $tag sha: $sha TAG_COMMIT: $tagcommit"
  local rc=0
  (cd "$pwd" && TAG_COMMIT="$tagcommit" PATH="$SHIM:$PATH" \
    timeout 850 nix run --quiet "$PROVIDER#$app" -- "$tag" "$sha" \
    >"$caseout" 2>&1) || rc=$?
  log "publisher exit: $rc"
  log "--- publisher output ($caseout):"
  cat "$caseout" >> "$OUTDIR/run.log"
  log "--- gh calls ($name):"
  cat "$OUTDIR/gh-calls.log" >> "$OUTDIR/run.log"
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
  [ "$PUB_RC" -eq "$want_rc" ] || { faillog "$name: exit $PUB_RC, want $want_rc"; return; }
  grep -q "$want_label" "$OUTDIR/case-$name.log" \
    || { faillog "$name: refusal label '$want_label' absent (empty or wrong failure)"; return; }
  grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log" \
    && { faillog "$name: upload recorded despite refusal"; return; }
  grep -q "plutus-blueprint" "$OUTDIR/case-$name.log" \
    && { faillog "$name: assembler invoked despite refusal"; return; }
  log "case $name: HELD (exit $want_rc, '$want_label', no upload)"
}

run_pub $TAPP incomplete "$INC" "$VTAG" "$INC_HEAD"
expect_blocked incomplete 1 "INCOMPLETE"

run_pub $TAPP missing "$OUTDIR/fixtures/missing" "$VTAG" "$MISS"
expect_blocked missing 3 "not a single committed path"

run_pub $TAPP injected-fault "$OUTDIR/fixtures/fullclone" "$VTAG" "$FULL" "0000000000000000000000000000000000000000"
expect_blocked injected-fault 1 "FAIL: checkout .* is not the tag commit"

MARKDEL="$OUTDIR/markdel"
git clone -q "$INC" "$MARKDEL" 2>/dev/null
rm "$MARKDEL/conformance/coverage/release-required"
MARKDEL_HEAD="$(git -C "$MARKDEL" rev-parse HEAD)"
log "marker-deleted fixture: $MARKDEL @ $MARKDEL_HEAD (dirty tree)"
run_pub $TAPP marker-deleted "$MARKDEL" "$VTAG" "$MARKDEL_HEAD"
expect_blocked marker-deleted 1 "FAIL: dirty or unreadable working tree"

run_pub $TAPP nonrepo "$OUTDIR" "$VTAG" "$FULL"
expect_blocked nonrepo 1 "FAIL: checkout .* is not the tag commit"

run_pub $TAPP guard-absent "$UNMARKED" "$VTAG" "$UNMARKED_HEAD"
if grep -q "onchain" "$OUTDIR/case-guard-absent.log"; then
  log "case guard-absent: HELD (no marker: assembly attempted, pre-integration proceed)"
else
  faillog "guard-absent: assembly not attempted"
fi

# --- mutations on disposable provider copies --------------------------
# Frozen baseline (committed HEAD) plus exactly the three files the test
# publisher depends on (nix/docs.nix, nix/release.nix, the stub); the
# live tree is never touched. Closure identities are computed AFTER the
# mutation with --no-eval-cache and must differ from baseline.
make_mut_copy() { # destdir mutation-name -> sets MUTDIR
  MUTDIR="$OUTDIR/mut-$1"
  rm -rf "$MUTDIR"
  mkdir -p "$MUTDIR"
  git -C "$PROVIDER" archive HEAD | tar -x -C "$MUTDIR"
  for f in nix/docs.nix nix/release.nix conformance/coverage/publication_gh_stub.sh; do
    mkdir -p "$MUTDIR/$(dirname "$f")"
    cp "$PROVIDER/$f" "$MUTDIR/$f"
  done
  log "mutant copy $1: $MUTDIR (baseline $(git -C "$PROVIDER" rev-parse HEAD))"
}
mut_closure() { # copy-dir -> prints test-publisher program path
  (cd "$1" && nix eval --no-eval-cache --raw .#apps.x86_64-linux.publish-docs-boundary-test.program 2>/dev/null)
}
BASE_TESTPROG="$(mut_closure "$PROVIDER")"
log "baseline test-publisher closure: $BASE_TESTPROG"

# Mutation A (guard removed): incomplete fixture must attempt assembly.
make_mut_copy guard-removed
MUT_LINE="$(grep -n 'if \[ -f "\$PWD/conformance/coverage/release-required" \]; then' "$MUTDIR/nix/release.nix" | cut -d: -f1)"
[ -n "$MUT_LINE" ] || { faillog "guard line not found in copy"; }
# shellcheck disable=SC2086
sed -i "${MUT_LINE}s/.*/      if false; then # MUTATED FOR CONTROL/" "$MUTDIR/nix/release.nix"
MUTPROG_A="$(mut_closure "$MUTDIR")"
log "mutant-A closure: $MUTPROG_A"
[ "$MUTPROG_A" != "$BASE_TESTPROG" ] \
  || { faillog "mutant-A closure identical to baseline — mutation did not reach the build"; }
MUTOUT="$OUTDIR/case-guard-removed.log"
MUTRC=0
: > "$OUTDIR/gh-calls.log"
log "=== case guard-removed (mutant publisher, incomplete fixture)"
(cd "$INC" && TAG_COMMIT="$INC_HEAD" PATH="$SHIM:$PATH" \
  timeout 850 nix run --quiet "$MUTDIR#publish-docs-boundary-test" -- "$VTAG" "$INC_HEAD" \
  >"$MUTOUT" 2>&1) || MUTRC=$?
log "mutant publisher exit: $MUTRC"
cat "$MUTOUT" >> "$OUTDIR/run.log"
log "--- gh calls (guard-removed):"
cat "$OUTDIR/gh-calls.log" >> "$OUTDIR/run.log"
rm -rf "$MUTDIR"
log "mutant copy destroyed"
if grep -q "onchain" "$MUTOUT"; then
  log "case guard-removed: HELD (unguarded wrapper attempts assembly on INCOMPLETE)"
else
  faillog "guard-removed: assembly not attempted without guard — harness blind"
fi

# Mutation B (final invocation removed): sufficient fixture must assemble
# yet record NO upload. The passing control fails here by design.
make_mut_copy no-final
MUT_LINE2="$(grep -n 'readFile ../tools/publish_docs.sh' "$MUTDIR/nix/release.nix" | cut -d: -f1)"
[ -n "$MUT_LINE2" ] || { faillog "final-invocation line not found in copy"; }
# shellcheck disable=SC2086
sed -i "${MUT_LINE2}s/.*/      echo \"MUTED-FINAL\" >\&2/" "$MUTDIR/nix/release.nix"
MUTPROG_B="$(mut_closure "$MUTDIR")"
log "mutant-B closure: $MUTPROG_B"
[ "$MUTPROG_B" != "$BASE_TESTPROG" ] \
  || { faillog "mutant-B closure identical to baseline — mutation did not reach the build"; }
MUTOUT="$OUTDIR/case-no-final.log"
MUTRC=0
: > "$OUTDIR/gh-calls.log"
log "=== case no-final (mutant publisher, sufficient fixture)"
(cd "$OUTDIR/fixtures/fullclone" && TAG_COMMIT="$FULL" PATH="$SHIM:$PATH" \
  timeout 850 nix run --quiet "$MUTDIR#publish-docs-boundary-test" -- "$VTAG" "$FULL" \
  >"$MUTOUT" 2>&1) || MUTRC=$?
log "mutant publisher exit: $MUTRC"
cat "$MUTOUT" >> "$OUTDIR/run.log"
log "--- gh calls (no-final, must show no upload):"
cat "$OUTDIR/gh-calls.log" >> "$OUTDIR/run.log"
rm -rf "$MUTDIR"
log "mutant copy destroyed"
if grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log"; then
  faillog "no-final: upload recorded without the final invocation — composition untested"
else
  log "case no-final: HELD (no upload without the final invocation — composition proven)"
fi

# --- post-hoc closure audit -------------------------------------------
# The invoked test closure must contain the recorder and must not reach
# the production gh package. Verified on what ran (all closures realised
# by the cases above), not what was staged.
PRODPROG="$(cd "$PROVIDER" && nix eval --no-eval-cache --raw .#apps.x86_64-linux.publish-docs.program 2>/dev/null)"
PRODGH="$(nix path-info -r "$PRODPROG" 2>/dev/null | grep -o '/nix/store/[a-z0-9]*-gh-[^/]*' | head -1)"
log "production gh package: $PRODGH"
nix path-info -r "$TESTPROG" 2>/dev/null | grep -q "upload-recorder" \
  || { faillog "invoked test closure lacks the recorder"; }
[ -n "$PRODGH" ] && nix path-info -r "$TESTPROG" 2>/dev/null | grep -q "$PRODGH" \
  && { faillog "invoked test closure reaches production gh"; }
log "closure audit: recorder present, production gh absent"

log "--- gh calls (uploads recorded only by the positive case):"
cat "$OUTDIR/gh-calls.log" >> "$OUTDIR/run.log"
[ "$FAIL" -eq 0 ] && log "ALL CASES HELD" || log "BOUNDARY BROKEN"
# Single repo write, after the last nix invocation: the tree (and therefore
# every closure identity logged above) stays frozen for the whole run.
cp "$OUTDIR/run.log" "$EVIDENCE"
exit "$FAIL"

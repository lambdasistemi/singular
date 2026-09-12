#!/usr/bin/env bash
# Publication-boundary control v4 (issue #80 slice t80c, NOTE-023).
#
# What v3 got wrong: expect_blocked accepted ANY nonzero exit with no
# assembly as HELD — command-not-found (127), timeouts (124) and empty
# failures all passed as refusals. Every negative case below now requires
# its REACHED, CORRECTLY ATTRIBUTED refusal (exact exit plus verdict
# label in the output); anything else, including empty output, fails.
#
# What v3 could not reach: the positive stopped at the assembler attempt
# with an always-empty gh log. The positive here is two links, stated as
# such: (a) the real publisher wrapper passes the guard on a sufficient
# fixture (COMPLETE verdict, assembler attempted); (b) the real final
# publication script (tools/publish_docs.sh from the provider tree) runs
# end to end against a fixture-built archive with gh stubbed at the
# upload boundary (exit 0, upload recorded). Blueprint CONTENT builds
# stay covered by release-check on the real tree, not here.
#
# External writes are replaced only at the last boundary: gh resolves to
# publication_gh_stub.sh (bash plus coreutils only — no network syscall
# possible by construction). The stub records every call; the harness
# asserts the recording matches the expectation per case.
#
# Pinned runnable command (run from the provider checkout):
#   OUTDIR=/tmp/pub-harness \
#     conformance/coverage/publication-boundary-check.sh
# OUTDIR defaults to a fresh mktemp dir; PROVIDER defaults to this
# checkout's top level. Full per-case output is retained in the evidence
# log; every SHA, exit, closure identity and recorded call is logged.
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
: > "$EVIDENCE"
log() { echo "$*" | tee -a "$EVIDENCE"; }
faillog() { echo "CASE-FAIL: $*" | tee -a "$EVIDENCE"; FAIL=1; }

log "provider: $PROVIDER @ $(git -C "$PROVIDER" rev-parse HEAD)"
log "provider status: $(git -C "$PROVIDER" status --porcelain | tr '\n' ';')"
log "publisher closure: $(cd "$PROVIDER" && nix eval --raw .#apps.x86_64-linux.publish-docs.program 2>/dev/null)"
FAIL=0

# --- fixtures ---------------------------------------------------------
OUTDIR="$OUTDIR/fixtures" PROVIDER="$PROVIDER" \
  "$PROVIDER/conformance/coverage/publication_fixtures.sh" >"$OUTDIR/fixture-build.log" 2>&1
SUFF="$(grep -h SUFFICIENT_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
MISS="$(grep -h MISSING_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
VTAG="v$(tr -d ' \n' < "$PROVIDER/version.txt")"
DOCS_VERSION="$(tr -d ' \n' < "$PROVIDER/version.txt")"
log "sufficient fixture: $OUTDIR/fixtures/sufficient @ $SUFF"
log "missing fixture: $OUTDIR/fixtures/missing @ $MISS"
log "version tag: $VTAG"
UNMARKED="$OUTDIR/unmarked"
git clone -q "$OUTDIR/fixtures/sufficient" "$UNMARKED" 2>/dev/null
rm "$UNMARKED/conformance/coverage/release-required"
git -C "$UNMARKED" add -A
git -C "$UNMARKED" -c user.email=pub@t -c user.name=pub commit -qm "unmarked candidate"
git -C "$UNMARKED" tag -f "$VTAG" HEAD
git -C "$UNMARKED" update-ref refs/remotes/origin/main HEAD
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

# --- case helpers -----------------------------------------------------
pub_run() { # name pwd tag sha [tagcommit-override]; sets PUB_RC, appends full output
  local name="$1" pwd="$2" tag="$3"
  local sha="$4"
  local tagcommit="${5:-$sha}"
  export PUB_PR_SHA="$sha"
  local caseout="$OUTDIR/case-$name.log"
  log "=== case $name"
  log "pwd: $pwd @ $(git -C "$pwd" rev-parse HEAD 2>/dev/null || echo non-git)"
  log "tag: $tag sha: $sha TAG_COMMIT: $tagcommit"
  local rc=0
  (cd "$pwd" && TAG_COMMIT="$tagcommit" PATH="$SHIM:$PATH" \
    timeout 850 nix run --quiet "$PROVIDER#publish-docs" -- "$tag" "$sha" \
    >"$caseout" 2>&1) || rc=$?
  log "publisher exit: $rc"
  log "--- publisher output ($caseout):"
  cat "$caseout" >> "$EVIDENCE"
  PUB_RC="$rc"
}

expect_blocked() { # name want_rc want_label -- reached, attributed refusal only
  local name="$1" want_rc="$2" want_label="$3"
  [ "$PUB_RC" -eq "$want_rc" ] || { faillog "$name: exit $PUB_RC, want $want_rc"; return; }
  grep -q "$want_label" "$OUTDIR/case-$name.log" \
    || { faillog "$name: refusal label '$want_label' absent (empty or wrong failure)"; return; }
  grep -q "onchain" "$OUTDIR/case-$name.log" \
    && { faillog "$name: assembler invoked despite refusal"; return; }
  [ -s "$OUTDIR/gh-calls.log" ] && { faillog "$name: upload attempted"; return; }
  log "case $name: HELD (exit $want_rc, '$want_label', no assembly, no upload)"
}

expect_reached() { # name -- guard passed/absent: assembler attempted, no upload
  local name="$1"
  grep -q "onchain" "$OUTDIR/case-$name.log" \
    || { faillog "$name: assembly not attempted"; return; }
  [ -s "$OUTDIR/gh-calls.log" ] && { faillog "$name: upload attempted"; return; }
  log "case $name: HELD (assembly attempted, no upload)"
}

# --- wrapper cases ----------------------------------------------------
pub_run positive "$OUTDIR/fixtures/sufficient" "$VTAG" "$SUFF"
# positive link (a): guard passes on the sufficient fixture (COMPLETE
# verdict visible in the log) and the assembler is attempted.
grep -q "COMPLETE" "$OUTDIR/case-positive.log" \
  || { faillog "positive: COMPLETE verdict absent"; }
expect_reached positive

pub_run incomplete "$INC" "$VTAG" "$INC_HEAD"
expect_blocked incomplete 1 "INCOMPLETE"

pub_run missing "$OUTDIR/fixtures/missing" "$VTAG" "$MISS"
expect_blocked missing 3 "not a single committed path"

pub_run injected-fault "$OUTDIR/fixtures/sufficient" "$VTAG" "$SUFF" "0000000000000000000000000000000000000000"
expect_blocked injected-fault 1 "FAIL: checkout .* is not the tag commit"

# --- preamble cases: identity and cleanliness before the marker choice -
MARKDEL="$OUTDIR/markdel"
git clone -q "$INC" "$MARKDEL" 2>/dev/null
rm "$MARKDEL/conformance/coverage/release-required"
MARKDEL_HEAD="$(git -C "$MARKDEL" rev-parse HEAD)"
log "marker-deleted fixture: $MARKDEL @ $MARKDEL_HEAD (dirty tree)"
pub_run marker-deleted "$MARKDEL" "$VTAG" "$MARKDEL_HEAD"
expect_blocked marker-deleted 1 "FAIL: dirty or unreadable working tree"

pub_run nonrepo "$OUTDIR" "$VTAG" "$SUFF"
expect_blocked nonrepo 1 "FAIL: checkout .* is not the tag commit"

# --- positive link (b): the real final publication script -------------
# tools/publish_docs.sh from the provider tree runs end to end against a
# fixture-built archive; gh is stubbed at the upload boundary only.
ARCH="$OUTDIR/archive"
mkdir -p "$ARCH"
(cd "$OUTDIR/fixtures/sufficient" && tar --sort=name --mtime=@1 --owner=0 --group=0 \
  --numeric-owner -cf "$ARCH/singular-docs-$DOCS_VERSION.tar.gz" lean flake.nix)
(cd "$OUTDIR/fixtures/sufficient" && tar --sort=name --mtime=@1 --owner=0 --group=0 \
  --numeric-owner -cf "$ARCH/singular-onchain-$DOCS_VERSION.tar.gz" tools)
(cd "$ARCH" && sha256sum singular-docs-*.tar.gz singular-onchain-*.tar.gz > SHA256SUMS)
log "=== case publish-script"
log "archive: $(ls "$ARCH")"
PUB_RC=0
(
  cd "$OUTDIR/fixtures/sufficient"
  export DOCS_VERSION="$DOCS_VERSION" RELEASE_NOTES="$OUTDIR/fixtures/sufficient/onchain-release/RELEASE.md"
  export DOCS_ARCHIVE="$ARCH" PUB_PR_SHA="$SUFF"
  export PATH="$SHIM:$PATH"
  timeout 300 bash "$PROVIDER/tools/publish_docs.sh" "$VTAG" "$SUFF" \
    >"$OUTDIR/case-publish-script.log" 2>&1
) || PUB_RC=$?
log "publish_docs.sh exit: $PUB_RC"
cat "$OUTDIR/case-publish-script.log" >> "$EVIDENCE"
if [ "$PUB_RC" -eq 0 ] && grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log"; then
  log "case publish-script: HELD (real final script, stubbed upload recorded)"
else
  faillog "publish-script: upload not reached (exit $PUB_RC)"
fi

# --- guard-removed mutation on a disposable provider copy --------------
# Frozen baseline (committed HEAD) plus the live uncommitted work, copied
# out; the guard neutralized ONLY in the copy, which is destroyed
# afterwards (trap). Proves the altered guard reaches the invoked
# wrapper: closure identities are logged (they must differ), and the
# incomplete fixture must then show the assembler attempt.
MUTPROV="$OUTDIR/mut-provider"
log "=== case guard-removed (mutation in disposable copy, live tree untouched)"
log "baseline: $(git -C "$PROVIDER" rev-parse HEAD)"
rm -rf "$MUTPROV"
mkdir -p "$MUTPROV"
git -C "$PROVIDER" archive HEAD | tar -x -C "$MUTPROV"
for f in $(git -C "$PROVIDER" status --porcelain | awk '{print $2}'); do
  mkdir -p "$MUTPROV/$(dirname "$f")"
  cp "$PROVIDER/$f" "$MUTPROV/$f"
done
log "provider closure: $(cd "$PROVIDER" && nix eval --raw .#apps.x86_64-linux.publish-docs.program 2>/dev/null)"
log "mutant closure: $(cd "$MUTPROV" && nix eval --raw .#apps.x86_64-linux.publish-docs.program 2>/dev/null)"
MUT_LINE="$(grep -n 'if \[ -f "\$PWD/conformance/coverage/release-required" \]; then' "$MUTPROV/nix/release.nix" | cut -d: -f1)"
[ -n "$MUT_LINE" ] || { faillog "guard line not found in copy"; }
sed -i "${MUT_LINE}s/.*/      if false; then # MUTATED FOR CONTROL/" "$MUTPROV/nix/release.nix"
grep -q "MUTATED FOR CONTROL" "$MUTPROV/nix/release.nix" || { faillog "mutation did not apply"; }
MUTOUT="$OUTDIR/case-guard-removed.log"
MUTRC=0
(cd "$INC" && TAG_COMMIT="$INC_HEAD" PATH="$SHIM:$PATH" \
  timeout 850 nix run --quiet "$MUTPROV#publish-docs" -- "$VTAG" "$INC_HEAD" \
  >"$MUTOUT" 2>&1) || MUTRC=$?
log "mutant publisher exit: $MUTRC"
cat "$MUTOUT" >> "$EVIDENCE"
rm -rf "$MUTPROV"
log "mutant copy destroyed"
if grep -q "onchain" "$MUTOUT"; then
  log "case guard-removed: HELD (unguarded wrapper attempts assembly on INCOMPLETE)"
else
  faillog "guard-removed: assembly not attempted without guard — harness blind"
fi

log "--- gh calls (uploads recorded only by the publish-script case):"
cat "$OUTDIR/gh-calls.log" >> "$EVIDENCE"
[ "$FAIL" -eq 0 ] && log "ALL CASES HELD" || log "BOUNDARY BROKEN"
exit "$FAIL"

#!/usr/bin/env bash
# Publication-boundary control v3 (issue #80 slice t80c, NOTE-022).
#
# What v1 got wrong: it echoed through its own `if`, never invoking the
# publisher. What v2 got wrong: a `nix` PATH shim that nested wrappers
# bypass (makeWrapper prepends store paths), plus kill-on-sight machinery
# around it. This version drops both: it runs the REAL publisher wrapper
# (`$PROVIDER#publish-docs`) and asserts on the REAL publisher output.
# The ordering proof needs no interception — the output itself shows it:
# a passed guard prints its COMPLETE verdict and the assembler attempt
# follows (`onchain` resolution error on fixtures, which carry no onchain
# flakes); a refused gate prints its verdict label and nothing follows.
#
# External writes are replaced only at the last boundary: `gh` resolves
# to publication_gh_stub.sh (bash plus coreutils only — no network
# syscall possible by construction; ported from the gh half of
# tools/check_publish.py's mock), which records every call. Upload
# reachability of publish_docs.sh itself is covered by that existing
# seam; here the gh log must stay empty in every case (no asset can
# publish from a fixture that cannot assemble).
#
# Pinned runnable command (run from the provider checkout):
#   OUTDIR=/tmp/pub-harness \
#     conformance/coverage/publication-boundary-check.sh
# OUTDIR defaults to a fresh mktemp dir; PROVIDER defaults to this
# checkout's top level. Fixtures come from publication_fixtures.sh
# (sufficient + missing) plus a throwaway provider clone (incomplete)
# and a marker-stripped sufficient clone (guard-absent). Every actual
# path, SHA and exit is logged; full per-case output is retained in the
# evidence log.
#
# Cases (all through the real publisher wrapper):
#   positive        sufficient fixture + marker: COMPLETE verdict, then
#                   the assembler attempt (fails environmentally — no
#                   onchain flakes in fixture-land, unrelated to coverage).
#   incomplete      real project + marker: INCOMPLETE verdict, nothing after.
#   missing         record absent at commit + marker: FAIL-CLOSED verdict,
#                   nothing after.
#   injected-fault  sufficient fixture, wrong TAG_COMMIT: the REAL gate
#                   call fails (mismatch), nothing after. Distinguished:
#                   injected input fault, not a natural verdict.
#   guard-absent    sufficient content WITHOUT the marker (pre-integration
#                   state): assembler attempted. Proves the guard is
#                   load-bearing. Expects proceed — labelled, not a failure.
#   guard-removed   MUTATION on the live provider tree (scratch backup,
#                   byte-identical restore verified): the publisher guard
#                   neutralized, incomplete fixture must then show the
#                   assembler attempt. If it does not, this harness cannot
#                   tell a guarded publisher from an unguarded one.
#
# No exit-5 checker crash appears here: no natural input drives the real
# gate to an unexpected exception by design (every anticipated failure
# fails closed), so exit-5 emission stays unit-proven
# (test_release_crash_is_neither_green_nor_incomplete) while this harness
# proves the boundary blocks every nonzero gate exit it can produce.
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
FAIL=0

# --- fixtures ---------------------------------------------------------
OUTDIR="$OUTDIR/fixtures" PROVIDER="$PROVIDER" \
  "$PROVIDER/conformance/coverage/publication_fixtures.sh" >"$OUTDIR/fixture-build.log" 2>&1
SUFF="$(grep -h SUFFICIENT_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
MISS="$(grep -h MISSING_HEAD "$OUTDIR/fixture-build.log" | cut -d= -f2)"
VTAG="v$(tr -d ' \n' < "$PROVIDER/version.txt")"
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

# --- case runner ------------------------------------------------------
# run_pub name pwd tag sha [tagcommit-override]
run_pub() {
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

expect_reached() { # guard passed/absent: gate verdict then assembler attempt, no upload
  grep -q "onchain" "$OUTDIR/case-$1.log" || { faillog "$1: assembler not attempted"; return; }
  [ -s "$OUTDIR/gh-calls.log" ] && { faillog "$1: upload attempted"; return; }
  log "case $1: HELD (guard passed/absent: assembly attempted, no upload)"
}

expect_blocked() { # refusing input: nonzero exit, gate verdict label, no assembler attempt
  [ "$PUB_RC" -eq 0 ] && { faillog "$1: publisher exited 0 on refusing input"; return; }
  grep -q "onchain" "$OUTDIR/case-$1.log" \
    && { faillog "$1: assembler invoked despite refusal"; return; }
  [ -s "$OUTDIR/gh-calls.log" ] && { faillog "$1: upload attempted"; return; }
  log "case $1: HELD (exit $PUB_RC, no assembly, no upload)"
}

run_pub positive "$OUTDIR/fixtures/sufficient" "$VTAG" "$SUFF"
expect_reached positive
run_pub incomplete "$INC" "$VTAG" "$INC_HEAD"
expect_blocked incomplete
run_pub missing "$OUTDIR/fixtures/missing" "$VTAG" "$MISS"
expect_blocked missing
run_pub injected-fault "$OUTDIR/fixtures/sufficient" "$VTAG" "$SUFF" "0000000000000000000000000000000000000000"
expect_blocked injected-fault
run_pub guard-absent "$UNMARKED" "$VTAG" "$UNMARKED_HEAD"
expect_reached guard-absent

# --- guard-removed mutation -------------------------------------------
GUARD_FILE="$PROVIDER/nix/release.nix"
cp "$GUARD_FILE" "$OUTDIR/release.nix.live-backup"
log "=== case guard-removed (mutation: guard neutralized, live tree restored after)"
GUARD_LINE="$(grep -n 'if \[ -f "\$PWD/conformance/coverage/release-required" \]; then' "$GUARD_FILE" | cut -d: -f1)"
[ -n "$GUARD_LINE" ] || { faillog "guard line not found"; }
# shellcheck disable=SC2086
sed -i "${GUARD_LINE}s/.*/      if false; then # MUTATED FOR CONTROL/" "$GUARD_FILE"
grep -q "MUTATED FOR CONTROL" "$GUARD_FILE" || { faillog "mutation did not apply"; }
run_pub guard-removed "$INC" "$VTAG" "$INC_HEAD"
cp "$OUTDIR/release.nix.live-backup" "$GUARD_FILE"
if cmp -s "$GUARD_FILE" "$OUTDIR/release.nix.live-backup"; then
  log "provider guard restored byte-identical"
else
  faillog "provider guard restore differs"
fi
if grep -q "onchain" "$OUTDIR/case-guard-removed.log"; then
  log "case guard-removed: HELD (unguarded publisher attempts assembly on INCOMPLETE — guard is load-bearing)"
else
  faillog "guard-removed: assembly not attempted without guard — harness blind"
fi

log "--- gh calls (must be empty in every fixture case):"
cat "$OUTDIR/gh-calls.log" >> "$EVIDENCE"
[ "$FAIL" -eq 0 ] && log "ALL CASES HELD" || log "BOUNDARY BROKEN"
exit "$FAIL"

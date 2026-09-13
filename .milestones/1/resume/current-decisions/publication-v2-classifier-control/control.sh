#!/usr/bin/env bash
OUTDIR="$1"
FAIL=0
: > "$OUTDIR/gh-calls.log"
log(){ echo "$*"; }
faillog(){ echo "CASE-FAIL: $*"; FAIL=1; }
expect_blocked() { # refusing input: nonzero exit, gate verdict label, no assembler attempt
  [ "$PUB_RC" -eq 0 ] && { faillog "$1: publisher exited 0 on refusing input"; return; }
  grep -q "onchain" "$OUTDIR/case-$1.log" \
    && { faillog "$1: assembler invoked despite refusal"; return; }
  [ -s "$OUTDIR/gh-calls.log" ] && { faillog "$1: upload attempted"; return; }
  log "case $1: HELD (exit $PUB_RC, no assembly, no upload)"
}

for PUB_RC in 127 124 1; do FAIL=0; : > "$OUTDIR/case-probe.log"; expect_blocked probe; echo "CASE_EXIT=$FAIL"; done

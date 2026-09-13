set -u
FAIL=0
log(){ echo "$*"; }
faillog(){ echo "CASE-FAIL: $*"; FAIL=1; }
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


exit "$FAIL"

set -u
FAIL=0
log(){ echo "$*"; }
faillog(){ echo "CASE-FAIL: $*"; FAIL=1; }
if grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log"; then
  faillog "no-final: upload recorded without the final invocation — composition untested"
else
  log "case no-final: HELD (no upload without the final invocation — composition proven)"
fi


exit "$FAIL"

set -u
FAIL=0
log(){ echo "$*"; }
faillog(){ echo "CASE-FAIL: $*"; FAIL=1; }
if [ "$MUTRC" -eq 1 ] && grep -q "release assembly: PASS" "$MUTOUT"; then
  if grep -q "GHCALL: release upload" "$OUTDIR/gh-calls.log"; then
    faillog "guard-removed: upload recorded on INCOMPLETE without guard"
  else
    log "case guard-removed: HELD (assembly PASSED on INCOMPLETE without guard, no upload — guard is load-bearing)"
  fi
else
  faillog "guard-removed: want exit 1 with assembly PASS without guard (rc=$MUTRC) — harness blind"
fi


exit "$FAIL"

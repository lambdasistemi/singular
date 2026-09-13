set -u
FAIL=0
log(){ echo "$*"; }
faillog(){ echo "CASE-FAIL: $*"; FAIL=1; }
if grep -q "onchain" "$MUTOUT"; then
  log "case guard-removed: HELD (unguarded wrapper attempts assembly on INCOMPLETE)"
else
  faillog "guard-removed: assembly not attempted without guard — harness blind"
fi


exit "$FAIL"

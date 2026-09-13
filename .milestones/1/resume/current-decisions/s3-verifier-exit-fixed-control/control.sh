#!/usr/bin/env bash
set -uo pipefail
EV="$1"
W=/tmp/singular-s2-v2-oOt8k8/source
WANT=control-candidate
naming_bp=unused
mpfs_bp=unused
verifier="$EV/failed-verifier"
fails=0
ok(){ printf "S3 %s PASS %s\n" "$1" "${2:-}"; }
bad(){ printf "S3 %s FAIL %s\n" "$1" "${2:-}"; fails=$((fails+1)); }
"$verifier" --evidence "$EV/run" --blueprint "$naming_bp" --mpfs-blueprint "$mpfs_bp" \
            --candidate "$WANT" --out "$EV/verdicts.json" > "$EV/verifier.stdout" 2>"$EV/verifier.stderr"
vrc=$?
# A crashed verifier cannot be overridden by a file. The evidence directory is
# unique to this invocation, so verdicts.json cannot pre-exist; and a nonzero
# verifier exit fails outright regardless of what it managed to write.
if [ "$vrc" -ne 0 ]; then
  bad verifier-exit "verifier exited $vrc — a nonzero verifier cannot establish anything (see $EV/verifier.stderr)"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
if [ ! -s "$EV/verdicts.json" ]; then
  bad verifier-produced-verdicts "verifier exited 0 but wrote no verdicts at $EV/verdicts.json"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
if ! jq -e 'type=="object" and length>0' "$EV/verdicts.json" >/dev/null 2>&1; then
  bad verdicts-wellformed "verdicts.json is not a non-empty object"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
dupes=$(jq -r 'keys_unsorted | group_by(.) | map(select(length>1)) | length' "$EV/verdicts.json" 2>/dev/null)
[ "${dupes:-0}" -eq 0 ] || bad verdicts-unique "verdicts.json contains duplicate obligation identities"
ok verifier-exit "exit 0, verdicts created by this invocation"

verdict() { jq -r --arg k "$1" '.[$k].status // "MISSING"' "$EV/verdicts.json" 2>/dev/null; }
detail() { jq -r --arg k "$1" '.[$k].detail // ""'        "$EV/verdicts.json" 2>/dev/null; }
require() {
  local key="$1" st; st=$(verdict "$key")
  case "$st" in
    ESTABLISHED) ok "$key" "$(detail "$key")" ;;
    REFUTED)     bad "$key" "REFUTED: $(detail "$key")" ;;
    MISSING)     bad "$key" "no verdict — an unreachable assertion blocks acceptance" ;;
    *)           bad "$key" "$st: $(detail "$key") — COULD-NOT-EVALUATE blocks acceptance" ;;
  esac
}

for k in connected.state-input connected.request-input connected.continuation \
         connected.root-before connected.root-after connected.txid \
         representative.applied representative.asset representative.approval representative.key; do
  require "$k"
done
for op in insert end migration sweep burning; do require "refusal.$op"; done
for c in free-key supported-action;               do require "control.$c"; done

# ------------------------------------------------------- 5. ownerless, behaviourally
# A schema grep and a green identity build cannot establish the absence of
# owner-authorized BEHAVIOUR. The refusal verdicts above are what establish it.
# The schema check stays only as a cheap corroboration, never as the evidence.
if grep -qE '^\s*(owner|stake_script)\s*:' "$W/onchain/validators/types.ak" 2>/dev/null; then
  bad no-authority-field "State still declares an owner/stake authority field"
else
  ok no-authority-field "corroboration only — refusal.{end,migration,sweep,burning} above are the evidence"
fi

# Clean up only the devnet session this invocation allocated. Evidence is never
# removed to satisfy cleanup.
[ -n "${RUN_TMP:-}" ] && [ -d "$RUN_TMP" ] && rm -rf "$RUN_TMP"

printf '\n'
printf 'S3 evidence retained at %s\n' "$EV"
if [ "$fails" -eq 0 ]; then printf 'S3 SUPPLEMENT GREEN (candidate %s, executed)\n' "$WANT"; exit 0; fi
printf 'S3 SUPPLEMENT RED — %d obligation(s) failed\n' "$fails"; exit 1

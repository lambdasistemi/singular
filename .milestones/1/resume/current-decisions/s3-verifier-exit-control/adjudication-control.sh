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
if [ ! -s "$EV/verdicts.json" ]; then
  bad verifier-produced-verdicts "no verdicts at $EV/verdicts.json (verifier exit $vrc)"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
ok verifier-produced-verdicts "exit $vrc"

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

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'S3 SUPPLEMENT GREEN (candidate %s, executed)\n' "$WANT"; exit 0; fi
printf 'S3 SUPPLEMENT RED — %d obligation(s) failed\n' "$fails"; exit 1

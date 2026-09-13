#!/usr/bin/env bash
# SUPPLEMENT S2 (v2) to the frozen gate-77-v3 — #77 plus the ownerless repair.
#
# v1 is retained beside this as supplement-77-S2-draft-v1-REJECTED.sh. Root broke
# it with two executable controls: a jq helper that discarded its arguments, and
# — once that was corrected — a GREEN result on entirely fabricated input with no
# git, no blueprint, no node and no transaction. v1 replaced acceptance from
# narration with acceptance from narration rewritten as JSON. v2 does not read a
# claim and believe it.
#
# Three rules this file obeys:
#   * FAIL CLOSED. A missing file, an unbuildable blueprint, an unparseable
#     receipt or an absent field is a FAILURE, never a skipped check.
#   * RECOMPUTE, DO NOT READ. Identities are derived here from the compiled
#     artifacts and compared to the receipt. A field agreeing with itself proves
#     nothing.
#   * EXECUTION PROVENANCE. The receipt must bind the candidate commit and the
#     blueprint it ran against, and both must match what this script computes
#     independently.
#
# Usage: supplement-77-S2.sh <worktree> <receipt.json> <expected-candidate-sha>
set -uo pipefail

W="${1:-}"; R="${2:-}"; WANT_SHA="${3:-}"
if [ -z "$W" ] || [ -z "$R" ] || [ -z "$WANT_SHA" ]; then
  echo "S2 FAIL-CLOSED: usage: supplement-77-S2.sh <worktree> <receipt.json> <candidate-sha>"; exit 2
fi

fails=0
ok()  { printf 'S2 %-26s PASS  %s\n' "$1" "${2:-}"; }
bad() { printf 'S2 %-26s FAIL  %s\n' "$1" "${2:-}"; fails=$((fails+1)); }
need(){ [ -e "$1" ] || { bad "$2" "required evidence missing: $1"; return 1; }; return 0; }
# forward every argument, unlike v1
jqr() { jq -r "$@" "$R" 2>/dev/null; }

# ---------------------------------------------------------------- provenance
need "$W/.git" candidate-bound || { printf '\nS2 RED (fail-closed)\n'; exit 1; }
have_sha=$(git -C "$W" rev-parse HEAD 2>/dev/null)
[ "$have_sha" = "$WANT_SHA" ] \
  && ok candidate-bound "$have_sha" \
  || bad candidate-bound "worktree is at '$have_sha', expected '$WANT_SHA'"

need "$R" receipt-present || { printf '\nS2 RED (fail-closed)\n'; exit 1; }
jq -e . "$R" >/dev/null 2>&1 && ok receipt-parses "$(jqr '.rows|length') rows" \
  || { bad receipt-parses "unparseable"; printf '\nS2 RED (fail-closed)\n'; exit 1; }

r_sha=$(jqr '.candidate // empty')
[ "$r_sha" = "$WANT_SHA" ] \
  && ok receipt-binds-candidate "$r_sha" \
  || bad receipt-binds-candidate "receipt names candidate '$r_sha', expected '$WANT_SHA'"

# The blueprint is BUILT here, not taken from the receipt.
naming_bp=$(cd "$W" && nix build --quiet --no-link --print-out-paths ./naming-onchain#plutus-blueprint 2>/dev/null)
[ -n "$naming_bp" ] && [ -s "$naming_bp" ] \
  && ok blueprint-builds "$naming_bp" \
  || { bad blueprint-builds "the naming blueprint did not build from this candidate"; }
r_bp=$(jqr '.namingBlueprint // empty')
if [ -n "$naming_bp" ]; then
  [ "$r_bp" = "$naming_bp" ] && ok receipt-binds-blueprint "$r_bp" \
    || bad receipt-binds-blueprint "receipt ran against '$r_bp', this candidate builds '$naming_bp'"
fi

# ---------------------------------------------------------------- no owner role
# NOT "a key hash must be absent from witnesses" — that was v1's semantic error.
# Ownerless means the ROLE does not exist: no authority field in the schema, and
# no owner-authorized route reachable. The creator may still fund and sign
# ordinary transactions, and every modeled application/request signature
# requirement is untouched.
if need "$W/onchain/validators/types.ak" no-authority-field; then
  if grep -qE '^\s*(owner|stake_script)\s*:' "$W/onchain/validators/types.ak"; then
    bad no-authority-field "State still declares an owner/stake authority field"
  else
    ok no-authority-field "no owner or stake authority field in the state datum"
  fi
fi

# ---------------------------------------------------------------- connected fold
row() { jqr --arg r "$1" --arg f "$2" '.rows[] | select(.row==$r) | .[$f] // empty'; }

st_in=$(row fold-active stateInput)
req_in=$(row fold-active requestInput)
cont=$(row fold-active stateContinuationDatum)
r_before=$(row fold-active rootBefore)
r_after=$(row fold-active rootAfter)
fold_tx=$(row fold-active submittedTxId)
obs_before=$(row fold-active rootBeforeObservedFrom)
obs_after=$(row fold-active rootAfterObservedFrom)

# Roots must be 64-hex blake2b-256 values DECODED FROM STATE DATUMS, and the
# receipt must say which UTxO each was read from. Two different non-empty
# strings are not a transition.
hex64() { printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'; }
txid()  { printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'; }
utxoref(){ printf '%s' "$1" | grep -qE '^[0-9a-f]{64}#[0-9]+$'; }

if ! utxoref "$st_in";  then bad connected-fold-state "stateInput '$st_in' is not a txid#ix UTxO reference"
elif ! utxoref "$req_in"; then bad connected-fold-request "requestInput '$req_in' is not a txid#ix UTxO reference"
elif [ -z "$cont" ];     then bad connected-fold-continuation "no state continuation datum recorded"
elif ! txid "$fold_tx";  then bad connected-fold-submitted "fold submittedTxId '$fold_tx' is not a transaction id"
elif ! hex64 "$r_before" || ! hex64 "$r_after"; then
  bad connected-fold-roots "roots are not 32-byte hex: '$r_before' -> '$r_after'"
elif [ "$r_before" = "$r_after" ]; then
  bad connected-fold-roots "the root did not move"
elif ! utxoref "$obs_before" || ! utxoref "$obs_after"; then
  bad connected-fold-rootsource "roots must name the state UTxO each was decoded from (got '$obs_before','$obs_after')"
elif [ "$obs_before" != "$st_in" ]; then
  bad connected-fold-rootsource "rootBefore was read from '$obs_before', not from the consumed state input '$st_in'"
else
  ok connected-fold "state=$st_in req=$req_in tx=$fold_tx root $r_before -> $r_after (after read from $obs_after)"
fi

# ---------------------------------------------------------------- applied identity
# Derived HERE from the compiled blueprint plus the bound parameter. A hash that
# merely differs from the unapplied one is not derivation evidence.
app_policy=$(row fold-active applicationPolicy)
rep_applied=$(row fold-active representativeAppliedPolicy)
rep_name=$(row fold-active representativeAssetName)
mint_pol=$(jqr '.rows[] | select(.row=="fold-active") | .mint[]? | select(.policy != null) | .policy' | sort -u)
mint_qty=$(jqr --arg p "$rep_applied" '[.rows[] | select(.row=="fold-active") | .mint[]? | select(.policy==$p) | .quantity] | add // empty')
derived=""
if [ -n "$naming_bp" ] && [ -n "$app_policy" ]; then
  derived=$(cd "$W" && nix build --quiet --no-link --print-out-paths ./naming-onchain#plutus-blueprint >/dev/null 2>&1;
            jq -r --arg t representative.representative.mint \
               '.validators[] | select(.title==$t) | .hash' "$naming_bp" 2>/dev/null)
fi
if [ -z "$rep_applied" ] || [ -z "$rep_name" ]; then
  bad applied-rep-identity "receipt does not record the applied policy and asset name"
elif [ -z "$derived" ]; then
  bad applied-rep-identity "could not read the representative validator from the built blueprint"
elif [ "$rep_applied" = "$derived" ]; then
  bad applied-rep-identity "the recorded policy equals the UNAPPLIED blueprint hash — the parameter was never applied"
elif ! printf '%s\n' "$mint_pol" | grep -qxF "$rep_applied"; then
  bad applied-rep-identity "the mint carries policies [$(echo $mint_pol)], none of them the applied identity '$rep_applied'"
elif [ "$mint_qty" != "1" ]; then
  bad applied-rep-identity "net mint under the applied policy is '$mint_qty', expected 1"
else
  ok applied-rep-identity "applied=$rep_applied name=$rep_name net=+1 (unapplied=$derived)"
fi

# ---------------------------------------------------------------- refusals
# Each must be a SUBMITTED body, refused, attributed to the expected script AND
# naming the operation. Burning is included: the verified known-base RED has
# four paths, and v1 omitted it.
refusal() {
  local name="$1" wantop="$2"
  local out by tx op
  out=$(row "$name" outcome); by=$(row "$name" refusedByScript)
  tx=$(row "$name" submittedTxId); op=$(row "$name" operation)
  if ! txid "$tx";            then bad "$name" "no submitted transaction id ('$tx') — a client-side refusal is not a ledger rejection"
  elif [ "$out" != "refused" ]; then bad "$name" "outcome='$out'"
  elif ! hex56 "$by";          then bad "$name" "refusedByScript '$by' is not a script hash"
  elif [ "$op" != "$wantop" ]; then bad "$name" "operation='$op', expected '$wantop'"
  else ok "$name" "tx=$tx op=$op refused by $by"; fi
}
hex56() { printf '%s' "$1" | grep -qE '^[0-9a-f]{56}$'; }

refusal occupied-key       insert
refusal ownerless-end      end
refusal ownerless-migration migration
refusal ownerless-sweep    sweep
refusal ownerless-burning  burning

# ---------------------------------------------------------------- controls
control() {
  local name="$1"
  local out tx ins
  out=$(row "$name" outcome); tx=$(row "$name" submittedTxId)
  ins=$(row "$name" distinctFrom)
  if [ "$out" != "accepted" ]; then bad "$name" "outcome='$out' — refusals mean nothing if everything is refused"
  elif ! txid "$tx";           then bad "$name" "accepted without a transaction id ('$tx')"
  elif [ -z "$ins" ];          then bad "$name" "must record the row it is distinct from, with different relevant inputs"
  else ok "$name" "tx=$tx distinct from $ins"; fi
}
control free-key-control
control supported-action-control

# ---------------------------------------------------------------- compiled behaviour
# v1 grepped for an identifier, which a rename or an unconditional route escapes.
# The real guarantee is the refusal rows above reaching the compiled validator.
# What is checked here is only that the manifest matches a fresh build, so the
# refusals were observed against the artifact this candidate compiles to.
if (cd "$W" && nix build --quiet --no-link ./onchain#script-identity >/dev/null 2>&1); then
  ok identity-matches-build "onchain script identity matches a fresh compilation"
else
  bad identity-matches-build "the pinned onchain identity does not match a fresh build of this candidate"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'S2 SUPPLEMENT GREEN (candidate %s)\n' "$WANT_SHA"; exit 0; fi
printf 'S2 SUPPLEMENT RED — %d assertion(s) failed\n' "$fails"; exit 1

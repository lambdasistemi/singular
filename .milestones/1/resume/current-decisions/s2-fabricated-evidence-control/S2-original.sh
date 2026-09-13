#!/usr/bin/env bash
# SUPPLEMENT S2 to the frozen gate-77-v3 — issue #77 plus the ownerless repair.
#
# gate-77-v3 stays untouched and remains the floor. It is not sufficient
# acceptance: five of its legs grep words in a log or in source text, and its
# representative leg reads the UNAPPLIED manifest hash where the chain carries
# the APPLIED policy id. This supplement asserts LEDGER AND SOURCE FACTS from
# the run's machine-readable receipt and from the built artifacts, never from
# narration.
#
# Recorded separately with its own command and hash, per NOTE-017/NOTE-029.
# Never merged into the frozen gate.
#
#   S2-1  receipt exists and is well formed
#   S2-2  CONNECTED FOLD        the state UTxO is an input, its continuation carries the new StateDatum,
#                               the request input is consumed, roots move as the chain reports
#   S2-3  NO REGISTRY OWNER     no owner key hash in reqSignerHashes or vkey witnesses of the fold;
#                               and no `owner` field survives anywhere in the state datum type
#   S2-4  APPLIED REP IDENTITY  the mint carries the APPLIED representative policy id, expected name, +1
#   S2-5  occupied-key EXECUTED the duplicate fold was SUBMITTED and refused by the state validator
#   S2-6  free-key control      a distinct name registers successfully in the same run
#   S2-7  OWNERLESS REFUSALS    End / migration / Sweep refused, attributed, with a supported-action control
#   S2-8  NO DESTRUCTIVE BACK DOOR  no executable owner-authorized path remains in the built blueprint
#
# Usage: supplement-77-S2.sh <worktree> <receipt.json>
set -uo pipefail
W="${1:?usage: supplement-77-S2.sh <worktree> <receipt.json>}"
R="${2:?usage: supplement-77-S2.sh <worktree> <receipt.json>}"
cd "$W"

fails=0
ok()   { printf 'S2 %-26s PASS  %s\n' "$1" "${2:-}"; }
bad()  { printf 'S2 %-26s FAIL  %s\n' "$1" "${2:-}"; fails=$((fails+1)); }
jqr()  { jq -r "$1" "$R" 2>/dev/null; }

# ---------------------------------------------------------------- S2-1
if [ ! -s "$R" ] || ! jq -e . "$R" >/dev/null 2>&1; then
  bad receipt-wellformed "no parseable receipt at $R"
  printf '\nS2 RED — %d\n' "$((fails+1))"; exit 1
fi
ok receipt-wellformed "$(jq -r '.rows | length' "$R") rows"

# ---------------------------------------------------------------- S2-2
# The fold row must name a state input, a continuation datum, a consumed
# request, and roots that differ. These are transaction facts, not sentences.
st_in=$(jqr '.rows[] | select(.row=="fold-active") | .stateInput // empty')
st_cont=$(jqr '.rows[] | select(.row=="fold-active") | .stateContinuationDatum // empty')
req_in=$(jqr '.rows[] | select(.row=="fold-active") | .requestInput // empty')
r_before=$(jqr '.rows[] | select(.row=="fold-active") | .rootBefore // empty')
r_after=$(jqr '.rows[] | select(.row=="fold-active") | .rootAfter // empty')
if [ -n "$st_in" ] && [ -n "$st_cont" ] && [ -n "$req_in" ] \
   && [ -n "$r_before" ] && [ -n "$r_after" ] && [ "$r_before" != "$r_after" ]; then
  ok connected-fold "state=$st_in request=$req_in root $r_before -> $r_after"
else
  bad connected-fold "missing state input / continuation datum / request input, or root did not move (state='$st_in' cont='$st_cont' req='$req_in' before='$r_before' after='$r_after')"
fi

# ---------------------------------------------------------------- S2-3
owner_hash=$(jqr '.registryOwnerKeyHash // empty')
signers=$(jqr '[.rows[] | select(.row=="fold-active") | .requiredSigners[]?] | join(" ")')
wits=$(jqr '[.rows[] | select(.row=="fold-active") | .vkeyWitnesses[]?] | join(" ")')
if [ -n "$owner_hash" ] && { printf '%s %s' "$signers" "$wits" | grep -qF "$owner_hash"; }; then
  bad no-registry-owner "an owner key hash appears in the fold's authorization material"
else
  ok no-registry-owner "signers=[$signers] witnesses=[$wits]"
fi
# and the field itself must be gone from the datum type
if grep -qE '^\s*owner\s*:' onchain/validators/types.ak; then
  bad owner-field-removed "State still carries an owner field in types.ak"
else
  ok owner-field-removed "no owner field in the state datum type"
fi

# ---------------------------------------------------------------- S2-4
# The APPLIED policy id, derived from the blueprint plus its parameter — not the
# unapplied manifest hash the frozen gate grepped for.
applied=$(jqr '.rows[] | select(.row=="fold-active") | .representativeAppliedPolicy // empty')
unapplied=$(jq -r '.validators[] | select(.title=="representative.representative.mint") | .hash' \
             naming-onchain/script-identity.json 2>/dev/null)
mint_pol=$(jqr '.rows[] | select(.row=="fold-active") | .mint[]? | .policy' | head -1)
mint_qty=$(jqr '.rows[] | select(.row=="fold-active") | .mint[]? | .quantity' | head -1)
if [ -z "$applied" ] || [ "$applied" != "$mint_pol" ]; then
  bad applied-rep-identity "mint policy '$mint_pol' is not the derived applied identity '$applied'"
elif [ "$applied" = "$unapplied" ]; then
  bad applied-rep-identity "applied equals the UNAPPLIED manifest hash — the parameter was not applied"
elif [ "$mint_qty" != "1" ]; then
  bad applied-rep-identity "representative minted at quantity '$mint_qty', expected 1"
else
  ok applied-rep-identity "applied=$applied (unapplied=$unapplied) qty=1"
fi

# ---------------------------------------------------------------- S2-5
dup_tx=$(jqr '.rows[] | select(.row=="occupied-key") | .submittedTxId // empty')
dup_out=$(jqr '.rows[] | select(.row=="occupied-key") | .outcome // empty')
dup_by=$(jqr '.rows[] | select(.row=="occupied-key") | .refusedByScript // empty')
if [ -z "$dup_tx" ]; then
  bad occupied-key-executed "no submitted txid — a client-side refusal is not a ledger rejection"
elif [ "$dup_out" != "refused" ] || [ -z "$dup_by" ]; then
  bad occupied-key-executed "outcome='$dup_out' refusedBy='$dup_by'"
else
  ok occupied-key-executed "tx=$dup_tx refused by $dup_by"
fi

# ---------------------------------------------------------------- S2-6
free_out=$(jqr '.rows[] | select(.row=="free-key-control") | .outcome // empty')
[ "$free_out" = "accepted" ] && ok free-key-control "a distinct name registered" \
  || bad free-key-control "outcome='$free_out' — without this, occupied-key proves only that nothing registers"

# ---------------------------------------------------------------- S2-7
for op in end migration sweep; do
  o=$(jqr --arg o "$op" '.rows[] | select(.row==("ownerless-"+$o)) | .outcome // empty')
  by=$(jqr --arg o "$op" '.rows[] | select(.row==("ownerless-"+$o)) | .refusedByScript // empty')
  tx=$(jqr --arg o "$op" '.rows[] | select(.row==("ownerless-"+$o)) | .submittedTxId // empty')
  if [ "$o" = "refused" ] && [ -n "$by" ] && [ -n "$tx" ]; then
    ok "ownerless-$op" "tx=$tx refused by $by"
  else
    bad "ownerless-$op" "outcome='$o' refusedBy='$by' tx='$tx' — must be a SUBMITTED, attributed refusal"
  fi
done
sup=$(jqr '.rows[] | select(.row=="supported-action-control") | .outcome // empty')
[ "$sup" = "accepted" ] && ok supported-action-control "the registry still works" \
  || bad supported-action-control "outcome='$sup' — refusals mean nothing if everything is refused"

# ---------------------------------------------------------------- S2-8
# No executable owner-authorized destructive path may survive in the source that
# produced the pinned blueprint.
if grep -rnE "validateOwnership" onchain/validators/*.ak | grep -v "^onchain/validators/shared.ak" | grep -qv tests; then
  bad no-back-door "validateOwnership is still reachable outside shared.ak:"
  grep -rnE "validateOwnership" onchain/validators/*.ak | grep -v shared.ak | grep -v tests | head -5
else
  ok no-back-door "no owner-authorized path outside shared.ak"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'S2 SUPPLEMENT GREEN\n'; exit 0; fi
printf 'S2 SUPPLEMENT RED — %d assertion(s) failed\n' "$fails"; exit 1

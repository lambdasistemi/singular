#!/usr/bin/env bash
# The registration journey of the proved design (#742): a registry of open
# datum is created, keys are booked, folded, updated, terminated, reclaimed and cleaned up through
# the packaged `singular` and `open-datum` programs on a generated development
# network, and the chain is read afterwards by a program that takes nothing
# from any command.
#
# usage: no_pin_registration_journey.sh SINGULAR OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW WORKDIR
#
# SINGULAR, OPEN_DATUM and DEVNET are executables, BLUEPRINT is the release's
# compiled validators (plutus.json), CHAIN_VIEW is tools/no_pin_chain_view.py
# and WORKDIR is the directory the receipts are kept in. The node and its
# record of the chain live under ${TMPDIR:-/tmp}, which must be short enough
# for a unix socket path, and are removed on exit.
#
# Four wallets: Carol creates registries, Alice books, Bob folds, Dave cleans
# up. Each runs every command as a separate process in a working directory and
# a home of their own, with nothing in the environment but that home. The
# registry parameters make the journey wait minutes: a registration is folded
# within a minute of its booking, can be taken back for the next three, and can
# be cleaned up by anyone after that.
#
#   creation      the first registry of the application publishes the state and
#                 request scripts and creates the registry; a later registry
#                 sends the creation alone and references the live copies; the
#                 packaged singular creates a registry from the same copy
#   fold          a registration is folded by Bob alone, from the network, the
#                 release, the registry's name and his own key: nothing of the
#                 booker's is in the folder's directories, the fold's signer is
#                 not the booker, and the holding at the committed address holds
#                 the key's token, the payload and exactly the deposit
#   reclaim       a registration is taken back inside its window by the refund
#                 address, which gets everything back
#   cleanup       a registration is cleaned up after its window by a wallet that
#                 is not the refund address; the deposit returns to the refund
#                 address
#   termination   the controller updates the holding and books termination,
#                 donating its deposit; a second wallet in fresh directories
#                 folds the public request and receives its whole value after
#                 its fee; registration of that terminated key is declined
#   controls      each assertion above, handed altered input, fails
#
# Every verdict is computed from the chain's own record or from files; none is
# typed. The verdict table is WORKDIR/verdicts.md, the creation measurement
# WORKDIR/creation-measurement.json and the story in words WORKDIR/receipt.md.
# A setup failure (no node, no socket) exits
# 3 and is never a verdict; any clause that does not hold exits 1.
# shellcheck disable=SC2016 # single-quoted jq programs name jq variables, never shell ones
set -euo pipefail

[ "$#" -eq 6 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW WORKDIR" >&2
  exit 2
}
singular="$1"
open_datum="$2"
devnet="$3"
blueprint_source="$4"
chain_view="$5"
work="$6"
rig_name=journey
# shellcheck source=tools/no_pin_rig.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/no_pin_rig.sh"

# The assertions, as functions of files and values so that a control can hand
# each one altered input.
receipt_steps_are() { jq -e --argjson steps "$2" '[.submissions[].step] == $steps and all(.submissions[]; .case == "included" and .observed == true)' "$1"; }
scripts_published_are() { jq -e --argjson want "$2" '[.scripts[].published] == $want' "$1"; }
# The outputs of a transaction that carry a reference script.
script_outputs_of() { jq -c '[.outputs[] | select(.script) | .ref]' "$1"; }
refs_equal() { jq -e -n --argjson a "$1" --argjson b "$2" '($a | sort) == ($b | sort) and ($a | length) > 0'; }
# The transaction reads exactly these outputs by reference.
reads_refs() { jq -e --argjson want "$2" '[.referenceInputs[].ref] | sort == ($want | sort)' "$1"; }
mints() { jq -e --arg p "$2" --arg n "$3" --argjson q "$4" 'any(.mint[]; .policy == $p and .name == $n and .quantity == $q)' "$1"; }
# Nothing unspent carries the asset.
none_unspent_with() { jq -e --arg p "$2" --arg n "$3" '[.outputs[] | select(any(.assets[]; .policy == $p and .name == $n))] | length == 0' "$1"; }
one_unspent_with() { jq -e --arg p "$2" --arg n "$3" '[.outputs[] | select(any(.assets[]; .policy == $p and .name == $n))] | length == 1' "$1"; }
# The holding the fold delivered: the one output of the fold that carries a
# token of the registry other than its state token, with the key's token alone,
# at the committed address, with the deposit and no more, and the key, the
# controller, the deposit and the payload in its datum.
holding_is() { # FOLD-TX STATE-POLICY STATE-NAME KEYHEX CONTROLLER DEPOSIT PAYLOAD-JSON
  jq -e --arg sp "$2" --arg sn "$3" --arg key "$4" --arg ctl "$5" --argjson deposit "$6" --argjson payload "$7" --arg app "$application_hash" '
    [.outputs[] | select(any(.assets[]; .policy == $sp and .name != $sn))] as $holdings
    | ($holdings | length) == 1
    and ($holdings[0]
      | (.assets | length) == 1 and .assets[0].policy == $sp and .assets[0].quantity == 1
      and .credential == {type: "script", hash: $app}
      and .lovelace == $deposit
      and .datum.constructor == 2
      and .datum.fields[0].fields[2] == {bytes: $key}
      and .datum.fields[0].fields[3] == {bytes: $ctl}
      and .datum.fields[0].fields[4] == {int: $deposit}
      and .datum.fields[1] == $payload)' "$1"
}
# The ref of that holding.
holding_ref() { jq -r --arg sp "$2" --arg sn "$3" '[.outputs[] | select(any(.assets[]; .policy == $sp and .name != $sn))][0].ref' "$1"; }
# The state output after a fold: unspent, one, with this root.
state_is() { # UNSPENT STATE-POLICY STATE-NAME ROOT
  jq -e --arg sp "$2" --arg sn "$3" --arg root "$4" '
    [.outputs[] | select(any(.assets[]; .policy == $sp and .name == $sn))] as $states
    | ($states | length) == 1 and $states[0].datum == {constructor: 0, fields: [{bytes: $root}]}' "$1"
}
# Everything the request returned went to the refund address.
paid_to() { # TX ADDRESS LOVELACE
  jq -e --arg a "$2" --argjson l "$3" 'any(.outputs[]; .address == $a and .lovelace == $l and (.assets | length) == 0)' "$1"
}
signed_by_only() { jq -e --argjson want "$2" '(.signers | sort) == ($want | sort) and (.signers | length) > 0' "$1"; }
signed_by_none_of() { jq -e --argjson not "$2" '(.signers | length) > 0 and ([.signers[] | select(. as $s | $not | index($s))] | length) == 0' "$1"; }
spends_ref() { jq -e --arg r "$2" 'any(.inputs[]; .ref == $r)' "$1"; }
listing_is() { # FILE LINE...
  local file="$1"
  shift
  diff -u <(printf '%s\n' "$@") "$file"
}
# The transaction burns the approval and nothing unspent carries it.
burned_and_gone() { # TX UNSPENT POLICY NAME
  mints "$1" "$3" "$4" -1 && none_unspent_with "$2" "$3" "$4"
}
# Each of these approvals is gone from the unspent outputs.
both_gone() { # UNSPENT POLICY NAME POLICY NAME
  none_unspent_with "$1" "$2" "$3" && none_unspent_with "$1" "$4" "$5"
}
# The transaction read exactly the live copies and created no reference script.
reads_and_creates_no_script() { # TX REFS
  reads_refs "$1" "$2" && [ "$(script_outputs_of "$1")" = "[]" ]
}
# A creation by singular: the state script alone, from its live copy.
singular_creation() { # RECEIPT TX STATE-REFERENCE
  receipt_steps_are "$1" '["create"]' && scripts_published_are "$1" '[false]' && reads_refs "$2" "[\"$3\"]"
}
all_distinct() { [ "$(printf '%s\n' "$@" | sort -u | wc -l)" = "$#" ]; }
# These pending registrations are the unspent outputs of the request validator
# that hold the deposit and the tip.
pendings_hold() { # UNSPENT TOTAL REF...
  local unspent="$1" total="$2"
  shift 2
  jq -e --arg app "$application_hash" --argjson total "$total" --argjson refs "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" '
    [.outputs[] | select(.ref as $r | $refs | index($r))] as $found
    | ($found | length) == ($refs | length)
    and all($found[]; .credential == {type: "script", hash: $app} and .lovelace == $total)' "$unspent"
}

# ------------------------------------------------------------------
# 1. The first registry of the application
# ------------------------------------------------------------------
leg="creation"
as carol create-first "$open_datum" create --blueprint plutus.json \
  --process-time 60000 --reclaim-time 180000 --booking-width 60000
token="$(field create-first .stateToken)"
[[ "$token" =~ ^[0-9a-f]{56}\.[0-9a-f]{64}$ ]] || setup_fail "the first creation printed no state token"
state_policy="${token%%.*}"
state_name="${token##*.}"
say "registry $token created"
publish_state_tx="$(tx_of create-first publish-state-script)"
publish_request_tx="$(tx_of create-first publish-application-script)"
create_tx="$(tx_of create-first create)"
view_tx first-publish-state "$publish_state_tx"
view_tx first-publish-request "$publish_request_tx"
view_tx first-create "$create_tx"
state_reference="$(field create-first '.scripts[] | select(.script == "state") | .reference')"
application_reference="$(field create-first '.scripts[] | select(.script == "application") | .reference')"
live_copies="$(jq -c -n --arg s "$state_reference" --arg a "$application_reference" '[$s, $a]')"
check "the first registry sends the state publication, the request publication and the creation, each included and observed" \
  receipt_steps_are "$receipts/create-first.json" '["publish-state-script","publish-application-script","create"]'
check "the publications and the creation are distinct transactions" \
  all_distinct "$publish_state_tx" "$publish_request_tx" "$create_tx"
check "it publishes both scripts" scripts_published_are "$receipts/create-first.json" '[true,true]'
check "the chain holds the state reference script in the first publication" \
  refs_equal "$(script_outputs_of "$chain_dir/first-publish-state.tx.json")" "[\"$state_reference\"]"
check "the chain holds the request reference script in the second publication" \
  refs_equal "$(script_outputs_of "$chain_dir/first-publish-request.tx.json")" "[\"$application_reference\"]"
control "one transaction named twice is not two publications and a creation" \
  all_distinct "$publish_state_tx" "$publish_state_tx" "$create_tx"
control "the first publication does not carry both scripts" \
  refs_equal "$(script_outputs_of "$chain_dir/first-publish-state.tx.json")" "$live_copies"
control "the second publication does not carry the state script" \
  refs_equal "$(script_outputs_of "$chain_dir/first-publish-request.tx.json")" "[\"$state_reference\"]"
check "the creation reads both live copies by reference" reads_refs "$chain_dir/first-create.tx.json" "$live_copies"
check "the creation mints the registry's state token" mints "$chain_dir/first-create.tx.json" "$state_policy" "$state_name" 1
control "a creation that sent the creation alone is not the first registry's" \
  receipt_steps_are "$receipts/create-first.json" '["create"]'
control "a first registry that published nothing is not this one" scripts_published_are "$receipts/create-first.json" '[false,false]'
control "other live copies are not the ones the creation read" reads_refs "$chain_dir/first-create.tx.json" '["0000000000000000000000000000000000000000000000000000000000000000#0"]'

# ------------------------------------------------------------------
# 2. Alice books three keys
# ------------------------------------------------------------------
leg="booking"
deposit=2100000
tip=1000000
printf '%s\n' '{"name":"alice"}' >"$work/actors/alice/cwd/payload.json"
payload_data='{"map":[[{"bytes":"6e616d65"},{"bytes":"616c696365"}]]}'
hex_of() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
for kind in fold reclaim cleanup; do
  as alice "book-$kind" "$open_datum" insert --blueprint plutus.json \
    --state-token "$token" --key "journey-$kind" --payload payload.json \
    --deposit "$deposit" --tip "$tip"
done
fold_pending="$(field book-fold .pending)"
reclaim_pending="$(field book-reclaim .pending)"
cleanup_pending="$(field book-cleanup .pending)"
view_tx book-fold "${fold_pending%%#*}"
view_tx book-reclaim "${reclaim_pending%%#*}"
view_tx book-cleanup "${cleanup_pending%%#*}"
refund_address="$(field book-fold .refundAddress)"
controller="$(jq -r --arg r "$fold_pending" '.outputs[] | select(.ref == $r) | .datum.fields[0].fields[2].bytes' "$chain_dir/book-fold.tx.json")"
[[ "$controller" =~ ^[0-9a-f]{56}$ ]] || setup_fail "the booking names no controller"
booker_signers="$(jq -c '.signers' "$chain_dir/book-fold.tx.json")"
view_unspent after-booking
check "each booking puts its pending registration at the request address, with the deposit and the tip" \
  pendings_hold "$chain_dir/after-booking.unspent.json" "$((deposit + tip))" "$fold_pending" "$reclaim_pending" "$cleanup_pending"
control "a pending registration that held less than the deposit and the tip is not one of these" \
  pendings_hold "$chain_dir/after-booking.unspent.json" "$deposit" "$fold_pending" "$reclaim_pending" "$cleanup_pending"
check "the booker signs the booking and is the controller" signed_by_only "$chain_dir/book-fold.tx.json" "[\"$controller\"]"
control "another controller did not sign the booking" signed_by_only "$chain_dir/book-fold.tx.json" '["00000000000000000000000000000000000000000000000000000000"]'

# ------------------------------------------------------------------
# 3. Bob folds the first, from public data alone
# ------------------------------------------------------------------
leg="fold"
# What Bob finds on the chain: the unspent outputs at the request validator that
# hold an approval of the registry for the key he wants folded.
key_hex="$(hex_of journey-fold)"
settle
bob_pending="$(chain unspent | jq -r --arg app "$application_hash" --arg sp "$state_policy" --arg sn "$state_name" --arg key "$key_hex" '
  [.outputs[] | select(.credential == {type: "script", hash: $app})
    | select(.datum.constructor == 1 and .datum.fields[0].fields[0].fields == [{bytes: $sp}, {bytes: $sn}]
             and .datum.fields[0].fields[1] == {bytes: $key})][0].ref')"
check "the pending registration Bob finds on the chain is the one Alice booked" equal "$bob_pending" "$fold_pending"
control "another pending registration is not the one Alice booked" equal "$bob_pending" "$reclaim_pending"
# Bob's directories before the fold: his key and the release, and nothing else.
(cd "$work/actors/bob" && find cwd home -mindepth 1 | LC_ALL=C sort) >"$listings/bob-before-fold.txt"
check "before the fold Bob's directories hold his key and the release and nothing of anyone else's" \
  listing_is "$listings/bob-before-fold.txt" cwd/bob.skey cwd/plutus.json
{
  cat "$listings/bob-before-fold.txt"
  echo home/.local/state/singular/journal.jsonl
} >"$scratch/bob-listing-with-a-journal.txt"
control "a booker's journal in Bob's home would be seen" \
  listing_is "$scratch/bob-listing-with-a-journal.txt" cwd/bob.skey cwd/plutus.json
as bob fold "$open_datum" fold --blueprint plutus.json --state-token "$token" --pending "$bob_pending"
(cd "$work/actors/bob" && find cwd home -mindepth 1 | LC_ALL=C sort) >"$listings/bob-after-fold.txt"
fold_tx="$(tx_of fold fold)"
view_tx fold "$fold_tx"
view_unspent after-fold
payload_json="$payload_data"
check "the fold's signer is not the booker" signed_by_none_of "$chain_dir/fold.tx.json" "$booker_signers"
control "a fold signed by the booker would be seen" signed_by_none_of "$chain_dir/fold.tx.json" "$(jq -c '.signers' "$chain_dir/fold.tx.json")"
check "the fold is signed by one wallet" jq -e '.signers | length == 1' "$chain_dir/fold.tx.json"
check "the holding carries the key's token, the payload and exactly the deposit, at the committed address" \
  holding_is "$chain_dir/fold.tx.json" "$state_policy" "$state_name" "$key_hex" "$controller" "$deposit" "$payload_json"
control "a holding with one lovelace more than the deposit is not this one" \
  holding_is "$chain_dir/fold.tx.json" "$state_policy" "$state_name" "$key_hex" "$controller" "$((deposit + 1))" "$payload_json"
control "a holding of another payload is not this one" \
  holding_is "$chain_dir/fold.tx.json" "$state_policy" "$state_name" "$key_hex" "$controller" "$deposit" '{"map":[]}'
holding="$(holding_ref "$chain_dir/fold.tx.json" "$state_policy" "$state_name")"
check "the holding is still unspent" jq -e --arg r "$holding" 'any(.outputs[]; .ref == $r)' "$chain_dir/after-fold.unspent.json"
check "the registry's state carries the root the fold wrote" state_is "$chain_dir/after-fold.unspent.json" "$state_policy" "$state_name" "$(field fold .root)"
control "the empty root is not the root after a fold" state_is "$chain_dir/after-fold.unspent.json" "$state_policy" "$state_name" "0000000000000000000000000000000000000000000000000000000000000000"
fold_approval="$(field book-fold .approval)"
check "the fold burns the approval and no unspent output carries it" \
  burned_and_gone "$chain_dir/fold.tx.json" "$chain_dir/after-fold.unspent.json" "${fold_approval%%.*}" "${fold_approval##*.}"
control "an approval that was minted, not burned, is not this one" \
  mints "$chain_dir/fold.tx.json" "${fold_approval%%.*}" "${fold_approval##*.}" 1

say "the folder's listing before the fold:"
cat "$listings/bob-before-fold.txt"

# The live holding continues through the controller's two commands. The
# independent observer below follows input references, not command receipts.
leg="update and termination"
printf '%s\n' '{"name":"updated"}' >"$work/actors/alice/cwd/updated.json"
as alice update "$open_datum" update --blueprint plutus.json \
  --state-token "$token" --holding "$holding" --payload updated.json
view_tx update "$(tx_of update update)"
updated_holding="$(field update .holding)"
check "the updated holding carries the chosen payload with the same protected deposit" \
  holding_is "$chain_dir/update.tx.json" "$state_policy" "$state_name" "$key_hex" "$controller" "$deposit" \
  '{"map":[[{"bytes":"6e616d65"},{"bytes":"75706461746564"}]]}'
as alice terminate "$open_datum" terminate --blueprint plutus.json \
  --state-token "$token" --holding "$updated_holding"
view_tx terminate "$(tx_of terminate terminate)"
view_unspent after-termination-booking
active_name="$(jq -r --arg r "$holding" '.outputs[] | select(.ref == $r) | .datum.fields[0].fields[1].fields[1].bytes' "$chain_dir/fold.tx.json")"
public_pending="$(jq -er --arg sp "$state_policy" --arg active "$active_name" --arg app "$application_hash" '
  [.outputs[] | select(.credential == {type: "script", hash: $app} and .datum == null)
    | select(any(.assets[]; .policy == $sp and .name == $active and .quantity == 1))]
  | if length == 1 then .[0].ref else error("no unique public termination request") end' "$chain_dir/after-termination-booking.unspent.json")"
check "the termination request found on chain is the one the controller booked" equal "$public_pending" "$(field terminate .pending)"

# Bob uses a fresh process home and working directory with only copies of
# his own key and the public release. Neither Alice's files nor Bob's earlier
# command records are inputs to this fold.
mkdir -p "$work/actors/bob-public/cwd" "$work/actors/bob-public/home"
cp "$work/actors/bob/cwd/bob.skey" "$work/actors/bob-public/cwd/bob-public.skey"
cp "$work/release/plutus.json" "$work/actors/bob-public/cwd/plutus.json"
(cd "$work/actors/bob-public" && find cwd home -mindepth 1 | LC_ALL=C sort) >"$listings/bob-before-termination-fold.txt"
as bob-public termination-fold "$open_datum" fold --blueprint plutus.json \
  --state-token "$token" --pending "$public_pending"
view_tx termination-fold "$(tx_of termination-fold fold)"
view_unspent after-termination-fold
check "no unspent output carries the terminated key's active token" \
  none_unspent_with "$chain_dir/after-termination-fold.unspent.json" "$state_policy" "$active_name"
control "the live state token is not a burned active token" \
  none_unspent_with "$chain_dir/after-termination-fold.unspent.json" "$state_policy" "$state_name"
as alice book-terminal "$open_datum" insert --blueprint plutus.json \
  --state-token "$token" --key journey-fold --payload payload.json --deposit "$deposit" --tip "$tip"
run_as bob-public reregister "$open_datum" fold --blueprint plutus.json \
  --state-token "$token" --pending "$(field book-terminal .pending)"

# ------------------------------------------------------------------
# 4. Alice takes the second back inside its window
# ------------------------------------------------------------------
leg="reclaim"
wait_until_ms "$(field book-reclaim .processDeadline)"
as alice reclaim "$open_datum" reclaim --blueprint plutus.json --state-token "$token" --pending "$reclaim_pending"
reclaim_tx="$(tx_of reclaim reclaim)"
view_tx reclaim "$reclaim_tx"
reclaim_approval="$(field book-reclaim .approval)"
check "the reclaim spends the pending registration" spends_ref "$chain_dir/reclaim.tx.json" "$reclaim_pending"
check "everything the registration held returns to the refund address" paid_to "$chain_dir/reclaim.tx.json" "$refund_address" "$((deposit + tip))"
control "less than everything is not what returned" paid_to "$chain_dir/reclaim.tx.json" "$refund_address" "$deposit"
check "the reclaim is signed by the controller alone" signed_by_only "$chain_dir/reclaim.tx.json" "[\"$controller\"]"
check "the reclaim burns the approval" mints "$chain_dir/reclaim.tx.json" "${reclaim_approval%%.*}" "${reclaim_approval##*.}" -1

# ------------------------------------------------------------------
# 5. Dave cleans up the third after its window
# ------------------------------------------------------------------
leg="cleanup"
wait_until_ms "$(field book-cleanup .reclaimEnd)"
as dave cleanup "$open_datum" cleanup --blueprint plutus.json --state-token "$token" --pending "$cleanup_pending"
cleanup_tx="$(tx_of cleanup cleanup)"
view_tx cleanup "$cleanup_tx"
cleanup_approval="$(field book-cleanup .approval)"
view_unspent after-cleanup
check "the cleanup spends the pending registration" spends_ref "$chain_dir/cleanup.tx.json" "$cleanup_pending"
check "the deposit returns to the refund address" paid_to "$chain_dir/cleanup.tx.json" "$refund_address" "$deposit"
control "the whole request is not what returned" paid_to "$chain_dir/cleanup.tx.json" "$refund_address" "$((deposit + tip))"
check "the cleaner is not the refund address" signed_by_none_of "$chain_dir/cleanup.tx.json" "[\"$controller\"]"
control "a cleanup signed by the refund address would be seen" signed_by_none_of "$chain_dir/cleanup.tx.json" "$(jq -c '.signers' "$chain_dir/cleanup.tx.json")"
check "the cleanup burns the approval" mints "$chain_dir/cleanup.tx.json" "${cleanup_approval%%.*}" "${cleanup_approval##*.}" -1
check "no unspent output carries the reclaimed or the cleaned-up approval" \
  both_gone "$chain_dir/after-cleanup.unspent.json" "${reclaim_approval%%.*}" "${reclaim_approval##*.}" "${cleanup_approval%%.*}" "${cleanup_approval##*.}"
control "an unspent approval would be seen: the state token is unspent once" \
  both_gone "$chain_dir/after-cleanup.unspent.json" "$state_policy" "$state_name" "${cleanup_approval%%.*}" "${cleanup_approval##*.}"

# ------------------------------------------------------------------
# 6. A later registry of the application, and one made by singular
# ------------------------------------------------------------------
leg="scripts published once"
as carol create-later "$open_datum" create --blueprint plutus.json \
  --process-time 60000 --reclaim-time 180000 --booking-width 60000
as carol create-singular "$singular" registry create --blueprint plutus.json --application-policy "$application_hash"
later_create_tx="$(tx_of create-later create)"
singular_create_tx="$(tx_of create-singular create)"
view_tx later-create "$later_create_tx"
view_tx singular-create "$singular_create_tx"
view_unspent after-creations
check "a later registry sends the creation alone" receipt_steps_are "$receipts/create-later.json" '["create"]'
check "it publishes no script" scripts_published_are "$receipts/create-later.json" '[false,false]'
check "the chain shows it reading the live copies and creating no reference script" \
  reads_and_creates_no_script "$chain_dir/later-create.tx.json" "$live_copies"
control "the first registry's publication is not a creation that created no reference script" \
  reads_and_creates_no_script "$chain_dir/first-publish-state.tx.json" "$live_copies"
control "a later registry that read other outputs is not this one" \
  reads_and_creates_no_script "$chain_dir/later-create.tx.json" '["0000000000000000000000000000000000000000000000000000000000000000#0"]'
check "singular creates a registry of the same application from the live copy of the state script" \
  singular_creation "$receipts/create-singular.json" "$chain_dir/singular-create.tx.json" "$state_reference"
control "singular's creation read the state script's copy, not the request script's" \
  singular_creation "$receipts/create-singular.json" "$chain_dir/singular-create.tx.json" "$application_reference"
check "the three registries are three registries" \
  all_distinct "$token" "$(field create-later .stateToken)" "$(field create-singular .stateToken)"
control "one registry named twice is not three registries" all_distinct "$token" "$token" "$(field create-singular .stateToken)"
check "after three creations the chain holds the two reference scripts and no other" \
  jq -e --argjson live "$live_copies" '[.outputs[] | select(.script) | .ref] | sort == ($live | sort)' "$chain_dir/after-creations.unspent.json"
control "a chain that held a third reference script would be seen" \
  jq -e --argjson live "$live_copies" '[.outputs[] | select(.script) | .ref] + ["x#0"] | sort == ($live | sort)' "$chain_dir/after-creations.unspent.json"

# The creation measurement: what each registry's creation sent and locked,
# read from the chain's transactions, not from any receipt.
locked_of() { # STATE-NAME TX... : the creation transactions, as JSON
  jq -c -s --arg sp "$state_policy" --arg sn "$1" --arg app "$application_hash" '
    {transactions: [.[] | {id, fee}],
     transactionCount: length,
     lockedLovelace: {
       state: ([.[].outputs[] | select(any(.assets[]; .policy == $sp and .name == $sn)) | .lovelace] | add // 0),
       configuration: ([.[].outputs[] | select(.credential == {type: "script", hash: $app} and (.assets | length) > 0) | .lovelace] | add // 0),
       referenceScripts: ([.[].outputs[] | select(.script) | .lovelace] | add // 0)},
     publishesScripts: any(.[].outputs[]; .script)}
    | .lockedLovelace.total = (.lockedLovelace.state + .lockedLovelace.configuration + .lockedLovelace.referenceScripts)
    | .feesLovelace = ([.transactions[].fee] | add)' "${@:2}"
}
jq -n \
  --argjson first "$(locked_of "$state_name" "$chain_dir/first-publish-state.tx.json" "$chain_dir/first-publish-request.tx.json" "$chain_dir/first-create.tx.json")" \
  --argjson later "$(locked_of "$(field create-later .stateToken | sed 's/.*\.//')" "$chain_dir/later-create.tx.json")" \
  --argjson singular "$(locked_of "$(field create-singular .stateToken | sed 's/.*\.//')" "$chain_dir/singular-create.tx.json")" \
  --arg app "$application_hash" --arg release "$release_hash" \
  '{application: $app, release: $release,
    registries: [
      ($first + {registry: "the first registry of the application", command: "open-datum create"}),
      ($later + {registry: "a later registry of the application", command: "open-datum create"}),
      ($singular + {registry: "a registry made by singular from the same state script", command: "singular registry create"})]}' \
  >"$work/creation-measurement.json"
say "creation measurement: $(jq -c '[.registries[] | {registry, transactions: .transactionCount, locked: .lockedLovelace.total}]' "$work/creation-measurement.json")"
check "the measurement counts three transactions for the first registry and one for a later one" \
  jq -e '[.registries[].transactionCount] == [3, 1, 1]' "$work/creation-measurement.json"
check "only the first registry locked ADA in reference scripts" \
  jq -e '[.registries[].lockedLovelace.referenceScripts > 0] == [true, false, false]' "$work/creation-measurement.json"
control "a measurement that gave a later registry two transactions would be seen" \
  jq -e '[.registries[].transactionCount] == [2, 2, 1]' "$work/creation-measurement.json"

observe_termination() {
  python3 -I "$(dirname "$chain_view")/no_pin_termination_observations.py" "$chain_dir" "$state_policy" "$state_name" "$key_hex" \
    >"$work/termination-measurement.json" 2>"$work/termination-measurement.err"
}
leg="update and termination"
check "the connected update and termination route the deposit and the whole request value as ruled" \
  observe_termination
if [ -r "$listings/bob-before-termination-fold.txt" ]; then
  check "the termination folder holds only its own key and the release" \
    listing_is "$listings/bob-before-termination-fold.txt" cwd/bob-public.skey cwd/plutus.json
else
  record "$leg" "the termination folder holds only its own key and the release" "COULD-NOT-EVALUATE"
  failed=1
fi
if [ -s "$receipts/reregister.json" ]; then
  check "the packaged fold refuses a new registration of the terminated key" \
    jq -e '.outcome == "client-refusal" and (.reason | contains("is already registered")) and (.submissions | length) == 0' "$receipts/reregister.json"
else
  record "$leg" "a new registration of the terminated key is refused" "COULD-NOT-EVALUATE"
  failed=1
fi

# ------------------------------------------------------------------
# The receipt
# ------------------------------------------------------------------
# What the journey showed, in the words of the story, from the files above.
{
  printf '# Registration, update and termination journey receipt\n\n'
  printf 'Release (sha256 of the validators every wallet ran against): `%s`\n' "$release_hash"
  printf 'Registry: `%s`\n\n' "$token"
  printf '## The folder had nothing of the booker'"'"'s\n\n'
  printf 'The directories of the second wallet, listed before the fold:\n\n```\n'
  cat "$listings/bob-before-fold.txt"
  printf '```\n\n'
  printf 'The fold was signed by `%s`; the booking was signed by `%s`.\n\n' \
    "$(jq -r '.signers | join(", ")' "$chain_dir/fold.tx.json")" "$(jq -r '.signers | join(", ")' "$chain_dir/book-fold.tx.json")"
  printf '## The holding the fold delivered\n\n```json\n'
  jq --arg sp "$state_policy" --arg sn "$state_name" '[.outputs[] | select(any(.assets[]; .policy == $sp and .name != $sn))][0]' "$chain_dir/fold.tx.json"
  printf '```\n\n'
  printf '## What the creations sent and locked\n\n'
  printf '| registry | command | transactions | state | configuration | reference scripts | total (lovelace) | fees (lovelace) |\n|---|---|---|---|---|---|---|---|\n'
  jq -r '.registries[] | "| \(.registry) | `\(.command)` | \(.transactionCount) | \(.lockedLovelace.state) | \(.lockedLovelace.configuration) | \(.lockedLovelace.referenceScripts) | \(.lockedLovelace.total) | \(.feesLovelace) |"' "$work/creation-measurement.json"
  printf '\n## Update and termination, read from the chain\n\n```json\n'
  cat "$work/termination-measurement.json"
  printf '\n```\n\nThe second wallet held these files before termination folding:\n\n```\n'
  cat "$listings/bob-before-termination-fold.txt"
  printf '```\n\nThe packaged re-registration fold reported:\n\n```json\n'
  cat "$receipts/reregister.json"
  printf '\n```\n\n## Verdicts\n\n'
  cat "$verdicts"
} >"$work/receipt.md"

# ------------------------------------------------------------------
# The verdict
# ------------------------------------------------------------------
leg="journey"
[ "$(grep -c ' holds |' "$verdicts")" -gt 0 ] || {
  say "no clause was judged"
  failed=1
}
say "release $release_hash; $(grep -c ' holds |' "$verdicts") clauses hold, $(grep -c 'fails on altered input' "$verdicts") controls fail as they must"
if [ "$failed" -ne 0 ]; then
  say "NO-PIN-JOURNEY-FAILED"
  exit 1
fi
say "NO-PIN-JOURNEY-OK"

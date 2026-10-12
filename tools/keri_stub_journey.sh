#!/usr/bin/env bash
# The keri-stub journey (#528, briefs 3 and 4): one registry booted for the stub's
# own always-succeeding policy, one key registered under it, the stub's own
# request folded by the stub's own fold, the key read back active with its
# holding, a second register of the same key refused at booking — before
# anything is signed — with the named client-policy reason, then the key
# convicted with its evidence, folded to terminal with its holding released
# to its controller and the deposit back — the repayment read back on the
# chain at the controller's own address, the holding observed spent, and
# the same observation shown failing at an address never owned.
#
# usage: keri_stub_journey.sh KERI_STUB DEVNET BLUEPRINT WORKDIR
#
# KERI_STUB and DEVNET are executables; BLUEPRINT is the registry partition's
# plutus.json; WORKDIR is the run's scratch. ONE development node is started
# once, funding one generated wallet (alice), and every command is a separate
# process against it:
#
#   create (preview) -> create -> register -> fold -> status -> register again
#     -> register --fold -> convict -> fold -> status -> convict --fold
#
# The register books an insertion under the stub's policy and leaves its
# request pending; `keri-stub fold` folds it, signed by the wallet that
# booked it. The second register of the same key must stop at the booking
# refusal with nothing submitted: its outcome class and exit status, the
# named client-policy reason, the refusal's fields, and the target's journal
# line count all say so. The journey also proves the run never used an
# `open-datum` executable: no open-datum binary is on the PATH it runs
# commands under, and the live process record holds none. Assertions read
# the receipts the commands print and nothing else. Setup failures (no node,
# no provider) are reported as setup (exit 3), never as a result.
set -euo pipefail

[ "$#" -eq 4 ] || {
  echo "usage: $0 KERI_STUB DEVNET BLUEPRINT WORKDIR" >&2
  exit 2
}
keri_stub="$1"
devnet="$2"
blueprint="$3"
work="$4"
rm -rf "$work"
mkdir -p "$work"
receipts="$work/receipts"
mkdir -p "$receipts"
reg="$work/registry"

fail() {
  echo "keri-stub journey: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "keri-stub journey: SETUP: $*" >&2
  exit 3
}
say() { echo "keri-stub journey: $*"; }

# Stop the node before touching the tree; the caller still reads receipts
# and harness markers in $work, so the directory stays while the node chain
# is what fills the disk. The devnet helper puts the node at
# $TMPDIR/cardano-e2e with this run's own TMPDIR, so the processes this
# run recorded are the devnet runner and the node holding that one
# directory: only their pids are signalled, never a sweep by name alone.
release_work() {
  local code=$?
  local pid _wait
  trap - EXIT
  [ -n "${devnet_pid:-}" ] && kill "$devnet_pid" 2>/dev/null || true
  for pid in $(node_pids); do
    kill "$pid" 2>/dev/null || true
  done
  for _wait in $(seq 1 100); do
    [ -z "$(node_pids)" ] && break
    sleep 0.1
  done
  if [ -n "${work:-}" ]; then
    rm -rf "$work/cardano-e2e" || true
    if [ -e "$work/cardano-e2e" ]; then
      echo "keri-stub journey: scratch remains: $work/cardano-e2e" >&2
      code=1
    fi
  fi
  exit "$code"
}

# The pids of this run's own node: the one whose config directory is this
# run's cardano-e2e. Reading them by pattern is not signalling; only these
# pids, found under this run's unique scratch, are ever signalled.
node_pids() {
  pgrep -f "cardano-node run --config $work/cardano-e2e" 2>/dev/null || true
}

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/alice.skey"

export TMPDIR="$work"

"$devnet" --fund-skey "$work/alice.skey" --fund-outputs 8 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
trap release_work EXIT

provider_url=""
time_directory=""
network_magic=""
sock=""
for _ in $(seq 1 900); do
  settings="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  sock="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
  provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
  time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
  network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
  [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_directory/time-manifest.json" ] && break
  kill -0 "$devnet_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -S "$sock" ] || [ ! -r "$time_directory/time-manifest.json" ]; then
  tail -40 "$work/devnet.err" >&2 || true
  setup_fail "the private devnet never printed usable provider/time and independent probe settings"
fi
say "one private development source at $provider_url"

# The CIP-19 network nibble every address header below is built from: 0 on
# every testnet, 1 on mainnet alone. The devnet above fixed magic 42, of the
# testnet family, so this is 0; a mainnet nibble here would refuse every
# query below at the reader.
net_nibble=0

node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
common=(--state-dir "$reg" --blueprint "$blueprint")
alice=(--wallet-skey "$work/alice.skey")

# run NAME CLASS -- ARGS: one keri-stub process, its receipt read back.
# The class names the outcome its exit status must match; a process whose
# receipt is missing or disagrees fails the row by name.
run() {
  local name="$1" class="$2"
  shift 3
  local status=0
  "$keri_stub" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  local got
  got="$(jq -er '.outcome' "$receipts/$name.json" 2>/dev/null || echo none)"
  case "$class" in
    success) want=0 ;;
    client-refusal) want=10 ;;
    *) fail "run: no exit status for class $class" ;;
  esac
  if [ "$got" != "$class" ] || [ "$status" -ne "$want" ]; then
    cat "$receipts/$name.json" >&2 2>/dev/null || true
    tail -20 "$receipts/$name.err" >&2 2>/dev/null || true
    fail "$name: outcome $got (exit $status), expected $class"
  fi
  say "$name: $class"
}
field() { jq -r "$2" "$receipts/$1.json"; }

# journal_lines: lines in every journal under the state root, so a refusal
# that submits nothing is proven by the count not moving.
journal_lines() {
  find "$reg" -name 'journal.jsonl' -type f -print0 2>/dev/null \
    | xargs -0 -r cat 2>/dev/null | wc -l | tr -d ' '
}

# key_enterprise HASH28: the bech32 testnet payment-key enterprise address
# (CIP-19 type 6) for a 28-byte hash as hex. The header is built from the
# one network nibble above, never typed here; the fold pays a termination's
# release to the enterprise address of the holding's controller hash, so
# the journey reads the repayment back there. Encoded by the pinned
# python3 below; a mistyped checksum fails loudly at the status call,
# whose decoder checks it, never silently.
key_enterprise() {
  case "$1" in
    *[!0-9a-fA-F]* | "") fail "key_enterprise: not hex bytes" ;;
  esac
  [ "${#1}" = 56 ] || fail "key_enterprise: not a 28-byte hash"
  python3 - "6$net_nibble$1" <<'PYEOF' || fail "key_enterprise: the encoder refused the bytes"
import sys
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GEN = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

def hrp_expand(h):
    return [ord(x) >> 5 for x in h] + [0] + [ord(x) & 31 for x in h]

def polymod(values):
    chk = 1
    for x in values:
        b = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ x
        for i in range(5):
            if (b >> i) & 1:
                chk ^= GEN[i]
    return chk

def convertbits(data, frombits, tobits):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for b in data:
        acc = (acc << frombits) | b
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret

raw = bytes.fromhex(sys.argv[1])
combined = convertbits(list(raw), 8, 5)
checksum = polymod(hrp_expand("addr_test") + combined + [0] * 6) ^ 1
combined += [(checksum >> 5 * (5 - i)) & 31 for i in range(6)]
print("addr_test1" + "".join(CHARSET[d] for d in combined))
PYEOF
}

# fold_repayment RECEIPT FOLD_TXID EXPECTED BEFORE_FILE: the receipt's
# outputsAt lists an output of the fold transaction (its reference carries
# the fold's transaction id) locking exactly EXPECTED lovelace and not
# named in the before file. The fold pays the release and returns the
# booking deposit to the same owner in one output, so the repayment is
# exactly their sum and is new; the wallet's older outputs, however rich,
# cannot satisfy it, and paying the release elsewhere leaves no such
# output here. Fails otherwise.
fold_repayment() {
  jq -e --arg tx "$2" --argjson exp "$3" --rawfile seen "$4" \
    '($seen | split("\n")) as $old
     | [.outputsAt.outputs[]? | select((.output | startswith($tx + "#")) and .locked.lovelace == $exp and ((.output as $o | $old | index($o)) | not))] | length >= 1' \
    "$1" >/dev/null
}

# The payload the register carries: an opaque identifier prefix, spelled as
# the Plutus data the holding datum's payload field is (base16 bytes).
payload_prefix="stub-prefix-1"
payload_hex="$(printf '%s' "$payload_prefix" | od -An -tx1 | tr -d ' \n')"
jq -n --arg h "$payload_hex" '{bytes: $h}' >"$work/payload.json"

# ------------------------------------------------------------------
# 1. create: a preview names the seed, the create boots the registry
# ------------------------------------------------------------------
run create-preview success -- create --process-time 120000 --retract-time 60000 --preview \
  "${common[@]}" "${node[@]}" "${alice[@]}"
[ ! -e "$reg/registry.json" ] || fail "a preview created the target"
seed="$(field create-preview .seed)"
[ -n "$seed" ] || fail "the preview printed no seed"
run create success -- create --process-time 120000 --retract-time 60000 --seed "$seed" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
state_token="$(field create .stateToken)"
[ -n "$state_token" ] || fail "create printed no state token"
controller="$(field create .walletKeyHash)"
[ -n "$controller" ] || fail "create printed no wallet key hash"
registry=(--state-token "$state_token")
say "registry $state_token booted for the stub's own policy"

# ------------------------------------------------------------------
# 2. register: one key booked under the stub's always-succeeding policy
# ------------------------------------------------------------------
key="keri-key-one"
key_hex="$(printf '%s' "$key" | od -An -tx1 | tr -d ' \n')"
deposit=4000000
run register success -- register --key "$key" --deposit "$deposit" --payload "$work/payload.json" \
  "${common[@]}" "${registry[@]}" "${node[@]}" "${alice[@]}"
jq -e --arg k "$key_hex" '.key == $k
  and (.booking | type == "string" and length > 0)
  and (.request | type == "string" and length > 0)
  and (.requester | type == "string" and length > 0)
  and (.foldDeadline.posixMs | type == "number")' "$receipts/register.json" >/dev/null \
  || fail "register: the receipt does not name the key, its pending request, the requester and the fold deadline"
jq -e 'has("submissions") and ([.submissions[]? | select(.step == "book")] | length >= 1)' "$receipts/register.json" >/dev/null \
  || fail "register: the receipt does not name its booking submission"
jq -e 'all(.submissions[]?; .step == "book")' "$receipts/register.json" >/dev/null \
  || fail "register: the booking-only command submitted something besides its booking"
[ "$(field register .request)" = "$(field register .booking)#0" ] \
  || fail "register: the pending request is not the booking's output 0"
jq -e --arg c "$controller" '.holding.fields[1].bytes == $c' "$receipts/register.json" >/dev/null \
  || fail "register: the booked holding names another controller than the signing wallet"

# ------------------------------------------------------------------
# 3. fold: the stub's own request, folded by the stub's own fold
# ------------------------------------------------------------------
run fold success -- fold "${common[@]}" "${registry[@]}" "${node[@]}" "${alice[@]}"
jq -e --arg k "$key_hex" '(.settled | length == 1)
  and .settled[0].edge == "insertActive"
  and .settled[0].key == $k' "$receipts/fold.json" >/dev/null \
  || fail "fold: the settled request is not this key's insertActive"
jq -e --arg k "$key_hex" --arg c "$controller" --arg p "$payload_hex" --argjson d "$deposit" \
  '.settled[0].settlement.envelope == {constructor: 0, fields: [{bytes: $k}, {bytes: $c}, {int: $d}, {bytes: $p}]}
    and (.settled[0].settlement.liveOutput | type == "string" and length > 0)' \
  "$receipts/fold.json" >/dev/null \
  || fail "fold: the delivered holding is not the one the booking wrote, derived from the command line's own inputs"

# ------------------------------------------------------------------
# 4. status: the key is active with its holding
# ------------------------------------------------------------------
run status success -- status --key "$key" "${common[@]}" "${registry[@]}" "${node[@]}"
[ "$(field status .leaf)" = "active" ] || fail "status: the key is not active after the fold"
jq -e --arg c "$controller" --arg p "$payload_hex" --argjson d "$deposit" \
  '.applicationOutput.deposit == $d
    and .applicationOutput.controller == $c
    and .applicationOutput.payload == {bytes: $p}
    and (.applicationOutput.output | type == "string" and length > 0)' "$receipts/status.json" >/dev/null \
  || fail "status: the holding the key reads back is not the one booked, with its deposit, controller and payload"
[ "$(jq -r '.pendingRequests | length' "$receipts/status.json")" = 0 ] \
  || fail "status: a request is still pending after the fold"
# The repayment addresses are well-formed before anything terminates: the
# controller's testnet enterprise address lists the signing wallet's own
# outputs here at the Active stage. This proves the encoder, the header
# and the reader agree, and it runs on the RED head too, which the
# convict-step observations cannot reach.
controller_enterprise="$(key_enterprise "$controller")"
run status-domain success -- status --key "$key" --outputs-at "$controller_enterprise" \
  "${common[@]}" "${registry[@]}" "${node[@]}"
jq -e '[.outputsAt.outputs[]?] | length >= 1' "$receipts/status-domain.json" >/dev/null \
  || fail "status-domain: the controller's address lists no wallet outputs"

# ------------------------------------------------------------------
# 5. the second register of the same key: refused at booking, nothing sent
# ------------------------------------------------------------------
before_journal="$(journal_lines)"
run register-again client-refusal -- register --key "$key" --deposit "$deposit" --payload "$work/payload.json" \
  "${common[@]}" "${registry[@]}" "${node[@]}" "${alice[@]}"
jq -e --arg k "$key_hex" '.key == $k
  and .verb == "insert" and .edge == "insertActive"
  and .leafFound == "active" and .leafRequired == "unknown"
  and .policy == "client"
  and (.reason | contains("already registered"))
  and (.reason | contains("(client policy)"))' "$receipts/register-again.json" >/dev/null \
  || fail "register-again: the refusal is not the named client-policy booking refusal with its fields"
jq -e 'has("submissions") | not' "$receipts/register-again.json" >/dev/null \
  || fail "register-again: the refused booking submitted something"
[ "$(journal_lines)" = "$before_journal" ] \
  || fail "register-again: the target's journal moved; the refusal submitted something"

# ------------------------------------------------------------------
# 5b. register with --fold: the same command folds its own booking
# ------------------------------------------------------------------
key_two="keri-key-two"
key_two_hex="$(printf '%s' "$key_two" | od -An -tx1 | tr -d ' \n')"
run register-fold success -- register --key "$key_two" --deposit "$deposit" --payload "$work/payload.json" --fold \
  "${common[@]}" "${registry[@]}" "${node[@]}" "${alice[@]}"
jq -e --arg k "$key_two_hex" --arg c "$controller" --arg p "$payload_hex" --argjson d "$deposit" \
  '.key == $k
    and (.booking | type == "string" and length > 0)
    and (.fold | type == "string" and length > 0)
    and (.liveOutput | type == "string" and length > 0)
    and (.root | type == "string" and length > 0)
    and .holding == {constructor: 0, fields: [{bytes: $k}, {bytes: $c}, {int: $d}, {bytes: $p}]}' \
  "$receipts/register-fold.json" >/dev/null \
  || fail "register-fold: the combined receipt names no booking, fold, live output, root and the booked holding"
run status-two success -- status --key "$key_two" "${common[@]}" "${registry[@]}" "${node[@]}"
[ "$(field status-two .leaf)" = "active" ] \
  || fail "status-two: the key folded by --fold is not active"

# ------------------------------------------------------------------
# 6. convict: terminate the key with its evidence, booking only
# ------------------------------------------------------------------
evidence_hex="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
run convict success -- convict --key "$key" --evidence "$evidence_hex" \
  "${common[@]}" "${registry[@]}" "${node[@]}" "${alice[@]}"
jq -e --arg k "$key_hex" --arg v "$evidence_hex" --argjson d "$deposit" '.key == $k
  and (.booking | type == "string" and length > 0)
  and (.request | type == "string" and length > 0)
  and (.requester | type == "string" and length > 0)
  and (.foldDeadline.posixMs | type == "number")
  and .evidence == $v
  and (.released | test("^[0-9a-f]{64}#[0-9]+$"))
  and .deposit == $d
  and (.bookingDeposit | type == "number" and . > 0)' "$receipts/convict.json" >/dev/null \
  || fail "convict: the receipt does not name the key, its pending request, the requester, the fold deadline, the evidence, the live output its fold will release and the booking deposit its fold returns"
jq -e 'has("submissions") and ([.submissions[]? | select(.step == "book")] | length >= 1)' "$receipts/convict.json" >/dev/null \
  || fail "convict: the receipt does not name its booking submission"
jq -e 'all(.submissions[]?; .step == "book")' "$receipts/convict.json" >/dev/null \
  || fail "convict: the booking-only command submitted something besides its booking"
[ "$(field convict .request)" = "$(field convict .booking)#0" ] \
  || fail "convict: the pending request is not the booking's output 0"
# The repayment the fold will pay is the release plus the booking deposit
# to the same owner in one output: both numbers come from the booking's
# own receipt, and the chain output below must match their sum.
controller_enterprise="$(key_enterprise "$controller")"
booking_deposit="$(field convict .bookingDeposit)"
repayment_expected="$((deposit + booking_deposit))"
say "the fold must pay $repayment_expected lovelace back at $controller_enterprise (deposit $deposit plus booking deposit $booking_deposit)"
run status-pre success -- status --key "$key" --outputs-at "$controller_enterprise" \
  "${common[@]}" "${registry[@]}" "${node[@]}"
jq -r '.outputsAt.outputs[].output' "$receipts/status-pre.json" | sort >"$work/before-one.txt"

# ------------------------------------------------------------------
# 7. fold the termination: the key reads terminal, the holding released
# ------------------------------------------------------------------
run convict-fold success -- fold "${common[@]}" "${registry[@]}" "${node[@]}" "${alice[@]}"
jq -e --arg k "$key_hex" '(.settled | length == 1)
  and .settled[0].edge == "updateTerminal"
  and .settled[0].key == $k' "$receipts/convict-fold.json" >/dev/null \
  || fail "convict-fold: the settled request is not this key's updateTerminal"
[ "$(field convict-fold .settled[0].settlement.released)" = "$(field convict .released)" ] \
  || fail "convict-fold: the fold released another output than the booking named"
jq -e --argjson d "$deposit" '.settled[0].settlement.deposit == $d
  and (.settled[0].settlement.released | type == "string" and length > 0)' "$receipts/convict-fold.json" >/dev/null \
  || fail "convict-fold: the released output and the deposit paid back are not the holding's, derived from the fold's own settlement"
run status-terminal success -- status --key "$key" "${common[@]}" "${registry[@]}" "${node[@]}"
[ "$(field status-terminal .leaf)" = "terminal" ] \
  || fail "status-terminal: the key is not terminal after the fold"
[ "$(jq -r '.pendingRequests | length' "$receipts/status-terminal.json")" = 0 ] \
  || fail "status-terminal: a request is still pending after the fold"

# ------------------------------------------------------------------
# 7b. the repayment: the fold's own output at the controller's address locks the
# release plus the booking deposit back, the holding is spent, and a
# decoy address shows none
# ------------------------------------------------------------------
fold_tx="$(field convict-fold .fold)"
run status-repayment success -- status --key "$key" --outputs-at "$controller_enterprise" \
  "${common[@]}" "${registry[@]}" "${node[@]}"
fold_repayment "$receipts/status-repayment.json" "$fold_tx" "$repayment_expected" "$work/before-one.txt" \
  || fail "status-repayment: no new output of the fold at the controller's address locks $repayment_expected lovelace back"
say "repayment: $(jq -r --arg tx "$fold_tx" --argjson exp "$repayment_expected" '[.outputsAt.outputs[] | select((.output | startswith($tx + "#")) and .locked.lovelace == $exp)][0] | "\(.output) \(.locked.lovelace)"' "$receipts/status-repayment.json") at the controller's address"
# The holding's input is spent: the key reads terminal with no holding.
# (The read below goes through the stub script's own address internally:
# `--outputs-at` takes payment-key enterprise addresses alone by design,
# so no caller spells the script address there. The fold itself also
# refuses unless the live output is spent.)
jq -e '.applicationOutput.absent and (.applicationOutput.holdings | length == 0)' "$receipts/status-terminal.json" >/dev/null \
  || fail "status-terminal: the holding is still live"
# The planted control: the same repayment observation aimed at an address
# the controller never owned fails it.
decoy_hash="$(od -An -tx1 -N28 /dev/urandom | tr -d ' \n')"
decoy_enterprise="$(key_enterprise "$decoy_hash")"
run status-decoy success -- status --key "$key" --outputs-at "$decoy_enterprise" \
  "${common[@]}" "${registry[@]}" "${node[@]}"
if jq -e --arg tx "$fold_tx" --argjson exp "$repayment_expected" \
  '[.outputsAt.outputs[]? | select((.output | startswith($tx + "#")) and .locked.lovelace == $exp)] | length == 0' \
  "$receipts/status-decoy.json" >/dev/null; then
  say "decoy: $(jq -r --arg tx "$fold_tx" '[.outputsAt.outputs[]? | select(.output | startswith($tx + "#"))] | length' "$receipts/status-decoy.json") outputs of the fold at the decoy address"
else
  fail "status-decoy: a repayment shows at an address the controller never owned"
fi
say "the deposit sits at the controller's address, the holding is spent, and a decoy address shows none"

# ------------------------------------------------------------------
# 8. convict with --fold: the same command folds its own booking
# ------------------------------------------------------------------
run status-pre-two success -- status --key "$key_two" --outputs-at "$controller_enterprise" \
  "${common[@]}" "${registry[@]}" "${node[@]}"
jq -r '.outputsAt.outputs[].output' "$receipts/status-pre-two.json" | sort >"$work/before-two.txt"
run convict-two success -- convict --key "$key_two" --evidence "$evidence_hex" --fold \
  "${common[@]}" "${registry[@]}" "${node[@]}" "${alice[@]}"
jq -e --arg k "$key_two_hex" --arg v "$evidence_hex" --argjson d "$deposit" '.key == $k
  and (.booking | type == "string" and length > 0)
  and (.fold | type == "string" and length > 0)
  and (.released | test("^[0-9a-f]{64}#[0-9]+$"))
  and .deposit == $d
  and .evidence == $v
  and (.bookingDeposit | type == "number" and . > 0)
  and (.root | type == "string" and length > 0)' \
  "$receipts/convict-two.json" >/dev/null \
  || fail "convict-two: the combined receipt names no booking, fold, released output, deposit, evidence, booking deposit and root"
run status-two-terminal success -- status --key "$key_two" "${common[@]}" "${registry[@]}" "${node[@]}"
[ "$(field status-two-terminal .leaf)" = "terminal" ] \
  || fail "status-two-terminal: the key folded by --fold is not terminal"
# The second repayment lands beside the first: the fold's own output at
# the controller's address locks the release plus the booking deposit
# back, and the key reads terminal with no holding.
booking_deposit_two="$(field convict-two .bookingDeposit)"
repayment_expected_two="$((deposit + booking_deposit_two))"
fold_tx_two="$(field convict-two .fold)"
run status-repayment-two success -- status --key "$key_two" --outputs-at "$controller_enterprise" \
  "${common[@]}" "${registry[@]}" "${node[@]}"
fold_repayment "$receipts/status-repayment-two.json" "$fold_tx_two" "$repayment_expected_two" "$work/before-two.txt" \
  || fail "status-repayment-two: no new output of the fold at the controller's address locks $repayment_expected_two lovelace back"
say "repayment: $(jq -r --arg tx "$fold_tx_two" --argjson exp "$repayment_expected_two" '[.outputsAt.outputs[] | select((.output | startswith($tx + "#")) and .locked.lovelace == $exp)][0] | "\(.output) \(.locked.lovelace)"' "$receipts/status-repayment-two.json") at the controller's address"
jq -e '.applicationOutput.absent and (.applicationOutput.holdings | length == 0)' "$receipts/status-two-terminal.json" >/dev/null \
  || fail "status-two-terminal: the holding is still live"

# ------------------------------------------------------------------
# 9. the run never used an open-datum executable
# ------------------------------------------------------------------
if command -v open-datum >/dev/null 2>&1; then
  fail "the journey's PATH holds an open-datum executable: $(command -v open-datum)"
fi
case ":$PATH:" in
  *:*/open-datum/*:*) fail "the journey's PATH walks an open-datum tree" ;;
esac
# The process record of this run: no process whose command line names this
# run's scratch names an open-datum executable with it, and nothing the run
# wrote under its receipts or state root names one either.
if pgrep -f "($work.*open-datum|open-datum.*$work)" >/dev/null 2>&1; then
  fail "the process record holds an open-datum executable"
fi
if grep -rniE 'open-datum' "$receipts" "$reg" >/dev/null 2>&1; then
  fail "something this run wrote names an open-datum executable"
fi
say "no open-datum executable on the journey's PATH, in its process record or in what it wrote"

say "one key registered, folded, active with its holding, a second register refused at booking, and both keys convicted to terminal with their deposits observed back at the controller's address"

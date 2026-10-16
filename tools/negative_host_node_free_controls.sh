#!/usr/bin/env bash
# Node-free controls for the negative host (#562). These are the legs of
# the retired tools/negative_host_proof.sh that no hosted job ran: the
# membership of the discovered parts, the empty-list refusal
# control on the discovery assertion, the four exit-2 parser refusals
# (bogus tamper, pay-short 0 and abc, unknown subcommand), the
# unknown-part refusal of the part dispatcher, and the terminate and
# insert handler receipts with exit 10 against an unreachable provider.
# The host build, plain discovery, the ordinary check and the lint check
# stay with their existing sole hosted carriers
# (tools/negative_host_ordinary.sh, the pair-parts discovery job and
# tools/negative_host_lint.sh); this script does not re-run them as
# verdicts. Setup (building the host binary from the application flake)
# is exit 2 on failure, never a verdict; exit 1 is a failed control.
# usage: negative_host_node_free_controls.sh REPO-ROOT
set -uo pipefail

root="$1"
setup_fail() {
  echo "negative-host-node-free-controls: SETUP: $*" >&2
  exit 2
}
# Output-state acquisition, one guard per step: an invalid TMPDIR or an
# unusable root stops here with exit 2 and writes nothing outside the
# scratch.
receipts="$(mktemp -d)" \
  || setup_fail "creating the receipts directory (TMPDIR=${TMPDIR:-unset})"
trap 'rm -rf "$receipts"' EXIT
failures=0
say() { printf 'NODE-FREE: %s\n' "$*"; }
fail() {
  say "FAIL: $*"
  failures=$((failures + 1))
}

# Setup: the host binary from the application flake. A build failure is
# setup (exit 2), never a verdict.
if ! host_out="$(cd "$root/applications/open-datum/offchain" && nix build --quiet --no-link --print-out-paths .#singular-negative)"; then
  echo "negative-host-node-free-controls: setup failed building the host from the application flake" >&2
  exit 2
fi
host_bin="$host_out/bin/singular-negative"
[ -x "$host_bin" ] || {
  echo "negative-host-node-free-controls: no singular-negative binary under $host_out" >&2
  exit 2
}

cd "$root" || setup_fail "entering the repository root $root"

# 1. Discovery lists every named part (the host table's complete row
# set): the discovery app's output must carry every part name, so a
# dropped part fails here and not only in a pair job that never ran.
if parts_out="$(nix run --quiet .#negative-host-parts)"; then
  for want in stranger-updates-the-key controller-tamper-controller controller-tamper-deposit controller-tamper-token controller-tamper-address controller-tamper-datum stranger-terminates-the-key controller-withdraws-outside-a-fold stranger-registers-a-taken-key owner-registers-a-taken-key-again owner-revives-a-terminated-key stranger-revives-a-terminated-key short-fold-of-a-booked-termination closed-update; do
    if grep -q "\"$want\"" <<<"$parts_out"; then
      say "parts list carries $want"
    else
      fail "parts list misses $want"
    fi
  done
else
  fail "negative-host-parts exited non-zero"
fi

# 2. Control: the non-empty assertion can fail. This is the assertion's
# own control (an empty JSON list must fail it); it is distinct from the
# discovery app refusing an empty source table, which no hosted job
# observes and which is recorded as such in the leg-to-job table.
if printf '{"part":[]}' | jq -e '.part | length > 0' >/dev/null 2>&1; then
  fail "empty parts list passed the non-empty assertion"
else
  say "control: empty parts list fails the non-empty assertion — check can fail"
fi

# 3. The negative forms refuse bad values without a node: bogus tamper,
# non-positive pay-short values and an unknown subcommand, each exit 2
# with its refusal text.
parse_case() {
  local name="$1" text="$2" code="" out=""
  shift 2
  out="$("$host_bin" "$@" 2>&1)" || code=$?
  code="${code:-0}"
  [ "$code" -eq 2 ] || {
    say "FAIL: parse case $name exited $code, expected 2"
    return 1
  }
  printf '%s' "$out" | grep -Fq "$text" || {
    say "FAIL: parse case $name names no refusal ($text)"
    return 1
  }
}
parse_ok=0
parse_case tamper-bogus "needs one of controller" registry update --tamper bogus || parse_ok=1
parse_case pay-short-zero "needs a positive integer" registry fold --pay-short 0 || parse_ok=1
parse_case pay-short-abc "needs a positive integer" registry fold --pay-short abc || parse_ok=1
parse_case unknown-command "not a command singular supports" registry frobnicate || parse_ok=1
# A failed parser control reaches the verdict: the success message is
# only for the case where all four held.
if [ "$parse_ok" -eq 0 ]; then
  say "parse refusals green without a node"
else
  failures=$((failures + 1))
fi

# 4. The part dispatcher refuses a part outside the host table before
# starting anything.
if nix run --quiet .#negative-host-part -- "bogus-part-xyz" >"$receipts/red-bogus.out" 2>"$receipts/red-bogus.err"; then
  fail "bogus part ran green"
elif grep -Fq "unknown part" "$receipts/red-bogus.err"; then
  say "control: bogus part refused as unknown — dispatch is real"
else
  fail "bogus refusal names no unknown part"
fi

# 5. Terminate and insert books reach the handler without a node: each
# runs against an unreachable provider (no blueprint, no skey, no koios)
# and must stop with its booking receipt, exit 10, naming its command,
# with no slice refusal left.
tok="00000000000000000000000000000000000000000000000000000000.0000000000000000000000000000000000000000000000000000000000000000"
term_out="$("$host_bin" registry terminate --blueprint "$receipts/nope.json" --key alice-1 --state-token "$tok" --koios-url http://127.0.0.1:1 --network-magic 42 --wallet-skey "$receipts/nope.skey" 2>&1)" || term_code=$?
term_code="${term_code:-0}"
if [ "$term_code" -eq 10 ] && printf '%s' "$term_out" | grep -Fq '"command": "terminate"' && ! printf '%s' "$term_out" | grep -Fq "not in this slice"; then
  say "terminate books: handler ran (exit 10)"
else
  fail "host terminate exited ${term_code:-0} with its slice refusal or no receipt"
fi
jq -n '{map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}' >"$receipts/payload.json" \
  || setup_fail "writing the insert payload"
ins_out="$("$host_bin" registry insert --blueprint "$receipts/nope.json" --key alice-1 --payload "$receipts/payload.json" --state-token "$tok" --koios-url http://127.0.0.1:1 --network-magic 42 --wallet-skey "$receipts/nope.skey" 2>&1)" || ins_code=$?
ins_code="${ins_code:-0}"
if [ "$ins_code" -eq 10 ] && printf '%s' "$ins_out" | grep -Fq '"command": "insert"' && ! printf '%s' "$ins_out" | grep -Fq "not in this slice"; then
  say "insert books: handler ran (exit 10)"
else
  fail "host insert exited ${ins_code:-0} with its slice refusal or no receipt"
fi

if [ "$failures" -gt 0 ]; then
  say "RED: $failures control(s) fail"
  exit 1
fi
say "GREEN: every node-free control holds"

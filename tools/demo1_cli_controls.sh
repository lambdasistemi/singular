#!/usr/bin/env bash
# The ordinary CLI's refusal controls (#299): a second insertion of an
# Active key and an insertion of a Terminal key, each beside an accepting
# control, against one generated development node.
#
# usage: demo1_cli_controls.sh SINGULAR DEVNET CLI_CONTROLS BLUEPRINT LEDGER WORKDIR
#
# This script only arranges processes: one node, one funded wallet, and
# one `cli-controls run`, which runs the story, leaves one receipt per
# action under WORKDIR/receipts and judges every clause from them. The
# verdict section is WORKDIR/controls.md. Setup failures (no node, no
# socket) exit 3 and are never a verdict.
set -euo pipefail

[ "$#" -eq 6 ] || {
  echo "usage: $0 SINGULAR DEVNET CLI_CONTROLS BLUEPRINT LEDGER WORKDIR" >&2
  exit 2
}
singular="$1"
devnet="$2"
controls="$3"
blueprint="$4"
ledger="$5"
work="$6"
[ ! -e "$work" ] || {
  echo "controls: $work exists; every run takes a fresh directory" >&2
  exit 2
}
mkdir -p "$work"

setup_fail() {
  echo "controls: SETUP: $*" >&2
  exit 3
}
say() { echo "controls: $*"; }

od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$work/wallet.skey"
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$work/stranger.skey"

export TMPDIR="$work"
"$devnet" --fund-skey "$work/wallet.skey" --fund-skey "$work/stranger.skey" --fund-outputs 8 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
trap 'kill "$devnet_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
sock=""
for _ in $(seq 1 900); do
  sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  [ -n "$sock" ] && [ -S "$sock" ] && break
  kill -0 "$devnet_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$sock" ] || [ ! -S "$sock" ]; then
  tail -40 "$work/devnet.err" >&2 || true
  setup_fail "the development node never printed a usable socket"
fi
say "one development node at $sock"

status=0
"$controls" run \
  --singular "$singular" --blueprint "$blueprint" --ledger "$ledger" \
  --node-socket "$sock" --network-magic 42 --wallet-skey "$work/wallet.skey" --stranger-skey "$work/stranger.skey" \
  --work "$work" >"$work/controls.md" 2> >(tee "$work/controls.err" >&2) || status=$?
tail -1 "$work/controls.md"
say "verdict section at $work/controls.md (exit $status)"
exit "$status"

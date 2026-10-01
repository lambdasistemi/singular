# shellcheck shell=bash
# #326 R5: the contract suite's external leg.
#
# A devnet is started here as a process of its own, funding a fresh key
# with outputs in blocks; the suite is then handed only the socket path the
# devnet printed, the network magic and the key file — the three settings a
# singular write takes — and builds the node and indexer adapters from
# them. The suite starts no node of its own on this leg.
work="$(mktemp -d)"
devnet_pid=""
cleanup() {
  if [ -n "$devnet_pid" ]; then
    kill "$devnet_pid" 2>/dev/null || true
    wait "$devnet_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

key="$work/funded.skey"
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$key"

# The devnet keeps its node under $TMPDIR/cardano-e2e; a private TMPDIR keeps
# it apart from any other devnet on the host.
mkdir -p "$work/tmp"

TMPDIR="$work/tmp" devnet --fund-skey "$key" --fund-outputs 3 --fund-lovelace 1000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!

sock=""
for _ in $(seq 1 1200); do
  sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  if [ -n "$sock" ] && [ -S "$sock" ]; then
    break
  fi
  if ! kill -0 "$devnet_pid" 2>/dev/null; then
    cat "$work/devnet.err" >&2
    echo "contract-external: the devnet exited before printing its socket" >&2
    exit 1
  fi
  sleep 0.5
done
if [ -z "$sock" ] || [ ! -S "$sock" ]; then
  cat "$work/devnet.err" >&2
  echo "contract-external: no devnet socket within ten minutes" >&2
  exit 1
fi
echo "contract-external: devnet pid $devnet_pid at $sock, funded key generated"

contract-tests --node-socket "$sock" --network-magic 42 --wallet-skey "$key"

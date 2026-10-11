#!/usr/bin/env bash
# negative-host-ordinary (row 6a): ordinary executables cannot reach the bypass.
# (a) built ordinary exes contain no host module, read from the built
#     executables, with a positive control on singular-negative;
# (b) nix closure of each ordinary exe contains no host store path;
# (c) bypass spellings refused by the ordinary parser;
# (d) no module defined both in host and shared sources.
# usage: negative_host_ordinary.sh REPO-ROOT
set -euo pipefail
[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$1"
cd "$root"

fail() {
  echo "negative-host-ordinary: FAIL: $*" >&2
  exit 1
}

singular_bin="$(nix build --quiet --no-link --print-out-paths ./offchain#singular)/bin/singular"
opendatum_bin="$(nix build --quiet --no-link --print-out-paths ./applications/open-datum/offchain#open-datum)/bin/open-datum"
host_bin="$(nix build --quiet --no-link --print-out-paths ./applications/open-datum/offchain#singular-negative)/bin/singular-negative"
[ -x "$singular_bin" ] || fail "singular binary missing"
[ -x "$opendatum_bin" ] || fail "open-datum binary missing"
[ -x "$host_bin" ] || fail "singular-negative binary missing"
tmp_singular_strings="$(mktemp)"
tmp_opendatum_strings="$(mktemp)"
tmp_host_strings="$(mktemp)"

# (a) No host code in the ordinary binary; positive control on host.
# Host-only strings (negative flags, slice refusals) and module names are
# read from the built executables. Strings are spooled to files first:
# with pipefail a strings|grep -q pipeline fails on SIGPIPE when grep
# exits early, so grep never runs on a pipe here.
strings "$singular_bin" >"$tmp_singular_strings"
strings "$opendatum_bin" >"$tmp_opendatum_strings"
strings "$host_bin" >"$tmp_host_strings"
if grep -q -- "--tamper\|--pay-short\|in this slice\|Negative\.Craft\|Negative\.Parse" "$tmp_singular_strings"; then
  rm -f "$tmp_singular_strings" "$tmp_opendatum_strings" "$tmp_host_strings"
  fail "ordinary singular contains host code"
fi
if grep -q -- "--tamper\|--pay-short\|in this slice\|Negative\.Craft\|Negative\.Parse" "$tmp_opendatum_strings"; then
  rm -f "$tmp_singular_strings" "$tmp_opendatum_strings" "$tmp_host_strings"
  fail "ordinary open-datum contains host code"
fi
grep -q -- "--tamper" "$tmp_host_strings" \
  || {
    rm -f "$tmp_singular_strings" "$tmp_opendatum_strings" "$tmp_host_strings"
    fail "control: host binary does not contain --tamper"
  }
rm -f "$tmp_singular_strings" "$tmp_opendatum_strings" "$tmp_host_strings"
echo "negative-host-ordinary: (a) no host code in ordinary exes"

# (b) Closure contains no host store path.
host_store="$(nix build --quiet --no-link --print-out-paths ./applications/open-datum/offchain#singular-negative)"
singular_closure="$(nix path-info -r "$singular_bin" 2>/dev/null || nix-store -qR "$singular_bin")"
if printf '%s\n' "$singular_closure" | grep -qx "$host_store"; then
  fail "ordinary singular closure contains the host store path $host_store"
fi
opendatum_closure="$(nix path-info -r "$opendatum_bin" 2>/dev/null || nix-store -qR "$opendatum_bin")"
if printf '%s\n' "$opendatum_closure" | grep -qx "$host_store"; then
  fail "ordinary open-datum closure contains the host store path $host_store"
fi
host_closure="$(nix path-info -r "$host_store" 2>/dev/null || nix-store -qR "$host_store")"
printf '%s\n' "$host_closure" | grep -qx "$host_store" \
  || fail "control: host closure does not contain its own store path"
echo "negative-host-ordinary: (b) no host store path in ordinary closure"

# (c) Bypass spellings refused by the ordinary parser.
cd "$root"
"$singular_bin" registry withdraw --state-dir /tmp/nope --blueprint /tmp/nope \
  --key k --state-token p.n --koios-url http://x --network-magic 42 \
  --wallet-skey /tmp/nope >/tmp/neg-ord-withdraw.out 2>&1 || true
grep -qi "not a command singular supports" /tmp/neg-ord-withdraw.out \
  || fail "(c) ordinary accepted 'registry withdraw' (out: $(head -n 1 /tmp/neg-ord-withdraw.out))"
"$singular_bin" registry update --tamper controller --state-dir /tmp/nope --blueprint /tmp/nope \
  --key k --state-token p.n --payload /tmp/nope --koios-url http://x --network-magic 42 \
  --wallet-skey /tmp/nope >/tmp/neg-ord-tamper.out 2>&1 || true
grep -qi "is not a flag singular reads" /tmp/neg-ord-tamper.out \
  || fail "(c) ordinary accepted '--tamper' (out: $(head -n 1 /tmp/neg-ord-tamper.out))"
"$singular_bin" registry fold --pay-short 1 --state-dir /tmp/nope --blueprint /tmp/nope \
  --state-token p.n --koios-url http://x --network-magic 42 \
  --wallet-skey /tmp/nope >/tmp/neg-ord-short.out 2>&1 || true
grep -qi "is not a flag singular reads" /tmp/neg-ord-short.out \
  || fail "(c) ordinary accepted '--pay-short' (out: $(head -n 1 /tmp/neg-ord-short.out))"
"$opendatum_bin" open-datum withdraw --state-dir /tmp/nope --blueprint /tmp/nope \
  --key k --state-token p.n --koios-url http://x --network-magic 42 \
  --wallet-skey /tmp/nope >/tmp/neg-ord-od-withdraw.out 2>&1 || true
grep -qi "not a command" /tmp/neg-ord-od-withdraw.out \
  || fail "(c) open-datum accepted 'open-datum withdraw' (out: $(head -n 1 /tmp/neg-ord-od-withdraw.out))"
"$opendatum_bin" open-datum update --tamper controller --state-dir /tmp/nope --blueprint /tmp/nope \
  --key k --state-token p.n --payload /tmp/nope --koios-url http://x --network-magic 42 \
  --wallet-skey /tmp/nope >/tmp/neg-ord-od-tamper.out 2>&1 || true
grep -qi "is not a flag" /tmp/neg-ord-od-tamper.out \
  || fail "(c) open-datum accepted '--tamper' (out: $(head -n 1 /tmp/neg-ord-od-tamper.out))"
"$opendatum_bin" open-datum fold --pay-short 1 --state-dir /tmp/nope --blueprint /tmp/nope \
  --state-token p.n --koios-url http://x --network-magic 42 \
  --wallet-skey /tmp/nope >/tmp/neg-ord-od-short.out 2>&1 || true
grep -qi "is not a flag" /tmp/neg-ord-od-short.out \
  || fail "(c) open-datum accepted '--pay-short' (out: $(head -n 1 /tmp/neg-ord-od-short.out))"
echo "negative-host-ordinary: (c) bypass spellings refused by ordinary"

# (d) No duplicated module name between host and shared sources.
host_modules="$(cd "$root/applications/open-datum/negative/src" && find . -name '*.hs' | sed 's|^\./||; s|/|.|g; s|\.hs$||' | sort)"
registry_modules="$(cd "$root/offchain/cli/src" && find . -name '*.hs' | sed 's|^\./||; s|/|.|g; s|\.hs$||' | sort)"
od_modules="$(cd "$root/applications/open-datum/offchain/src" && find . -name '*.hs' | sed 's|^\./||; s|/|.|g; s|\.hs$||' | sort)"
shared_modules="$(printf '%s\n%s\n' "$registry_modules" "$od_modules" | sort -u)"
dup="$(comm -12 <(printf '%s\n' "$host_modules") <(printf '%s\n' "$shared_modules") || true)"
[ -z "$dup" ] || fail "(d) duplicated module(s): $dup"
echo "negative-host-ordinary: (d) no duplicated module names"

echo "negative-host-ordinary: PASS"

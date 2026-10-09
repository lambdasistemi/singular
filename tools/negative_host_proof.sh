#!/usr/bin/env bash
# Proof for #358 first slice (commit-owner): the slice subject, executed.
# Rows: gate 1 (host builds; parts discovery fails closed on empty),
# row 6a (negative-host-ordinary), row 6d (negative-host-lint).
# Expected oracle: specs/358-singular-negative/tasks.md first slice.
# Tree presence (a cabal file existing) is a lead, never a proving leg:
# every leg below executes its subject. Failure text lands in the receipt
# directory given as $2 (default: a fresh temp dir), never /tmp fixed paths.
# usage: negative_host_proof.sh REPO-ROOT [RECEIPT-DIR]
set -u

root="$1"
receipts="${2:-$(mktemp -d)}"
mkdir -p "$receipts"
cd "$root" || exit 1
failures=0
durations="$receipts/durations.txt"
: >"$durations"
leg_start=0
begin_leg() { leg_start=$(date +%s); }
end_leg() {
  printf '%s %ss\n' "$1" "$(($(date +%s) - leg_start))" >>"$durations"
}

say() { printf 'PROOF: %s\n' "$*"; }

# 1. The host builds from the offchain flake (executes the build subject).
begin_leg
if (cd "$root/offchain" && nix build --quiet --no-link --print-out-paths .#singular-negative) >"$receipts/host-build.out" 2>"$receipts/host-build.err"; then
  say "host builds from the offchain flake"
  end_leg host-build
else
  end_leg host-build
  say "FAIL: nix build offchain#singular-negative failed (see host-build.err)"
  failures=$((failures + 1))
fi

# 2. Discovery lists the first-slice part (executes the parts subject).
begin_leg
if nix run --quiet .#negative-host-parts >"$receipts/parts.out" 2>"$receipts/parts.err"; then
  if grep -q stranger-updates-the-key "$receipts/parts.out"; then
    say "parts list carries stranger-updates-the-key"
    end_leg parts
  else
    end_leg parts
    say "FAIL: parts list misses stranger-updates-the-key"
    failures=$((failures + 1))
  fi
else
  end_leg parts
  say "FAIL: negative-host-parts exited non-zero (see parts.err)"
  failures=$((failures + 1))
fi

# Positive control: the discovery non-empty assertion can fail.
if printf '{"part":[]}' | jq -e '.part | length > 0' >/dev/null 2>&1; then
  say "FAIL: control: empty parts list passed the non-empty assertion"
  failures=$((failures + 1))
else
  say "control: empty parts list fails the non-empty assertion — check can fail"
fi

# 3. Ordinary executables cannot reach the bypass (executes row 6a).
begin_leg
if nix run --quiet .#negative-host-ordinary >"$receipts/ordinary.out" 2>"$receipts/ordinary.err"; then
  say "ordinary check green"
  end_leg ordinary
else
  end_leg ordinary
  say "FAIL: negative-host-ordinary not green (see ordinary.err)"
  failures=$((failures + 1))
fi

# 4. Host sources build, format and lint (executes row 6d).
begin_leg
if nix run --quiet .#negative-host-lint >"$receipts/lint.out" 2>"$receipts/lint.err"; then
  say "host lint green"
  end_leg lint
else
  end_leg lint
  say "FAIL: negative-host-lint not green (see lint.err)"
  failures=$((failures + 1))
fi

# 5. The three negative forms refuse bad values without a node: bogus
# tamper, non-positive pay-short values and an unknown subcommand, each
# with its refusal text and exit 2.
begin_leg
host_bin="$(cat "$receipts/host-build.out")/bin/singular-negative"
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
if [ "$parse_ok" -eq 0 ]; then
  say "parse refusals green without a node"
  end_leg parse
else
  end_leg parse
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  say "RED: $failures leg(s) fail"
  exit 1
fi
say "GREEN: every proving leg holds; receipts in $receipts"

#!/usr/bin/env bash
# installed-journey (#747): the registration journey played from a release's own
# files on a machine without Nix. `singular`, `open-datum`, the development node
# and the deployment blueprint come out of the Linux release bundle or out of
# the installed Linux package; the journey runs on a PATH that holds ordinary
# tools and no Nix, from a fresh working directory and home, as a user who has
# only the release would play it.
#
# usage: installed_journey.sh tarball TARBALL WORK
#        installed_journey.sh package WORK
#
# tarball   TARBALL is singular-VERSION-SYSTEM.tar.gz, unpacked under WORK. The
#           commands are its bin/, the blueprint its share/plutus.json and the
#           genesis of the node its share/devnet/genesis.
# package   the Debian package is already installed with the system package
#           manager. The commands are resolved from /usr/bin, the blueprint is
#           /usr/share/singular/plutus.json, and every one of them must be a
#           file the package owns.
#
# WORK must not exist. The harness (the journey, its rig and the chain view)
# is the one beside this script, in a checkout; it is a reader and a judge, not
# a program under test, and the first thing the run shows is that no command,
# blueprint or node it plays comes from the checkout or from a Nix store the
# machine already had (the hosted job shows the machine has no /nix before it
# starts). INSTALLED_JOURNEY_PATH names the ordinary tools (default
# /usr/local/bin:/usr/bin:/bin); it must hold jq, python3 and procps.
#
# Kept under WORK, whatever the outcome: provenance.txt (what each program
# resolved to), journey/verdicts.md, journey/creation-measurement.json,
# journey/receipt.md and journey/receipts/.
#
# Exit 0 when the journey passes; the journey's own status otherwise (1 a
# clause does not hold, 3 a setup failure); 2 on usage or when the programs
# are not the release's.
set -euo pipefail

usage() {
  echo "usage: $0 tarball TARBALL WORK | $0 package WORK" >&2
  exit 2
}
fail() {
  echo "installed-journey: FAIL $*" >&2
  exit 2
}
[ "$#" -ge 1 ] || usage
leg="$1"
case "$leg" in
  tarball) [ "$#" -eq 3 ] || usage ;;
  package) [ "$#" -eq 2 ] || usage ;;
  *) usage ;;
esac
tools="$(cd "$(dirname "$0")" && pwd)"
checkout="$(cd "$tools/.." && pwd)"
candidate="$checkout/specs/745-shared-publications/evidence/candidate.json"
ordinary="${INSTALLED_JOURNEY_PATH:-/usr/local/bin:/usr/bin:/bin}"
work="${*: -1}"
[ ! -e "$work" ] || fail "$work exists; every run takes a fresh directory"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
provenance="$work/provenance.txt"

# no_nix PATH: no directory of PATH holds a Nix.
no_nix() {
  ! PATH="$1" command -v nix >/dev/null 2>&1
}
# under_release ROOT PROGRAM: the program resolves to a file inside ROOT, and
# ROOT is neither a Nix store nor the checkout.
under_release() {
  local resolved
  resolved="$(readlink -f "$2")"
  case "$1/" in /nix/store/* | "$checkout"/*) return 1 ;; esac
  case "$resolved" in "$1"/*) [ -e "$resolved" ] ;; *) return 1 ;; esac
}
# owned_by_package PACKAGE PATH: the system package manager lists the resolved
# file as installed by the package.
owned_by_package() {
  dpkg -S "$(readlink -f "$2")" 2>/dev/null | grep -q "^$1: "
}
# prove NAME TEST OWNER PROGRAM: print what the program resolved to, and refuse
# when TEST does not accept it as a file of the release.
prove() {
  local name="$1" program="$4"
  shift
  if "$@"; then
    printf '%s: %s -> %s\n' "$name" "$program" "$(readlink -f "$program")" >>"$provenance"
  else
    fail "$name ($program, resolved to $(readlink -f "$program")) is not a file of the release"
  fi
}

: >"$provenance"
no_nix "$ordinary" || fail "the PATH $ordinary holds a nix"
echo "no nix on the PATH $ordinary" >>"$provenance"

case "$leg" in
  tarball)
    [ -f "$2" ] || fail "no tarball at $2"
    mkdir -p "$work/unpacked"
    tar -xzf "$2" -C "$work/unpacked"
    [ "$(find "$work/unpacked" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] \
      || fail "$2 does not hold exactly one top directory"
    bundle="$(find "$work/unpacked" -mindepth 1 -maxdepth 1)"
    singular="$bundle/bin/singular"
    open_datum="$bundle/bin/open-datum"
    devnet="$bundle/bin/devnet"
    blueprint="$bundle/share/plutus.json"
    genesis="$bundle/share/devnet/genesis"
    root="$bundle"
    for program in "$singular" "$open_datum" "$devnet" "$bundle/bin/cardano-node" "$blueprint"; do
      prove "$(basename "$program")" under_release "$root" "$program"
    done
    # the control of the proof: a file of the checkout, and an ordinary tool of
    # this machine, are not the release's
    ! under_release "$root" "$tools/installed_journey.sh" || fail "the proof accepted a file of the checkout"
    ! under_release "$root" "$(PATH="$ordinary" command -v env)" || fail "the proof accepted an ordinary tool"
    ;;
  package)
    root=/usr
    singular=/usr/bin/singular
    open_datum=/usr/bin/open-datum
    devnet=/usr/bin/devnet
    blueprint=/usr/share/singular/plutus.json
    for program in singular open-datum devnet; do
      [ "$(PATH="/usr/bin:$ordinary" command -v "$program")" = "/usr/bin/$program" ] \
        || fail "command -v $program does not name /usr/bin/$program"
    done
    for program in "$singular" "$open_datum" "$devnet" "$blueprint"; do
      prove "$(basename "$program")" owned_by_package singular "$program"
    done
    # the control of the proof: a file of the checkout, and an ordinary tool of
    # this machine, are not the package's
    ! owned_by_package singular "$tools/installed_journey.sh" || fail "the proof accepted a file of the checkout"
    ! owned_by_package singular "$(PATH="$ordinary" command -v env)" || fail "the proof accepted an ordinary tool"
    # the genesis the development node starts from is the package's own
    genesis="$(dirname "$(dpkg -L singular | grep -- '-genesis/node-config\.json$' | head -n 1)")"
    [ -f "$genesis/node-config.json" ] || fail "the package carries no genesis directory"
    ;;
esac
# the control of the other proof: a directory holding a nix is seen
fake="$(mktemp -d)"
printf '#!/bin/sh\n' >"$fake/nix"
chmod +x "$fake/nix"
! no_nix "$fake:$ordinary" || fail "the proof did not see a nix on the PATH"
rm -rf "$fake"
# no node but the release's is on the machine to be found by name
! PATH="$ordinary" command -v cardano-node >/dev/null 2>&1 || fail "the machine holds a cardano-node of its own"
cat "$provenance"

# The harness: the journey and what it sources, from the checkout, with the
# creation candidate beside the chain view as the journey expects.
harness="$work/harness"
mkdir -p "$harness"
cp "$tools"/*.sh "$tools"/*.py "$harness"/
cp "$candidate" "$harness/creation-candidate.json"

mkdir -p "$work/cwd" "$work/home"
scratch="$(mktemp -d /tmp/installed-journey.XXXXXX)"
trap 'chmod -R u+rwx "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
status=0
(
  cd "$work/cwd"
  env -i HOME="$work/home" TMPDIR="$scratch" PATH="$ordinary" LC_ALL=C.UTF-8 E2E_GENESIS_DIR="$genesis" \
    bash "$harness/no_pin_registration_journey.sh" \
    "$singular" "$open_datum" "$devnet" "$blueprint" "$harness/no_pin_chain_view.py" "$work/journey"
) || status=$?
[ "$status" -eq 0 ] \
  || {
    echo "installed-journey: the journey exited $status; receipts in $work/journey" >&2
    exit "$status"
  }
echo "installed-journey: PASS — the registration journey from the $leg alone (programs, node and blueprint), no Nix on the PATH"

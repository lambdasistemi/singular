#!/usr/bin/env bash
# verify-release (#326): check a published Singular release from its
# downloaded bytes alone.
#
# usage: verify-release [--assets DIR] [--work DIR] TAG
#
# TAG is a release tag, vX.Y.Z. The release's three assets —
# singular-docs-X.Y.Z.tar.gz, singular-onchain-X.Y.Z.tar.gz and SHA256SUMS —
# are downloaded from the GitHub release without authentication, or, with
# --assets DIR, read from DIR instead: that is the only step the option
# changes. Then, in order, each check stopping the run on refusal:
#
#   sums            SHA256SUMS lists exactly the two archives and both match;
#                   the on-chain archive's own SHA256SUMS covers every file
#                   it carries and every file matches
#   model revision  the archive's MODEL-REVISION names the application model
#                   commit the conformance evidence is compiled against
#   members         the run page, the offchain flake, the command's source
#                   and the compiled registry blueprint are present
#   journey         `singular` and the development node are built from the
#                   archive's own offchain flake, and create, insert, update,
#                   terminate and inspect run as separate processes on one
#                   generated development network (demo1_cli_journey.sh)
#
# The archive is extracted under --work DIR (a fresh temporary directory
# when not given), which must not lie inside a git checkout.
#
# Exit 0 and a `verify-release: PASS` line when every check passes; exit 1
# and one `verify-release: REFUSED <name>: <detail>` line when one refuses.
# The names: download-failed, sum-mismatch, model-revision-missing,
# model-revision-mismatch, member-missing, command-failed. Exit 2 on usage.
set -euo pipefail

usage() {
  echo "usage: verify-release [--assets DIR] [--work DIR] TAG" >&2
  exit 2
}
assets=""
work=""
tag=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --assets)
      [ "$#" -ge 2 ] || usage
      assets="$2"
      shift 2
      ;;
    --work)
      [ "$#" -ge 2 ] || usage
      work="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      [ -z "$tag" ] || usage
      tag="$1"
      shift
      ;;
  esac
done
[[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || usage
version="${BASH_REMATCH[1]}"
repo="${VERIFY_RELEASE_REPOSITORY:-lambdasistemi/singular}"
journey="${VERIFY_RELEASE_JOURNEY:?verify-release needs VERIFY_RELEASE_JOURNEY}"
expected_revision="$(cat "${VERIFY_RELEASE_MODEL_REVISION:?verify-release needs VERIFY_RELEASE_MODEL_REVISION}")"

refuse() {
  echo "verify-release: REFUSED $1: $2"
  exit 1
}
pass() { echo "verify-release: $1: PASS${2:+ — $2}"; }

if [ -z "$work" ]; then
  work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/verify-release.XXXXXX")"
fi
mkdir -p "$work"
work="$(cd "$work" && pwd)"
if git -C "$work" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "verify-release: --work $work lies inside a git checkout" >&2
  exit 2
fi
download="$work/assets"
extracted="$work/extracted"
rm -rf "$download" "$extracted"
mkdir -p "$download" "$extracted"

docs="singular-docs-$version.tar.gz"
onchain="singular-onchain-$version.tar.gz"
for name in SHA256SUMS "$docs" "$onchain"; do
  if [ -n "$assets" ]; then
    [ -f "$assets/$name" ] || refuse download-failed "$name is not in $assets"
    cp "$assets/$name" "$download/$name"
  else
    curl -fsSL --retry 3 -o "$download/$name" \
      "https://github.com/$repo/releases/download/$tag/$name" \
      || refuse download-failed "$name of $tag from github.com/$repo"
  fi
done
echo "verify-release: $tag from ${assets:-github.com/$repo}"

# sums
listed="$(cut -d' ' -f3- "$download/SHA256SUMS" | LC_ALL=C sort | tr '\n' ' ')"
[ "$listed" = "$docs $onchain " ] \
  || refuse sum-mismatch "SHA256SUMS lists [${listed% }], not exactly $docs and $onchain"
(cd "$download" && sha256sum --check --strict --quiet SHA256SUMS) >"$work/sums.log" 2>&1 \
  || refuse sum-mismatch "$(tr '\n' ' ' <"$work/sums.log")"
tar -xzf "$download/$onchain" -C "$extracted" \
  || refuse sum-mismatch "$onchain does not extract"
[ -f "$extracted/SHA256SUMS" ] || refuse sum-mismatch "$onchain carries no SHA256SUMS"
carried="$(cd "$extracted" && find . -type f ! -path ./SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort)"
covered="$(cut -d' ' -f3- "$extracted/SHA256SUMS" | LC_ALL=C sort)"
[ "$carried" = "$covered" ] \
  || refuse sum-mismatch "$onchain's SHA256SUMS does not cover exactly the files it carries"
(cd "$extracted" && sha256sum --check --strict --quiet SHA256SUMS) >"$work/inner-sums.log" 2>&1 \
  || refuse sum-mismatch "$onchain: $(tr '\n' ' ' <"$work/inner-sums.log")"
pass sums "$(cut -c1-64 "$download/SHA256SUMS" | paste -sd ' ')"

# model revision
[ -f "$extracted/MODEL-REVISION" ] \
  || refuse model-revision-missing "$onchain states no MODEL-REVISION; the conformance evidence names $expected_revision"
stated="$(cat "$extracted/MODEL-REVISION")"
[ "$stated" = "$expected_revision" ] \
  || refuse model-revision-mismatch "$onchain states $stated; the conformance evidence names $expected_revision"
pass "model revision" "$stated"

# members
for member in DEMO1.md offchain/flake.nix offchain/flake.lock offchain/cli/Main.hs onchain/plutus.json; do
  [ -f "$extracted/$member" ] || refuse member-missing "$onchain carries no $member"
done
pass members

# journey
cd "$extracted/offchain"
singular="$(nix build --quiet --no-link --print-out-paths .#singular 2>"$work/build-singular.log")" \
  || refuse command-failed "nix build .#singular from the archive: $(tail -n 3 "$work/build-singular.log" | tr '\n' ' ')"
devnet="$(nix build --quiet --no-link --print-out-paths .#devnet 2>"$work/build-devnet.log")" \
  || refuse command-failed "nix build .#devnet from the archive: $(tail -n 3 "$work/build-devnet.log" | tr '\n' ' ')"
status=0
bash "$journey" "$singular/bin/singular" "$devnet/bin/devnet" "$extracted/onchain/plutus.json" "$work/journey" \
  || status=$?
[ "$status" -eq 0 ] || refuse command-failed "the journey exited $status; receipts in $work/journey/receipts"
pass journey "create, insert, update, terminate and inspect as separate processes"

echo "verify-release: PASS $tag — sums, model revision $stated, members and the journey, from $extracted"

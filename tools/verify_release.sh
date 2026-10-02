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
#   build           `singular` and the development node are built from the
#                   archive's own offchain flake
#   journey         create, insert, update, terminate and inspect run as
#                   separate processes on one generated development network
#                   (demo1_cli_journey.sh)
#   harness hooks   computed from that run: every process of the five
#                   commands ran at least once with no SINGULAR_HARNESS_*
#                   variable set, and the hold points that fired (each
#                   leaves PATH.waiting) are exactly the ones a process was
#                   started with a variable for
#
# The archive is extracted under --work DIR (a fresh temporary directory,
# removed at exit, when not given), which must not lie inside a git checkout.
#
# Exit 0 and a `verify-release: PASS` line when every check passes; exit 1
# and one `verify-release: REFUSED <name>: <detail>` line when one refuses.
# The names: download-failed, sum-mismatch, model-revision-missing,
# model-revision-mismatch, member-missing, command-failed,
# harness-hook-fired. Exit 2 on usage.
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

temporary=false
if [ -z "$work" ]; then
  work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/verify-release.XXXXXX")"
  temporary=true
  trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fi
mkdir -p "$work"
work="$(cd "$work" && pwd)"
kept=""
$temporary || kept="; receipts in $work/journey/receipts"
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
carried="$(cd "$extracted" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort)"
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

# build
cd "$extracted/offchain"
singular="$(nix build --quiet --no-link --print-out-paths .#singular 2>"$work/build-singular.log")" \
  || refuse command-failed "nix build .#singular from the archive: $(tail -n 3 "$work/build-singular.log" | tr '\n' ' ')"
devnet="$(nix build --quiet --no-link --print-out-paths .#devnet 2>"$work/build-devnet.log")" \
  || refuse command-failed "nix build .#devnet from the archive: $(tail -n 3 "$work/build-devnet.log" | tr '\n' ' ')"
pass build "singular and the development node from the archive's own flake"

# journey
# Every `singular` process the journey starts goes through a wrapper that
# records which SINGULAR_HARNESS_* variables it was started with, and the
# path each hold variable names, before it replaces itself with the
# released executable (so a process the journey kills is that executable).
invocations="$work/invocations.tsv"
: >"$invocations"
mkdir -p "$work/bin"
cat >"$work/bin/singular" <<WRAPPER
#!/usr/bin/env bash
harness="\$(env | grep -o '^SINGULAR_HARNESS_[A-Z_]*' | LC_ALL=C sort | paste -sd, - || true)"
holds="\$(env | grep '^SINGULAR_HARNESS_HOLD_' | grep -v '^SINGULAR_HARNESS_HOLD_STEP=' | cut -d= -f2- | paste -sd'|' - || true)"
printf '%s\t%s\t%s\n' "\${1:-} \${2:-}" "\$harness" "\$holds" >>$(printf '%q' "$invocations")
exec $(printf '%q' "$singular/bin/singular") "\$@"
WRAPPER
chmod +x "$work/bin/singular"
status=0
bash "$journey" "$work/bin/singular" "$devnet/bin/devnet" "$extracted/onchain/plutus.json" "$work/journey" \
  || status=$?
[ "$status" -eq 0 ] || refuse command-failed "the journey exited $status$kept"
pass journey "create, insert, update, terminate and inspect as separate processes"

# harness hooks: computed from the run. A hold point that fires writes
# PATH.waiting; the holds that fired must be exactly the ones a process was
# started with a variable for, and every process of the five commands
# started with no harness variable at all must exist.
for command in create insert update terminate inspect; do
  awk -F'\t' -v c="registry $command" '$1 == c && $2 == ""' "$invocations" | grep -q . \
    || refuse harness-hook-fired "no $command process ran without a harness variable"
done
plain="$(awk -F'\t' '$2 == ""' "$invocations" | wc -l)"
requested="$(awk -F'\t' '$3 != "" { n = split($3, p, "|"); for (i = 1; i <= n; i++) print p[i] ".waiting" }' "$invocations" | LC_ALL=C sort -u)"
[ -n "$requested" ] || refuse harness-hook-fired "the journey asked for no hold, so firing cannot be observed"
fired="$(find "$work" -path "$work/journey*" -name '*.waiting' | LC_ALL=C sort -u)"
[ "$fired" = "$requested" ] \
  || refuse harness-hook-fired "holds fired: [$(echo "$fired" | paste -sd' ' -)], requested: [$(echo "$requested" | paste -sd' ' -)]"
pass "harness hooks" "$plain processes started with none set; holds fired only where requested ($(echo "$requested" | wc -l))"

echo "verify-release: PASS $tag — sums, model revision $stated, members, the journey and its harness hooks, from $extracted"

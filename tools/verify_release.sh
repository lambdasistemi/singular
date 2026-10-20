#!/usr/bin/env bash
# verify-release (#326): check a published Singular release from its
# downloaded bytes alone.
#
# usage: verify-release [--assets DIR [--without-bundles]] [--work DIR] TAG
#
# TAG is a release tag, vX.Y.Z. The release's assets —
# singular-docs-X.Y.Z.tar.gz, singular-onchain-X.Y.Z.tar.gz, SHA256SUMS and,
# for a release that ships them (tools/release_bundles.sh), one
# singular-X.Y.Z-SYSTEM.tar.gz bundle per platform —
# are downloaded from the GitHub release without authentication, or, with
# --assets DIR, read from DIR instead: that is the only step the option
# changes. A release a pipeline step has only just assembled and not published
# carries no bundles, because the bundles are built and run by their own
# workflow: `--without-bundles`, accepted only with `--assets`, says so, and
# then SHA256SUMS must list the two archives and nothing else. Without it a
# release of a version that ships bundles is refused when one is missing,
# however it is read, and a published tag can never be verified with it.
# Then, in order, each check stopping the run on refusal:
#
#   sums            SHA256SUMS lists exactly the archives and bundles the release
#                   ships and every one matches;
#                   the on-chain archive's own SHA256SUMS covers every file
#                   it carries and every file matches
#   model revision  the archive's MODEL-REVISION names the application model
#                   commit the conformance evidence is compiled against
#   members         the run page, both flakes, both commands' sources
#                   and the compiled registry blueprint are present
#   bundles         every platform's bundle extracts, names the release and the
#                   tag's commit, and the one for this platform runs: `--version`
#                   from the executable itself names that commit, and each way the
#                   bundle can be wrong is refused (tools/verify_release_bundles.sh)
#   build           `singular`, `open-datum` and the development node are built
#                   from the archive's own flakes
#   journey         create, insert, update, terminate and inspect run as
#                   separate processes on one generated development network
#                   (demo1_cli_journey.sh)
#   release build   the stripped compiled executables contain no harness inputs,
#                   and their actual resolved registry-cli flags disable them
#   ordinary run    every command invocation is free of hidden harness inputs;
#                   no fault injection or test-only trie observation is claimed
#
# The archive is extracted under --work DIR (a fresh temporary directory,
# removed at exit, when not given), which must not lie inside a git checkout.
#
# Exit 0 and a `verify-release: PASS` line when every check passes; exit 1
# and one `verify-release: REFUSED <name>: <detail>` line when one refuses.
# The names: download-failed, sum-mismatch, model-revision-missing,
# model-revision-mismatch, member-missing, command-failed,
# harness-code-present, bundle-missing, bundle-sum-mismatch, bundle-layout,
# bundle-commit-mismatch, bundle-run-failed. Exit 2 on usage.
set -euo pipefail

usage() {
  echo "usage: verify-release [--assets DIR [--without-bundles]] [--work DIR] TAG" >&2
  exit 2
}
assets=""
work=""
tag=""
without_bundles=false
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
    --without-bundles)
      without_bundles=true
      shift
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
# a published release is never read without its bundles
if $without_bundles && [ -z "$assets" ]; then
  usage
fi
version="${BASH_REMATCH[1]}"
repo="${VERIFY_RELEASE_REPOSITORY:-lambdasistemi/singular}"
journey="${VERIFY_RELEASE_JOURNEY:?verify-release needs VERIFY_RELEASE_JOURNEY}"
binary_check="${VERIFY_RELEASE_BINARY_CHECK:?verify-release needs VERIFY_RELEASE_BINARY_CHECK}"
expected_revision="$(cat "${VERIFY_RELEASE_MODEL_REVISION:?verify-release needs VERIFY_RELEASE_MODEL_REVISION}")"
bundle_conf="${VERIFY_RELEASE_BUNDLE_CONF:?verify-release needs VERIFY_RELEASE_BUNDLE_CONF}"
bundle_verifier="${VERIFY_RELEASE_BUNDLE_VERIFIER:?verify-release needs VERIFY_RELEASE_BUNDLE_VERIFIER}"
bundle_smoke="${VERIFY_RELEASE_BUNDLE_SMOKE:?verify-release needs VERIFY_RELEASE_BUNDLE_SMOKE}"
bundle_controls="${VERIFY_RELEASE_BUNDLE_CONTROLS:?verify-release needs VERIFY_RELEASE_BUNDLE_CONTROLS}"
# shellcheck source=/dev/null
. "$bundle_conf"

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
# a release after the last one without bundles ships one per platform
bundle_names=""
if bundles_required "$version" && ! $without_bundles; then
  for system in $SYSTEMS; do bundle_names="$bundle_names singular-$version-$system.tar.gz"; done
fi
# shellcheck disable=SC2086
for name in SHA256SUMS "$docs" "$onchain" $bundle_names; do
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
if $without_bundles; then
  echo "verify-release: bundles: not part of this release (--without-bundles); SHA256SUMS must list the two archives only"
fi

# sums
listed="$(cut -d' ' -f3- "$download/SHA256SUMS" | LC_ALL=C sort | tr '\n' ' ')"
# shellcheck disable=SC2086
expected_listing="$(printf '%s\n' "$docs" "$onchain" $bundle_names | LC_ALL=C sort | tr '\n' ' ')"
[ "$listed" = "$expected_listing" ] \
  || refuse sum-mismatch "SHA256SUMS lists [${listed% }], not exactly ${expected_listing% }"
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
for member in offchain/flake.nix offchain/flake.lock offchain/cli/Main.hs applications/open-datum/offchain/flake.nix applications/open-datum/offchain/flake.lock applications/open-datum/offchain/app/Main.hs onchain/plutus.json; do
  [ -f "$extracted/$member" ] || refuse member-missing "$onchain carries no $member"
done
pass members

# bundles (#695): the platform bundles of a release that ships them, against
# the commit the tag itself names, which the on-chain archive must state too.
if [ -n "$bundle_names" ]; then
  tag_commit="${VERIFY_RELEASE_TAG_COMMIT:-}"
  if [ -z "$tag_commit" ]; then
    refs="$(git ls-remote "https://github.com/$repo.git" "refs/tags/$tag" "refs/tags/$tag^{}" 2>"$work/ls-remote.log")" \
      || refuse download-failed "the commit $tag names on github.com/$repo: $(tail -n 1 "$work/ls-remote.log")"
    tag_commit="$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ { print $1 }')"
    [ -n "$tag_commit" ] || tag_commit="$(printf '%s\n' "$refs" | awk 'NR == 1 { print $1 }')"
  fi
  [[ "$tag_commit" =~ ^[0-9a-f]{40}$ ]] \
    || refuse download-failed "the commit $tag names is [$tag_commit], not a commit"
  [ "$(cat "$extracted/RELEASE-COMMIT" 2>/dev/null)" = "$tag_commit" ] \
    || refuse bundle-commit-mismatch "$tag names $tag_commit, $onchain states $(cat "$extracted/RELEASE-COMMIT" 2>/dev/null || echo nothing)"
  status=0
  bash "$bundle_verifier" "$bundle_conf" "$bundle_smoke" "$bundle_controls" "$download" "$version" "$tag_commit" \
    >"$work/bundles.out" 2>&1 || status=$?
  cat "$work/bundles.out"
  [ "$status" -eq 0 ] || exit 1
fi

# #528 slice 4: the application's flake reaches the registry via
# ../../../offchain, which pure evaluation allows only inside a git worktree.
# The archive carries no .git, so the extracted copy is made a temporary git
# worktree for the builds below; the archive itself is untouched.
git -C "$extracted" init -q 2>"$work/git-init.log" \
  || refuse command-failed "git init in the extracted archive: $(tail -n 3 "$work/git-init.log" | tr '\n' ' ')"
git -C "$extracted" add -A 2>"$work/git-add.log" \
  || refuse command-failed "git add in the extracted archive: $(tail -n 3 "$work/git-add.log" | tr '\n' ' ')"
git -C "$extracted" -c user.email=verify@local -c user.name=verify -c commit.gpgsign=false commit -qm extracted 2>"$work/git-commit.log" \
  || refuse command-failed "git commit in the extracted archive: $(tail -n 3 "$work/git-commit.log" | tr '\n' ' ')"

# build
cd "$extracted/offchain"
singular="$(nix build --quiet --no-link --print-out-paths .#singular 2>"$work/build-singular.log")" \
  || refuse command-failed "nix build .#singular from the archive: $(tail -n 3 "$work/build-singular.log" | tr '\n' ' ')"
devnet="$(nix build --quiet --no-link --print-out-paths .#devnet 2>"$work/build-devnet.log")" \
  || refuse command-failed "nix build .#devnet from the archive: $(tail -n 3 "$work/build-devnet.log" | tr '\n' ' ')"
# #528 slice 4: `open-datum` is its own executable, built from the
# application's flake the archive carries beside the registry.
cd "$extracted/applications/open-datum/offchain"
open_datum="$(nix build --quiet --no-link --print-out-paths .#open-datum 2>"$work/build-open-datum.log")" \
  || refuse command-failed "nix build .#open-datum from the archive: $(tail -n 3 "$work/build-open-datum.log" | tr '\n' ' ')"
[ -x "$open_datum/bin/open-datum" ] \
  || refuse command-failed "open-datum binary missing from the archive build"
pass build "singular and open-datum and the development node from the archive's own flakes"

# #695: a build from the archive names the release and the commit the archive
# states. Releases before the bundles predate `--version`.
if bundles_required "$version"; then
  archive_commit="$(cat "$extracted/RELEASE-COMMIT")"
  for program in singular open-datum; do
    case "$program" in
      singular) binary="$singular/bin/singular" ;;
      *) binary="$open_datum/bin/open-datum" ;;
    esac
    printed="$("$binary" --version)" \
      || refuse command-failed "$program --version from the archive build exited non-zero"
    [ "$printed" = "$program $version (commit $archive_commit)" ] \
      || refuse command-failed "$program --version from the archive build printed [$printed], not [$program $version (commit $archive_commit)]"
  done
  pass identity "the archive build names $version and $archive_commit"
fi

# The actual compiled bytes and resolved component configuration, checked
# before any journey starts. Unset environment variables alone prove nothing.
for binary in "$singular/bin/singular" "$open_datum/bin/open-datum"; do
  label="$(basename "$binary")"
  python3 "$binary_check" "$binary" >"$work/release-build-$label.jsonl" 2>&1 \
    || refuse harness-code-present "$(tail -n 1 "$work/release-build-$label.jsonl")"
done
pass "release build" "stripped singular/open-datum bytes and actual flags exclude test controls"

# journey
# Every `singular` and `open-datum` process the journey starts goes through
# a wrapper that records which SINGULAR_HARNESS_* variables it was started
# with, and the path each hold variable names, before it replaces itself with
# the released executable (so a process the journey kills is that executable).
invocations="$work/invocations.tsv"
: >"$invocations"
mkdir -p "$work/bin"
cat >"$work/bin/singular" <<WRAPPER
#!/usr/bin/env bash
harness="\$(env | grep -o '^SINGULAR_HARNESS_[A-Z_]*' | LC_ALL=C sort | paste -sd, - || true)"
holds="\$(env | grep '^SINGULAR_HARNESS_HOLD_' | grep -v '^SINGULAR_HARNESS_HOLD_STEP=' | cut -d= -f2- | paste -sd'|' - || true)"
printf '%s\t%s\t%s\n' "singular \${1:-} \${2:-}" "\$harness" "\$holds" >>$(printf '%q' "$invocations")
exec $(printf '%q' "$singular/bin/singular") "\$@"
WRAPPER
chmod +x "$work/bin/singular"
cat >"$work/bin/open-datum" <<WRAPPER
#!/usr/bin/env bash
harness="\$(env | grep -o '^SINGULAR_HARNESS_[A-Z_]*' | LC_ALL=C sort | paste -sd, - || true)"
holds="\$(env | grep '^SINGULAR_HARNESS_HOLD_' | grep -v '^SINGULAR_HARNESS_HOLD_STEP=' | cut -d= -f2- | paste -sd'|' - || true)"
printf '%s\t%s\t%s\n' "open-datum \${1:-} \${2:-}" "\$harness" "\$holds" >>$(printf '%q' "$invocations")
exec $(printf '%q' "$open_datum/bin/open-datum") "\$@"
WRAPPER
chmod +x "$work/bin/open-datum"
# #528 slice 4: the development node reads its genesis from E2E_GENESIS_DIR,
# falling back to a relative `e2e-test/genesis` that only resolves when the
# caller happens to run from the registry tree. The archive build leaves the
# caller in the application's tree before the journey runs, so the
# genesis-only source (and every later node) would die before printing
# settings. Point the journey at the genesis the archive carries, so the
# node starts regardless of the caller's directory.
export E2E_GENESIS_DIR="$extracted/offchain/e2e-test/genesis"
status=0
bash "$journey" "$work/bin/singular" "$work/bin/open-datum" "$devnet/bin/devnet" "$extracted/onchain/plutus.json" "$work/journey" ordinary \
  || status=$?
[ "$status" -eq 0 ] || refuse command-failed "the journey exited $status$kept"
pass journey "create, insert, update, terminate and inspect as separate processes"

# The journey uses only the ordinary extracted binaries. Recovery injection
# and independent trie-capability diagnostics have their own required test
# carrier; they are not evidence from these release bytes.
for command in create insert update terminate inspect; do
  awk -F'\t' -v c="open-datum $command" 'index($1, c) == 1 && $2 == ""' "$invocations" | grep -q . \
    || refuse harness-code-present "no ordinary $command invocation was recorded"
done
if awk -F'\t' '$2 != "" || $3 != ""' "$invocations" | grep -q .; then
  refuse harness-code-present "ordinary journey received a hidden test input"
fi
fired="$(find "$work/journey" -name '*.waiting' | LC_ALL=C sort -u)"
[ -z "$fired" ] || refuse harness-code-present "ordinary journey left a harness hold marker"
plain="$(wc -l <"$invocations")"
pass "ordinary run" "$plain invocations of the actual extracted-release binaries"

echo "verify-release: PASS $tag — sums, model revision $stated, members, compiled hook exclusion and the ordinary journey, from $extracted"

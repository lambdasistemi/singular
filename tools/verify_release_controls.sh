#!/usr/bin/env bash
# verify-release-controls (#326): every refusal of `verify-release`, each
# produced by the verifier itself, by its own failure, and matched by its
# name.
#
# usage: verify_release_controls.sh RELEASE-DIR
#
# RELEASE-DIR holds a release as the pipeline assembles it (`nix run
# .#release-artifacts -- RELEASE-DIR`): the documentation archive, the
# on-chain archive and SHA256SUMS. It is never modified.
#
#   enabled test build      compiled hooks refused as harness-code-present
#   published v0.7.0         the real release, downloaded unauthenticated
#                            from GitHub; it predates the stated model
#                            revision and must be refused as
#                            model-revision-missing after its sums pass
#   sum-mismatch, three ways one byte appended to the documentation
#                            archive; one byte appended to the on-chain
#                            archive; a file inside the on-chain archive
#                            changed with the archive's own SHA256SUMS left
#                            as it was (the release's sums recomputed)
#   model-revision-missing   the on-chain archive without MODEL-REVISION
#   model-revision-mismatch  MODEL-REVISION naming another commit
#   member-missing, three ways the on-chain archive without its flake lock;
#                            without its open-datum entry point;
#                            without its singular entry point
#   command-failed, two ways the archive's offchain flake made unevaluable
#                            (the build fails, nothing runs); and the
#                            archive's compiled blueprint replaced by an
#                            empty one, so the build passes and the first
#                            `singular registry` command of the journey fails
#   bundles, three ways      a release of a version that ships bundles, read
#                            without them and not said to have none, refused as
#                            download-failed naming the first bundle; the same
#                            release said to have none (`--without-bundles`)
#                            passing every check up to the archive build and
#                            refused only there, at the identity of its version;
#                            a release said to have none but carrying a bundle
#                            refused as sum-mismatch. The flag without `--assets`
#                            is a usage refusal (exit 2): a published release
#                            is never read without its bundles
#
# Each variant is a copy of RELEASE-DIR, mutated, with the checksum
# manifests recomputed so that only the intended check can refuse it, and
# each must be refused only after every check before its own reported
# PASS: the variants that pass up to the build or the journey are the
# accepting control for every check before it. The variants are presented
# to the verifier as its download input (`--assets`, with `--without-bundles`
# because an assembled release carries none); only the published control
# downloads. Exit 0 iff every control refuses by its own name.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 RELEASE-DIR" >&2
  exit 2
}
release="$(cd "$1" && pwd)"
verify="${VERIFY_RELEASE:-verify-release}"
command -v "$verify" >/dev/null || {
  echo "verify-release-controls: FAIL: no verifier at $verify" >&2
  exit 1
}
onchain="$(cd "$release" && echo singular-onchain-*.tar.gz)"
[ -f "$release/$onchain" ] || {
  echo "verify-release-controls: FAIL: no on-chain archive in $release" >&2
  exit 1
}
version="${onchain#singular-onchain-}"
version="${version%.tar.gz}"
docs="singular-docs-$version.tar.gz"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/verify-release-controls.XXXXXX")"
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT
fail() {
  echo "verify-release-controls: FAIL: $*" >&2
  exit 1
}
before="$(sha256sum "$release"/* | sha256sum)"

# What the variants are read as: a release assembled and not published has no
# bundles, so the verifier is told so; the bundle controls change these.
staged_flags=(--without-bundles)
staged_version="$version"

# check LABEL NAME FRAGMENT PASSED NOT-PASSED — run the verifier over the
# variant LABEL (`published` downloads instead); it must exit 1, refused by
# NAME with FRAGMENT in its detail, after every stage in PASSED (a
# space-separated list) reported PASS and no stage in NOT-PASSED did.
check() {
  local label="$1" name="$2" fragment="$3" passed="$4" unpassed="$5"
  local log="$scratch/$label.log" status=0 stage line
  if [ "$label" = published ]; then
    "$verify" v0.7.0 >"$log" 2>&1 || status=$?
  else
    "$verify" --assets "$scratch/$label" ${staged_flags[@]+"${staged_flags[@]}"} "v$staged_version" >"$log" 2>&1 || status=$?
  fi
  [ "$status" -eq 1 ] \
    || fail "$label: the verifier exited $status, not 1: $(tail -n 3 "$log" | tr '\n' ' ')"
  line="$(grep '^verify-release: REFUSED ' "$log" || true)"
  case "$line" in
    "verify-release: REFUSED $name: "*"$fragment"*) ;;
    *) fail "$label: not refused as $name ($fragment): ${line:-no refusal line}" ;;
  esac
  for stage in $passed; do
    grep -q "^verify-release: ${stage//_/ }: PASS" "$log" \
      || fail "$label: refused before its ${stage//_/ } check passed"
  done
  for stage in $unpassed; do
    ! grep -q "^verify-release: ${stage//_/ }: PASS" "$log" \
      || fail "$label: its ${stage//_/ } check passed"
  done
  echo "control: $label -> $line"
}

# copy LABEL — the release as assembled, under $scratch/LABEL.
copy() {
  mkdir -p "$scratch/$1"
  cp "$release"/* "$scratch/$1/"
}

# variant LABEL MUTATOR [keep-inner] — a copy of the release whose
# extracted on-chain archive MUTATOR edits, its own SHA256SUMS recomputed
# in the assembler's format unless keep-inner, repacked, and the release's
# SHA256SUMS recomputed over both archives.
variant() {
  local label="$1" mutator="$2" keep="${3:-}" tree="$scratch/$1-tree"
  copy "$label"
  mkdir -p "$tree"
  tar -xzf "$release/$onchain" -C "$tree"
  "$mutator" "$tree"
  if [ "$keep" != keep-inner ]; then
    (cd "$tree" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort \
      | while IFS= read -r path; do sha256sum "$path"; done) >"$scratch/$label.sums"
    mv "$scratch/$label.sums" "$tree/SHA256SUMS"
  fi
  tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C "$tree" -cf - . \
    | gzip -n >"$scratch/$label/$onchain"
  (cd "$scratch/$label" && sha256sum "$docs" "$onchain" >SHA256SUMS)
}

no_model_revision() { rm "$1/MODEL-REVISION"; }
other_model_revision() { printf '%040d\n' 0 >"$1/MODEL-REVISION"; }
no_flake_lock() { rm "$1/offchain/flake.lock"; }
# #528 slice 4: the release ships both executables. Removing either entry
# point must refuse as member-missing naming that member.
no_open_datum() { rm "$1/applications/open-datum/offchain/app/Main.hs"; }
no_singular() { rm "$1/offchain/cli/Main.hs"; }
changed_readme() { printf '\n' >>"$1/README.md"; }
broken_flake() { printf '\n}\n' >>"$1/offchain/flake.nix"; }
empty_blueprint() { printf '{}\n' >"$1/onchain/plutus.json"; }
# This deliberately builds ordinary-named outputs with the real test flag
# enabled. The same compiled checker must reject that hook-bearing artifact.
test_build_enabled() {
  sed -i 's/testHarness ? false/testHarness ? true/' "$1/offchain/nix/project.nix"
}

check published model-revision-missing "states no MODEL-REVISION" "sums" "model_revision"

copy docs-byte
printf 'x' >>"$scratch/docs-byte/$docs"
check docs-byte sum-mismatch "$docs" "" "sums"

copy onchain-byte
printf 'x' >>"$scratch/onchain-byte/$onchain"
check onchain-byte sum-mismatch "$onchain" "" "sums"

variant inner-file changed_readme keep-inner
check inner-file sum-mismatch "README.md" "" "sums"

variant no-revision no_model_revision
check no-revision model-revision-missing "states no MODEL-REVISION" "sums" "model_revision"

variant other-revision other_model_revision
check other-revision model-revision-mismatch "states 0000000000000000000000000000000000000000" "sums" "model_revision"

variant no-flake-lock no_flake_lock
check no-flake-lock member-missing "offchain/flake.lock" "sums model_revision" "members"

variant no-open-datum no_open_datum
check no-open-datum member-missing "applications/open-datum/offchain/app/Main.hs" "sums model_revision" "members"

variant no-singular no_singular
check no-singular member-missing "offchain/cli/Main.hs" "sums model_revision" "members"

variant broken-flake broken_flake
check broken-flake command-failed "nix build .#singular" "sums model_revision members" "build"

variant empty-blueprint empty_blueprint
check empty-blueprint command-failed "the journey exited" "sums model_revision members build" "journey"

variant test-build-enabled test_build_enabled
check test-build-enabled harness-code-present "release-binary: REFUSED" "sums model_revision members build" "release_build journey"

# the bundle rule, at a version that ships bundles whatever the current one is
mkdir -p "$scratch/bundles-missing"
cp "$release/$onchain" "$scratch/bundles-missing/singular-onchain-99.0.0.tar.gz"
cp "$release/$docs" "$scratch/bundles-missing/singular-docs-99.0.0.tar.gz"
(cd "$scratch/bundles-missing" && sha256sum singular-docs-99.0.0.tar.gz singular-onchain-99.0.0.tar.gz >SHA256SUMS)
cp -r "$scratch/bundles-missing" "$scratch/bundles-waived"
staged_version=99.0.0
staged_flags=()
check bundles-missing download-failed "singular-99.0.0-x86_64-linux.tar.gz" "" "sums"
staged_flags=(--without-bundles)
check bundles-waived command-failed "not [singular 99.0.0 (commit" "sums model_revision members build" "release_build journey"
staged_version="$version"

copy with-bundle
printf 'x' >"$scratch/with-bundle/singular-$version-x86_64-linux.tar.gz"
(cd "$scratch/with-bundle" && sha256sum "$docs" "$onchain" "singular-$version-x86_64-linux.tar.gz" >SHA256SUMS)
check with-bundle sum-mismatch "singular-$version-x86_64-linux.tar.gz" "" "sums"

status=0
"$verify" --without-bundles "v$version" >"$scratch/flag-alone.log" 2>&1 || status=$?
[ "$status" -eq 2 ] \
  || fail "--without-bundles without --assets exited $status, not 2: $(tail -n 3 "$scratch/flag-alone.log" | tr '\n' ' ')"
echo "control: flag-alone -> usage refusal (exit 2)"

[ "$(sha256sum "$release"/* | sha256sum)" = "$before" ] || fail "the assembled release was modified"
echo "verify-release-controls: PASS — the published v0.7.0 and fourteen mutated copies of the v$version assets each refused by name, and the flag refused without --assets, after every check before its own passed; the assembled release unmodified"

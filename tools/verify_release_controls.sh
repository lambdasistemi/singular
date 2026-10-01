#!/usr/bin/env bash
# verify-release-controls (#326): every refusal of `verify-release`, each
# produced by the verifier itself and matched by its name.
#
# usage: verify_release_controls.sh RELEASE-DIR
#
# RELEASE-DIR holds a release as the pipeline assembles it (`nix run
# .#release-artifacts -- RELEASE-DIR`): the documentation archive, the
# on-chain archive and SHA256SUMS.
#
#   published v0.7.0     the real release, downloaded unauthenticated from
#                        GitHub; it predates the stated model revision and
#                        must be refused as model-revision-missing
#   sum-mismatch         one byte appended to the documentation archive
#   model-revision-missing   the on-chain archive without MODEL-REVISION
#   model-revision-mismatch  MODEL-REVISION naming another commit
#   member-missing       the on-chain archive without its DEMO1.md run page
#   command-failed       the archive's offchain flake made unevaluable; the
#                        variant must pass sums, model revision and members
#                        first, which is the accepting control for every
#                        check before the build
#
# Each variant is a copy of RELEASE-DIR, mutated, with both checksum
# manifests recomputed so that only the intended check can refuse it. The
# variants are presented to the verifier as its download input (`--assets`);
# only the published control downloads. Exit 0 iff every control refuses by
# its own name and nothing passes.
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
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/verify-release-controls.XXXXXX")"
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT
fail() {
  echo "verify-release-controls: FAIL: $*" >&2
  exit 1
}

# expect NAME LOG STAGE... — the verifier refused, by NAME, after reporting
# every STAGE as passed.
expect() {
  local name="$1" log="$2" stage
  shift 2
  grep -q "^verify-release: PASS" "$log" && fail "$name: the verifier passed"
  grep -q "^verify-release: REFUSED $name: " "$log" \
    || fail "$name: not refused by that name: $(grep '^verify-release: ' "$log" | tail -n 2 | tr '\n' ' ')"
  for stage in "$@"; do
    grep -q "^verify-release: $stage: PASS" "$log" \
      || fail "$name: refused before its $stage check passed"
  done
  echo "control: $name refused by name ($(grep "^verify-release: REFUSED $name: " "$log"))"
}

# run LABEL ARGS... — the verifier's output in $scratch/LABEL.log; its exit
# must be 1, a refusal, never a usage or setup error.
run() {
  local label="$1" status=0
  shift
  "$verify" "$@" >"$scratch/$label.log" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "$label: the verifier exited $status, not 1: $(tail -n 3 "$scratch/$label.log" | tr '\n' ' ')"
}

# variant LABEL MUTATOR — a copy of the release whose extracted on-chain
# archive MUTATOR edits, repacked and re-summed in the assembler's format.
variant() {
  local label="$1" mutator="$2" dir="$scratch/$1" tree="$scratch/$1-tree"
  mkdir -p "$dir" "$tree"
  cp "$release"/singular-docs-*.tar.gz "$dir/"
  tar -xzf "$release/$onchain" -C "$tree"
  "$mutator" "$tree"
  (cd "$tree" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort \
    | while IFS= read -r path; do sha256sum "$path"; done) >"$tree/SHA256SUMS.new"
  mv "$tree/SHA256SUMS.new" "$tree/SHA256SUMS"
  tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C "$tree" -cf - . \
    | gzip -n >"$dir/$onchain"
  (cd "$dir" && sha256sum singular-docs-*.tar.gz "$onchain" >SHA256SUMS)
}

no_model_revision() { rm "$1/MODEL-REVISION"; }
other_model_revision() { printf '%040d\n' 0 >"$1/MODEL-REVISION"; }
no_run_page() { rm "$1/DEMO1.md"; }
broken_flake() { printf '\n}\n' >>"$1/offchain/flake.nix"; }

# The real published release that predates the stated model revision.
run published v0.7.0
expect model-revision-missing "$scratch/published.log" sums

# One byte more in the documentation archive, the sums left as published.
mkdir -p "$scratch/sums"
cp "$release"/* "$scratch/sums/"
printf 'x' >>"$scratch/sums/singular-docs-$version.tar.gz"
run sums --assets "$scratch/sums" "v$version"
expect sum-mismatch "$scratch/sums.log"

variant no-revision no_model_revision
run no-revision --assets "$scratch/no-revision" "v$version"
expect model-revision-missing "$scratch/no-revision.log" sums

variant other-revision other_model_revision
run other-revision --assets "$scratch/other-revision" "v$version"
expect model-revision-mismatch "$scratch/other-revision.log" sums

variant no-page no_run_page
run no-page --assets "$scratch/no-page" "v$version"
expect member-missing "$scratch/no-page.log" sums "model revision"

variant broken broken_flake
run broken --assets "$scratch/broken" "v$version"
expect command-failed "$scratch/broken.log" sums "model revision" members

echo "verify-release-controls: PASS — the published v0.7.0 and five mutated copies of the v$version assets each refused by name"

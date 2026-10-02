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
#   member-missing           the on-chain archive without its DEMO1.md
#   command-failed, two ways the archive's offchain flake made unevaluable
#                            (the build fails, nothing runs); and the
#                            archive's compiled blueprint replaced by an
#                            empty one, so the build passes and the first
#                            `singular registry` command of the journey fails
#
# Each variant is a copy of RELEASE-DIR, mutated, with the checksum
# manifests recomputed so that only the intended check can refuse it, and
# each must be refused only after every check before its own reported
# PASS: the variants that pass up to the build or the journey are the
# accepting control for every check before it. The variants are presented
# to the verifier as its download input (`--assets`); only the published
# control downloads. Exit 0 iff every control refuses by its own name.
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
    "$verify" --assets "$scratch/$label" "v$version" >"$log" 2>&1 || status=$?
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
no_run_page() { rm "$1/DEMO1.md"; }
changed_run_page() { printf '\n' >>"$1/DEMO1.md"; }
broken_flake() { printf '\n}\n' >>"$1/offchain/flake.nix"; }
empty_blueprint() { printf '{}\n' >"$1/onchain/plutus.json"; }

check published model-revision-missing "states no MODEL-REVISION" "sums" "model_revision"

copy docs-byte
printf 'x' >>"$scratch/docs-byte/$docs"
check docs-byte sum-mismatch "$docs" "" "sums"

copy onchain-byte
printf 'x' >>"$scratch/onchain-byte/$onchain"
check onchain-byte sum-mismatch "$onchain" "" "sums"

variant inner-file changed_run_page keep-inner
check inner-file sum-mismatch "DEMO1.md" "" "sums"

variant no-revision no_model_revision
check no-revision model-revision-missing "states no MODEL-REVISION" "sums" "model_revision"

variant other-revision other_model_revision
check other-revision model-revision-mismatch "states 0000000000000000000000000000000000000000" "sums" "model_revision"

variant no-page no_run_page
check no-page member-missing "DEMO1.md" "sums model_revision" "members"

variant broken-flake broken_flake
check broken-flake command-failed "nix build .#singular" "sums model_revision members" "build"

variant empty-blueprint empty_blueprint
check empty-blueprint command-failed "the journey exited" "sums model_revision members build" "journey"

[ "$(sha256sum "$release"/* | sha256sum)" = "$before" ] || fail "the assembled release was modified"
echo "verify-release-controls: PASS — the published v0.7.0 and eight mutated copies of the v$version assets each refused by name, after every check before its own passed; the assembled release unmodified"

#!/usr/bin/env bash
# Negative control for the on-chain release surface.
#
# Given an assembled release directory (from `nix run .#release-artifacts --
# <out-dir>`), builds stale-surface variants and proves the release checker
# refuses each SPECIFICALLY on its surface — never accidentally at a checksum
# mismatch or an earlier setup failure. The variants, against the corrected
# availability promise (README presents the verified journey as runnable and
# discloses every retained unverified command as not currently buildable or
# verified, with the published-archive limit):
#
#   A. missing-verified-command: removes the `nix run .#journey` lines from
#      the archived README. The checker must refuse naming that phrase.
#   B. removed-disclosure: removes the whole retained-command availability
#      table and the disclosure sentences (the seven advertised commands,
#      repair-rows, connected-verifier, the not-currently-buildable-or-
#      verified marker, the published-archive limit). The checker must
#      refuse naming the undisclosed retained legacy commands.
#   B2. status-flip: flips ONE retained row's unavailable status (li01) to
#      a claimed verified-and-available status, leaving the table and both
#      manifests otherwise valid. The checker must refuse that row for
#      contradicting the retained status.
#   C. release-text-tamper (source-consistency control): injects a stale
#      future-scope sentence into the archived RELEASE.md. The checker's
#      byte-comparison with the source RELEASE.md fires first, so this
#      variant proves the release-text consistency assertion can fail; it
#      is NOT evidence about the forbidden-stale-scope wording rule, which
#      the equality check shadows.
#
# Each variant rebuilds BOTH manifests in the assembler's exact bytes —
# the archive-internal `HASH␣␣path` SHA256SUMS (proven by recomputation
# before the surface verdict) and the release-directory SHA256SUMS over
# the two tarballs (also proven) — so only the intended assertion can
# fire. The assembled archive itself is never modified: variants work on
# extracted copies in temporary directories that are removed at the end.
#
# Usage: release_surface_control.sh <repo-root> <archive-dir>
# Exit 0 iff: the ordinary archive passes AND every variant refuses on its
# stated reason. Needs: bash, tar, gzip, sha256sum, python3 with pyyaml
# (the assembler's own environment provides all of these).
set -euo pipefail
root="$1"; archive="$2"
onchain_tarball="$(echo "$archive"/singular-onchain-*.tar.gz)"
[ -f "$onchain_tarball" ] || { echo "CONTROL-ERROR: no onchain tarball in $archive" >&2; exit 2; }

# 0. Sanity: the ordinary assembled archive passes the checker.
python3 "$root/tools/check_release.py" "$root" "$archive" > /dev/null
echo "control: ordinary archive passes check_release.py"

# Manifest writer with the assembler's exact bytes: `<hex>␣␣<relpath>`,
# sorted, trailing newline (tools/assemble_onchain_release.py).
write_manifest() { # $1 = dir
  python3 - "$1" << 'EOF'
import hashlib, sys
from pathlib import Path
work = Path(sys.argv[1])
lines = sorted(
    f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(work).as_posix()}\n"
    for p in work.rglob("*")
    if p.is_file() and p.name != "SHA256SUMS"
)
(work / "SHA256SUMS").write_text("".join(lines))
EOF
}

# Positive integrity proofs (must pass BEFORE any surface verdict is
# meaningful): the archive-internal manifest against every file, and the
# release-directory manifest against the two tarballs.
prove_integrity() { # $1 = dir, $2 = label
  python3 - "$1" << 'EOF'
import hashlib, sys
from pathlib import Path
work = Path(sys.argv[1])
expect = {}
for line in (work / "SHA256SUMS").read_text().splitlines():
    digest, name = line.split("  ", 1)
    expect[name] = digest
actual = {
    p.relative_to(work).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in work.rglob("*")
    if p.is_file() and p.name != "SHA256SUMS"
}
assert expect == actual, f"integrity proof failed: {set(expect) ^ set(actual)}"
EOF
  echo "control: $2 internal integrity proved (manifest accepted)"
}

prove_release_dir_integrity() { # $1 = release dir, $2 = label
  python3 - "$1" << 'EOF'
import hashlib, sys
from pathlib import Path
release = Path(sys.argv[1])
expect = {}
for line in (release / "SHA256SUMS").read_text().splitlines():
    digest, name = line.split("  ", 1)
    expect[name] = digest
actual = {
    p.name: hashlib.sha256(p.read_bytes()).hexdigest()
    for p in release.glob("*.tar.gz")
}
assert expect == actual, f"release-dir integrity proof failed: {set(expect) ^ set(actual)}"
EOF
  echo "control: $2 release-directory checksums proved (both tarballs covered)"
}

# Variant A: remove the verified lifecycle command the README promises.
mutate_missing_verified_command() {
  grep -v "nix run .#journey" "$1/README.md" > "$1/README.md.new"
  mv "$1/README.md.new" "$1/README.md"
}

# Variant B: remove the retained-command availability disclosure the README
# promises (the table, its header, the marker sentence, the limit sentence).
mutate_removed_disclosure() {
  grep -vE 'nix run \.#(li01|li-refusals|naming-rows|register-rows|recovery-rows|retirement-rows|retirement-verify)|repair-rows|connected-verifier|not currently buildable or verified|already published archives are never rewritten|retained command \|' \
    "$1/README.md" > "$1/README.md.new"
  mv "$1/README.md.new" "$1/README.md"
}

# Variant B2: flip exactly one row's unavailable status (the li01 row) to a
# claimed verified-and-available status; table, issues and manifests stay valid.
mutate_status_flip() {
  sed -i '/nix run \.#li01/s/unavailable: no passing build evidence at this source/available: verified under the current source/' "$1/README.md"
}

# Variant C: inject a stale future-scope sentence into the archived
# release text (all other bytes untouched — the source byte-comparison,
# not a checksum, is the assertion this variant exercises).
mutate_release_text_tamper() {
  cat >> "$1/RELEASE.md" << 'EOF'

Recovery and retirement belong to epic 17 as future work with their own evidence.
EOF
}

run_variant() { # $1 = name, $2 = mutator, $3 = expected reason fragment
  local name="$1" work vdir
  work="$(mktemp -d)"
  tar -xzf "$onchain_tarball" -C "$work"
  "$2" "$work"
  write_manifest "$work"
  prove_integrity "$work" "$name"
  vdir="$(mktemp -d)"
  tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C "$work" -cf - . | gzip -n > "$vdir/$(basename "$onchain_tarball")"
  # The docs tarball rides along unchanged (the checker requires it);
  # outer sums cover exactly the two tarballs in assembler format.
  for docs_tarball in "$archive"/singular-docs-*.tar.gz; do
    cp "$docs_tarball" "$vdir/"
  done
  ( cd "$vdir" && sha256sum ./*.tar.gz | sed 's|  \./|  |' > SHA256SUMS )
  prove_release_dir_integrity "$vdir" "$name"
  local out rc=0
  out="$(python3 "$root/tools/check_release.py" "$root" "$vdir" 2>&1)" && rc=$? || rc=$?
  rm -rf "$work" "$vdir"
  if [ "$rc" -eq 0 ]; then
    echo "CONTROL-FAIL: variant $name unexpectedly PASSED" >&2; exit 1
  fi
  case "$out" in
    *"checksum manifest drift"*|*"checksum"*)
      echo "CONTROL-FAIL: variant $name refused at checksums, not the surface:" >&2
      echo "$out" >&2; exit 1 ;;
  esac
  case "$out" in
    *"$3"*) echo "control: variant $name refused specifically ($3)" ;;
    *) echo "CONTROL-FAIL: variant $name refused, but not for the surface reason:" >&2; echo "$out" >&2; exit 1 ;;
  esac
}

run_variant "missing-verified-command" mutate_missing_verified_command \
  "does not document: nix run .#journey"
run_variant "removed-disclosure" mutate_removed_disclosure \
  "does not disclose retained legacy commands"
run_variant "status-flip" mutate_status_flip \
  "contradicts the retained status"
run_variant "release-text-tamper" mutate_release_text_tamper \
  "differ from source"
echo "CONTROL-PASS: ordinary archive passes; the verified-command promise, the retained-command disclosure, the per-row retained status and the release-text consistency each refuse specifically"

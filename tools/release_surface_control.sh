#!/usr/bin/env bash
# Negative control for the on-chain release surface (NOTE-103/104,
# NOTE-043/044).
#
# Given an assembled release directory (from `nix run .#release-artifacts --
# <out-dir>`), builds two stale-surface variants and proves the release
# checker refuses each SPECIFICALLY on the surface — never accidentally
# at a checksum mismatch:
#   A. missing-command: omits every `nix run .#retirement-rows` line.
#   B. future-scope: INJECTS the old contradictory future-E17 sentence
#      into the otherwise-current RELEASE text (all required tokens
#      retained), tripping the explicit forbidden-stale-scope assertion.
# Each variant rebuilds manifests in the assembler's exact
# `HASH␣␣path` format (verified by a positive integrity proof before
# the surface verdict), so only the intended assertion can fire.
#
# Usage: release_surface_control.sh <repo-root> <archive-dir>
# Exit 0 iff: normal archive passes AND both variants refuse on their
# surface reason. Needs: bash, tar, gzip, sha256sum, python3 with
# pyyaml (e.g. inside `nix develop`).
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

# Positive integrity proof: recompute and compare (must pass BEFORE
# any surface verdict is meaningful).
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

# Variant A: omit a required advertised command (all retirement-rows lines).
mutate_missing_command() {
  grep -v "nix run .#retirement-rows" "$1/README.md" > "$1/README.md.new"
  mv "$1/README.md.new" "$1/README.md"
}

# Variant B: INJECT the old contradictory future-E17 sentence into the
# otherwise-current text (all required tokens retained — absence checks
# alone would pass; only the forbidden-scope assertion may fire).
mutate_future_scope() {
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

run_variant "missing-command" mutate_missing_command "does not document: nix run .#retirement-rows"
run_variant "future-scope" mutate_future_scope "stale scope"
echo "CONTROL-PASS: ordinary archive passes; both stale-surface variants refuse specifically"

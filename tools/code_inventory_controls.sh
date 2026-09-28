#!/usr/bin/env bash
# Negative and positive controls for tools/code_inventory.py (#278 S1).
#
# Each control exports the classified tree to a fresh scratch copy — a copy
# that carries NO .git directory, so every control run also re-proves the
# inventory works where Git is absent (flake-source context) — injects one
# synthetic orphan into it, and requires the inventory to fail (or pass) for
# the intended reason, never for a setup failure. The orphans never touch the
# working tree, and no deliberate source defect is ever committed: the
# controls are permanent harness inputs, run by `just inventory-controls`
# inside `just ci` and PR CI.
#
# Intended diagnostics (must match tools/code_inventory.py):
#   c1  new code source in a new directory          -> unmapped <family> source
#   c2  extensionless script discovered by shebang  -> unmapped shell source
#                                                    (discovered by shebang)
#   c3  extensionless executable, no shebang        -> unknown executable file
#   c4  nonstandard extension inside a cabal
#       hs-source-dir (manifest discovery)          -> unmapped haskell source
#                                                    (nonstandard extension …)
#   c5  extension nobody recognizes                 -> unclassified file
#   c6  new covered source in a covered directory   -> PASS (auto-mapped; a
#                                                    frozen per-file list
#                                                    could not do this)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tool="$here/code_inventory.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

# Baseline: the real tree must pass before any control can mean anything.
if ! python3 "$tool" --root "$root" >"$work/baseline.log" 2>&1; then
  echo "controls: SETUP FAILURE — the real tree does not pass the inventory:" >&2
  cat "$work/baseline.log" >&2
  exit 1
fi
echo "controls: baseline PASS — the tracked tree inventories clean"

scratch() { # scratch <name> — fresh exported copy of the classified tree
  local dest="$work/$1"
  if ! python3 "$tool" --root "$root" --export-tree "$dest" \
      >"$work/$1.export.log" 2>&1; then
    echo "controls: SETUP FAILURE — cannot export the classified tree:" >&2
    cat "$work/$1.export.log" >&2
    exit 1
  fi
}

expect_reject() { # expect_reject <name> <diagnostic-substring>
  local name=$1 diagnostic=$2 log="$work/$1.log"
  if python3 "$tool" --root "$work/$name" >"$log" 2>&1; then
    echo "control $name FAILED: the inventory accepted a defective tree" >&2
    failures=$((failures + 1))
  elif grep -qF "$diagnostic" "$log"; then
    echo "control $name PASS: rejected with the intended diagnostic"
  else
    echo "control $name FAILED: rejected for the wrong reason (wanted: $diagnostic)" >&2
    sed 's/^/  | /' "$log" >&2
    failures=$((failures + 1))
  fi
}

# c1 — a new Haskell source in a new directory has no policy mapping.
scratch c1-new-directory-source
mkdir -p "$work/c1-new-directory-source/orphan-lane"
printf 'module Orphan () where\n' \
  > "$work/c1-new-directory-source/orphan-lane/orphan.hs"
expect_reject c1-new-directory-source \
  "unmapped haskell source: orphan-lane/orphan.hs"

# c2 — an extensionless script is discovered ONLY by its shebang.
scratch c2-shebang-discovery
mkdir -p "$work/c2-shebang-discovery/orphan-lane"
printf '#!/usr/bin/env bash\nexit 0\n' \
  > "$work/c2-shebang-discovery/orphan-lane/shebang-only"
expect_reject c2-shebang-discovery \
  "unmapped shell source (discovered by shebang): orphan-lane/shebang-only"

# c3 — an extensionless executable with no shebang fails closed.
scratch c3-executable-mode
mkdir -p "$work/c3-executable-mode/orphan-lane"
printf 'not a script, no shebang, no extension\n' \
  > "$work/c3-executable-mode/orphan-lane/unknown-executable"
chmod +x "$work/c3-executable-mode/orphan-lane/unknown-executable"
expect_reject c3-executable-mode \
  "unknown executable file (no extension, no shebang): orphan-lane/unknown-executable"

# c4 — a nonstandard extension inside a cabal hs-source-dir is attributed to
# the component by the manifest, not silently dropped as unknown data.
scratch c4-manifest-nonstandard
printf '%s\n' '-- hsc2hs source nobody registered' \
  > "$work/c4-manifest-nonstandard/offchain/lib/Orphan.hsc"
expect_reject c4-manifest-nonstandard \
  "unmapped haskell source (nonstandard extension .hsc inside a declared component source directory): offchain/lib/Orphan.hsc"

# c5 — an extension nobody recognizes anywhere fails closed.
scratch c5-unknown-extension
mkdir -p "$work/c5-unknown-extension/orphan-lane"
printf 'opaque\n' > "$work/c5-unknown-extension/orphan-lane/mystery.zzz"
expect_reject c5-unknown-extension \
  "unclassified file (unknown extension .zzz): orphan-lane/mystery.zzz"

# c6 (positive) — a NEW source in a covered directory is mapped with no
# registry edit; this is what a frozen per-file list could never do.
scratch c6-covered-new-source
printf 'module PositivelyNewModule () where\n' \
  > "$work/c6-covered-new-source/offchain/lib/PositivelyNewModule.hs"
if python3 "$tool" --root "$work/c6-covered-new-source" \
    >"$work/c6-covered-new-source.log" 2>&1; then
  echo "control c6-covered-new-source PASS: new covered source mapped automatically"
else
  echo "control c6-covered-new-source FAILED: a new source in a covered directory was not mapped" >&2
  sed 's/^/  | /' "$work/c6-covered-new-source.log" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "controls: FAILED — $failures control(s) did not produce their intended outcome" >&2
  exit 1
fi
echo "controls: PASS — 6/6 controls produced their intended outcome"

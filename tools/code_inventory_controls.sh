#!/usr/bin/env bash
# Negative and positive controls for tools/code_inventory.py (#278 terminal-attestation-sound).
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
#   c7  new offchain source outside every
#       checker-visited component directory         -> haskell source outside
#                                                    every checker-visited
#                                                    component directory
#                                                    (audit F-001: enforced
#                                                    policies are bound to
#                                                    the checker's extent)
#   c8  ignored source present in the Git-free
#       export (store-like context)                 -> must NOT vanish; it
#                                                    fails as unmapped
#                                                    (audit F-002)
#   c9  force-added (tracked) source in a Git
#       checkout whose path matches .gitignore      -> must NOT vanish; it
#                                                    fails as unmapped
#                                                    (audit F-002)
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

expect_reject() { # expect_reject <name> <required-substring> [more…]
  local name=$1
  shift
  local log="$work/$name.log"
  if python3 "$tool" --root "$work/$name" >"$log" 2>&1; then
    echo "control $name FAILED: the inventory accepted a defective tree" >&2
    failures=$((failures + 1))
  elif ! grep -qF "$1" "$log"; then
    echo "control $name FAILED: rejected for the wrong reason (wanted: $1)" >&2
    sed 's/^/  | /' "$log" >&2
    failures=$((failures + 1))
  else
    local missing=""
    for pat in "$@"; do
      grep -qF "$pat" "$log" || missing="$missing $pat"
    done
    if [ -n "$missing" ]; then
      echo "control $name FAILED: diagnostic missing:$missing" >&2
      sed 's/^/  | /' "$log" >&2
      failures=$((failures + 1))
    else
      echo "control $name PASS: rejected with the intended diagnostic"
    fi
  fi
}

# c1 — a new Haskell source in a new directory has no policy mapping.
scratch c1-new-directory-source
mkdir -p "$work/c1-new-directory-source/orphan-lane"
printf 'module Orphan () where\n' \
  >"$work/c1-new-directory-source/orphan-lane/orphan.hs"
expect_reject c1-new-directory-source \
  "unmapped haskell source: orphan-lane/orphan.hs"

# c2 — an extensionless script is discovered ONLY by its shebang.
scratch c2-shebang-discovery
mkdir -p "$work/c2-shebang-discovery/orphan-lane"
printf '#!/usr/bin/env bash\nexit 0\n' \
  >"$work/c2-shebang-discovery/orphan-lane/shebang-only"
expect_reject c2-shebang-discovery \
  "unmapped shell source (discovered by shebang): orphan-lane/shebang-only"

# c3 — an extensionless executable with no shebang fails closed.
scratch c3-executable-mode
mkdir -p "$work/c3-executable-mode/orphan-lane"
printf 'not a script, no shebang, no extension\n' \
  >"$work/c3-executable-mode/orphan-lane/unknown-executable"
chmod +x "$work/c3-executable-mode/orphan-lane/unknown-executable"
expect_reject c3-executable-mode \
  "unknown executable file (no extension, no shebang): orphan-lane/unknown-executable"

# c4 — a nonstandard extension inside a cabal hs-source-dir is attributed to
# the component by the manifest, not silently dropped as unknown data.
scratch c4-manifest-nonstandard
printf '%s\n' '-- hsc2hs source nobody registered' \
  >"$work/c4-manifest-nonstandard/offchain/lib/Orphan.hsc"
expect_reject c4-manifest-nonstandard \
  "unmapped haskell source (nonstandard extension .hsc inside a declared component source directory): offchain/lib/Orphan.hsc"

# c5 — an extension nobody recognizes anywhere fails closed.
scratch c5-unknown-extension
mkdir -p "$work/c5-unknown-extension/orphan-lane"
printf 'opaque\n' >"$work/c5-unknown-extension/orphan-lane/mystery.zzz"
expect_reject c5-unknown-extension \
  "unclassified file (unknown extension .zzz): orphan-lane/mystery.zzz"

# c6 (positive) — a NEW source in a covered directory is mapped with no
# registry edit; this is what a frozen per-file list could never do.
scratch c6-covered-new-source
printf 'module PositivelyNewModule () where\n' \
  >"$work/c6-covered-new-source/offchain/lib/PositivelyNewModule.hs"
if python3 "$tool" --root "$work/c6-covered-new-source" \
  >"$work/c6-covered-new-source.log" 2>&1; then
  echo "control c6-covered-new-source PASS: new covered source mapped automatically"
else
  echo "control c6-covered-new-source FAILED: a new source in a covered directory was not mapped" >&2
  sed 's/^/  | /' "$work/c6-covered-new-source.log" >&2
  failures=$((failures + 1))
fi

# c7 — a new offchain Haskell source outside every checker-visited component
# directory must fail closed: no enforced policy may be claimed for a file
# the offchain lint never visits (its extent is the Cabal hs-source-dirs
# plus naming/test and naming/drift — audit finding F-001).
scratch c7-offchain-outside-component
mkdir -p "$work/c7-offchain-outside-component/offchain/unbuilt-component"
printf 'module Unvisited () where\n' \
  >"$work/c7-offchain-outside-component/offchain/unbuilt-component/Unvisited.hs"
expect_reject c7-offchain-outside-component \
  "haskell source outside every checker-visited component directory" \
  "offchain/unbuilt-component/Unvisited.hs"

# c8 — a source present in the Git-free export cannot be concealed by an
# ignore pattern: in a Git-free source (Nix store copy, scratch export)
# every present file is repository source, so ignore rules are inert and
# the file must fail as unmapped rather than vanish (audit finding F-002).
scratch c8-ignored-source-git-free
mkdir -p "$work/c8-ignored-source-git-free/orphan-lane"
printf 'module Hidden () where\n' \
  >"$work/c8-ignored-source-git-free/orphan-lane/Hidden.hs"
printf 'orphan-lane/\n' >>"$work/c8-ignored-source-git-free/.gitignore"
expect_reject c8-ignored-source-git-free \
  "unmapped haskell source: orphan-lane/Hidden.hs"

# c9 — a TRACKED (force-added) source whose path matches .gitignore must not
# be concealed in a Git checkout either: ignore rules skip untracked noise
# only, and a tracked file is repository content (audit finding F-002).
scratch c9-tracked-ignored-checkout
if ! git -C "$work/c9-tracked-ignored-checkout" init -q \
  || ! git -C "$work/c9-tracked-ignored-checkout" add -A; then
  echo "controls: SETUP FAILURE — cannot stage the scratch checkout" >&2
  exit 1
fi
mkdir -p "$work/c9-tracked-ignored-checkout/ignored-lane"
printf 'module Hidden () where\n' \
  >"$work/c9-tracked-ignored-checkout/ignored-lane/Hidden.hs"
printf 'ignored-lane/\n' >>"$work/c9-tracked-ignored-checkout/.gitignore"
git -C "$work/c9-tracked-ignored-checkout" add -f ignored-lane/Hidden.hs
expect_reject c9-tracked-ignored-checkout \
  "unmapped haskell source: ignored-lane/Hidden.hs"

if ((failures > 0)); then
  echo "controls: FAILED — $failures control(s) did not produce their intended outcome" >&2
  exit 1
fi
echo "controls: PASS — 9/9 controls produced their intended outcome"

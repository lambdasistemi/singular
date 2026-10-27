#!/usr/bin/env bash
# Negative and positive controls for the IO ownership boundary (#544).
#
# Each control copies the tree to a scratch directory (hardlinks where the
# filesystem allows, so the copy is instant; planted files replace their
# links, never the working tree), injects one synthetic defect, and requires
# tools/io_ownership_check.sh to fail — or pass — for the intended reason,
# never for a setup failure. The orphans never touch the working tree, and no
# deliberate source defect is ever committed. Run by `just io-ownership-controls`
# inside `just ci` and PR CI.
#
# Intended outcomes (must match tools/io_ownership_check.sh diagnostics):
#   c1  new production file naming IORef, no allowlist entry
#       -> unallowlisted gated site
#   c2  unsafePerformIO added to a covered production file
#       -> unallowlisted gated site naming unsafe
#   c3  forkIO added to a tool file (product concurrency rule)
#       -> unallowlisted gated site naming fork
#   c4  new primitive-free module in a covered directory
#       -> PASS (no allowlist edit; the check gates effects, not files)
#   c5  allowlist entry for a file naming no gated effect
#       -> names no gated effect (stale exemptions fail)
#   c6  conformance library module importing the runner
#       -> B1 violated
#   c7  allowlist entry with an unknown class token
#       -> unknown classes (changed bound input is rejected)
#   c8  new newIORef site in an already ioref-classified file, imports
#       unchanged (NOTE-001)                       -> site-count drift
#   c9  substitution across functions, file totals and imports unchanged
#       (NOTE-002)                                 -> per-function drift
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
check="$here/io_ownership_check.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

# Snapshot the working tree's tracked state: the controls must add no
# modification of their own. The writer's own uncommitted work is already
# present and must be unchanged afterwards — compare, not empty.
tree_before="$work/tree-before.txt"
tree_after="$work/tree-after.txt"
git -C "$root" status --porcelain | grep -v '^??' | sort >"$tree_before" || true

# Baseline: the real tree must pass before any control can mean anything.
if ! bash "$check" "$root" >"$work/baseline.log" 2>&1; then
  echo "controls: SETUP FAILURE — the real tree does not pass the ownership check:" >&2
  cat "$work/baseline.log" >&2
  exit 1
fi
echo "controls: baseline PASS — the tree's 95 gated sites are allowlisted, B1-B5 hold"

# One baseline copy; each control derives its own scratch from it.
# Hardlinks are read-only sharing: EVERY plant step below removes its target
# first (rm + create/append), because writing through a shared inode would
# mutate the baseline, every sibling scratch AND the working tree. An
# in-place append (>> , >) through a hardlink is a worktree edit.
#
# Cross-device copies cannot hardlink: a naive `cp -al || cp -a` fallback
# nests the source inside the partial destination left by the failed
# hardlink attempt (dest/base/...), so every plant misses its target and
# the check mis-reports the setup loss as a wrong-reason rejection
# (hosted PR620 red). The copy below always starts from an absent dest and
# asserts a sentinel afterwards; a copy defect is a loud SETUP-FAILURE,
# never a cascade.
copy_tree() { # copy_tree <src> <dest> — complete copy or loud failure
  local src=$1 dest=$2
  rm -rf "$dest"
  if ! cp -al "$src" "$dest" 2>/dev/null; then
    rm -rf "$dest"
    cp -a "$src" "$dest"
  fi
  [ -f "$dest/tools/io_ownership_inventory.py" ] || {
    echo "controls: SETUP FAILURE — scratch copy $dest lacks the inventory tool" >&2
    exit 1
  }
}
copy_tree "$root" "$work/base"
rm -rf "$work/base/.git"

scratch() { # scratch <name> — fresh derived copy of the baseline
  copy_tree "$work/base" "$work/$1"
}

plant_target() { # plant_target <scratch> <relpath> — require the plant site
  local target="$work/$1/$2"
  [ -f "$target" ] || {
    echo "controls: SETUP FAILURE — scratch $1 lacks plant target $2" >&2
    exit 1
  }
}

expect_reject() { # expect_reject <name> <required-substring> [more…]
  local name=$1
  shift
  local log="$work/$name.log"
  if bash "$check" "$work/$name" >"$log" 2>&1; then
    echo "control $name FAILED: the check accepted a defective tree" >&2
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

# c1 — a new production file naming IORef with no allowlist entry.
scratch c1-new-ioref-site
rm -f "$work/c1-new-ioref-site/offchain/lib/Singular/Registry/OrphanEscape.hs"
cat >"$work/c1-new-ioref-site/offchain/lib/Singular/Registry/OrphanEscape.hs" <<'EOF'
module Singular.Registry.OrphanEscape (orphanEscape) where

import Data.IORef (newIORef)

orphanEscape :: IO Int
orphanEscape = newIORef 0 >>= \_ -> pure 0
EOF
expect_reject c1-new-ioref-site \
  "unallowlisted gated site" \
  "offchain/lib/Singular/Registry/OrphanEscape.hs"

# c2 — an unsafe escape added to a covered production file.
scratch c2-unsafe-escape
c2target="$work/c2-unsafe-escape/offchain/lib/Singular/Registry/Trie/PureManager.hs"
plant_target c2-unsafe-escape offchain/lib/Singular/Registry/Trie/PureManager.hs
cp "$c2target" "$c2target.plant" && rm "$c2target" && mv "$c2target.plant" "$c2target"
printf '\nimport System.IO.Unsafe (unsafePerformIO)\n' >>"$c2target"
printf '\norphanEscaped :: Int\norphanEscaped = unsafePerformIO (pure 1)\n' >>"$c2target"
expect_reject c2-unsafe-escape \
  "unallowlisted gated site" \
  "unsafe"

# c3 — a forkIO site added to a tool file.
scratch c3-fork-site
c3target="$work/c3-fork-site/offchain/devnet/Main.hs"
plant_target c3-fork-site offchain/devnet/Main.hs
cp "$c3target" "$c3target.plant" && rm "$c3target" && mv "$c3target.plant" "$c3target"
printf '\nimport Control.Concurrent (forkIO)\n' >>"$c3target"
printf '\norphanThread :: IO ()\norphanThread = forkIO (pure ()) >> pure ()\n' >>"$c3target"
expect_reject c3-fork-site \
  "unallowlisted gated site" \
  "fork"

# c4 (positive) — a new primitive-free module is mapped with no allowlist
# edit; the check gates effects, not files.
scratch c4-covered-new-module
rm -f "$work/c4-covered-new-module/offchain/lib/Singular/Registry/PositivelyNewModule.hs"
cat >"$work/c4-covered-new-module/offchain/lib/Singular/Registry/PositivelyNewModule.hs" <<'EOF'
module Singular.Registry.PositivelyNewModule (positivelyNew) where

positivelyNew :: Int
positivelyNew = 41 + 1
EOF
if bash "$check" "$work/c4-covered-new-module" >"$work/c4-covered-new-module.log" 2>&1; then
  echo "control c4-covered-new-module PASS: primitive-free module needs no allowlist entry"
else
  echo "control c4-covered-new-module FAILED: a primitive-free module was not mapped" >&2
  sed 's/^/  | /' "$work/c4-covered-new-module.log" >&2
  failures=$((failures + 1))
fi

# c5 — a stale allowlist entry names no gated effect (Types.hs is clean).
scratch c5-stale-entry
c5allow="$work/c5-stale-entry/tools/io-ownership.allow"
plant_target c5-stale-entry tools/io-ownership.allow
cp "$c5allow" "$c5allow.plant" && rm "$c5allow" && mv "$c5allow.plant" "$c5allow"
cat >>"$c5allow" <<'EOF'
offchain/lib/Singular/Registry/Types.hs: ioref — bogus stale entry: this module names no gated effect
EOF
expect_reject c5-stale-entry \
  "names no gated effect" \
  "offchain/lib/Singular/Registry/Types.hs"

# c6 — a conformance library module importing the runner breaks B1.
scratch c6-boundary-drift
c6target="$work/c6-boundary-drift/conformance/lib/Conformance/Receipt.hs"
plant_target c6-boundary-drift conformance/lib/Conformance/Receipt.hs
cp "$c6target" "$c6target.plant" && rm "$c6target" && mv "$c6target.plant" "$c6target"
printf '\nimport Conformance.Run.Live\n' >>"$c6target"
expect_reject c6-boundary-drift \
  "B1" \
  "conformance/lib/Conformance/Receipt.hs"

# c7 — an unknown class token in the bound input is rejected.
scratch c7-bound-input
c7allow="$work/c7-bound-input/tools/io-ownership.allow"
plant_target c7-bound-input tools/io-ownership.allow
cp "$c7allow" "$c7allow.plant" && rm "$c7allow" && mv "$c7allow.plant" "$c7allow"
cat >>"$c7allow" <<'EOF'
offchain/lib/Singular/Registry/Types.hs: frobnicate — bogus class token: changed bound input must fail
EOF
expect_reject c7-bound-input \
  "unknown classes" \
  "frobnicate"

# c8 (NOTE-001) — a new site of an existing class in an already classified
# file, imports unchanged: one more newIORef in PureManager.hs, which already
# imports Data.IORef and is allowlisted for ioref. The file/class gate stays
# green; only the site-count binding may reject it.
scratch c8-new-site-same-class
c8target="$work/c8-new-site-same-class/offchain/lib/Singular/Registry/Trie/PureManager.hs"
plant_target c8-new-site-same-class offchain/lib/Singular/Registry/Trie/PureManager.hs
cp "$c8target" "$c8target.plant" && rm "$c8target" && mv "$c8target.plant" "$c8target"
printf '\norphanExtraRef :: IO (IORef ())\norphanExtraRef = newIORef ()\n' >>"$c8target"
if ! grep -q '^import Data.IORef' "$c8target"; then
  echo "controls: SETUP FAILURE — c8 broke the planted file's imports" >&2
  exit 1
fi
expect_reject c8-new-site-same-class \
  "io-ownership-sites" \
  "PureManager.hs" \
  "newIORef"

# c9 (NOTE-002) — a substitution across functions with file totals and
# imports unchanged: remove the withSession newIORef site, add one in
# submitBuiltIn. Per-function counts drift both ways; the bound file rejects
# what the count-only binding accepted (observed PASS before the fix).
scratch c9-substitution-across-functions
c9target="$work/c9-substitution-across-functions/offchain/cli/src/Singular/CLI/Session.hs"
plant_target c9-substitution-across-functions offchain/cli/src/Singular/CLI/Session.hs
cp "$c9target" "$c9target.plant" && rm "$c9target" && mv "$c9target.plant" "$c9target"
sed -i 's/connected <- newIORef False/connected <- pure False/' "$c9target"
# Insert the new site inside submitBuiltIn's body (line 607 is its header).
sed -i '607a\    _orphanExtra <- newIORef ()' "$c9target"
if ! grep -q '^import Data.IORef' "$c9target"; then
  echo "controls: SETUP FAILURE — c9 broke the planted file's imports" >&2
  exit 1
fi
expect_reject c9-substitution-across-functions \
  "io-ownership-sites" \
  "Session.hs" \
  "newIORef"

if ((failures > 0)); then
  echo "controls: FAILED — $failures control(s) did not produce their intended outcome" >&2
  exit 1
fi
# The controls must never touch the working tree: no tracked entry may
# differ from the snapshot above (a hardlinked scratch written through its
# links would show here). The writer's own uncommitted work is preserved
# as-is; only new differences fail.
git -C "$root" status --porcelain | grep -v '^??' | sort >"$tree_after" || true
if ! diff -u "$tree_before" "$tree_after" >&2; then
  echo "controls: FAILED — the working tree changed under the controls" >&2
  exit 1
fi
echo "controls: PASS — 9/9 controls produced their intended outcome"

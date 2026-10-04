#!/usr/bin/env bash
# Negative and positive controls for the Haskell format check
# (issue #278 terminal-attestation-permanent).
#
#   f1  a misformatted Haskell source — one that Fourmolu DEFAULTS accept
#       but the house configuration rejects (function-arrows: leading,
#       column-limit: 70) — makes the repository format check fail with
#       the formatter diagnostic naming the file. The defect is chosen so
#       only the committed fourmolu.yaml rejects it: the control proves
#       the check reads the house configuration, not merely that a
#       formatter runs. The positive correction then formats that file
#       and the same check must pass again.
#   f2  a tree whose fourmolu.yaml is gone must fail loudly — never fall
#       back to Fourmolu defaults and pass (no orphan default check).
#   f3  a NEWLY TRACKED component tree outside the old directories joins
#       the check through the Git index (audit F001: two fixed root
#       directory names missed it). A deliberately misformatted source in
#       the new tree must fail the check naming it; formatting the tree
#       (the positive correction) must bring it in — baseline + 1 discovered
#       sources — and pass the same check.
#   f4  ignored untracked build noise never enters the set, while a
#       TRACKED file under an ignored path stays in it (audit F002): with
#       an untracked offchain/dist-newstyle/Noise.hs present and a
#       force-added offchain/dist-newstyle/Kept.hs tracked, the check
#       must pass over exactly baseline + 1 sources — never baseline + 2.
#
# Every control runs over a scratch copy of the Haskell trees; the
# working tree is never touched and no deliberate defect is ever
# committed. The controls are permanent harness inputs, run by
# `just format-controls` inside `just ci` and PR CI.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
check="$here/format_haskell.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

scratch() { # scratch <name> — fresh copy of the two Haskell trees and
  # the one configuration; everything the checker discovers and reads.
  local dest="$work/$1"
  mkdir -p "$dest"
  cp -r "$root/offchain" "$root/conformance" "$root/fourmolu.yaml" "$dest/"
}

# Baseline: the real tree must pass before any control can mean anything.
if ! bash "$check" check >"$work/baseline.log" 2>&1; then
  echo "controls: SETUP FAILURE — the real tree does not pass the format check:" >&2
  cat "$work/baseline.log" >&2
  exit 1
fi
# The extent is read from the baseline's own discovery, never typed: f3 and
# f4 each add exactly one tracked source to it.
baseline=$(sed -n 's/^format: \([0-9][0-9]*\) discovered Haskell sources.*/\1/p' "$work/baseline.log")
if [[ -z "$baseline" ]]; then
  echo "controls: SETUP FAILURE — the baseline did not report its discovered extent" >&2
  exit 1
fi
expected=$((baseline + 1))
echo "controls: baseline PASS — the tracked tree is formatted under the house configuration"

# f1 — misformatted source: accepted by Fourmolu defaults, rejected by the
# house configuration. A new source in a covered directory joins the
# discovered extent with no list to edit.
scratch f1-misformatted
printf '%s\n' \
  'module FormatControlHouseConfig where' \
  '' \
  'veryLongHouseConfigControlSignature :: Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int' \
  'veryLongHouseConfigControlSignature a b c d e f g = a + b + c + d + e + f + g' \
  >"$work/f1-misformatted/offchain/lib/FormatControlHouseConfig.hs"
log="$work/f1-misformatted.log"
if bash "$check" check "$work/f1-misformatted" >"$log" 2>&1; then
  echo "control f1-misformatted FAILED: the format check accepted a source the house configuration rejects" >&2
  failures=$((failures + 1))
elif ! grep -qF "offchain/lib/FormatControlHouseConfig.hs" "$log"; then
  echo "control f1-misformatted FAILED: rejected for the wrong reason (no diagnostic naming the file)" >&2
  sed 's/^/  | /' "$log" >&2
  failures=$((failures + 1))
else
  echo "control f1-misformatted PASS: the check failed with the formatter diagnostic"
fi

# f1 positive correction: the formatter fixes the file; the SAME check
# must pass over the same extent.
if bash "$check" inplace "$work/f1-misformatted" >>"$log" 2>&1; then
  if bash "$check" check "$work/f1-misformatted" >"$work/f1-positive.log" 2>&1; then
    echo "control f1-positive PASS: the corrected source passes the same check"
  else
    echo "control f1-positive FAILED: the corrected source still fails the check" >&2
    cat "$work/f1-positive.log" >&2
    failures=$((failures + 1))
  fi
else
  echo "control f1-positive FAILED: the formatter could not correct the source" >&2
  sed 's/^/  | /' "$log" >&2
  failures=$((failures + 1))
fi

# f2 — the configuration itself: without it the check must fail loudly,
# never fall back to Fourmolu defaults and pass.
scratch f2-missing-config
rm "$work/f2-missing-config/fourmolu.yaml"
if bash "$check" check "$work/f2-missing-config" >"$work/f2-missing-config.log" 2>&1; then
  echo "control f2-missing-config FAILED: the check passed without the house configuration" >&2
  failures=$((failures + 1))
else
  echo "control f2-missing-config PASS: missing configuration fails loudly"
fi

# f3 — a newly tracked component tree outside the old directories: the
# index, not a fixed directory list, defines the extent (audit F001). The
# scratch becomes a Git checkout holding the exported tree plus one
# deliberately misformatted source in a brand-new tree.
scratch f3-new-tracked-tree
git -C "$work/f3-new-tracked-tree" init -q
git -C "$work/f3-new-tracked-tree" add -A
mkdir -p "$work/f3-new-tracked-tree/new-haskell-component"
printf '%s\n' \
  'module NewComponentControl where' \
  '' \
  'brandNewTreeControlSignatureName :: Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int' \
  'brandNewTreeControlSignatureName a b c d e f g = a + b + c + d + e + f + g' \
  >"$work/f3-new-tracked-tree/new-haskell-component/NewComponentControl.hs"
git -C "$work/f3-new-tracked-tree" add new-haskell-component/NewComponentControl.hs
log="$work/f3-new-tracked-tree.log"
if bash "$check" check "$work/f3-new-tracked-tree" >"$log" 2>&1; then
  echo "control f3-new-tracked-tree FAILED: the check accepted a misformatted source in a newly tracked tree" >&2
  failures=$((failures + 1))
elif ! grep -qF "new-haskell-component/NewComponentControl.hs" "$log"; then
  echo "control f3-new-tracked-tree FAILED: rejected for the wrong reason (no diagnostic naming the new-tree file)" >&2
  sed 's/^/  | /' "$log" >&2
  failures=$((failures + 1))
elif ! grep -qF "$expected discovered Haskell sources" "$log"; then
  echo "control f3-new-tracked-tree FAILED: the new tracked tree did not join the discovered extent" >&2
  sed 's/^/  | /' "$log" >&2
  failures=$((failures + 1))
else
  echo "control f3-new-tracked-tree PASS: the newly tracked tree joined the check and its defect failed it"
fi

# f3 positive correction: formatting the scratch brings the new tree to
# the house configuration and the SAME check passes over 203 sources.
if bash "$check" inplace "$work/f3-new-tracked-tree" >>"$log" 2>&1; then
  if bash "$check" check "$work/f3-new-tracked-tree" >"$work/f3-positive.log" 2>&1 \
    && grep -qF "$expected discovered Haskell sources" "$work/f3-positive.log"; then
    echo "control f3-positive PASS: the corrected new tree passes the same check"
  else
    echo "control f3-positive FAILED: the corrected new tree still fails the check" >&2
    cat "$work/f3-positive.log" >&2
    failures=$((failures + 1))
  fi
else
  echo "control f3-positive FAILED: the formatter could not correct the new tree" >&2
  sed 's/^/  | /' "$log" >&2
  failures=$((failures + 1))
fi

# f4 — ignored untracked build noise never enters the set; a tracked file
# under an ignored path stays in it (audit F002). With an untracked,
# ignore-matched offchain/dist-newstyle/Noise.hs present AND a
# force-added tracked offchain/dist-newstyle/Kept.hs, the check must pass
# over exactly baseline + 1 sources — never baseline + 2, never a failure on the noise.
scratch f4-ignored-noise
git -C "$work/f4-ignored-noise" init -q
git -C "$work/f4-ignored-noise" add -A
mkdir -p "$work/f4-ignored-noise/offchain/dist-newstyle"
printf '%s\n' 'module Noise () where' \
  >"$work/f4-ignored-noise/offchain/dist-newstyle/Noise.hs"
printf '%s\n' 'module Kept () where' \
  >"$work/f4-ignored-noise/offchain/dist-newstyle/Kept.hs"
git -C "$work/f4-ignored-noise" add -f offchain/dist-newstyle/Kept.hs
log="$work/f4-ignored-noise.log"
if bash "$check" check "$work/f4-ignored-noise" >"$log" 2>&1 \
  && grep -qF "$expected discovered Haskell sources" "$log"; then
  if grep -qF "dist-newstyle/Noise.hs" "$log"; then
    echo "control f4-ignored-noise FAILED: ignored build noise entered the discovered extent" >&2
    failures=$((failures + 1))
  else
    echo "control f4-ignored-noise PASS: ignored noise excluded, tracked file under the ignored path retained"
  fi
else
  echo "control f4-ignored-noise FAILED: the check did not pass over exactly baseline+1 sources with the noise present" >&2
  sed 's/^/  | /' "$log" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  echo "controls: FAILED — $failures control(s) did not produce their intended outcome" >&2
  exit 1
fi
echo "controls: PASS — 4/4 controls produced their intended outcome"

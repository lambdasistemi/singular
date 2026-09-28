#!/usr/bin/env bash
# Negative and positive controls for the Haskell format check
# (issue #278 S2).
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

if ((failures > 0)); then
    echo "controls: FAILED — $failures control(s) did not produce their intended outcome" >&2
    exit 1
fi
echo "controls: PASS — 3/3 controls produced their intended outcome"

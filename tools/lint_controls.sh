#!/usr/bin/env bash
# Negative controls for `just lint` (tools/lint_code.py, issue #278).
#
# The classified tree is exported to a scratch copy (no .git), which must
# pass `lint_code.py check` first; then each control plants one deliberate
# lint or formatting defect in a fresh copy and requires the family's check
# to fail. A defect in a source under a brand-new directory proves the
# extent is discovered, not listed. The working tree is never touched and no
# defect is ever committed.
# shellcheck disable=SC2016 # the planted defects are literal text, never expanded
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! python3 "$here/code_inventory.py" --root "$root" --export-tree "$work/tree" \
  >"$work/export.log" 2>&1; then
  echo "lint-controls: SETUP FAILURE — export failed:" >&2
  cat "$work/export.log" >&2
  exit 1
fi
if ! python3 "$work/tree/tools/lint_code.py" check >"$work/baseline.log" 2>&1; then
  echo "lint-controls: SETUP FAILURE — the exported tree does not lint clean:" >&2
  cat "$work/baseline.log" >&2
  exit 1
fi
echo "lint-controls: baseline PASS — the exported tree lints clean"

failures=0
n=0

# control <name> <family> <relative path> <content appended or written>
# mode: append (add the text to an existing file) or create (new file).
control() {
  local name=$1 family=$2 mode=$3 rel=$4 text=$5
  local tree="$work/c$n"
  n=$((n + 1))
  cp -r "$work/tree" "$tree"
  mkdir -p "$(dirname "$tree/$rel")"
  if [ "$mode" = append ]; then
    [ -f "$tree/$rel" ] || {
      echo "control $name SETUP FAILURE: $rel is missing" >&2
      failures=$((failures + 1))
      return
    }
    printf '%b' "$text" >>"$tree/$rel"
  else
    printf '%b' "$text" >"$tree/$rel"
  fi
  if python3 "$tree/tools/lint_code.py" check "$family" >"$tree.log" 2>&1; then
    echo "control $name FAIL: the $family check accepted the planted defect in $rel" >&2
    failures=$((failures + 1))
  elif grep -q '^lint: FAILED' "$tree.log"; then
    echo "control $name PASS: the $family check rejected the planted defect"
  else
    echo "control $name FAIL: the $family check did not run to a verdict:" >&2
    tail -5 "$tree.log" >&2
    failures=$((failures + 1))
  fi
  rm -rf "$tree"
}

control nix-format nix append flake.nix '\n'
control nix-lint nix create nix/control.nix '{ pkgs }:\nlet\n  unused = 1;\nin\npkgs\n'
control nix-lock-parity nix append conformance/flake.lock '\n'
control python-lint python append tools/stamp_speech.py '\nimport os\n'
control python-format python append tools/stamp_speech.py '\nx = [ 1,2 ]\n'
control python-new-directory python create control_new_tree/tool.py 'import sys\n'
control shell-lint shell append tools/no-global-fixture-state.sh '\necho $1\n'
control shell-format shell append tools/no-global-fixture-state.sh '\nif true;   then echo ok; fi\n'
control javascript-lint javascript append simulator/serve.mjs '\nvar unusedControl = 1;\n'
control javascript-format javascript append simulator/serve.mjs '\nconsole.log( "control" )\n'
control css-format css append simulator/page.css '\na{color:red}\n'
control just-format just append justfile '\ncontrol:\n  echo control\n'
control workflow-lint workflow-yaml append .github/workflows/ci.yml '  control:\n    runs-on: nixos\n    steps:\n      - run: echo ${{ github.event.pull_request.title }}\n'
control workflow-format workflow-yaml append .github/workflows/ci.yml '\n\n\n'
control lean-style lean append lean/Singular.lean '-- control \n'
control lean-tab lean append lean/Singular.lean '\t\n'
control html-style html append overrides/main.html '\t\n'

if [ "$failures" -ne 0 ]; then
  echo "lint-controls: FAILED — $failures control(s) did not produce their intended outcome" >&2
  exit 1
fi
echo "lint-controls: PASS — $n/$n planted defects rejected"

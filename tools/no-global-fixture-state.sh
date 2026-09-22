#!/usr/bin/env bash
# No process-wide mutable state under conformance/.
#
# Supporting evidence, not proof. This reads source text, so it establishes a
# source fact and nothing about behaviour: what a temporary directory actually
# does when an example throws, or when a second process runs the same example,
# is settled by the controls in Conformance.Support.Fixture and by nothing here.
#
# What it does add is extent. Those controls exercise one fixture; this refuses
# the whole tree, so moving a global counter into another module does not escape
# them quietly.
#
# Two shapes are forbidden:
#   * unsafePerformIO anywhere — there is no use for it in a test tree;
#   * a binding written at column zero whose type is an IORef, which every
#     example in the process shares.
#
# An IORef created inside a function is ordinary local state, is used correctly
# in several places here, and is deliberately NOT reported.
set -euo pipefail

root=${1:-conformance}

mapfile -t sources < <(find "$root" -name '*.hs' -not -path '*/dist-newstyle/*' | sort)
if [ ${#sources[@]} -eq 0 ]; then
    echo "EMPTY EXTENT: no Haskell sources found under $root" >&2
    exit 2
fi

status=0
for file in "${sources[@]}"; do
    if grep -n 'unsafePerformIO' "$file"; then
        echo "  ^ $file: unsafePerformIO has no use in a test tree" >&2
        status=1
    fi
    # A binding whose type IS an IORef, not a function that happens to take
    # one: `dirCounter :: IORef Int` is shared state, while
    # `allocateIdentity :: ... => IORef s -> k -> IO Integer` is a function
    # handed state its caller owns. The absence of `->` is what separates them.
    if grep -nE '^[a-zA-Z_][a-zA-Z0-9_'"'"']* :: ([^=]*=> *)?IORef\b' "$file" | grep -v -- '->'; then
        echo "  ^ $file: a column-zero IORef is state the whole process shares" >&2
        status=1
    fi
done

if [ $status -ne 0 ]; then
    echo "FAIL no-global-fixture-state: see the lines above" >&2
    exit 1
fi

echo "PASS no-global-fixture-state: ${#sources[@]} Haskell sources under $root carry no unsafePerformIO and no column-zero IORef"

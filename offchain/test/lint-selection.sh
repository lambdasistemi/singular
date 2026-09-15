#!/usr/bin/env bash
# Exercise the production selector in an isolated repository, without Nix.
set -euo pipefail
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/offchain/lib" "$work/bin"
cp "$source_dir/lint-changes.sh" "$work/repo/offchain/"
cd "$work/repo"
git init -q
printf 'module Original where\nx :: Int\nx = 1\n' > offchain/lib/Original.hs
git add .
git -c user.name=SelectorControl -c user.email=selector@example.invalid commit -qm baseline
base=$(git rev-parse HEAD)
git mv offchain/lib/Original.hs offchain/lib/Renamed.hs
printf 'module Added where\n' > offchain/lib/Added.hs
git add offchain/lib/Added.hs
printf 'module Untracked where\n' > offchain/lib/Untracked.hs
bash offchain/lint-changes.sh "$base" --select-only "$work/selected.json"
for name in Added Renamed Untracked; do
    grep -Fq "\"lib/$name.hs\"" "$work/selected.json"
done
if grep -Fq 'Original.hs' "$work/selected.json"; then
    echo 'deleted rename source remained selected' >&2; exit 1
fi
echo 'selection: added, renamed and untracked files included'
if bash offchain/lint-changes.sh missing-base --select-only "$work/bad-base.json" > "$work/base.log" 2>&1; then
    echo 'invalid base was accepted' >&2; exit 1
fi
[ ! -e "$work/bad-base.json" ]
echo 'selection: invalid base refused before emitting a selection'
export S107_REAL_GIT
S107_REAL_GIT=$(command -v git)
cat > "$work/bin/git" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == diff ]]; then
    echo 'seeded git diff failure' >&2
    exit 23
fi
exec "$S107_REAL_GIT" "$@"
SHIM
chmod +x "$work/bin/git"
if PATH="$work/bin:$PATH" bash offchain/lint-changes.sh "$base" --select-only "$work/bad-diff.json" > "$work/diff.log" 2>&1; then
    echo 'failed diff was accepted as empty selection' >&2; exit 1
fi
grep -Fq 'seeded git diff failure' "$work/diff.log"
[ ! -e "$work/bad-diff.json" ]
echo 'selection: failed git diff refused before emitting a selection'

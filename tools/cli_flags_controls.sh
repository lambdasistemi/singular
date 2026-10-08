#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks are literal Markdown here, never expansions
# Controls for tools/cli_flags_check.sh: it passes on this tree and fails,
# with its named diagnostic, on each disagreement it exists to refuse.
#
# Every control runs on a scratch copy of docs/ and README.md, against the
# real binary or a stand-in that prints the real binary's help with one
# edit; the tree itself is never touched.
#
# Usage: tools/cli_flags_controls.sh [repo-root]
#        SINGULAR=/path/to/singular as for the check.
set -euo pipefail

repo=${1:-.}
check="$repo/tools/cli_flags_check.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

real=${SINGULAR:-}
if [ -z "$real" ]; then
  real="$(nix build --quiet --no-link --print-out-paths "$repo/offchain#singular")/bin/singular"
fi

mapfile -t pages < <(bash "$check" --pages "$repo")
[ ${#pages[@]} -gt 0 ] || {
  echo "SETUP-FAIL: the check reads no Markdown page" >&2
  exit 2
}

# The scratch tree: every page the check reads, at its own path.
fresh() {
  rm -rf "$scratch/t"
  mkdir -p "$scratch/t/tools"
  for p in "${pages[@]}"; do
    rel=${p#"$repo"/}
    mkdir -p "$scratch/t/$(dirname "$rel")"
    cp "$p" "$scratch/t/$rel"
  done
  binary="$real"
}

# stand-in SED: a singular whose help is the real help passed through SED.
stand_in() {
  cat >"$scratch/singular" <<EOF
#!/usr/bin/env bash
"$real" "\$@" | sed -e '$1'
exit "\${PIPESTATUS[0]}"
EOF
  chmod +x "$scratch/singular"
  binary="$scratch/singular"
}

# expect NAME STATUS PATTERN: the check on the scratch tree exits STATUS
# and its output matches PATTERN.
expect() {
  local name="$1" want="$2" pattern="$3" got=0
  SINGULAR="$binary" bash "$check" "$scratch/t" >"$scratch/out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ] || ! grep -qE -- "$pattern" "$scratch/out"; then
    cat "$scratch/out" >&2
    echo "FAIL cli-flags control '$name': exit $got (wanted $want), pattern '$pattern'" >&2
    exit 1
  fi
  echo "control $name: exit $got, $(grep -cE -- "$pattern" "$scratch/out") matching line(s)"
}

table="$scratch/t/docs/singular-node.md"

fresh
expect clean-tree 0 '^PASS cli-flags'

# The binary takes a flag the documentation never mentions.
fresh
stand_in 's/^\(  singular registry create .*\)$/\1 --planted-flag X/'
expect undocumented-flag 1 '^undocumented: singular registry create takes --planted-flag'

# The documentation names a flag the binary does not take.
fresh
sed -i '/^| `--receipt FILE`/a | `--ghost-flag X` | all five | A flag the binary does not take. |' "$table"
grep -q 'ghost-flag' "$table" || {
  echo "SETUP-FAIL: the ghost row did not apply" >&2
  exit 2
}
expect documented-missing 1 '^documented, not in --help: the settings table gives --ghost-flag to singular registry'

# A flag documented for a command whose --help does not give it.
fresh
sed -i 's/^| `--key KEY` | `insert`, `update`, `terminate`, `inspect` |/| `--key KEY` | `create`, `insert`, `update`, `terminate`, `inspect` |/' "$table"
grep -q '^| `--key KEY` | `create`' "$table" || {
  echo "SETUP-FAIL: the key row did not change" >&2
  exit 2
}
expect wrong-command 1 '^documented, not in --help: the settings table gives --key to singular registry create'

# A documented invocation uses a flag its command does not print.
fresh
printf '\n```sh\nsingular registry inspect --state-dir ./reg \\\n  --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect invocation-unknown 1 'docs/cli-recovery.md:[0-9]+: singular registry inspect --made-up-flag'

# The release archive's run page, invoking the binary through a variable
# and through a path: an unknown flag there fails, by page and line.
fresh
printf '\n```sh\n"$singular" registry update --state-dir reg --run-page-flag 1\n```\n' \
  >>"$scratch/t/onchain-release/DEMO1.md"
expect run-page-variable 1 'onchain-release/DEMO1.md:[0-9]+: singular registry update --run-page-flag'

fresh
printf '\n```sh\n./bin/singular registry terminate --state-dir reg \\\n  --path-form-flag 1\n```\n' \
  >>"$scratch/t/onchain-release/DEMO1.md"
expect run-page-path 1 'onchain-release/DEMO1.md:[0-9]+: singular registry terminate --path-form-flag'

# A subcommand's own --help disagrees with the top-level help.
fresh
cat >"$scratch/singular" <<EOF
#!/usr/bin/env bash
if [ "\$1" = registry ] && [ "\$2" = update ]; then
  "$real" "\$@" | sed -e 's/--payload DATUM_JSON/--payload DATUM_JSON --sub-only X/'
  exit "\${PIPESTATUS[0]}"
fi
exec "$real" "\$@"
EOF
chmod +x "$scratch/singular"
binary="$scratch/singular"
expect subcommand-disagrees 1 '^singular registry update --help disagrees with singular --help about update'

# A flag in the help's prose that no command takes.
fresh
stand_in 's/^Each command prints one JSON receipt/Each command (--stray) prints one JSON receipt/'
expect unattributed-flag 1 '^--help prints a flag no command takes: --stray'

# An empty side is a setup failure, never a pass.
fresh
stand_in 's/^  singular registry /  other /'
expect empty-help 2 '^EMPTY EXTENT: singular --help names no registry command'

fresh
sed -i 's/^## The settings you give/## Settings, renamed/' "$table"
expect empty-table 2 '^EMPTY EXTENT: .*has no settings table row'

echo "PASS cli-flags-controls: 11 controls over ${#pages[@]} pages"

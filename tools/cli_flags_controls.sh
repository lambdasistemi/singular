#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks are literal Markdown here, never expansions
# Controls for tools/cli_flags_check.sh: it passes on this tree and fails,
# with its named diagnostic, on each disagreement it exists to refuse.
#
# Every control runs on a scratch copy of every page the check reads, against
# the real binaries or stand-ins that print a real binary's help with one
# edit; the tree itself is never touched.
#
# Usage: tools/cli_flags_controls.sh [repo-root]
#        SINGULAR=/path/to/singular OPEN_DATUM=/path/to/open-datum as for the check.
set -euo pipefail

repo=${1:-.}
check="$repo/tools/cli_flags_check.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

real_singular=${SINGULAR:-}
if [ -z "$real_singular" ]; then
  real_singular="$(nix build --quiet --no-link --print-out-paths "$repo/offchain#singular")/bin/singular"
fi
real_od=${OPEN_DATUM:-}
if [ -z "$real_od" ]; then
  real_od="$(nix build --quiet --no-link --print-out-paths "$repo/applications/open-datum/offchain#open-datum")/bin/open-datum"
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
  binary_singular="$real_singular"
  binary_od="$real_od"
}

# stand-in SED: a singular whose help is the real singular help passed through SED.
stand_in_singular() {
  cat >"$scratch/singular" <<EOF
#!/usr/bin/env bash
"$real_singular" "\$@" | sed -e '$1'
exit "\${PIPESTATUS[0]}"
EOF
  chmod +x "$scratch/singular"
  binary_singular="$scratch/singular"
}

# stand-in SED: an open-datum whose help is the real open-datum help passed through SED.
stand_in_od() {
  cat >"$scratch/open-datum" <<EOF
#!/usr/bin/env bash
"$real_od" "\$@" | sed -e '$1'
exit "\${PIPESTATUS[0]}"
EOF
  chmod +x "$scratch/open-datum"
  binary_od="$scratch/open-datum"
}

# expect NAME STATUS PATTERN: the check on the scratch tree exits STATUS
# and its output matches PATTERN.
expect() {
  local name="$1" want="$2" pattern="$3" got=0
  SINGULAR="$binary_singular" OPEN_DATUM="$binary_od" bash "$check" "$scratch/t" >"$scratch/out" 2>&1 || got=$?
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

# The singular binary takes a flag the documentation never mentions.
fresh
stand_in_singular 's/^\(  singular registry create .*\)$/\1 --planted-flag X/'
expect undocumented-flag 1 '^undocumented: singular registry create takes --planted-flag'

# The submit verb takes a flag the documentation never mentions: the
# check reads submit's own usage line, not only the registry group.
fresh
stand_in_singular 's/^\(  singular submit .*\)$/\1 --planted-flag X/'
expect undocumented-flag-submit 1 '^undocumented: singular submit takes --planted-flag'

# The open-datum binary takes a flag the documentation never mentions.
fresh
stand_in_od 's/^\(  open-datum insert .*\)$/\1 --planted-flag X/'
expect undocumented-flag-od 1 '^undocumented: open-datum insert takes --planted-flag'

# The documentation names a flag neither binary takes (singular side).
fresh
sed -i '/^| `--receipt FILE`/a | `--ghost-flag X` | all five | A flag the binary does not take. |' "$table"
grep -q 'ghost-flag' "$table" || {
  echo "SETUP-FAIL: the ghost row did not apply" >&2
  exit 2
}
expect documented-missing 1 '^documented, not in --help: the settings table gives --ghost-flag to singular registry'
# The documentation names a flag neither binary takes (six singular commands).
fresh
sed -i '/^| `--receipt FILE`/a | `--ghost-flag X` | all six singular commands | A flag the binary does not take. |' "$table"
grep -q 'all six singular commands' "$table" || {
  echo "SETUP-FAIL: the six-command ghost row did not apply" >&2
  exit 2
}
expect documented-missing-six 1 '^documented, not in --help: the settings table gives --ghost-flag to singular registry'

# The documentation names a flag neither binary takes (open-datum side).
fresh
sed -i '/^| `--receipt FILE`/a | `--ghost-flag X` | all six | A flag the binary does not take. |' "$table"
grep -q 'ghost-flag' "$table" || {
  echo "SETUP-FAIL: the ghost row did not apply" >&2
  exit 2
}
expect documented-missing-od 1 '^documented, not in --help: the settings table gives --ghost-flag to open-datum'

# A flag documented for a command whose --help does not give it (singular side).
fresh
sed -i 's/^| `--key KEY` | `insert`, `update`, `terminate`, `inspect` |/| `--key KEY` | `create`, `insert`, `update`, `terminate`, `inspect` |/' "$table"
grep -q '^| `--key KEY` | `create`' "$table" || {
  echo "SETUP-FAIL: the key row did not change" >&2
  exit 2
}
expect wrong-command 1 '^documented, not in --help: the settings table gives --key to singular registry create'

# A flag documented for a command whose --help does not give it (open-datum side).
fresh
sed -i 's/^| `--payload DATUM_JSON` | `insert`, `update` |/| `--payload DATUM_JSON` | `insert`, `update`, `fold` |/' "$table"
grep -q '^| `--payload DATUM_JSON` | `insert`, `update`, `fold`' "$table" || {
  echo "SETUP-FAIL: the payload row did not change" >&2
  exit 2
}
expect wrong-command-od 1 '^documented, not in --help: the settings table gives --payload to open-datum fold'

# A documented singular invocation uses a flag its command does not print.
fresh
printf '\n```sh\nsingular registry inspect --state-dir ./reg \\\n  --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect invocation-unknown 1 'docs/cli-recovery.md:[0-9]+: singular registry inspect --made-up-flag'

# A documented open-datum invocation uses a flag its command does not print.
fresh
printf '\n```sh\nopen-datum insert --state-dir ./reg \\\n  --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect invocation-unknown-od 1 'docs/cli-recovery.md:[0-9]+: open-datum insert --made-up-flag'

# The release archive's run page, invoking the singular binary through a
# variable and through a path: an unknown flag there fails, by page and line.
fresh
printf '\n```sh\n"$singular" registry inspect --state-dir reg --run-page-flag 1\n```\n' \
  >>"$scratch/t/onchain-release/DEMO1.md"
expect run-page-variable 1 'onchain-release/DEMO1.md:[0-9]+: singular registry inspect --run-page-flag'

fresh
printf '\n```sh\n./bin/singular registry inspect --state-dir reg \\\n  --path-form-flag 1\n```\n' \
  >>"$scratch/t/onchain-release/DEMO1.md"
expect run-page-path 1 'onchain-release/DEMO1.md:[0-9]+: singular registry inspect --path-form-flag'

# The run page invoking the open-datum binary through a variable and through
# a path: an unknown flag there fails, by page and line.
fresh
printf '\n```sh\n"$open_datum" insert --state-dir reg --run-page-flag 1\n```\n' \
  >>"$scratch/t/onchain-release/DEMO1.md"
expect run-page-variable-od 1 'onchain-release/DEMO1.md:[0-9]+: open-datum insert --run-page-flag'

fresh
printf '\n```sh\n./bin/open-datum insert --state-dir reg \\\n  --path-form-flag 1\n```\n' \
  >>"$scratch/t/onchain-release/DEMO1.md"
expect run-page-path-od 1 'onchain-release/DEMO1.md:[0-9]+: open-datum insert --path-form-flag'

# A singular subcommand's own --help disagrees with the top-level help.
fresh
cat >"$scratch/singular" <<EOF
#!/usr/bin/env bash
if [ "\$1" = registry ] && [ "\$2" = fold ]; then
  "$real_singular" "\$@" | sed -e 's/--request TXID#IX/--request TXID#IX --sub-only X/'
  exit "\${PIPESTATUS[0]}"
fi
exec "$real_singular" "\$@"
EOF
chmod +x "$scratch/singular"
binary_singular="$scratch/singular"
expect subcommand-disagrees 1 '^singular registry fold --help disagrees with singular --help about fold'

# An open-datum subcommand's own --help disagrees with the top-level help.
fresh
cat >"$scratch/open-datum" <<EOF
#!/usr/bin/env bash
if [ "\$1" = update ]; then
  "$real_od" "\$@" | sed -e 's/--payload DATUM_JSON/--payload DATUM_JSON --sub-only X/'
  exit "\${PIPESTATUS[0]}"
fi
exec "$real_od" "\$@"
EOF
chmod +x "$scratch/open-datum"
binary_od="$scratch/open-datum"
expect subcommand-disagrees-od 1 '^open-datum update --help disagrees with open-datum --help about update'

# A flag in the singular help's prose that no command takes.
fresh
stand_in_singular 's/^Each command prints one JSON receipt/Each command (--stray) prints one JSON receipt/'
expect unattributed-flag 1 '^--help prints a flag no command takes: --stray'

# A flag in the open-datum help's prose that no command takes.
fresh
stand_in_od 's/^Each command prints one JSON receipt/Each command (--stray) prints one JSON receipt/'
expect unattributed-flag-od 1 '^open-datum --help prints a flag no command takes: --stray'

# An empty side is a setup failure, never a pass. Every verb line goes:
# the wallet lines are commands too (#638), and so is submit.
fresh
stand_in_singular 's/^  singular registry /  other /; s/^  singular wallet /  other wallet /; s/^  singular submit/  other submit/'
expect empty-help 2 '^EMPTY EXTENT: singular --help names no registry command'

fresh
stand_in_od 's/^  open-datum /  other /'
expect empty-help-od 2 '^EMPTY EXTENT: open-datum --help names no command'

fresh
sed -i 's/^## The settings you give/## Settings, renamed/' "$table"
expect empty-table 2 '^EMPTY EXTENT: .*has no settings table row'

# An invocation with an unknown verb fails, for each binary (slice 4 r1).
# `zap` never was a verb; `reject` is singular-only, unknown for open-datum.
# Each is planted as a fenced invocation in a scratch copy of a page.
fresh
printf '\n```sh\nsingular registry zap --state-dir ./reg \\\n  --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect unknown-verb-singular 1 'docs/cli-recovery.md:[0-9]+: singular registry zap .*not a command singular supports'

fresh
printf '\n```sh\nopen-datum reject --state-dir ./reg \\\n  --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect unknown-verb-od 1 'docs/cli-recovery.md:[0-9]+: open-datum reject .*not a command open-datum supports'

# An invocation of a known verb with an unprinted flag fails, for each binary,
# on verbs the committed controls do not cover (`fold` here; the committed
# `inspect`/`insert` controls stay as they are).
fresh
printf '\n```sh\nsingular registry fold --state-dir ./reg \\\n  --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect invocation-known-bad-flag 1 'docs/cli-recovery.md:[0-9]+: singular registry fold --made-up-flag'

fresh
printf '\n```sh\nopen-datum fold --state-dir ./reg \\\n  --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect invocation-known-bad-flag-od 1 'docs/cli-recovery.md:[0-9]+: open-datum fold --made-up-flag'

# A real invocation of a removed verb under singular is still caught: the
# documented-refusals rule is narrow and does not swallow invocations
# without refusal language.
fresh
printf '\n```sh\nsingular registry insert --state-dir ./reg --blueprint plutus.json \\\n  --state-token POLICY.NAME --key keyA --payload alice.json\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect removed-verb-invocation 1 'docs/cli-recovery.md:[0-9]+: singular registry insert .*not a command singular supports'

# A bare unknown command with no flag still fails, for each binary: the
# discovered subject extent survives validation (slice 4 r2).
fresh
printf '\n```sh\nsingular registry zapzap\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect bare-unknown-singular 1 'docs/cli-recovery.md:[0-9]+: singular registry zapzap .*not a command singular supports'

fresh
printf '\n```sh\nopen-datum zapzap\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect bare-unknown-od 1 'docs/cli-recovery.md:[0-9]+: open-datum zapzap .*not a command open-datum supports'

# A removed-verb invocation carrying the refusal substring in a flag value
# still fails: the documented refusal is the page's own sentence form,
# never a substring in an argument (slice 4 r2).
fresh
printf '\n```sh\nsingular registry insert --state-dir ./refusal --made-up-flag 1\n```\n' >>"$scratch/t/docs/cli-recovery.md"
expect removed-verb-refusal-value 1 'docs/cli-recovery.md:[0-9]+: singular registry insert .*not a command singular supports'

# The three removed verbs are refused as unknown commands (slice 4).
# Each invocation omits --help so it reaches dispatch: at the base the verb
# parses and is refused for a missing flag, never as unknown, so this
# control fails there; after the split it is refused as unknown.
for verb in insert update terminate; do
  fresh
  got=0
  "$binary_singular" registry "$verb" >"$scratch/out-$verb" 2>"$scratch/err-$verb" || got=$?
  if [ "$got" -eq 0 ] || ! grep -q -- "not a command singular supports: registry $verb" "$scratch/err-$verb"; then
    cat "$scratch/err-$verb" >&2
    echo "FAIL cli-flags control 'removed-$verb': exit $got, expected unknown-command refusal for registry $verb" >&2
    exit 1
  fi
  echo "control removed-$verb: exit $got, refused as unknown"
done

# The wallet verbs, both directions (#638): a flag the wallet usage lines
# print that the settings table never mentions, and a table row giving a
# flag the wallet commands' --help does not print.
fresh
stand_in_singular 's/^  singular wallet create --vault FILE/  singular wallet create --vault FILE --planted-wallet X/'
expect undocumented-wallet-flag 1 '^undocumented: singular wallet create takes --planted-wallet'

fresh
sed -i '/^| `--vault FILE`/i | `--ghost-wallet-flag X` | `singular wallet create`, `singular wallet address` | A flag the binary does not take. |' "$table"
grep -q 'ghost-wallet-flag' "$table" || {
  echo "SETUP-FAIL: the ghost wallet row did not apply" >&2
  exit 2
}
expect documented-missing-wallet 1 '^documented, not in --help: the settings table gives --ghost-wallet-flag to singular wallet create'

echo "PASS cli-flags-controls: 34 controls over ${#pages[@]} pages"

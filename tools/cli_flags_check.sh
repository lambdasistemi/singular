#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks are literal Markdown here, never expansions
# The flags documented for `singular` are the flags its --help prints.
#
# Two sides, from two sources:
#
#   * the binary: `singular --help`, and `singular registry COMMAND --help`
#     for every command the help names. A command's flags are those on its
#     usage lines, plus those a note gives to "every command" or to the
#     "write commands" (the commands whose usage takes --wallet-skey). A flag
#     the help prints anywhere else belongs to no command and is refused.
#   * the documentation: the settings table of docs/singular-node.md, one
#     row per flag naming the commands that take it, and every
#     `singular registry COMMAND ...` invocation on any Markdown page of
#     the tree (docs, README, the release archive's run pages), however
#     the binary is named: `singular`, `"$singular"`, a path ending in
#     `/singular`.
#
# Refused, each by name: a (flag, command) pair --help prints and the table
# does not, or the table states and --help does not; an invocation using a
# flag its command's --help does not print; a subcommand whose own --help
# disagrees with the top-level help about that command. An empty side —
# no command in the help, no row in the table — is a setup failure, never
# a pass.
#
# Usage: tools/cli_flags_check.sh [repo-root]
#        SINGULAR=/path/to/singular overrides the binary, which is otherwise
#        built from the repository's offchain flake.
#        tools/cli_flags_check.sh --pages [repo-root] prints the pages read.
set -euo pipefail

# Every Markdown page in the tree — the docs site, the README, the release
# archive's run pages, the specifications — discovered, never listed;
# build and dependency directories are not pages.
markdown_pages() {
  find "$1" \( -name .git -o -name dist-newstyle -o -name node_modules \
    -o -name .lake -o -name result -o -name 'result-*' \) -prune \
    -o -name '*.md' -type f -print | sort
}

if [ "${1:-}" = --pages ]; then
  markdown_pages "${2:-.}"
  exit 0
fi

root=${1:-.}
table_doc="$root/docs/singular-node.md"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

singular=${SINGULAR:-}
if [ -z "$singular" ]; then
  singular="$(nix build --quiet --no-link --print-out-paths "$root/offchain#singular")/bin/singular"
fi

# command flag lines ("CMD FLAG"), one per pair, from one help text.
help_pairs() {
  awk '
    /^  singular registry [a-z]+/ { cmd = $3; usage = 1 }
    usage && /^  singular registry [a-z]+/ || usage && /^      / {
      line = $0
      while (match(line, /--[a-z][a-z-]*/)) {
        flags[cmd] = flags[cmd] " " substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
      if ($0 ~ /--wallet-skey/) writes[cmd] = 1
      cmds[cmd] = 1
      next
    }
    /^$/ { usage = 0 }
    !usage {
      line = $0
      scope = ""
      if (line ~ /Every command also takes/) scope = "every"
      else if (line ~ /Write commands also take/) scope = "writes"
      while (match(line, /--[a-z][a-z-]*/)) {
        f = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (scope == "") { print "UNATTRIBUTED " f; continue }
        notes[scope] = notes[scope] " " f
      }
    }
    END {
      for (c in cmds) {
        n = split(flags[c] " " notes["every"] (writes[c] ? " " notes["writes"] : ""), fs, " ")
        for (i = 1; i <= n; i++) if (fs[i] != "") print c, fs[i]
      }
    }
  ' | sort -u
}

"$singular" --help >"$scratch/help" 2>&1 || {
  echo "SETUP-FAIL: '$singular --help' exited non-zero" >&2
  exit 2
}
help_pairs <"$scratch/help" >"$scratch/help.pairs"
status=0
if grep '^UNATTRIBUTED ' "$scratch/help.pairs" | sed 's/^UNATTRIBUTED /--help prints a flag no command takes: /' >&2; then
  status=1
fi
sed -i '/^UNATTRIBUTED /d' "$scratch/help.pairs"
mapfile -t commands < <(cut -d' ' -f1 "$scratch/help.pairs" | sort -u)
if [ ${#commands[@]} -eq 0 ]; then
  echo "EMPTY EXTENT: singular --help names no registry command" >&2
  exit 2
fi
mapfile -t writes < <(grep ' --wallet-skey$' "$scratch/help.pairs" | cut -d' ' -f1)

# Each command's own --help agrees with the top-level help about it.
for c in "${commands[@]}"; do
  "$singular" registry "$c" --help >"$scratch/help.$c" 2>&1 || {
    echo "singular registry $c --help exited non-zero" >&2
    status=1
    continue
  }
  if ! diff <(grep "^$c " "$scratch/help.pairs") \
    <(help_pairs <"$scratch/help.$c" | grep "^$c ") >"$scratch/diff.$c"; then
    echo "singular registry $c --help disagrees with singular --help about $c:" >&2
    sed 's/^/  /' "$scratch/diff.$c" >&2
    status=1
  fi
done

# The settings table: "| `--flag ...` [or `--flag`] | COMMANDS | why |".
[ -f "$table_doc" ] || {
  echo "SETUP-FAIL: no $table_doc" >&2
  exit 2
}
number_word() {
  case "$1" in
    one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;;
    five) echo 5 ;; six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;;
    *) echo "?" ;;
  esac
}
awk '/^## The settings you give/ { t = 1; next } t && /^## / { exit } t && /^\| `--/' "$table_doc" >"$scratch/rows"
if [ ! -s "$scratch/rows" ]; then
  echo "EMPTY EXTENT: $table_doc has no settings table row" >&2
  exit 2
fi
: >"$scratch/doc.pairs"
while IFS= read -r row; do
  flagcell=$(cut -d'|' -f2 <<<"$row")
  cmdcell=$(cut -d'|' -f3 <<<"$row" | sed 's/^ *//; s/ *$//')
  mapfile -t rowflags < <(grep -oE -- '--[a-z][a-z-]*' <<<"$flagcell")
  applies=()
  if [[ $cmdcell =~ ^all\ ([a-z]+)$ ]]; then
    n=$(number_word "${BASH_REMATCH[1]}")
    [ "$n" = "${#commands[@]}" ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but --help names ${#commands[@]} commands" >&2
      status=1
    }
    applies=("${commands[@]}")
  elif [[ $cmdcell =~ ^the\ ([a-z]+)\ writes$ ]]; then
    n=$(number_word "${BASH_REMATCH[1]}")
    [ "$n" = "${#writes[@]}" ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but --help names ${#writes[@]} write commands" >&2
      status=1
    }
    applies=("${writes[@]}")
  else
    mapfile -t applies < <(grep -oE '`[a-z]+`' <<<"$cmdcell" | tr -d '`')
  fi
  if [ ${#rowflags[@]} -eq 0 ] || [ ${#applies[@]} -eq 0 ]; then
    echo "settings table: row names no flag or no command: $row" >&2
    status=1
    continue
  fi
  for f in "${rowflags[@]}"; do
    for c in "${applies[@]}"; do echo "$c $f"; done
  done >>"$scratch/doc.pairs"
done <"$scratch/rows"
sort -u -o "$scratch/doc.pairs" "$scratch/doc.pairs"

comm -23 "$scratch/help.pairs" "$scratch/doc.pairs" | while read -r c f; do
  echo "undocumented: singular registry $c takes $f (--help) but the settings table does not say so" >&2
done
comm -13 "$scratch/help.pairs" "$scratch/doc.pairs" | while read -r c f; do
  echo "documented, not in --help: the settings table gives $f to singular registry $c" >&2
done
if ! cmp -s "$scratch/help.pairs" "$scratch/doc.pairs"; then status=1; fi

# Every documented invocation uses only flags its command's --help prints.
mapfile -t pages < <(markdown_pages "$root")
[ ${#pages[@]} -gt 0 ] || {
  echo "EMPTY EXTENT: no Markdown page under $root" >&2
  exit 2
}
invocations=0
for page in "${pages[@]}"; do
  rel=${page#"$root"/}
  while IFS=$'\t' read -r line c flags; do
    invocations=$((invocations + 1))
    for f in $flags; do
      grep -qx "$c $f" "$scratch/help.pairs" || {
        echo "$rel:$line: singular registry $c $f — $c's --help prints no $f" >&2
        status=1
      }
    done
  done < <(awk '
    function flush() {
      if (cmd != "") {
        out = ""; s = acc
        while (match(s, /--[a-z][a-z-]*/)) { out = out " " substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
        print start "\t" cmd "\t" out
      }
      cmd = ""; acc = ""
    }
    {
      if (cmd != "") { acc = acc " " $0; if ($0 !~ /\\[[:space:]]*$/) flush(); next }
      if (match($0, /(^|[^A-Za-z0-9_-])("?[$][{]?singular[}]?"?|[A-Za-z0-9_.~\/-]*singular)[ \t]+registry[ \t]+[a-z]+/)) {
        n = split(substr($0, RSTART, RLENGTH), w, /[ \t]+/)
        cmd = w[n]; start = NR; acc = substr($0, RSTART + RLENGTH)
        if ($0 !~ /\\[[:space:]]*$/) flush()
      }
    }
    END { flush() }
  ' "$page")
done

if [ $status -ne 0 ]; then
  echo "FAIL cli-flags: see the lines above" >&2
  exit 1
fi
echo "PASS cli-flags: $(wc -l <"$scratch/help.pairs") (command, flag) pairs over ${#commands[@]} commands agree between singular --help and docs/singular-node.md; $invocations documented invocations use only printed flags"

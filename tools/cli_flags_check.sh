#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks are literal Markdown here, never expansions
# The flags documented for `singular` and `open-datum` are the flags
# each binary's --help prints.
#
# Two sides, from two sources:
#
#   * the binaries: `singular --help`, and `singular registry COMMAND --help`
#     (`singular submit --help` for the submit verb, `singular wallet VERB
#     --help` for a wallet verb) for every command the help names; `open-datum --help`, and
#     `open-datum COMMAND --help` for every command it names. A command's
#     flags are those on its usage lines, plus those a note gives to
#     "every command" or to the "write commands" (the commands whose usage
#     takes --wallet-skey). A flag the help prints anywhere else belongs to
#     no command and is refused.
#   * the documentation: the settings table of docs/singular-node.md, one
#     row per flag naming the commands that take it, and every
#     `singular registry WORD ...` and every `open-datum WORD ...`
#     invocation on any Markdown page of the tree (docs, README, the release
#     archive's run pages), however the binary is named: `singular`,
#     `"$singular"`, a path ending in `/singular`; `open-datum`,
#     `"$open_datum"`, `"$open-datum"`, a path ending in `/open-datum`
#     or `/open_datum`. Only code counts as invocation: a fenced code
#     block other than a mermaid diagram, or an inline code span that
#     carries flags; plain prose, diagram labels and bare name mentions
#     never are. The one documented refusal is recognised only by the
#     page's own sentence form about `singular` refusing `insert`,
#     `update` and `terminate` (fixed-string match on its distinctive
#     clause), never by a substring in an argument value.
#
# The table names commands plainly (`create`, `fold`, ...) meaning every
# binary that has the command, or qualified (`singular create`,
# `open-datum insert`) meaning one binary only. `all five` is singular's
# five commands, `all six` is open-datum's six; a cell naming both covers
# all eleven pairs. `the four singular writes` and `the five open-datum
# writes` cover the writes of each binary; a cell naming both covers all
# nine write pairs.
#
# Refused, each by name: a (binary, flag, command) triple --help prints and
# the table does not, or the table states and --help does not; an invocation
# whose word is not a verb its binary's --help lists; an invocation
# using a flag its command's --help does not print; a subcommand whose own
# --help disagrees with the top-level help about that command. An empty side —
# no command in either help, no row in the table — is a setup failure, never
# a pass.
#
# Usage: tools/cli_flags_check.sh [repo-root]
#        SINGULAR=/path/to/singular OPEN_DATUM=/path/to/open-datum override
#        the binaries, which are otherwise built from the repository's
#        offchain flake and the application's offchain flake.
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
open_datum=${OPEN_DATUM:-}
if [ -z "$open_datum" ]; then
  open_datum="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")/bin/open-datum"
fi

# command flag lines ("CMD FLAG"), one per pair, from one singular help text.
# Wallet verbs are commands of their own group, named "wallet VERB", so
# the table can name them and refuse them apart from the registry group.
singular_pairs() {
  awk '
    /^  singular registry [a-z]+/ { cmd = $3; usage = 1 }
    /^  singular submit( |$)/ { cmd = "submit"; usage = 1 }
    /^  singular wallet [a-z]+/ { cmd = "wallet " $3; usage = 1 }
    usage && /^  singular ((registry|wallet) [a-z]+|submit( |$))/ || usage && /^      / {
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
      else if (line ~ /Every registry command also takes/) scope = "registry"
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
        n = split(flags[c] " " notes["every"] (writes[c] ? " " notes["writes"] : "") (c !~ /^wallet / ? " " notes["registry"] : ""), fs, " ")
        for (i = 1; i <= n; i++) if (fs[i] != "") print c, fs[i]
      }
    }
  ' | sort -u
}

# command flag lines ("CMD FLAG") from one open-datum help text.
opendatum_pairs() {
  awk '
    /^  open-datum [a-z]+/ { cmd = $2; usage = 1 }
    usage && /^  open-datum [a-z]+/ || usage && /^      / {
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

status=0

"$singular" --help >"$scratch/help.singular" 2>&1 || {
  echo "SETUP-FAIL: '$singular --help' exited non-zero" >&2
  exit 2
}
singular_pairs <"$scratch/help.singular" >"$scratch/singular.pairs"
if grep '^UNATTRIBUTED ' "$scratch/singular.pairs" | sed 's/^UNATTRIBUTED /--help prints a flag no command takes: /' >&2; then
  status=1
fi
sed -i '/^UNATTRIBUTED /d' "$scratch/singular.pairs"
mapfile -t singular_commands < <(awk '{ if ($1 == "wallet") print $1 " " $2; else print $1 }' "$scratch/singular.pairs" | sort -u)
if [ ${#singular_commands[@]} -eq 0 ]; then
  echo "EMPTY EXTENT: singular --help names no registry command" >&2
  exit 2
fi
mapfile -t singular_writes < <(grep ' --wallet-skey$' "$scratch/singular.pairs" | cut -d' ' -f1 | sort -u)

"$open_datum" --help >"$scratch/help.opendatum" 2>&1 || {
  echo "SETUP-FAIL: '$open_datum --help' exited non-zero" >&2
  exit 2
}
opendatum_pairs <"$scratch/help.opendatum" >"$scratch/opendatum.pairs"
if grep '^UNATTRIBUTED ' "$scratch/opendatum.pairs" | sed 's/^UNATTRIBUTED /open-datum --help prints a flag no command takes: /' >&2; then
  status=1
fi
sed -i '/^UNATTRIBUTED /d' "$scratch/opendatum.pairs"
mapfile -t od_commands < <(cut -d' ' -f1 "$scratch/opendatum.pairs" | sort -u)
if [ ${#od_commands[@]} -eq 0 ]; then
  echo "EMPTY EXTENT: open-datum --help names no command" >&2
  exit 2
fi
mapfile -t od_writes < <(grep ' --wallet-skey$' "$scratch/opendatum.pairs" | cut -d' ' -f1 | sort -u)

# Namespaced triples "BIN CMD FLAG" for the comparison.
: >"$scratch/help.pairs"
sed 's/^/singular /' "$scratch/singular.pairs" >>"$scratch/help.pairs"
while read -r c f; do echo "open-datum $c $f"; done <"$scratch/opendatum.pairs" >>"$scratch/help.pairs"
sort -u -o "$scratch/help.pairs" "$scratch/help.pairs"

# Each command's own --help agrees with the top-level help about it.
for c in "${singular_commands[@]}"; do
  case $c in
    "wallet "*)
      # "wallet VERB" is one command name of two words: split it so the
      # expansion stays quoted.
      read -r -a c_words <<<"$c"
      "$singular" "${c_words[@]}" --help >"$scratch/help.singular.$c" 2>&1 || {
        echo "singular $c --help exited non-zero" >&2
        status=1
        continue
      }
      ;;
    submit) "$singular" submit --help >"$scratch/help.singular.$c" 2>&1 || {
      echo "singular submit --help exited non-zero" >&2
      status=1
      continue
    } ;;
    *) "$singular" registry "$c" --help >"$scratch/help.singular.$c" 2>&1 || {
      echo "singular registry $c --help exited non-zero" >&2
      status=1
      continue
    } ;;
  esac
  if ! diff <(grep "^$c " "$scratch/singular.pairs") \
    <(singular_pairs <"$scratch/help.singular.$c" | grep "^$c ") >"$scratch/diff.singular.$c"; then
    echo "singular registry $c --help disagrees with singular --help about $c:" >&2
    sed 's/^/  /' "$scratch/diff.singular.$c" >&2
    status=1
  fi
done
for c in "${od_commands[@]}"; do
  "$open_datum" "$c" --help >"$scratch/help.opendatum.$c" 2>&1 || {
    echo "open-datum $c --help exited non-zero" >&2
    status=1
    continue
  }
  if ! diff <(grep "^$c " "$scratch/opendatum.pairs") \
    <(opendatum_pairs <"$scratch/help.opendatum.$c" | grep "^$c ") >"$scratch/diff.opendatum.$c"; then
    echo "open-datum $c --help disagrees with open-datum --help about $c:" >&2
    sed 's/^/  /' "$scratch/diff.opendatum.$c" >&2
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
has_cmd() { # has_cmd BINARY CMD: that binary's help names the command
  local bin="$1" cmd="$2"
  if [ "$bin" = singular ]; then
    grep -qx -- "$cmd" <<<"$(printf '%s\n' "${singular_commands[@]}")"
  else
    grep -qx -- "$cmd" <<<"$(printf '%s\n' "${od_commands[@]}")"
  fi
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
  if [[ "$cmdcell" == *"all five"* && "$cmdcell" == *"all six"* ]]; then
    [ "${#singular_commands[@]}" = 5 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_commands[@]} commands (wanted five)" >&2
      status=1
    }
    [ "${#od_commands[@]}" = 6 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but open-datum --help names ${#od_commands[@]} commands (wanted six)" >&2
      status=1
    }
    for c in "${singular_commands[@]}"; do applies+=("singular $c"); done
    for c in "${od_commands[@]}"; do applies+=("open-datum $c"); done
  elif [[ "$cmdcell" == *"all five"* ]]; then
    [ "${#singular_commands[@]}" = 5 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_commands[@]} commands (wanted five)" >&2
      status=1
    }
    for c in "${singular_commands[@]}"; do applies+=("singular $c"); done
  elif [[ "$cmdcell" == *"all six"* && "$cmdcell" == *"singular"* && "$cmdcell" == *"open-datum"* ]]; then
    [ "${#singular_commands[@]}" = 6 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_commands[@]} commands (wanted six)" >&2
      status=1
    }
    [ "${#od_commands[@]}" = 6 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but open-datum --help names ${#od_commands[@]} commands (wanted six)" >&2
      status=1
    }
    for c in "${singular_commands[@]}"; do applies+=("singular $c"); done
    for c in "${od_commands[@]}"; do applies+=("open-datum $c"); done
  elif [[ "$cmdcell" == *"all six"* && "$cmdcell" == *"singular"* ]]; then
    [ "${#singular_commands[@]}" = 6 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_commands[@]} commands (wanted six)" >&2
      status=1
    }
    for c in "${singular_commands[@]}"; do applies+=("singular $c"); done
  elif [[ "$cmdcell" == *"all six"* ]]; then
    [ "${#od_commands[@]}" = 6 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but open-datum --help names ${#od_commands[@]} commands (wanted six)" >&2
      status=1
    }
    for c in "${od_commands[@]}"; do applies+=("open-datum $c"); done
  elif [[ "$cmdcell" == *"four"* && "$cmdcell" == *"five"* && "$cmdcell" == *"writes"* ]]; then
    [ "${#singular_writes[@]}" = 4 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_writes[@]} write commands (wanted four)" >&2
      status=1
    }
    [ "${#od_writes[@]}" = 5 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but open-datum --help names ${#od_writes[@]} write commands (wanted five)" >&2
      status=1
    }
    for c in "${singular_writes[@]}"; do applies+=("singular $c"); done
    for c in "${od_writes[@]}"; do applies+=("open-datum $c"); done
  elif [[ "$cmdcell" == *"four"* && "$cmdcell" == *"writes"* ]]; then
    [ "${#singular_writes[@]}" = 4 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_writes[@]} write commands (wanted four)" >&2
      status=1
    }
    for c in "${singular_writes[@]}"; do applies+=("singular $c"); done
  elif [[ "$cmdcell" == *"five"* && "$cmdcell" == *"writes"* ]]; then
    [ "${#od_writes[@]}" = 5 ] || {
      echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but open-datum --help names ${#od_writes[@]} write commands (wanted five)" >&2
      status=1
    }
    for c in "${od_writes[@]}"; do applies+=("open-datum $c"); done
  elif [[ $cmdcell =~ ^all\ ([a-z]+)$ ]]; then
    n=$(number_word "${BASH_REMATCH[1]}")
    echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_commands[@]} commands and open-datum --help names ${#od_commands[@]} commands" >&2
    status=1
    _want="$n"
    if [ "$_want" = "${#singular_commands[@]}" ]; then
      for c in "${singular_commands[@]}"; do applies+=("singular $c"); done
    elif [ "$_want" = "${#od_commands[@]}" ]; then
      for c in "${od_commands[@]}"; do applies+=("open-datum $c"); done
    fi
  elif [[ $cmdcell =~ ^the\ ([a-z]+)\ writes$ ]]; then
    n=$(number_word "${BASH_REMATCH[1]}")
    echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_writes[@]} write commands and open-datum --help names ${#od_writes[@]} write commands" >&2
    status=1
    if [ "$n" = "${#singular_writes[@]}" ]; then
      for c in "${singular_writes[@]}"; do applies+=("singular $c"); done
    elif [ "$n" = "${#od_writes[@]}" ]; then
      for c in "${od_writes[@]}"; do applies+=("open-datum $c"); done
    fi
  else
    while IFS= read -r ticked; do
      [ -n "$ticked" ] || continue
      inner=${ticked#\`}
      inner=${inner%\`}
      # qualified `singular create` or `open-datum insert`, else plain `create`;
      # every word after the binary is the command's name, so the wallet
      # verbs `singular wallet create` keep their group word
      if [[ "$inner" == *" "* ]]; then
        bin=${inner%% *}
        cmd=${inner#* }
        bin=${bin//[_-]/-}
        if [ "$bin" != singular ] && [ "$bin" != open-datum ]; then
          echo "settings table: row names unknown binary '$bin': $row" >&2
          status=1
          continue
        fi
        applies+=("$bin $cmd")
      else
        cmd="$inner"
        found=0
        if has_cmd singular "$cmd"; then
          applies+=("singular $cmd")
          found=1
        fi
        if has_cmd open-datum "$cmd"; then
          applies+=("open-datum $cmd")
          found=1
        fi
        if [ "$found" = 0 ]; then
          echo "settings table: row names unknown command '$cmd': $row" >&2
          status=1
        fi
      fi
    done < <(grep -oE '`[^`]+`' <<<"$cmdcell")
  fi
  if [ ${#rowflags[@]} -eq 0 ] || [ ${#applies[@]} -eq 0 ]; then
    echo "settings table: row names no flag or no command: $row" >&2
    status=1
    continue
  fi
  for f in "${rowflags[@]}"; do
    for a in "${applies[@]}"; do echo "$a $f"; done
  done >>"$scratch/doc.pairs"
done <"$scratch/rows"
sort -u -o "$scratch/doc.pairs" "$scratch/doc.pairs"

comm -23 "$scratch/help.pairs" "$scratch/doc.pairs" | while read -r b c1 rest; do
  cmd=$c1
  f=$rest
  case $c1 in wallet)
    read -r verb f <<<"$rest"
    cmd="wallet $verb"
    ;;
  esac
  if [ "$b" = singular ]; then
    case $cmd in
      wallet* | submit) echo "undocumented: singular $cmd takes $f (--help) but the settings table does not say so" >&2 ;;
      *) echo "undocumented: singular registry $cmd takes $f (--help) but the settings table does not say so" >&2 ;;
    esac
  else
    echo "undocumented: open-datum $cmd takes $f (--help) but the settings table does not say so" >&2
  fi
done
comm -13 "$scratch/help.pairs" "$scratch/doc.pairs" | while read -r b c1 rest; do
  cmd=$c1
  f=$rest
  case $c1 in wallet)
    read -r verb f <<<"$rest"
    cmd="wallet $verb"
    ;;
  esac
  if [ "$b" = singular ]; then
    case $cmd in
      wallet* | submit) echo "documented, not in --help: the settings table gives $f to singular $cmd" >&2 ;;
      *) echo "documented, not in --help: the settings table gives $f to singular registry $cmd" >&2 ;;
    esac
  else
    echo "documented, not in --help: the settings table gives $f to open-datum $cmd" >&2
  fi
done
if ! cmp -s "$scratch/help.pairs" "$scratch/doc.pairs"; then status=1; fi

# Every documented invocation uses only flags its binary's --help prints.
mapfile -t pages < <(markdown_pages "$root")
[ ${#pages[@]} -gt 0 ] || {
  echo "EMPTY EXTENT: no Markdown page under $root" >&2
  exit 2
}
invocations=0
is_removed() {
  if [ "$1" = singular ]; then
    [[ "$2" == insert || "$2" == update || "$2" == terminate ]]
  else
    [[ "$2" == reclaim || "$2" == reject ]]
  fi
}
for page in "${pages[@]}"; do
  rel=${page#"$root"/}
  while IFS=$'\t' read -r line b c flags; do
    if ! has_cmd "$b" "$c"; then
      # The documented refusal is recognised only by the page's own
      # sentence form (fixed-string match on its distinctive clause),
      # never by a substring in an argument value.
      srcline=$(sed -n "${line}p" "$page")
      if [ "$b" = singular ] && is_removed "$b" "$c" \
        && grep -qF -- '`singular registry insert`, `update` and `terminate` are each refused as an unknown command' <<<"$srcline"; then
        # The page documents the refusal: not an invocation.
        continue
      fi
      invocations=$((invocations + 1))
      if [ "$b" = singular ]; then
        echo "$rel:$line: singular registry $c — $c is not a command singular supports" >&2
      else
        echo "$rel:$line: open-datum $c — $c is not a command open-datum supports" >&2
      fi
      status=1
      continue
    fi
    invocations=$((invocations + 1))
    for f in $flags; do
      grep -qx "$b $c $f" "$scratch/help.pairs" || {
        if [ "$b" = singular ]; then
          echo "$rel:$line: singular registry $c $f — $c's --help prints no $f" >&2
        else
          echo "$rel:$line: open-datum $c $f — $c's --help prints no $f" >&2
        fi
        status=1
      }
    done
  done < <({
    awk '
      function flush() {
        if (cmd != "") {
          out = ""; s = acc
          while (match(s, /--[a-z][a-z-]*/)) { out = out " " substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
          print start "\tsingular\t" cmd "\t" out
        }
        cmd = ""; acc = ""
      }
      /^```/ {
        if (!in_fence) { lang = $0; sub(/^```/, "", lang); in_fence = 1 }
        else { in_fence = 0; lang = "" }
      }
      {
        if (cmd != "") { acc = acc " " $0; if ($0 !~ /\\[[:space:]]*$/) flush(); next }
        if (match($0, /(^|[^A-Za-z0-9_-])("?[$][{]?singular[}]?"?|[A-Za-z0-9_.~\/-]*singular)[ \t]+((registry|wallet)[ \t]+[a-z][a-z-]*|submit)/) && substr($0, RSTART + RLENGTH, 1) !~ /[a-z-]/) {
          m = substr($0, RSTART, RLENGTH)
          n = split(m, w, /[ \t]+/)
          verb = w[n]
          if (w[n-1] == "wallet") verb = "wallet " verb
          vstart = RSTART + RLENGTH - length(verb)
          pre = substr($0, 1, vstart-1)
          tmp = pre
          inside = (gsub(/`/, "`", tmp) % 2 == 1)
          fence_code = (in_fence && lang !~ /^mermaid/)
          if (!fence_code && !inside) next
          rest0 = substr($0, vstart + length(verb))
          if (!fence_code) {
            if (match(rest0, /`/)) rest0 = substr(rest0, 1, RSTART-1)
            if (rest0 !~ /--[a-z]/) next
          }
          cmd = verb; start = NR
          acc = rest0
          if ($0 !~ /\\[[:space:]]*$/) flush()
        }
      }
      END { flush() }
    ' "$page"
    awk '
      function flush() {
        if (cmd != "") {
          out = ""; s = acc
          while (match(s, /--[a-z][a-z-]*/)) { out = out " " substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
          print start "\topen-datum\t" cmd "\t" out
        }
        cmd = ""; acc = ""
      }
      /^```/ {
        if (!in_fence) { lang = $0; sub(/^```/, "", lang); in_fence = 1 }
        else { in_fence = 0; lang = "" }
      }
      {
        if (cmd != "") { acc = acc " " $0; if ($0 !~ /\\[[:space:]]*$/) flush(); next }
        if (match($0, /(^|[^A-Za-z0-9_-])("?[$][{]?open[-_]datum[}]?"?|[A-Za-z0-9_.~\/-]*open[-_]datum)[ \t]+[a-z][a-z-]*/)) {
          m = substr($0, RSTART, RLENGTH)
          n = split(m, w, /[ \t]+/)
          verb = w[n]
          vstart = RSTART + RLENGTH - length(verb)
          pre = substr($0, 1, vstart-1)
          tmp = pre
          inside = (gsub(/`/, "`", tmp) % 2 == 1)
          fence_code = (in_fence && lang !~ /^mermaid/)
          if (!fence_code && !inside) next
          rest0 = substr($0, vstart + length(verb))
          if (!fence_code) {
            if (match(rest0, /`/)) rest0 = substr(rest0, 1, RSTART-1)
            if (rest0 !~ /--[a-z]/) next
          }
          cmd = verb; start = NR
          acc = rest0
          if ($0 !~ /\\[[:space:]]*$/) flush()
        }
      }
      END { flush() }
    ' "$page"
  })
done

if [ $status -ne 0 ]; then
  echo "FAIL cli-flags: see the lines above" >&2
  exit 1
fi
echo "PASS cli-flags: $(grep -c '^singular ' "$scratch/help.pairs") pairs over ${#singular_commands[@]} singular commands and $(grep -c '^open-datum ' "$scratch/help.pairs") pairs over ${#od_commands[@]} open-datum commands agree with docs/singular-node.md; $invocations documented invocations use only printed flags"

#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks are literal Markdown here, never expansions
# The flags documented for `singular` and `open-datum` are the flags
# each binary's --help prints.
#
# Two sides, from two sources:
#
#   * the binaries: the commands `singular --help` and `open-datum --help`
#     name in their "All commands" table, and for each the settings its own
#     help lists (`singular registry COMMAND --help`, `singular submit
#     --help`, `singular wallet VERB --help`, `singular state create
#     --help`; `open-datum COMMAND --help`, `open-datum state VERB --help`,
#     `open-datum registration VERB --help`). A command's flags are the
#     `option:` and `switch:` entries of its "Available settings"; the help
#     and version switches belong to no command. The write commands are those
#     whose help lists --wallet-skey.
#   * the documentation: the settings table of docs/singular-node.md, one
#     row per flag naming the commands that take it, and every
#     `singular registry WORD ...`, `singular wallet WORD ...`, `singular
#     state WORD ...`, `singular submit ...`, `open-datum WORD ...`,
#     `open-datum state WORD ...` and `open-datum registration WORD ...`
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
# `open-datum registration book`, `singular state create`, `open-datum registration
# book`) meaning one binary only. `all five` and `all six` are counts of a
# binary's commands, refused when its help names another number. `the five
# singular writes` and `the ten open-datum writes` cover the writes of each
# binary, counted from the help; a cell naming both covers both sets, and a
# count the help does not give is refused.
#
# Refused, each by name: a (binary, flag, command) triple --help prints and
# the table does not, or the table states and --help does not; an invocation
# whose word is not a verb its binary's --help lists; an invocation
# using a flag its command's --help does not print; a command the overview
# names whose own --help fails. An empty side —
# no command in either help, no row in the table — is a setup failure, never
# a pass.
#
# Usage: tools/cli_flags_check.sh [repo-root]
#        SINGULAR=/path/to/singular OPEN_DATUM=/path/to/open-datum override
#        the binaries, which are otherwise built from the repository's
#        offchain flake and the application's offchain flake.
#        tools/cli_flags_check.sh --pages [repo-root] prints the pages read.
set -euo pipefail

# Every current Markdown page is discovered, including pages outside navigation.
# specs/ records each plan's historical command surface. onchain-release/ holds
# the old release run pages; its exclusion leaves when that archive is rewritten.
# Only those two root-level classes are historical. A docs/specs/ page is current.
markdown_pages() {
  local page_root=${1%/}
  find "$page_root" \( -path "$page_root/specs" -o -path "$page_root/onchain-release" \
    -o -name .git -o -name dist-newstyle -o -name node_modules \
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

# The commands a program's overview names, one per line: the "All commands:"
# table lists `PROGRAM WORDS  summary` rows. singular's registry commands are
# named plainly (`create`), its wallet and state verbs `wallet VERB` and
# `state VERB`, and `submit` as itself, so the settings table can name them;
# open-datum's are its verbs, `state VERB` and `registration VERB`.
overview_commands() {
  awk -v prog="$1" '
    /^All commands:/ { t = 1; next }
    t && /^$/ { exit }
    t && $1 == prog {
      if (prog == "singular" && $2 == "registry") print $3
      else if (prog == "singular" && ($2 == "wallet" || $2 == "state")) print $2 " " $3
      else if (prog == "open-datum" && ($2 == "state" || $2 == "registration" || $2 == "holding")) print $2 " " $3
      else print $2
    }
  '
}

# The flags one command's help lists among its settings, one per line: the
# `option: --flag ...` and `switch: --flag` entries of its "Available
# settings". The help and version switches belong to no command.
page_flags() {
  awk '
    /^Available settings:/ { t = 1; next }
    t && /^[A-Za-z]/ { exit }
    t && /^  (option|switch): / {
      if (match($0, /--[a-z][a-z-]*/)) {
        f = substr($0, RSTART, RLENGTH)
        if (f != "--help" && f != "--version") print f
      }
    }
  ' | sort -u
}

# Print the command-line words that reach one command's own help.
help_words() { # help_words PROGRAM COMMAND
  case "$1:$2" in
    singular:"wallet "* | singular:"state "*) echo "${2}" ;;
    singular:submit) echo submit ;;
    singular:*) echo "registry $2" ;;
    *) echo "$2" ;;
  esac
}

status=0

"$singular" --help >"$scratch/help.singular" 2>&1 || {
  echo "SETUP-FAIL: '$singular --help' exited non-zero" >&2
  exit 2
}
mapfile -t singular_commands < <(overview_commands singular <"$scratch/help.singular")
if [ ${#singular_commands[@]} -eq 0 ]; then
  echo "EMPTY EXTENT: singular --help names no command" >&2
  exit 2
fi
: >"$scratch/singular.pairs"
for c in "${singular_commands[@]}"; do
  read -r -a words <<<"$(help_words singular "$c")"
  if "$singular" "${words[@]}" --help >"$scratch/help.singular.$c" 2>&1; then
    page_flags <"$scratch/help.singular.$c" | sed "s/^/$c /" >>"$scratch/singular.pairs"
  else
    echo "singular ${words[*]} --help exited non-zero" >&2
    status=1
  fi
done
sort -u -o "$scratch/singular.pairs" "$scratch/singular.pairs"
mapfile -t singular_writes < <(grep ' --wallet-skey$' "$scratch/singular.pairs" | sed 's/ --wallet-skey$//' | sort -u)

"$open_datum" --help >"$scratch/help.opendatum" 2>&1 || {
  echo "SETUP-FAIL: '$open_datum --help' exited non-zero" >&2
  exit 2
}
mapfile -t od_commands < <(overview_commands open-datum <"$scratch/help.opendatum")
if [ ${#od_commands[@]} -eq 0 ]; then
  echo "EMPTY EXTENT: open-datum --help names no command" >&2
  exit 2
fi
: >"$scratch/opendatum.pairs"
for c in "${od_commands[@]}"; do
  read -r -a words <<<"$c"
  if "$open_datum" "${words[@]}" --help >"$scratch/help.opendatum.$c" 2>&1; then
    page_flags <"$scratch/help.opendatum.$c" | sed "s/^/$c /" >>"$scratch/opendatum.pairs"
  else
    echo "open-datum $c --help exited non-zero" >&2
    status=1
  fi
done
sort -u -o "$scratch/opendatum.pairs" "$scratch/opendatum.pairs"
mapfile -t od_writes < <(grep ' --wallet-skey$' "$scratch/opendatum.pairs" | sed 's/ --wallet-skey$//' | sort -u)

# Namespaced triples "BIN CMD FLAG" for the comparison.
: >"$scratch/help.pairs"
sed 's/^/singular /' "$scratch/singular.pairs" >>"$scratch/help.pairs"
sed 's/^/open-datum /' "$scratch/opendatum.pairs" >>"$scratch/help.pairs"
sort -u -o "$scratch/help.pairs" "$scratch/help.pairs"

# The settings table: "| `--flag ...` [or `--flag`] | COMMANDS | why |".
[ -f "$table_doc" ] || {
  echo "SETUP-FAIL: no $table_doc" >&2
  exit 2
}
number_word() {
  case "$1" in
    one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;;
    five) echo 5 ;; six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;;
    nine) echo 9 ;; ten) echo 10 ;; eleven) echo 11 ;; twelve) echo 12 ;;
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
  elif [[ "$cmdcell" == *"singular write"* || "$cmdcell" == *"open-datum writes"* ]]; then
    if [[ $cmdcell =~ the\ ([a-z]+)\ singular\ writes? ]]; then
      word=${BASH_REMATCH[1]}
      [ "${#singular_writes[@]}" = "$(number_word "$word")" ] || {
        echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but singular --help names ${#singular_writes[@]} write commands (wanted $word)" >&2
        status=1
      }
      for c in "${singular_writes[@]}"; do applies+=("singular $c"); done
    fi
    if [[ $cmdcell =~ the\ ([a-z]+)\ open-datum\ writes ]]; then
      word=${BASH_REMATCH[1]}
      [ "${#od_writes[@]}" = "$(number_word "$word")" ] || {
        echo "settings table: '${rowflags[*]}' applies to \"$cmdcell\", but open-datum --help names ${#od_writes[@]} write commands (wanted $word)" >&2
        status=1
      }
      for c in "${od_writes[@]}"; do applies+=("open-datum $c"); done
    fi
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
      # qualified `singular create` or `open-datum registration book`, else plain `create`;
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

# The words a person types to reach a command: a pair line is
# "BINARY COMMAND... FLAG", so the command is everything between the two.
spoken() { # spoken BINARY COMMAND
  if [ "$1" = singular ]; then
    echo "singular $(help_words singular "$2")"
  else
    echo "open-datum $2"
  fi
}
comm -23 "$scratch/help.pairs" "$scratch/doc.pairs" | while read -r b rest; do
  echo "undocumented: $(spoken "$b" "${rest% *}") takes ${rest##* } (--help) but the settings table does not say so" >&2
done
comm -13 "$scratch/help.pairs" "$scratch/doc.pairs" | while read -r b rest; do
  echo "documented, not in --help: the settings table gives ${rest##* } to $(spoken "$b" "${rest% *}")" >&2
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
      echo "$rel:$line: $(spoken "$b" "$c") — $c is not a command $b supports" >&2
      status=1
      continue
    fi
    invocations=$((invocations + 1))
    for f in $flags; do
      grep -qx "$b $c $f" "$scratch/help.pairs" || {
        echo "$rel:$line: $(spoken "$b" "$c") $f — $c's --help prints no $f" >&2
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
        if (match($0, /(^|[^A-Za-z0-9_-])("?[$][{]?singular[}]?"?|[A-Za-z0-9_.~\/-]*singular)[ \t]+((registry|wallet|state)[ \t]+[a-z][a-z-]*|submit)/) && substr($0, RSTART + RLENGTH, 1) !~ /[a-z-]/) {
          m = substr($0, RSTART, RLENGTH)
          n = split(m, w, /[ \t]+/)
          verb = w[n]
          if (w[n-1] == "wallet" || w[n-1] == "state") verb = w[n-1] " " verb
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
        if (match($0, /(^|[^A-Za-z0-9_-])("?[$][{]?open[-_]datum[}]?"?|[A-Za-z0-9_.~\/-]*open[-_]datum)[ \t]+((state|registration|holding)[ \t]+[a-z][a-z-]*|[a-z][a-z-]*)/)) {
          m = substr($0, RSTART, RLENGTH)
          n = split(m, w, /[ \t]+/)
          verb = w[n]
          if (w[n-1] == "state" || w[n-1] == "registration" || w[n-1] == "holding") verb = w[n-1] " " verb
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

# Every quotation of a program's help on a page is that help. A line
# `<!-- quoted-help: PROGRAM WORDS -->` followed by a fenced block says the
# block is what `PROGRAM WORDS --help` prints, without its first two lines
# (the identity of the build) and with the version printed as VERSION. A page
# quoting the program is never retyped, and none can drift from it.
quotes=0
mkdir -p "$scratch/quotes"
for page in "${pages[@]}"; do
  rel=${page#"$root"/}
  tag=$(printf '%s' "$rel" | tr '/' '_')
  while IFS=$'\t' read -r line words file; do
    [ -n "$line" ] || continue
    quotes=$((quotes + 1))
    read -r -a w <<<"$words"
    prog=${w[0]}
    case $prog in
      singular) bin=$singular ;;
      open-datum) bin=$open_datum ;;
      *)
        echo "$rel:$line: quoted help names a program that is not singular or open-datum: '$prog'" >&2
        status=1
        continue
        ;;
    esac
    if ! "$bin" "${w[@]:1}" --help >"$scratch/quote.actual" 2>&1; then
      echo "$rel:$line: $prog ${w[*]:1} --help exited non-zero" >&2
      status=1
      continue
    fi
    version=$("$bin" --version | awk '{ print $2 }')
    tail -n +3 "$scratch/quote.actual" | sed "s/${version//./\\.}/VERSION/g" >"$scratch/quote.expected"
    if ! diff -u "$scratch/quote.expected" "$file" >"$scratch/quote.diff"; then
      echo "$rel:$line: the quoted help for '$words' differs from what the program prints (- program, + page):" >&2
      sed 's/^/  /' "$scratch/quote.diff" >&2
      status=1
    fi
  done < <(awk -v out="$scratch/quotes" -v tag="$tag" '
    /^<!-- quoted-help: .* -->[[:space:]]*$/ { w = $0; sub(/^<!-- quoted-help: /, "", w); sub(/ -->[[:space:]]*$/, "", w); want = NR; next }
    want && /^```/ {
      if (!inb) { inb = 1; k++; f = out "/" tag "." k; printf "" > f; print want "\t" w "\t" f; next }
      inb = 0; want = 0; close(f); next
    }
    inb { print > f; next }
    want && !/^[[:space:]]*$/ { want = 0 }
  ' "$page")
done
if [ "$quotes" -eq 0 ]; then
  echo "EMPTY EXTENT: no page quotes a program's help" >&2
  exit 2
fi

if [ $status -ne 0 ]; then
  echo "FAIL cli-flags: see the lines above" >&2
  exit 1
fi
echo "PASS cli-flags: $(grep -c '^singular ' "$scratch/help.pairs") pairs over ${#singular_commands[@]} singular commands and $(grep -c '^open-datum ' "$scratch/help.pairs") pairs over ${#od_commands[@]} open-datum commands agree with docs/singular-node.md; $invocations documented invocations use only printed flags; $quotes quotations of a program's help are what it prints"

#!/usr/bin/env bash
# Documentation guard for the state validator and its registry owners (#271).
#
#   check.sh VALIDATORS_DIR [--reference DOCS_DIR [--reference-only]]
#   check.sh --list VALIDATORS_DIR
#
# The extent is discovered, never listed: `state.ak` plus every `.ak` module
# found under `registry/`, at any depth. Two layers, each able to fail alone:
#
# Source layer (always). For each module:
# - a module doc (`////` lines) carries the four sections `## Responsibility`,
#   `## Dependencies`, `## Assumptions` and `## Invariants`, in that order,
#   each with text of its own;
# - every public declaration — `pub fn`, `pub type`, `pub opaque type`,
#   `pub const` — and every `validator` is immediately preceded by a `///`
#   doc comment with text. A declaration is found whatever its indentation:
#   the compiler accepts an indented top-level declaration, so the guard does.
#
# Reference layer (with --reference DOCS_DIR, the output of `aiken docs` for
# the same tree). What a reader of the generated reference sees: each
# module's page exists and its module documentation renders the four
# sections in order with content under each. The members the compiler put on
# the page are discovered from the page itself and reconciled with the source
# inventory in both directions — a member on the page the source layer did
# not find, or a source export missing from the page, fails — and every
# member on the page must render a non-empty description. (Aiken renders no
# page entry for a `validator`; the source layer alone covers it.)
# `--reference-only` reports this layer alone, so its negative controls show
# it refuses a gap by itself.
#
# An extent with no registry module, no `state.ak` or no public declaration
# fails: an empty inventory is a failure, not a vacuous pass.
#
# Presence is all this establishes. Whether a doc comment is TRUE of the
# code is a review question, and no doc comment is evidence of how the
# validator behaves.
set -euo pipefail

list=0
if [ "${1:-}" = "--list" ]; then
  list=1
  shift
fi
dir=${1:?usage: check.sh VALIDATORS_DIR [--reference DOCS_DIR [--reference-only]] | check.sh --list VALIDATORS_DIR}
shift
reference=""
source_layer=1
if [ "${1:-}" = "--reference" ]; then reference=${2:?--reference needs a directory}; fi
if [ "${3:-}" = "--reference-only" ]; then source_layer=0; fi

modules=()
[ -f "$dir/state.ak" ] && modules+=("$dir/state.ak")
if [ -d "$dir/registry" ]; then
  while IFS= read -r m; do modules+=("$m"); done \
    < <(find "$dir/registry" -type f -name '*.ak' | LC_ALL=C sort)
fi

# FILE:LINE:DECLARATION for every public declaration and validator, at any
# indentation. `pub` and `validator` only open top-level declarations, and a
# line starting with them is never inside a comment.
exports() {
  awk '/^[[:space:]]*(pub[[:space:]]+(fn|type|opaque[[:space:]]+type|const)|validator)[[:space:]]+[A-Za-z_]/ {
         line = $0; sub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+/, " ", line)
         match(line, /^(pub (fn|type|opaque type|const)|validator) [A-Za-z_][A-Za-z0-9_]*/)
         print FILENAME ":" FNR ":" substr(line, RSTART, RLENGTH)
       }' "$@"
}

if [ "$list" = 1 ]; then
  if [ "${#modules[@]}" -gt 0 ]; then exports "${modules[@]}"; fi
  exit 0
fi

fail=0
report() {
  echo "FAIL $*"
  fail=1
}
source_report() { if [ "$source_layer" = 1 ]; then report "$@"; fi; }

# The four sections, in order, each with content, from lines already reduced
# to the module doc's text: headings are "## Name" lines, content is any
# other non-blank line.
sections_check() {
  local where=$1
  awk -v where="$where" '
    /^## / { heading = substr($0, 4); sub(/[[:space:]]+$/, "", heading); order = order heading "|"; body[heading] = 0; next }
    heading != "" && /[^[:space:]]/ { body[heading]++ }
    END {
      if (order !~ /Responsibility\|.*Dependencies\|.*Assumptions\|.*Invariants\|/)
        print "FAIL " where ": module doc lacks Responsibility, Dependencies, Assumptions, Invariants in order (found: " (order == "" ? "none" : order) ")"
      n = split("Responsibility Dependencies Assumptions Invariants", want, " ")
      for (i = 1; i <= n; i++) if (!(want[i] in body) || body[want[i]] == 0)
        print "FAIL " where ": module doc section " want[i] " is missing or empty"
    }'
}

[ -f "$dir/state.ak" ] || report "no state.ak under $dir"
registry=0
for m in "${modules[@]}"; do case "$m" in "$dir/registry/"*) registry=$((registry + 1)) ;; esac done
[ "$registry" -gt 0 ] || report "no registry module under $dir/registry"

total=0
checked=0
members=0
for m in "${modules[@]}"; do
  rel="${m#"$dir"/}"
  rel="${rel%.ak}"
  entries="$(exports "$m")"

  # Source layer: module doc.
  out="$(sed -n 's/^[[:space:]]*\/\/\/\/ \{0,1\}//p' "$m" | sections_check "$m")"
  if [ -n "$out" ] && [ "$source_layer" = 1 ]; then
    printf '%s\n' "$out"
    fail=1
  fi

  # Source layer: a doc comment with text directly above every export.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    total=$((total + 1))
    line="${entry#*:}"
    line="${line%%:*}"
    decl="${entry#*:*:}"
    if ! awk -v n="$line" '
        FNR < n { if ($0 ~ /^[[:space:]]*\/\/\/( |$)/) { if ($0 ~ /^[[:space:]]*\/\/\/ .*[^[:space:]]/) text = 1 } else { text = 0 } }
        FNR == n { exit !(text) }' "$m"; then
      source_report "$m:$line: '$decl' has no doc comment"
    fi
  done <<<"$entries"

  [ -n "$reference" ] || continue

  # Reference layer: the generated page for this module.
  page="$reference/$rel.html"
  if [ ! -f "$page" ]; then
    report "$rel: no generated reference page $page"
    continue
  fi
  checked=$((checked + 1))
  out="$(awk '/id="module-name"/ { on = 1; next } /<section class="module-members">/ { on = 0 } on' "$page" \
    | sed -e 's/<h2>\([^<]*\)<\/h2>/\n## \1\n/g' -e 's/<[^>]*>//g' \
    | sections_check "$page")"
  [ -n "$out" ] && {
    printf '%s\n' "$out"
    fail=1
  }

  # The page's own member extent, reconciled with the source inventory.
  on_page="$(awk '/<section class="module-members">/ { on = 1 } /<\/section>/ { on = 0 }
                  on && match($0, /<h2 id="[^"]+">/) { print substr($0, RSTART + 8, RLENGTH - 10) }' "$page" | LC_ALL=C sort)"
  in_source="$(sed -n 's/^.*:\(pub [a-z ]*\) \([A-Za-z_][A-Za-z0-9_]*\)$/\2/p' <<<"$entries" | LC_ALL=C sort)"
  while IFS= read -r extra; do
    [ -n "$extra" ] && report "$page: member '$extra' is on the generated page but not in the source inventory"
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$on_page" | sed '/^$/d') <(printf '%s\n' "$in_source" | sed '/^$/d'))
  while IFS= read -r missing; do
    [ -n "$missing" ] && report "$page: source export '$missing' is missing from the generated page"
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$on_page" | sed '/^$/d') <(printf '%s\n' "$in_source" | sed '/^$/d'))

  # Every member the compiler put on the page renders a description.
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    members=$((members + 1))
    if ! awk -v id="<h2 id=\"$name\">" '
        index($0, id) { found = 1; next }
        found && /class="member"/ { exit }
        found && /class="rendered-markdown"/ { grab = 1 }
        grab { text = text $0; if ($0 ~ /<\/div>/) exit }
        END {
          gsub(/<[^>]*>/, "", text); gsub(/[[:space:]]/, "", text)
          exit !(found && text != "")
        }' "$page"; then
      report "$page: member '$name' renders no description"
    fi
  done <<<"$on_page"
done

[ "$total" -gt 0 ] || report "no public declaration found in the extent"
if [ -n "$reference" ] && [ "$checked" -eq 0 ]; then report "no generated reference page checked under $reference"; fi
if [ -n "$reference" ] && [ "$members" -eq 0 ]; then report "no member found on any generated reference page under $reference"; fi
echo "INVENTORY modules=${#modules[@]} registry_modules=$registry exports=$total reference_pages=$checked page_members=$members"
if [ "$fail" = 1 ]; then
  echo "aiken-docs: FAILED"
  exit 1
fi
echo "aiken-docs: OK"

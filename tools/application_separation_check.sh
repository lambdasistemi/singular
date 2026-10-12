#!/usr/bin/env bash
# application-separation-check: the registry trees name no application,
# and each application tree reaches only the registry.
#
# Registry side: every text file under each registry tree (excluding build
# output: dist-newstyle, result, build, .git) must name no application — neither
# the module prefix Singular.Application.OpenDatum, the path
# applications/, the validator title open_datum, the words open-datum and
# OpenDatum (comments and documentation included), nor the open-datum
# script hash, read from the open_datum.open_datum entry of
# applications/open-datum/onchain/permanent-contract.json at run time and
# never typed here; nor the module prefix Singular.Application.KeriStub,
# the words keri-stub and KeriStub, nor the stub script bytes, hash and
# constant names, read from applications/keri-stub/offchain/script-record.json
# at run time and never typed here. No
# registry component lists an application package in build-depends either.
#
# Application side: for each application tree, a cabal file, cabal.project,
# flake or script naming a path outside its own tree — other than the
# registry packages it depends on — or naming another application's tree
# is refused.
#
# Usage: application-separation-check [ROOT] (default: the working tree,
# the repository root).
# Exit 0: clean. Exit 1: a violation is named. Exit 2: the harness failed
# (missing tree, empty extent, unreadable contract) — a setup failure,
# never a verdict.
set -euo pipefail

root="${1:-$PWD}"
# Canonicalize: the reach leg compares resolved absolute paths.
root=$(realpath -m "$root")

# The registry trees this checkpoint covers, in one place: since the
# S5.1 Aiken slice the onchain tree holds the registry only, so it is
# covered here too; the keri-stub slice adds naming-onchain.
registry_trees="offchain onchain naming-onchain"
# The application trees covered by the reach rule, in one place.
application_trees="applications/open-datum applications/keri-stub"
# The registry packages an application may reach (paths relative to root).
registry_packages="offchain onchain"

contract="$root/applications/open-datum/onchain/permanent-contract.json"
[ -f "$contract" ] || {
  echo "application-separation-check: no applications/open-datum/onchain/permanent-contract.json under $root" >&2
  exit 2
}

# The open-datum hash, read at run time, never typed. Fail closed on an
# empty or misshapen answer: without the hash the scan proves nothing.
if ! app_hash=$(jq -r '.scripts[] | select(.title == "open_datum.open_datum") | .hash' "$contract"); then
  echo "application-separation-check: cannot read the open-datum hash from $contract" >&2
  exit 2
fi
[[ "$app_hash" =~ ^[0-9a-f]{56}$ ]] || {
  echo "application-separation-check: no open_datum.open_datum hash in $contract" >&2
  exit 2
}

# The stub script bytes, hash and constant names, read at run time from
# the stub tree, never typed. Fail closed on a missing or misshapen
# record, exactly like the open-datum hash: without them the scan proves
# nothing.
stub_record="$root/applications/keri-stub/offchain/script-record.json"
[ -f "$stub_record" ] || {
  echo "application-separation-check: no applications/keri-stub/offchain/script-record.json under $root" >&2
  exit 2
}
if ! stub_bytes=$(jq -r '.scriptBytesHex' "$stub_record"); then
  echo "application-separation-check: cannot read the stub script bytes from $stub_record" >&2
  exit 2
fi
if ! stub_hash=$(jq -r '.scriptHashHex' "$stub_record"); then
  echo "application-separation-check: cannot read the stub script hash from $stub_record" >&2
  exit 2
fi
if ! mapfile -t stub_names < <(jq -r '.scriptConstantNames[]' "$stub_record"); then
  echo "application-separation-check: cannot read the stub constant names from $stub_record" >&2
  exit 2
fi
[[ "$stub_bytes" =~ ^[0-9a-f]+$ ]] || {
  echo "application-separation-check: misshapen stub script bytes in $stub_record" >&2
  exit 2
}
[[ "$stub_hash" =~ ^[0-9a-f]{56}$ ]] || {
  echo "application-separation-check: misshapen stub script hash in $stub_record" >&2
  exit 2
}
[ "${#stub_names[@]}" -gt 0 ] || {
  echo "application-separation-check: no stub constant names in $stub_record" >&2
  exit 2
}
for stub_name in "${stub_names[@]}"; do
  [ -n "$stub_name" ] && [ "$stub_name" != "null" ] || {
    echo "application-separation-check: misshapen stub constant name in $stub_record" >&2
    exit 2
  }
done

for tree in $registry_trees; do
  [ -d "$root/$tree" ] || {
    echo "application-separation-check: no registry tree $tree under $root" >&2
    exit 2
  }
done
for tree in $application_trees; do
  [ -d "$root/$tree" ] || {
    echo "application-separation-check: no application tree $tree under $root" >&2
    exit 2
  }
done

# Text files under a tree, excluding build output.
tree_files() {
  find "$1" \
    \( -type d \( -name dist-newstyle -o -name result -o -name build -o -name .git \) \) -prune \
    -o -type f -print
}

fail=0

# --- registry side: application names ---------------------------------
registry_list=$(mktemp)
trap 'rm -f "$registry_list"' EXIT
for tree in $registry_trees; do
  tree_files "$root/$tree"
done | sort -u >"$registry_list"
[ -s "$registry_list" ] || {
  echo "application-separation-check: empty registry extent under $root" >&2
  exit 2
}

scan_token() {
  local name="$1"
  local pattern="$2"
  local hits
  hits=$(xargs -0 -r -a <(tr '\n' '\0' <"$registry_list") grep -nI -F -e "$pattern" || true)
  if [ -n "$hits" ]; then
    echo "application-separation-check: registry tree names an application [$name]:" >&2
    printf '%s\n' "$hits" >&2
    fail=1
  fi
}

scan_token "module Singular.Application.OpenDatum" "Singular.Application.OpenDatum"
scan_token "path applications/" "applications/"
scan_token "validator open_datum" "open_datum"
scan_token "word open-datum" "open-datum"
scan_token "word OpenDatum" "OpenDatum"
# S5-1d-r1: the brief binds the Aiken module spelling application/envelope
# explicitly (no onchain file may name it, comments included). None of the
# tokens above matches that spelling alone (open_datum needs an underscore,
# applications/ needs the plural), so it gets its own token and plant.
scan_token "Aiken module application/envelope" "application/envelope"
scan_token "open-datum script hash" "$app_hash"
scan_token "module Singular.Application.KeriStub" "Singular.Application.KeriStub"
scan_token "word keri-stub" "keri-stub"
scan_token "word KeriStub" "KeriStub"
scan_token "stub script bytes" "$stub_bytes"
scan_token "stub script hash" "$stub_hash"
for stub_name in "${stub_names[@]}"; do
  scan_token "stub script constant $stub_name" "$stub_name"
done

# --- registry side: build-depends --------------------------------------
# The case the retired boundary apps covered: no registry component lists
# the application package in build-depends. Parsed per stanza, so the
# offender is named with its file, line and stanza. (A depends entry also
# trips the word scan above; this leg adds the stanza attribution.)
for tree in $registry_trees; do
  while IFS= read -r cabal; do
    dep_hits=$(awk '
      /^library([ \t]|$)/ {
        if ($0 ~ /^library[ \t]+/) { stanza = "sublib:" $2 } else { stanza = "lib" }
        indep = 0; next
      }
      /^executable[ \t]+/ { stanza = "exe:" $2; indep = 0; next }
      /^test-suite[ \t]+/ { stanza = "test:" $2; indep = 0; next }
      /^[^ \t]/ { stanza = ""; indep = 0; next }
      stanza != "" && /^[ \t]*build-depends:/ { indep = 1 }
      stanza != "" && indep && /(^|[^A-Za-z0-9_-])open-datum([^A-Za-z0-9_-]|$)/ {
        print FILENAME ":" NR ": " stanza ": " $0
      }
      stanza != "" && indep && /^[ \t]*[A-Za-z0-9-]+:/ && $0 !~ /^[ \t]*build-depends:/ { indep = 0 }
    ' "$cabal")
    if [ -n "$dep_hits" ]; then
      echo "application-separation-check: registry component lists the application package in build-depends:" >&2
      printf '%s\n' "$dep_hits" >&2
      fail=1
    fi
  done < <(tree_files "$root/$tree" | grep -E '\.cabal$' || true)
done
# The keri-stub slice adds the same attribution for the second
# application package: no registry component lists it either.
for tree in $registry_trees; do
  while IFS= read -r cabal; do
    dep_hits=$(awk '
      /^library([ \t]|$)/ {
        if ($0 ~ /^library[ \t]+/) { stanza = "sublib:" $2 } else { stanza = "lib" }
        indep = 0; next
      }
      /^executable[ \t]+/ { stanza = "exe:" $2; indep = 0; next }
      /^test-suite[ \t]+/ { stanza = "test:" $2; indep = 0; next }
      /^[^ \t]/ { stanza = ""; indep = 0; next }
      stanza != "" && /^[ \t]*build-depends:/ { indep = 1 }
      stanza != "" && indep && /(^|[^A-Za-z0-9_-])keri-stub([^A-Za-z0-9_-]|$)/ {
        print FILENAME ":" NR ": " stanza ": " $0
      }
      stanza != "" && indep && /^[ \t]*[A-Za-z0-9-]+:/ && $0 !~ /^[ \t]*build-depends:/ { indep = 0 }
    ' "$cabal")
    if [ -n "$dep_hits" ]; then
      echo "application-separation-check: registry component lists the stub package in build-depends:" >&2
      printf '%s\n' "$dep_hits" >&2
      fail=1
    fi
  done < <(tree_files "$root/$tree" | grep -E '\.cabal$' || true)
done

# --- application side: reach -------------------------------------------
# Covered file classes: cabal files, cabal.project, flakes, scripts.
# Every path a covered file names is resolved to a location and tested
# against the application's own tree and the registry packages:
# relative (./, ../, plain with a slash), root-relative applications/ and
# absolute paths (with or without a trailing slash). Every absolute path
# naming a destination is judged: only the application's own subtree and
# the registry packages are permitted — any other absolute path is a
# reach, wherever it points (inside the checked root, outside it, or in
# another checkout). Path positions are validated structurally: every
# entry under a cabal.project packages: stanza (c) and every cd target in
# a shell script (d), even a slash-only one. Tokens of only slashes (the
# Nix // update operator, prose /) name no position in the unstructured
# token stream and are out of scope there, as are URLs and var/glob
# tokens, which cannot resolve statically.
# judge_reach <path> <base-dir> <display-rel>: resolve one path-position
# candidate and refuse it unless it lands in the application's own subtree
# ($own) or a registry package. Absolute candidates are judged wherever
# they point; relative ones resolve against the naming file's directory.
judge_reach() {
  local ref="$1" base="$2" rel="$3"
  local resolved ok pkg
  case "$ref" in
    /*) resolved=$(realpath -m "$ref") ;;
    *) resolved=$(realpath -m "$base/$ref") ;;
  esac
  ok=0
  case "$resolved" in
    "$root/$own"/*) ok=1 ;;
  esac
  if [ "$ok" -eq 0 ]; then
    for pkg in $registry_packages; do
      case "$resolved" in
        "$root/$pkg" | "$root/$pkg"/*)
          ok=1
          break
          ;;
      esac
    done
  fi
  if [ "$ok" -eq 0 ]; then
    echo "application-separation-check: $rel reaches outside its own tree and the registry: $ref" >&2
    fail=1
  fi
}
for tree in $application_trees; do
  own="$tree"
  while IFS= read -r file; do
    rel="${file#"$root"/}"
    dir=$(dirname "$file")
    # (a) applications/-rooted references: only the tree's own subtree.
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      case "$ref" in
        "$own"/*) ;;
        *)
          echo "application-separation-check: $rel reaches outside its own tree: $ref" >&2
          fail=1
          ;;
      esac
    done < <(grep -oE 'applications/[^ "\"'"'"'``,;)\]]*' "$file" || true)
    # (b) every other path spelling naming a slash (relative ./, ../ and
    # plain foo/bar file-relative; absolute paths judged wherever they
    # point): must land in the tree's own subtree or in one of the
    # registry packages. Root-relative applications/ is handled by (a);
    # URLs and var/glob tokens cannot resolve statically and stay out of
    # scope, as do shebang tokens (#!...). Tokens of only slashes (the
    # Nix // operator, prose /) name no position in this unstructured
    # stream and are skipped here; slash-only tokens in a path position
    # are validated by (c) and (d) below.
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in
        applications/* | *://* | *\$* | *\** | *\?* | *\[* | '#!'*) continue ;;
      esac
      case "$tok" in
        */*) ;;
        *) continue ;;
      esac
      ref="$tok"
      case "$ref" in
        /*)
          # A token of only slashes names no destination (Nix //,
          # prose /); every other absolute path is judged below,
          # wherever it points.
          case "$ref" in
            *[!/]*) ;;
            *) continue ;;
          esac
          resolved=$(realpath -m "$ref")
          ;;
        *) resolved=$(realpath -m "$dir/$ref") ;;
      esac
      ok=0
      case "$resolved" in
        "$root/$own"/*) ok=1 ;;
      esac
      if [ "$ok" -eq 0 ]; then
        for pkg in $registry_packages; do
          case "$resolved" in
            "$root/$pkg" | "$root/$pkg"/*)
              ok=1
              break
              ;;
          esac
        done
      fi
      if [ "$ok" -eq 0 ]; then
        echo "application-separation-check: $rel reaches outside its own tree and the registry: $ref" >&2
        fail=1
      fi
    done < <(grep -oE '[^ "\"'"'"'``,;()]+' "$file" || true)
  done < <(tree_files "$root/$tree" | grep -E '(/cabal\.project[^/]*$|\.cabal$|/flake\.nix$|\.sh$)' || true)
  # (c) cabal.project package positions: every entry under a packages:
  # stanza is a path position, even a slash-only one (operators and
  # prose never occur here). Judged exactly as in (b).
  while IFS= read -r proj; do
    rel="${proj#"$root"/}"
    dir=$(dirname "$proj")
    in_packages=0
    while IFS= read -r line || [ -n "$line" ]; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      case "$trimmed" in
        packages:*)
          in_packages=1
          rest="${trimmed#packages:}"
          if [ -n "$rest" ]; then
            read -r -a same_line <<<"$rest" || true
            for entry in "${same_line[@]}"; do
              entry="${entry//\"/}"
              entry="${entry//\'/}"
              [ -n "$entry" ] || continue
              judge_reach "$entry" "$dir" "$rel"
            done
          fi
          continue
          ;;
      esac
      if [ "$in_packages" -eq 1 ]; then
        case "$line" in
          [[:space:]]*)
            case "$trimmed" in
              '' | --*) continue ;;
            esac
            entry="${trimmed%%[[:space:]]*}"
            entry="${entry//\"/}"
            entry="${entry//\'/}"
            [ -n "$entry" ] || continue
            judge_reach "$entry" "$dir" "$rel"
            ;;
          *)
            case "$trimmed" in
              '' | --* | '#'*) continue ;;
              *) in_packages=0 ;;
            esac
            ;;
        esac
      fi
    done <"$proj"
  done < <(tree_files "$root/$tree" | grep -E '/cabal\.project[^/]*$' || true)
  # (d) shell cd positions: the target of cd is a path position, even a
  # slash-only one. `cd -`, flags and var/glob targets name no static
  # path and stay out of scope, as in (b).
  while IFS= read -r sh; do
    rel="${sh#"$root"/}"
    dir=$(dirname "$sh")
    while IFS= read -r line || [ -n "$line" ]; do
      code="${line%%#*}"
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        tmp="${hit#*cd}"
        target="${tmp#"${tmp%%[![:space:]]*}"}"
        target="${target//\"/}"
        target="${target//\'/}"
        case "$target" in
          '' | - | -* | *\$* | *\** | *\?* | *\[*) continue ;;
        esac
        judge_reach "$target" "$dir" "$rel"
      done < <(grep -oE '(^|[[:space:];|&(){}]+)cd[[:space:]]+[^[:space:];|&(){}]+' <<<"$code" || true)
    done <"$sh"
  done < <(tree_files "$root/$tree" | grep -E '\.sh$' || true)
done

# --- cross-application: the stub names no open datum ---------------------
# The stub tree must name neither the open-datum module prefix nor the
# open-datum words and tree. Scanned with the same text-file extent as
# the registry side; a hit names the file, the line and the name.
# Every temporary list registers its cleanup at the moment it is
# acquired, before the next acquisition: if a later mktemp fails, the
# active trap already covers every earlier list, so no exit leaves one
# behind.
stub_list=$(mktemp)
trap 'rm -f "$registry_list" "$stub_list"' EXIT
opendatum_list=$(mktemp)
trap 'rm -f "$registry_list" "$stub_list" "$opendatum_list"' EXIT
tree_files "$root/applications/keri-stub" | sort -u >"$stub_list"
[ -s "$stub_list" ] || {
  echo "application-separation-check: empty stub extent under $root" >&2
  exit 2
}
tree_files "$root/applications/open-datum" | sort -u >"$opendatum_list"
[ -s "$opendatum_list" ] || {
  echo "application-separation-check: empty open-datum extent under $root" >&2
  exit 2
}

scan_stub_token() {
  local name="$1"
  local pattern="$2"
  local hits
  hits=$(xargs -0 -r -a <(tr '\n' '\0' <"$stub_list") grep -nI -F -e "$pattern" || true)
  if [ -n "$hits" ]; then
    echo "application-separation-check: stub tree names the open datum [$name]:" >&2
    printf '%s\n' "$hits" >&2
    fail=1
  fi
}

scan_stub_token "module Singular.Application.OpenDatum" "Singular.Application.OpenDatum"
scan_stub_token "word open-datum" "open-datum"
scan_stub_token "word OpenDatum" "OpenDatum"
scan_stub_token "path applications/open-datum" "applications/open-datum"

# The stub cabal depending on the open datum is refused with stanza
# attribution, as the registry side attributes its own dependencies.
while IFS= read -r cabal; do
  dep_hits=$(awk '
    /^library([ \t]|$)/ {
      if ($0 ~ /^library[ \t]+/) { stanza = "sublib:" $2 } else { stanza = "lib" }
      indep = 0; next
    }
    /^executable[ \t]+/ { stanza = "exe:" $2; indep = 0; next }
    /^test-suite[ \t]+/ { stanza = "test:" $2; indep = 0; next }
    /^[^ \t]/ { stanza = ""; indep = 0; next }
    stanza != "" && /^[ \t]*build-depends:/ { indep = 1 }
    stanza != "" && indep && /(^|[^A-Za-z0-9_-])open-datum([^A-Za-z0-9_-]|$)/ {
      print FILENAME ":" NR ": " stanza ": " $0
    }
    stanza != "" && indep && /^[ \t]*[A-Za-z0-9-]+:/ && $0 !~ /^[ \t]*build-depends:/ { indep = 0 }
  ' "$cabal")
  if [ -n "$dep_hits" ]; then
    echo "application-separation-check: stub component lists the open-datum package in build-depends:" >&2
    printf '%s\n' "$dep_hits" >&2
    fail=1
  fi
done < <(tree_files "$root/applications/keri-stub" | grep -E '\.cabal$' || true)

# --- cross-application: the open datum names no stub ------------------------
scan_opendatum_token() {
  local name="$1"
  local pattern="$2"
  local hits
  hits=$(xargs -0 -r -a <(tr '\n' '\0' <"$opendatum_list") grep -nI -F -e "$pattern" || true)
  if [ -n "$hits" ]; then
    echo "application-separation-check: open-datum tree names the stub [$name]:" >&2
    printf '%s\n' "$hits" >&2
    fail=1
  fi
}

scan_opendatum_token "path applications/keri-stub" "applications/keri-stub"
scan_opendatum_token "module Singular.Application.KeriStub" "Singular.Application.KeriStub"
scan_opendatum_token "word keri-stub" "keri-stub"
scan_opendatum_token "word KeriStub" "KeriStub"
scan_opendatum_token "stub script bytes" "$stub_bytes"
scan_opendatum_token "stub script hash" "$stub_hash"
for stub_name in "${stub_names[@]}"; do
  scan_opendatum_token "stub script constant $stub_name" "$stub_name"
done

while IFS= read -r cabal; do
  dep_hits=$(awk '
    /^library([ \t]|$)/ {
      if ($0 ~ /^library[ \t]+/) { stanza = "sublib:" $2 } else { stanza = "lib" }
      indep = 0; next
    }
    /^executable[ \t]+/ { stanza = "exe:" $2; indep = 0; next }
    /^test-suite[ \t]+/ { stanza = "test:" $2; indep = 0; next }
    /^[^ \t]/ { stanza = ""; indep = 0; next }
    stanza != "" && /^[ \t]*build-depends:/ { indep = 1 }
    stanza != "" && indep && /(^|[^A-Za-z0-9_-])keri-stub([^A-Za-z0-9_-]|$)/ {
      print FILENAME ":" NR ": " stanza ": " $0
    }
    stanza != "" && indep && /^[ \t]*[A-Za-z0-9-]+:/ && $0 !~ /^[ \t]*build-depends:/ { indep = 0 }
  ' "$cabal")
  if [ -n "$dep_hits" ]; then
    echo "application-separation-check: open-datum component lists the stub package in build-depends:" >&2
    printf '%s\n' "$dep_hits" >&2
    fail=1
  fi
done < <(tree_files "$root/applications/open-datum" | grep -E '\.cabal$' || true)

if [ "$fail" -eq 0 ]; then
  echo "application-separation-check: clean (trees: $registry_trees; applications: $application_trees)"
fi
exit "$fail"

#!/usr/bin/env bash
# The ledger client core depends only on reviewed packages, and on no Singular
# component and no file, process, POSIX or network package.
#
# `library ledger-client` in offchain/singular-registry.cabal holds the
# provider-independent part of the ledger client: evidence, network time,
# typed read traces and local script evaluation. An application that reads
# Cardano through the provider interface depends on it, so it must stay
# free of signing, wallet, file, process and network code, and of the
# transaction-building package, or it cannot move out unchanged.
#
# What is read is the stanza's resolved direct dependencies: its own
# `build-depends` fields, in conditionals too, and those of every `common`
# stanza it imports, followed through imports of imports. A dependency
# declared by any of these counts the same.
#
# Refuses (exit 1, naming the offender and where it is declared):
#   * a dependency that tools/ledger-client-dependencies.allow does not list:
#     whether a package belongs to a forbidden category cannot be enumerated
#     by name, so each addition is a reviewed edit of the allowlist;
#   * any `singular-registry` component, and any of the packages below, even
#     when the allowlist lists them: the allowlist cannot admit them;
#   * an allowlist entry with no reason, or that names no dependency of the
#     library: an exemption nothing needs is a hole waiting for a use.
# Exit 2 on a setup failure: no Cabal file or allowlist, no such stanza, an
# imported common stanza that does not exist, no dependencies.
#
# This names the dependencies the library declares; what a transitive
# dependency links is the package solver's business, not read here.
#
# Usage: tools/ledger_client_dependencies_check.sh [repo-root]
set -euo pipefail

forbidden=(
  directory filepath unix process network
  http-client http-client-tls wai warp
  cardano-tx-tools
)

root=${1:-.}
cabal="$root/offchain/singular-registry.cabal"
allow="$root/tools/ledger-client-dependencies.allow"
for f in "$cabal" "$allow"; do
  if [ ! -f "$f" ]; then
    echo "SETUP-FAIL: no $f" >&2
    exit 2
  fi
done

if ! grep -qE '^library ledger-client[[:space:]]*$' "$cabal"; then
  echo "SETUP-FAIL: no 'library ledger-client' stanza in $cabal" >&2
  exit 2
fi

# One line per resolved dependency: "<dependency><TAB><stanza declaring it>",
# or "SETUP<TAB><message>". Stanzas are keyed "library <name>" or
# "common <name>"; a field's continuation lines run to the next field, the
# next conditional keyword or the next stanza.
resolved=$(awk '
  function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
  function add_deps(text,   n, i, parts) {
    n = split(text, parts, ",")
    for (i = 1; i <= n; i++) {
      parts[i] = trim(parts[i])
      if (parts[i] != "") deps[cur] = deps[cur] parts[i] "\n"
    }
  }
  function add_imports(text,   n, i, parts) {
    gsub(/,/, " ", text)
    n = split(text, parts, " ")
    for (i = 1; i <= n; i++) if (parts[i] != "") imports[cur] = imports[cur] parts[i] "\n"
  }
  function walk(key,   n, i, lines, name) {
    if (key in seen) return
    seen[key] = 1
    if (!(key in exists)) { print "SETUP\t" "no stanza " key; return }
    n = split(deps[key], lines, "\n")
    for (i = 1; i <= n; i++) if (lines[i] != "") print lines[i] "\t" key
    n = split(imports[key], lines, "\n")
    for (i = 1; i <= n; i++) if (lines[i] != "") walk("common " lines[i])
  }
  /^[[:space:]]*(--.*)?$/ { next }
  /^[^[:space:]]/ {
    in_deps = 0
    kind = $1; sub(/:$/, "", kind)
    if (kind == "library" || kind == "common") {
      cur = kind " " (NF > 1 ? $2 : "singular-registry")
      exists[cur] = 1
    } else {
      cur = ""
    }
    next
  }
  cur == "" { next }
  {
    line = $0
    if (line ~ /^[[:space:]]+(if|elif|else)([[:space:](]|$)/) { in_deps = 0; next }
    if (line ~ /^[[:space:]]+[A-Za-z][A-Za-z0-9-]*:/) {
      in_deps = 0
      field = tolower(trim(substr(line, 1, index(line, ":") - 1)))
      value = substr(line, index(line, ":") + 1)
      if (field == "build-depends") { in_deps = 1; add_deps(value) }
      else if (field == "import") add_imports(value)
      next
    }
    if (in_deps) add_deps(line)
  }
  END { walk("library ledger-client") }
' "$cabal")

status=0
declare -A used=() origin=()
count=0
while IFS=$'\t' read -r dep where; do
  [ -n "$dep" ] || continue
  if [ "$dep" = SETUP ]; then
    echo "SETUP-FAIL: $where in $cabal" >&2
    exit 2
  fi
  count=$((count + 1))
  case "$dep" in *[{}]*)
    echo "ledger-client depends on '$dep' (declared in $where): a brace set of components cannot be checked; list each component" >&2
    status=1
    continue
    ;;
  esac
  name=${dep%%[[:space:]<>=^]*}
  used[$name]=1
  origin[$name]=$where
done <<<"$resolved"

if [ "$count" -eq 0 ]; then
  echo "SETUP-FAIL: 'library ledger-client' resolves to no build-depends in $cabal" >&2
  exit 2
fi

declare -A allowed=()
while IFS= read -r line; do
  case "$line" in '' | '#'*) continue ;; esac
  pkg=${line%%:*}
  rest=${line#"$pkg":}
  # A qualified entry "pkg:component: reason" keeps its component.
  case "$rest" in
    [A-Za-z]*:*)
      comp=${rest%%:*}
      if [[ $comp != *[[:space:]]* ]]; then
        pkg="$pkg:$comp"
        rest=${rest#"$comp":}
      fi
      ;;
  esac
  reason=${rest#"${rest%%[![:space:]]*}"}
  if [ -z "$reason" ] || [ "$rest" = "$line" ]; then
    echo "allowlist: '$pkg' carries no reason" >&2
    status=1
  fi
  allowed[$pkg]=1
done <"$allow"

for pkg in "${!allowed[@]}"; do
  if [ -z "${used[$pkg]:-}" ]; then
    echo "allowlist: '$pkg' is no dependency of ledger-client; drop its entry" >&2
    status=1
  fi
done

for name in "${!used[@]}"; do
  where=${origin[$name]}
  case "$name" in
    singular-registry | singular-registry:*)
      echo "ledger-client depends on $name (declared in $where): the Singular component $name may not be a dependency" >&2
      status=1
      continue
      ;;
  esac
  for bad in "${forbidden[@]}"; do
    if [ "${name%%:*}" = "$bad" ]; then
      echo "ledger-client depends on $name (declared in $where): $bad is forbidden in the ledger client core" >&2
      status=1
    fi
  done
  if [ -z "${allowed[$name]:-}" ]; then
    echo "ledger-client depends on $name (declared in $where): $name is not in tools/ledger-client-dependencies.allow" >&2
    status=1
  fi
done

if [ $status -ne 0 ]; then
  echo "FAIL ledger-client-dependencies: see the lines above" >&2
  exit 1
fi

echo "PASS ledger-client-dependencies: $count resolved direct dependencies, all allowlisted, none a Singular component or a forbidden package"

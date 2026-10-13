#!/usr/bin/env bash
# IO ownership boundary (issue #544): every gated effect site is allowlisted
# with its owner, and the module boundaries the guides promise actually hold.
#
# `tools/io_ownership_inventory.py` discovers every Haskell source and reports
# its gated classes (ioref/mvar/stm/unsafe/fork/async). This check requires:
#   * every reported gated class to have a file-level entry in
#     tools/io-ownership.allow carrying its classes and its reason
#     (owner, lifetime, access model, reason);
#   * every allowlisted class to be actually present (a stale exemption is a
#     hole waiting for a use);
#   * every allowlist entry to name an existing file with a non-empty reason
#     and only known classes;
#   * the five dependency boundaries B1-B5 below to hold over the discovered
#     extent (source-derived graph, not a frozen list: the rules name
#     namespaces, the scan discovers the files).
#
# Supporting evidence, not proof. This reads source text (imports and a few
# code-only tokens), so it establishes that no other module NAMES a gated
# effect or crosses a boundary; what a command does with what it names is
# settled by the cage tests, the journeys and the hosted runs named in
# docs/io-ownership.md, not here. The census establishes structural facts,
# never runtime behavior.
#
# Usage: tools/io_ownership_check.sh [repo-root]
set -euo pipefail

root=${1:-.}
tool="$root/tools/io_ownership_inventory.py"
allow="$root/tools/io-ownership.allow"

for f in "$tool" "$allow"; do
  [ -f "$f" ] || {
    echo "SETUP-FAIL: no $f" >&2
    exit 2
  }
done

status=0

# 1. The census itself must pass (every file classified, no use-without-import).
census_out=$(mktemp)
if ! python3 "$tool" --root "$root" >"$census_out" 2>&1; then
  echo "census: the inventory itself fails:" >&2
  cat "$census_out" >&2
  status=1
fi
rm -f "$census_out"

# 2. Census-vs-allowlist exact match, computed by the inventory's own JSON
# against the allow file (dev-shell banner stripped to the first brace).
comparison=$(mktemp)
sites_now=$(mktemp)
sites_diff=$(mktemp)
trap 'rm -f "$comparison" "$sites_now" "$sites_diff"' EXIT
python3 "$tool" --root "$root" --json 2>/dev/null | sed -n '/^{/,$p' >"$comparison" || {
  echo "SETUP-FAIL: the inventory produced no JSON" >&2
  exit 2
}
IO_ROOT="$root" IO_ALLOW="$allow" python3 - "$comparison" <<'PYEOF' || status=1
import json, os, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    census = json.load(fh)

allowed: dict[str, set[str]] = {}
failures: list[str] = []
known = {"ioref", "mvar", "stm", "unsafe", "fork", "async"}
root = os.environ.get("IO_ROOT", ".")

with open(os.environ["IO_ALLOW"], encoding="utf-8") as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        if ":" not in line or "—" not in line:
            failures.append(f"allowlist line {lineno} is not '<path>: <classes> — <reason>': {line}")
            continue
        path, rest = line.split(":", 1)
        path = path.strip()
        classes_part, reason = rest.split("—", 1)
        classes = {c.strip() for c in classes_part.split(",") if c.strip()}
        reason = reason.strip()
        if not path or not classes:
            failures.append(f"allowlist line {lineno} names no path or no classes: {line}")
            continue
        if not reason:
            failures.append(f"allowlist: '{path}' carries no reason")
        unknown = classes - known
        if unknown:
            failures.append(f"allowlist: '{path}' names unknown classes: {sorted(unknown)}")
        if path in allowed:
            failures.append(f"allowlist: '{path}' listed twice")
        allowed[path] = classes
        if not os.path.isfile(os.path.join(root, path)):
            failures.append(f"allowlist: '{path}' does not exist")

detected: dict[str, set[str]] = {}
for row in census["files"]:
    if row["gated"]:
        detected[row["file"]] = set(row["gated"])

for path in sorted(detected):
    if path not in allowed:
        failures.append(
            f"unallowlisted gated site: {path} names {sorted(detected[path])}; "
            "add it to tools/io-ownership.allow with owner, lifetime and reason"
        )
    else:
        missing = detected[path] - allowed[path]
        if missing:
            failures.append(
                f"unallowlisted gated site: {path} newly names {sorted(missing)}; "
                "extend its tools/io-ownership.allow entry"
            )
for path in sorted(allowed):
    if path not in detected:
        failures.append(
            f"allowlist: '{path}' names no gated effect; drop its exemption"
        )
    else:
        stale = allowed[path] - detected[path]
        if stale:
            failures.append(
                f"allowlist: '{path}' exempts {sorted(stale)} nothing names; "
                "drop the stale classes"
            )

if failures:
    print("FAIL io-ownership-allowlist:", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    sys.exit(1)
print(f"PASS io-ownership-allowlist: {len(detected)} files name gated effects, "
      f"all {len(allowed)} entries bound with reasons")
PYEOF

# 2b. Site-count binding (NOTE-001): the committed per-file per-token counts
# must equal the census recomputed now. A new site of an already-allowed
# class in an already-allowed file changes a count with its imports
# untouched, so this diff rejects it as unclassified. Regenerate with
# `python3 tools/io_ownership_inventory.py --root . --sites`, review the
# diff beside the code change, and commit both together.
sites_file="$root/tools/io-ownership.sites"
[ -f "$sites_file" ] || {
  echo "SETUP-FAIL: no $sites_file" >&2
  exit 2
}
python3 "$tool" --root "$root" --sites 2>/dev/null >"$sites_now" || {
  echo "SETUP-FAIL: the inventory produced no site binding" >&2
  exit 2
}
# The committed file carries a #-comment header; the fresh output is pure
# data. Compare data against data.
if ! diff -u <(grep -v '^#' "$sites_file") "$sites_now" >"$sites_diff" 2>&1; then
  echo "FAIL io-ownership-sites: the tree's effect sites drifted from tools/io-ownership.sites:" >&2
  grep -E '^[+-][^+-]' "$sites_diff" | head -n 20 >&2
  echo "  regenerate, review and commit beside the code change (see the file header)" >&2
  status=1
else
  echo "PASS io-ownership-sites: $(grep -vc '^#' "$sites_file") bound site counts hold"
fi

# 3. Dependency boundaries over the discovered extent. Each rule names
# namespaces; the scan discovers the files, so a moved module is rechecked
# with nothing to edit. A violation names the file and the import.
check_boundary() { # check_boundary <rule-id> <path-prefix-or-EMPTY> <import-re> [allowed-dirs...]
  local rule=$1 scope=$2 pattern=$3
  shift 3
  local found=0
  while IFS= read -r file; do
    local rel=${file#"$root"/}
    case "$scope" in
      EMPTY) : ;;
      *) case "$rel" in $scope/*) continue ;; esac ;;
    esac
    local skip=""
    for dir in "$@"; do
      case "$rel" in "$dir"/*) skip=1 ;; esac
    done
    [ -n "$skip" ] && continue
    if grep -nE -e "$pattern" "$file" | sed "s|^|$rel:|"; then
      found=1
    fi
  done < <(find "$root" -name '*.hs' -not -path '*/dist-newstyle/*' -not -path '*/.git/*' | sort)
  if [ "$found" -ne 0 ]; then
    echo "  ^ $rule violated above" >&2
    status=1
  fi
}

echo "boundary B1: the conformance library never imports the runner"
check_boundary "B1" EMPTY '^import[[:space:]]+(qualified[[:space:]]+)?Conformance\.(Run|Cli)\b' conformance/app conformance/app-cli conformance/app-default conformance/test
echo "boundary B2: the offchain libraries never import the command layer"
check_boundary "B2" EMPTY '^import[[:space:]]+(qualified[[:space:]]+)?Singular\.CLI\b' offchain/cli offchain/test offchain/e2e-test applications conformance
echo "boundary B3: journey executables keep their local modules"
check_boundary "B3a" offchain/journey '^import[[:space:]]+(qualified[[:space:]]+)?Journey\b'
check_boundary "B3b" offchain/insert-active '^import[[:space:]]+(qualified[[:space:]]+)?InsertActive\b'
check_boundary "B3c" offchain/update-terminal '^import[[:space:]]+(qualified[[:space:]]+)?UpdateTerminal\b'
echo "boundary B4: no ordinary executable links a host module"
check_boundary "B4" EMPTY '^import[[:space:]]+(qualified[[:space:]]+)?Negative\b' applications/open-datum/negative applications/open-datum/offchain/test
echo "boundary B5: the command layer is imported only at composition (commands, applications, tests)"
check_boundary "B5" EMPTY '^import[[:space:]]+(qualified[[:space:]]+)?Singular\.CLI\.' offchain/cli offchain/test offchain/e2e-test applications

if [ $status -ne 0 ]; then
  echo "FAIL io-ownership: see the lines above" >&2
  exit 1
fi
echo "PASS io-ownership: census, allowlist and B1-B5 boundaries hold"

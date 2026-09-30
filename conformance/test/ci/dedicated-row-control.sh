#!/usr/bin/env bash
# Retention control for the dedicated conformance row steps (#287).
#
# Each of the CG07, CG22 and CG23 steps runs its row through
# dedicated-row.sh. A row that fails must still leave its receipts and its
# replay index where the always-run upload collects them. This control runs
# that same script with a stand-in row that writes the index a differing step
# leaves and exits non-zero, and requires: the row's exit status kept, the
# receipts root published to the workflow environment before the row ran, and
# the index retained under the published root. It then shows it can fail: a
# copy with the publication removed and a copy that discards the receipts on
# exit must each be refused.
#
# usage: dedicated-row-control.sh [SCRIPT]   (default: dedicated-row.sh beside it)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${1:-$here/dedicated-row.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The stand-in row: it proves retention, never chain behaviour. It refuses to
# run (exit 9) unless the root was published before it started.
stub="$work/failing-row"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
grep -q '^CONFORMANCE_DEDICATED_RECEIPTS=' "$GITHUB_ENV" || exit 9
dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --receipts-dir)
      dir="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
mkdir -p "$dir/replay"
printf '[{"kind":"refusal","rejectedTxId":"stand-in","modelReason":"not-phase2","comparison":"differs"}]\n' \
  >"$dir/replay/index.json"
exit 7
STUB
chmod +x "$stub"

# check CANDIDATE: succeeds only when the candidate keeps the row's exit,
# published the root before the row, and the index survives under it.
check() {
  local candidate="$1" root env rc published
  root="$(mktemp -d "$work/root.XXXXXX")"
  env="$(mktemp "$work/env.XXXXXX")"
  set +e
  CONFORMANCE_DEDICATED_RECEIPTS="$root" GITHUB_ENV="$env" \
    bash "$candidate" STAND-IN -- "$stub" >"$work/out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 9 ]; then
    echo "the receipts root was not published before the row ran"
    return 1
  fi
  if [ "$rc" -ne 7 ]; then
    echo "exit $rc, not the row's 7"
    return 1
  fi
  published="$(sed -n 's/^CONFORMANCE_DEDICATED_RECEIPTS=//p' "$env" | tail -n 1)"
  if [ "$published" != "$root" ]; then
    echo "published '$published', not '$root'"
    return 1
  fi
  if ! grep -q '"comparison":"differs"' "$published/STAND-IN/replay/index.json" 2>/dev/null; then
    echo "no replay index retained under $published/STAND-IN"
    return 1
  fi
}

if ! reason="$(check "$script")"; then
  echo "FAIL: $script does not retain a failing row's evidence: $reason"
  exit 1
fi
echo "retention: exit 7 kept, root published before the row, replay index retained"

# Mutant 1: the publication removed. The edit must apply, or it tests nothing.
unpublished="$work/unpublished.sh"
grep -v 'GITHUB_ENV' "$script" >"$unpublished"
if cmp -s "$script" "$unpublished"; then
  echo "FAIL: the publication mutant did not change the script"
  exit 1
fi
if reason="$(check "$unpublished")"; then
  echo "FAIL: the control accepted a script that publishes nothing"
  exit 1
fi
echo "control: refused the unpublished copy ($reason)"

# Mutant 2: the receipts discarded when the script exits.
discarding="$work/discarding.sh"
awk 'NR == 2 { print "trap '\''rm -rf \"${CONFORMANCE_DEDICATED_RECEIPTS:?}\"'\'' EXIT" } { print }' \
  "$script" >"$discarding"
if cmp -s "$script" "$discarding"; then
  echo "FAIL: the retention mutant did not change the script"
  exit 1
fi
if reason="$(check "$discarding")"; then
  echo "FAIL: the control accepted a script that discards the receipts"
  exit 1
fi
echo "control: refused the discarding copy ($reason)"

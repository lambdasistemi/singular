#!/usr/bin/env bash
# The evidence-page check must be able to fail. On scratch copies of the
# committed page, its speech companion, the inventory, the model revision and
# the receipt snapshot, each control tampers one thing and requires
# `conformance evidence-page` to refuse it, naming the disagreement. The
# untampered copy must pass first, and every tampered copy must differ from
# the original, so a mutation that silently fails to apply cannot pass as a
# caught one.
#
# Usage: evidence_page_controls.sh [REPOSITORY-ROOT]   (conformance on PATH)
set -euo pipefail

root="${1:-.}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
copy="$work/root"
snapshot="$copy/conformance/evidence/page"
page="$copy/docs/conformance-evidence.md"

fresh() {
  rm -rf "$copy"
  mkdir -p "$copy/conformance/evidence" "$copy/docs"
  cp "$root/conformance/rows.json" "$root/conformance/model-revision" "$copy/conformance/"
  cp -r "$root/conformance/evidence/page" "$copy/conformance/evidence/"
  cp "$root/docs/conformance-evidence.md" "$root/docs/conformance-evidence.speech.json" "$copy/docs/"
  cp "$root/docs/consumer-conformance.md" "$root/docs/consumer-conformance.speech.json" "$copy/docs/"
  chmod -R u+w "$copy"
}

applied() {
  if cmp -s "$1" "$2"; then
    echo "CONTROL BROKEN: $3: the tampering did not change $1" >&2
    exit 1
  fi
}

refused() {
  local label="$1" reason="$2" out
  if out="$(conformance evidence-page --root "$copy" 2>&1)"; then
    echo "CONTROL FAILED: $label: the check accepted it" >&2
    exit 1
  fi
  if ! grep -qF -- "$reason" <<<"$out"; then
    echo "CONTROL FAILED: $label: refused for another reason: $out" >&2
    exit 1
  fi
  echo "control $label: refused ($reason)"
}

fresh
conformance evidence-page --root "$copy"
echo 'control untampered: accepted'

fresh
cp "$page" "$work/before"
sed -i '0,/| uncovered |/s//| demonstrated |/' "$page"
applied "$work/before" "$page" 'page state'
refused 'tampered page' 'disagrees with the receipts it is computed from'

fresh
results="$(find "$snapshot/contract" -name '*.jsonl' | sort | head -n1)"
line="$(grep -n '"outcome":"passed"' "$results" | head -n1 | cut -d: -f1)"
[ -n "$line" ] || {
  echo 'CONTROL BROKEN: no passed contract result in the snapshot' >&2
  exit 1
}
cp "$results" "$work/before"
sed -n "${line}p" "$work/before" | jq -c '.outcome = "failed" | .reason = "tampered"' >"$work/line"
{
  head -n "$((line - 1))" "$work/before"
  cat "$work/line"
  tail -n "+$((line + 1))" "$work/before"
} >"$results"
applied "$work/before" "$results" 'contract result'
refused 'contract result flipped' 'disagrees with the receipts it is computed from'

fresh
results="$(find "$snapshot/contract" -name '*.jsonl' | sort | head -n1)"
cp "$results" "$work/before"
jq -c '.base = "other-base"' "$work/before" >"$results"
applied "$work/before" "$results" 'contract revision'
refused 'contract from another revision' 'not the stated base'

fresh
results="$(find "$snapshot/contract" -name '*.jsonl' | sort | head -n1)"
cp "$results" "$work/before"
jq -c '.dirty = true' "$work/before" >"$results"
applied "$work/before" "$results" 'contract dirty state'
refused 'contract from a dirty tree' 'dirty tree'

fresh
consumer="$copy/docs/consumer-conformance.md"
cp "$consumer" "$work/before"
sed -i '0,/[Uu]ncovered/s//demonstrated/' "$consumer"
applied "$work/before" "$consumer" 'consumer standing'
refused 'tampered consumer standing' 'consumer-conformance.md disagrees with the receipts it is computed from'

fresh
consumer="$copy/docs/consumer-conformance.md"
cp "$consumer" "$work/before"
awk -F'|' -v OFS='|' '$2 == " Total requirements " { $3 = " " ($3 + 1) " " } { print }' "$work/before" >"$consumer"
applied "$work/before" "$consumer" 'consumer total'
refused 'tampered consumer total' 'consumer-conformance.md disagrees with the receipts it is computed from'

echo 'evidence page controls: every tampering refused'

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

# One receipt the snapshot shows as demonstrated: its verdict agrees.
agreeing() {
  for f in "$snapshot"/receipts/receipt-*.json; do
    if [ "$(jq -r '.verdict' "$f")" = agrees-with-model ]; then
      echo "$f"
      return
    fi
  done
  echo "CONTROL BROKEN: no agreeing receipt in the snapshot" >&2
  exit 1
}

retouch() {
  local f="$1" program="$2"
  cp "$f" "$work/before"
  jq -c "$program" "$work/before" >"$f"
  applied "$work/before" "$f" "$program"
}

fresh
conformance evidence-page --root "$copy"
echo 'control untampered: accepted'

fresh
cp "$page" "$work/before"
sed -i '0,/| demonstrated |/s//| uncovered |/' "$page"
applied "$work/before" "$page" 'page state'
refused 'tampered page' 'disagrees with the receipts it is computed from'

fresh
retouch "$(agreeing)" '.verdict = "held-q002"'
refused 'receipt verdict flipped' 'disagrees with the receipts it is computed from'

fresh
retouch "$(agreeing)" '.base = "0000000000000000000000000000000000000000"'
refused 'receipt from another revision' 'not the stated base'

fresh
retouch "$(agreeing)" '.dirty = true'
refused 'receipt from a dirty tree' 'dirty tree'

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

echo 'evidence page controls: every tampering refused'

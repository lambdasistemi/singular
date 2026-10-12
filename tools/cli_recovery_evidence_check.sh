#!/usr/bin/env bash
# Verify a collected cross-wallet evidence bundle (#543 retention repair).
#
# usage: cli_recovery_evidence_check.sh EVIDENCE
#
# EVIDENCE is what cli-recovery-cross-wallet-evidence collected from one
# hosted run root: original command receipts, the managed journals and
# signed bodies with their run-relative identities, and manifest.txt
# pinning every collected byte. Fails (exit 1) naming the first defect:
# a manifest entry whose file is missing or altered, a collected file the
# manifest does not pin, no managed journal, no signed body, or journals
# from fewer than two wallet partitions (a wallet's records lost, or two
# command lifetimes mixed into one partition). Usage and setup failures
# exit 2, distinct from the verdict.
set -u

[ "$#" -eq 1 ] || {
  echo "usage: $0 EVIDENCE" >&2
  exit 2
}
evidence="$1"
[ -d "$evidence" ] || {
  echo "evidence: no directory: $evidence" >&2
  exit 2
}
manifest="$evidence/manifest.txt"
[ -f "$manifest" ] || {
  echo "evidence: REFUSED: no manifest.txt in $evidence" >&2
  exit 1
}

fail() {
  echo "evidence: REFUSED: $*" >&2
  exit 1
}

for field in producer_sha producer_run producer_part; do
  grep -q "^$field=" "$manifest" || fail "manifest names no $field"
done

# Every manifest-pinned byte still matches the collected file.
pinned="$(mktemp)"
trap 'rm -f "$pinned"' EXIT
sha_line='^[0-9a-f]{64}  '
while IFS= read -r line; do
  [[ "$line" =~ $sha_line ]] || continue
  sum="${line:0:64}"
  path="${line:66}"
  # The collector hashes from inside the bundle, so manifest paths
  # start with ./ — the same file the bundle carries.
  path="${path#./}"
  [ -f "$evidence/$path" ] || fail "manifest pins missing file: $path"
  got="$(sha256sum <"$evidence/$path" | cut -d' ' -f1)"
  [ "$got" = "$sum" ] || fail "manifest hash mismatch (altered record): $path"
  printf '%s\n' "$path" >>"$pinned"
done <"$manifest"
[ -s "$pinned" ] || fail "manifest pins no files"

# Every collected file is manifest-pinned; nothing extra rode along.
collected="$(mktemp)"
trap 'rm -f "$pinned" "$collected"' EXIT
(cd "$evidence" && find . -type f ! -name manifest.txt | sed 's|^\./||' | sort) >"$collected"
extra="$(comm -23 "$collected" <(sort "$pinned"))"
[ -z "$extra" ] || fail "collected files the manifest does not pin: $(head -n 3 <<<"$extra" | tr '\n' ' ')"

# Required record classes: at least one managed journal, one signed body.
journals="$(find "$evidence" -path '*/wallets/*/journal.jsonl' -type f | sort)"
[ -n "$journals" ] || fail "no managed journal (*/wallets/*/journal.jsonl)"
bodies="$(find "$evidence" -path '*/submissions/*' -type f | sort)"
[ -n "$bodies" ] || fail "no signed body (*/submissions/*)"

# Multiple wallet partitions: journals from at least two wallets, so no
# command lifetime is mixed into another and none was lost.
partitions="$(sed 's|.*/wallets/||; s|/journal.jsonl||' <<<"$journals" | sort -u)"
count="$(wc -l <<<"$partitions" | tr -d ' ')"
[ "$count" -ge 2 ] || fail "journals from fewer than two wallet partitions ($count)"

echo "evidence: OK: $(wc -l <"$pinned" | tr -d ' ') manifest-pinned files verified;"
echo "evidence: OK: $(wc -l <<<"$journals" | tr -d ' ') journals across $count wallet partitions;"
echo "evidence: OK: $(wc -l <<<"$bodies" | tr -d ' ') signed bodies"

#!/usr/bin/env bash
set -euo pipefail

HISTORICAL_BASE=0100012b1afa318df3bae6cf40d6d9ee3507110e
CONSUMER=14a64a4681d3e429fab5877062b5c476c2a4bfe2
V1_SHA=e73d96749930acbb98abe70e67c01f2dfc13b284a4e8a1cd901aadf72aeb9eb0
REPORT_ONLY_SHA=01dde92a4531bf5eca2c751566480c772c0a10695d5f5f69e0b7f786b2dd2009
VALID_LABELS_SHA=c6008b632db3b5d694dc299a46fa544997991175ce6c6c08aeb35de28e6ffc66

gate_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
milestone="$(realpath "$gate_dir/../../..")"
report_only="$milestone/handoffs/registration-gate-v1-report-only-control.json"
valid_labels="$milestone/handoffs/registration-gate-v1-valid-labels-control.json"
seal="$gate_dir/consumer-registration-v2.producer-seal.json"

fail() {
  echo "gate-v2: $*" >&2
  exit 1
}

test_sha() {
  local file="$1" expected="$2" actual
  test -f "$file" || fail "missing parent control: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  test "$actual" = "$expected" || fail "parent control digest drift: $file"
}

test_sha "$report_only" "$REPORT_ONLY_SHA"
test_sha "$valid_labels" "$VALID_LABELS_SHA"
for control in "$report_only" "$valid_labels"; do
  jq -e --arg gate "$V1_SHA" --arg base "$HISTORICAL_BASE" '
    .gateSha256 == $gate and .base == $base and .exit == 0 and
    .executedPrograms == "none: report writer and git identity only" and
    .fakeEvidenceFilesExist == false and
    (.candidate | type == "string" and length == 40) and
    (.interpretation | startswith("FALSE GREEN"))
  ' "$control" >/dev/null || fail "invalid parent false-green receipt: $control"
done

repo="${1:?usage: consumer-registration-v2.sh <candidate-worktree> [evidence-dir]}"
evidence="${2:-}"
repo="$(realpath "$repo")"

git -C "$repo" merge-base --is-ancestor "$HISTORICAL_BASE" HEAD ||
  fail "candidate does not descend from historical base $HISTORICAL_BASE"
test -z "$(git -C "$repo" status --porcelain)" || fail "candidate tree is not clean"
head_commit="$(git -C "$repo" rev-parse HEAD)"

runner="$repo/conformance/consumer-adapter/run-registration-gate"
test -x "$runner" || fail "missing executable $runner"

if test -z "$evidence"; then
  evidence="$(mktemp -d /tmp/e18-consumer-registration-v2.XXXXXXXX)"
else
  mkdir -p "$evidence"
  evidence="$(realpath "$evidence")"
fi
test -z "$(find "$evidence" -mindepth 1 -maxdepth 1 -print -quit)" ||
  fail "evidence directory must start empty: $evidence"

prepared="$evidence/prepared"
mkdir "$prepared"
"$runner" "$prepared" >"$evidence/runner.stdout" 2>"$evidence/runner.stderr"

# Inspect every legacy evidence claim before accepting a v2 schema. This is the
# exact rejection path exercised by both v1 false-green candidates.
while IFS=$'\t' read -r report entry_kind rel digest; do
  test -n "$rel" || fail "$report contains an empty evidence path"
  case "$rel" in
    /*|*..*) fail "$report contains unsafe evidence path: $rel" ;;
  esac
  test -f "$prepared/$rel" || fail "$report declares nonexistent evidence: $rel"
  test "$entry_kind" = object ||
    fail "$report uses an unbound legacy evidence string: $rel"
  test "$digest" = "$(sha256sum "$prepared/$rel" | awk '{print $1}')" ||
    fail "$report evidence digest mismatch: $rel"
done < <(
  find "$prepared" -maxdepth 1 -type f -name '*.json' -print0 |
    while IFS= read -r -d '' report; do
      jq -r --arg report "$(basename "$report")" '
        [.. | objects | .evidence? | select(type == "array") | .[]] |
        .[] | if type == "object"
          then [$report, "object", (.path // ""), (.sha256 // "")]
          else [$report, (type), (if type == "string" then . else "" end), ""]
          end | @tsv
      ' "$report"
    done
)

for file in prepared.json inventory.json cek-vectors.json ledger-plan.json; do
  test -f "$prepared/$file" || fail "runner did not prepare v2 file: $file"
  jq -e . "$prepared/$file" >/dev/null || fail "invalid JSON: $file"
done
test -d "$prepared/raw" || fail "runner did not prepare raw/ evidence tree"
test -z "$(find "$prepared/raw" -type l -print -quit)" ||
  fail "symlinks are forbidden in raw evidence"

# The inventory is a closed, measured set. The candidate's claimed hashes are
# recomputed here; duplicate, missing, absolute and traversal paths are rejected.
jq -e '
  .schema == "singular-consumer-registration-inventory-v2" and
  (.files | type == "array" and length > 0) and
  ([.files[].path] | length == (unique | length)) and
  all(.files[];
    (.path | type == "string" and length > 0 and
      (startswith("/") | not) and (contains("..") | not)) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.bytes | type == "number" and . >= 0))
' "$prepared/inventory.json" >/dev/null || fail "invalid closed inventory schema"

actual_list="$evidence/actual-files.txt"
declared_list="$evidence/declared-files.txt"
find "$prepared/raw" -type f -printf '%P\n' | LC_ALL=C sort >"$actual_list"
jq -r '.files[].path' "$prepared/inventory.json" | LC_ALL=C sort >"$declared_list"
cmp -s "$actual_list" "$declared_list" || fail "raw artifact inventory is not closed"
while IFS=$'\t' read -r rel want_sha want_bytes; do
  file="$prepared/raw/$rel"
  got_sha="$(sha256sum "$file" | awk '{print $1}')"
  got_bytes="$(wc -c <"$file" | tr -d ' ')"
  test "$got_sha" = "$want_sha" || fail "raw artifact digest mismatch: $rel"
  test "$got_bytes" = "$want_bytes" || fail "raw artifact byte count mismatch: $rel"
done < <(jq -r '.files[] | [.path,.sha256,(.bytes|tostring)] | @tsv' "$prepared/inventory.json")

# Preparation files are inputs only. Outcome-like keys are forbidden here so a
# candidate report can never become the oracle again.
for file in prepared.json inventory.json cek-vectors.json ledger-plan.json; do
  jq -e '[.. | objects | keys[] | select(
    . == "expected" or . == "observed" or . == "verdict" or
    . == "passed" or . == "established" or . == "refuted" or
    . == "tree_clean" or . == "compiled_bytes_changed" or
    . == "source_rebuilt" or . == "clean_restored"
  )] | length == 0' "$prepared/$file" >/dev/null ||
    fail "candidate preparation contains forbidden outcome/identity claims: $file"
done

test -f "$seal" ||
  fail "missing parent producer seal (BLOCKED-PRE-SEAL; no behavioral result)"

jq -e --arg historical "$HISTORICAL_BASE" --arg consumer "$CONSUMER" '
  .schema == "singular-consumer-registration-parent-seal-v2" and
  .historical_base == $historical and
  .consumer_source_commit == $consumer and
  (.integration_base | type == "string" and length == 40) and
  .plutus_version == "v3" and .protocol_major == 10 and
  .builtin_semantics_variant == "defaultFunSemanticsVariantC" and
  (.parent_verifier.path | type == "string" and length > 0) and
  (.parent_verifier.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
' "$seal" >/dev/null || fail "invalid parent producer seal"

integration_base="$(jq -r .integration_base "$seal")"
git -C "$repo" merge-base --is-ancestor "$HISTORICAL_BASE" "$integration_base" ||
  fail "sealed integration base does not descend from historical base"
git -C "$repo" merge-base --is-ancestor "$integration_base" "$head_commit" ||
  fail "candidate does not descend from sealed integration base"
changed="$(git -C "$repo" diff --name-only "$integration_base..$head_commit")"
test -n "$changed" || fail "no adapter change from sealed integration base"
bad="$(printf '%s\n' "$changed" | awk '$0 !~ /^conformance\/consumer-adapter\//')"
test -z "$bad" || {
  echo "gate-v2: paths outside frozen adapter fence:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
}

verifier_rel="$(jq -r .parent_verifier.path "$seal")"
case "$verifier_rel" in
  /*|*..*) fail "unsafe parent verifier path in seal: $verifier_rel" ;;
esac
verifier="$gate_dir/$verifier_rel"
test -x "$verifier" || fail "sealed parent verifier is missing/not executable"
test "$(sha256sum "$verifier" | awk '{print $1}')" = "$(jq -r .parent_verifier.sha256 "$seal")" ||
  fail "sealed parent verifier digest mismatch"

# The sealed parent verifier owns fixed expected rows/purposes, compilation,
# parameter application, CEK execution, ledger submission/query and mutations.
# Its success receipt is written by the verifier, not by the candidate runner.
parent_receipt="$evidence/parent-receipt.json"
"$verifier" \
  --repo "$repo" \
  --candidate "$head_commit" \
  --prepared "$prepared" \
  --seal "$seal" \
  --receipt "$parent_receipt"
jq -e --arg candidate "$head_commit" '
  .schema == "singular-consumer-registration-parent-receipt-v2" and
  .candidate_commit == $candidate and .real_positive_executed == true and
  .real_positive_accepted == true and .all_fixed_rows_satisfied == true and
  .all_parent_mutation_controls_fired == true and
  .artifacts_rebuilt_and_measured == true and
  .ledger_submitted_and_queried == true
' "$parent_receipt" >/dev/null || fail "parent verifier did not issue a complete receipt"

echo "gate-v2: GREEN candidate=$head_commit evidence=$evidence"

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
seal="$gate_dir/consumer-registration-v3.producer-seal.json"
seal_digest="$gate_dir/consumer-registration-v3.producer-seal.sha256"

fail() {
  echo "gate-v3: $*" >&2
  exit 1
}

test_sha() {
  local file="$1" expected="$2" actual
  test -f "$file" || fail "missing parent control: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  test "$actual" = "$expected" || fail "parent control digest drift: $file"
}

# Parent controls and the complete parent authority packet are admitted before
# even locating the candidate runner.  Missing authority therefore executes no
# candidate-controlled program.
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

test -f "$seal" || fail "missing parent producer seal (BLOCKED-PRE-SEAL; zero candidate execution)"
test -f "$seal_digest" || fail "missing parent seal digest (BLOCKED-PRE-SEAL; zero candidate execution)"
read -r expected_seal sealed_name extra <"$seal_digest"
test -z "${extra:-}" || fail "invalid parent seal digest sidecar"
test "$sealed_name" = "consumer-registration-v3.producer-seal.json" ||
  fail "parent seal digest names the wrong file"
test_sha "$seal" "$expected_seal"

repo="${1:?usage: consumer-registration-v3.sh <candidate-worktree> [evidence-dir]}"
test -d "$repo/.git" -o -f "$repo/.git" || fail "candidate is not a git worktree: $repo"
repo="$(realpath "$repo")"
test -z "$(git -C "$repo" status --porcelain)" || fail "candidate tree is not clean"
head_commit="$(git -C "$repo" rev-parse HEAD)"

# Validate the fixed seal identity fields before any candidate execution.
jq -e \
  --arg historical "$HISTORICAL_BASE" \
  --arg consumer "$CONSUMER" \
  --arg candidate "$head_commit" '
  .schema == "singular-consumer-registration-parent-seal-v3" and
  .historical_base == $historical and
  .consumer_source_commit == $consumer and
  .candidate_commit == $candidate and
  (.integration_base | type == "string" and test("^[0-9a-f]{40}$")) and
  .plutus_version == "v3" and .protocol_major == 10 and
  .builtin_semantics_variant == "defaultFunSemanticsVariantC" and
  (.parent_verifier.path | type == "string" and length > 0 and
    (startswith("/") | not) and (contains("..") | not)) and
  (.parent_verifier.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
' "$seal" >/dev/null || fail "invalid parent producer seal identity"

integration_base="$(jq -r .integration_base "$seal")"
git -C "$repo" merge-base --is-ancestor "$HISTORICAL_BASE" "$integration_base" ||
  fail "sealed integration base does not descend from historical base"
git -C "$repo" merge-base --is-ancestor "$integration_base" "$head_commit" ||
  fail "candidate does not descend from sealed integration base"
changed="$(git -C "$repo" diff --name-only "$integration_base..$head_commit")"
test -n "$changed" || fail "no adapter change from sealed integration base"
bad="$(printf '%s\n' "$changed" | awk '$0 !~ /^conformance\/consumer-adapter\//')"
test -z "$bad" || {
  echo "gate-v3: paths outside frozen adapter fence:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
}

verifier_rel="$(jq -r .parent_verifier.path "$seal")"
verifier="$gate_dir/$verifier_rel"
test -x "$verifier" || fail "sealed parent verifier is missing/not executable"
test_sha "$verifier" "$(jq -r .parent_verifier.sha256 "$seal")"
python="$(jq -r .tools.python "$seal")"
test -x "$python" || fail "sealed Python interpreter is missing/not executable"
test "$("$python" --version 2>&1)" = "$(jq -r .tools.python_version "$seal")" ||
  fail "sealed Python interpreter version drift"

evidence="${2:-}"
if test -z "$evidence"; then
  evidence="$(mktemp -d /tmp/e18-consumer-registration-v3.XXXXXXXX)"
else
  mkdir -p "$evidence"
  evidence="$(realpath "$evidence")"
fi
test -z "$(find "$evidence" -mindepth 1 -maxdepth 1 -print -quit)" ||
  fail "evidence directory must start empty: $evidence"

# This validates the complete fixed inventories, semantic bindings, mutation
# inventory, exact tools, and every source commit/tree before candidate code.
"$python" "$verifier" \
  --repo "$repo" \
  --candidate "$head_commit" \
  --seal "$seal" \
  --evidence-root "$evidence/parent-preflight" \
  --preflight-only \
  >"$evidence/parent-preflight.stdout" \
  2>"$evidence/parent-preflight.stderr"
cat "$evidence/parent-preflight.stdout"
cat "$evidence/parent-preflight.stderr" >&2

runner="$repo/conformance/consumer-adapter/run-registration-gate"
test -x "$runner" || fail "missing executable candidate runner: $runner"

prepared="$evidence/prepared"
mkdir "$prepared"

# First and only candidate-controlled execution in the gate.
"$runner" "$prepared" >"$evidence/runner.stdout" 2>"$evidence/runner.stderr"

# Reject the exact v1 report-writer shape before accepting v3 preparation.
while IFS=$'\t' read -r report entry_kind rel digest; do
  test -n "$rel" || fail "$report contains an empty evidence path"
  case "$rel" in
    /*|*..*) fail "$report contains unsafe evidence path: $rel" ;;
  esac
  test -f "$prepared/$rel" || fail "$report declares nonexistent evidence: $rel"
  test "$entry_kind" = object || fail "$report uses an unbound legacy evidence string: $rel"
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
  test -f "$prepared/$file" || fail "runner did not prepare v3 file: $file"
  jq -e . "$prepared/$file" >/dev/null || fail "invalid JSON: $file"
done
test -d "$prepared/raw" || fail "runner did not prepare raw/ evidence tree"
test -z "$(find "$prepared/raw" -type l -print -quit)" || fail "symlinks are forbidden in raw evidence"

# Outcome-like claims remain inadmissible even though the parent verifier does
# not read them as an oracle.
for file in prepared.json inventory.json cek-vectors.json ledger-plan.json; do
  jq -e '[.. | objects | keys[] | select(
    . == "expected" or . == "observed" or . == "verdict" or
    . == "passed" or . == "established" or . == "refuted" or
    . == "tree_clean" or . == "compiled_bytes_changed" or
    . == "source_rebuilt" or . == "clean_restored"
  )] | length == 0' "$prepared/$file" >/dev/null ||
    fail "candidate preparation contains forbidden outcome/identity claims: $file"
done

parent_receipt="$evidence/parent-receipt.json"
"$python" "$verifier" \
  --repo "$repo" \
  --candidate "$head_commit" \
  --prepared "$prepared" \
  --seal "$seal" \
  --evidence-root "$evidence/parent-execution" \
  --receipt "$parent_receipt"

jq -e --arg candidate "$head_commit" --arg seal_sha "$expected_seal" '
  .schema == "singular-consumer-registration-parent-receipt-v3" and
  .candidate_commit == $candidate and .seal_sha256 == $seal_sha and
  .real_positive_executed == true and .real_positive_accepted == true and
  .all_fixed_rows_satisfied == true and
  .all_parent_mutation_controls_fired == true and
  .artifacts_rebuilt_and_measured == true and
  .ledger_submitted_and_queried == true and
  .variant_c_executed_and_discriminated == true and
  .cek_semantics_control.variant == "defaultFunSemanticsVariantC" and
  .cek_semantics_control.discriminator_fired == true
' "$parent_receipt" >/dev/null || fail "parent verifier did not issue a complete receipt"

echo "gate-v3: GREEN candidate=$head_commit evidence=$evidence"

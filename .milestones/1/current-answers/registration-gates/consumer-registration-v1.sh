#!/usr/bin/env bash
set -euo pipefail

BASE=0100012b1afa318df3bae6cf40d6d9ee3507110e
CONSUMER=14a64a4681d3e429fab5877062b5c476c2a4bfe2

repo="${1:?usage: consumer-registration-v1.sh <candidate-worktree> [evidence-dir]}"
evidence="${2:-}"
repo="$(realpath "$repo")"

git -C "$repo" merge-base --is-ancestor "$BASE" HEAD
test -z "$(git -C "$repo" status --porcelain)" || {
  echo "gate: candidate tree is not clean" >&2
  exit 1
}

head_commit="$(git -C "$repo" rev-parse HEAD)"
changed="$(git -C "$repo" diff --name-only "$BASE..$head_commit")"
test -n "$changed" || {
  echo "gate: no candidate changes from $BASE" >&2
  exit 1
}
bad="$(printf '%s\n' "$changed" | awk '$0 !~ /^conformance\/consumer-adapter\//')"
test -z "$bad" || {
  echo "gate: paths outside the frozen writable fence:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
}

runner="$repo/conformance/consumer-adapter/run-registration-gate"
test -x "$runner" || {
  echo "gate: missing executable $runner" >&2
  exit 1
}

if test -z "$evidence"; then
  evidence="$(mktemp -d /tmp/e18-consumer-registration-v1.XXXXXXXX)"
else
  mkdir -p "$evidence"
  evidence="$(realpath "$evidence")"
fi
test -z "$(find "$evidence" -mindepth 1 -maxdepth 1 -print -quit)" || {
  echo "gate: evidence directory must start empty: $evidence" >&2
  exit 1
}

"$runner" "$evidence" >"$evidence/runner.stdout" 2>"$evidence/runner.stderr"

identity="$evidence/identity.json"
results="$evidence/results.json"
controls="$evidence/controls.json"
for file in "$identity" "$results" "$controls"; do
  jq -e . "$file" >/dev/null
done

jq -e --arg head "$head_commit" --arg consumer "$CONSUMER" '
  .schema == "singular-consumer-registration-identity-v1" and
  .candidate_commit == $head and .tree_clean == true and
  .consumer_source_commit == $consumer and
  (.compiler.aiken_actual | type == "string" and length > 0) and
  .plutus_version == "v3" and .protocol_major == 10 and
  .builtin_semantics_variant == "defaultFunSemanticsVariantC" and
  (.artifacts | type == "array" and length > 0) and
  ([.artifacts[].name] | length == (unique | length)) and
  ([.artifacts[] | select(
    (.source_digest | type != "string" or length != 64) or
    (.compiled_digest | type != "string" or length != 64) or
    (.script_hash | type != "string" or length != 56)
  )] | length == 0) and
  (["producer-state", "producer-request", "producer-application",
    "producer-applied-representative", "registry-adapter",
    "checkpoint-policy", "lifecycle-observer"] - [.artifacts[].name] | length == 0)
' "$identity" >/dev/null

expected_rows='["E0-register-valid-cek","E0-register-valid-ledger","E1-missing-inception-cek","E1-missing-inception-ledger","E4-wrong-allocation-cek","E4-wrong-allocation-ledger","register-omitted-adapter","register-swapped-adapter","register-extra-checkpoint-mint","register-wrong-aid-name","register-delete","register-surplus-action"]'
jq -e --argjson expected "$expected_rows" '
  .schema == "singular-consumer-registration-results-v1" and
  ([.rows[].id] | sort == ($expected | sort)) and
  ([.rows[].id] | length == (unique | length)) and
  ([.rows[] | select(.observed != .expected)] | length == 0) and
  ([.rows[] | select(.observed == "COULD-NOT-EVALUATE")] | length == 0) and
  ([.rows[] | select(
    (.stage | type != "string" or length == 0) or
    (.purpose | type != "string" or length == 0) or
    (.evidence | type != "array" or length == 0)
  )] | length == 0)
' "$results" >/dev/null

expected_controls='["always-refuse","always-accept","remove-inception-observer-check","remove-allocation-check","remove-unaccounted-checkpoint-check","remove-mandatory-adapter-invocation","inventory-remove-one"]'
jq -e --argjson expected "$expected_controls" '
  .schema == "singular-consumer-registration-controls-v1" and
  ([.controls[].id] | sort == ($expected | sort)) and
  ([.controls[].id] | length == (unique | length)) and
  ([.controls[] | select(
    .verdict != "REFUTED" or .clean_restored != true or
    (.evidence | type != "array" or length == 0)
  )] | length == 0)
  and
  ([.controls[] | select(.id != "inventory-remove-one") | select(
    .source_rebuilt != true or .compiled_bytes_changed != true
  )] | length == 0)
  and
  ([.controls[] | select(.id == "inventory-remove-one") | select(
    .inventory_changed != true
  )] | length == 0)
' "$controls" >/dev/null

echo "gate: GREEN candidate=$head_commit evidence=$evidence"

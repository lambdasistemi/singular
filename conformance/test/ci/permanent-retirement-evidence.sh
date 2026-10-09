#!/usr/bin/env bash
# Current retirement evidence; the broader Absent requirement is a separate row.
set -euo pipefail
receipt="$1" base="$2" state="$3"
# jq expands its own --arg variables inside this program.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg base "$base" --arg state "$state" '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  def text: type == "string" and length > 0;
  def complete: .comparison == "agrees" and .tamper == null
    and (.compared | length) == 9 and .perturbation.refused > 0;
  .row == "permanent-retire-active-key"
  and .verdict == "agrees-with-model"
  and .base == $base and .dirty == false
  and (.blueprint | text) and (.node | text)
  and (.steps | length) == 11
  and ([.steps[].edge] == ["insertActive","updateTerminal","insertAbsent","updateTerminal","insertActive","updateTerminal","updateTerminal","insertActive","deleteActive","updateTerminal","insertActive"])
  and all(.steps[]; .tamper == null and .comparison == "agrees")
  and ([.steps[].model.outcome] == ["accepted","accepted","refused","refused","accepted","accepted","refused","accepted","refused","accepted","refused"])
  and ([.steps[].chain.outcome] == [.steps[].model.outcome])
  and .steps[2].model.reason == "edge-inadmissible"
  and .steps[3].model.reason == "key-unknown"
  and .steps[6].model.reason == "key-unknown"
  and .steps[8].model.reason == "edge-inadmissible"
  and .steps[10].model.reason == "key-exists"
  and all(.steps[] | select(.model.outcome == "accepted"); complete and (.chain.txid | txid))
  and all(.steps[] | select(.model.outcome == "refused");
    (.chain.txid | txid) and (.chain.refusal.hashes | index($state) != null))
  and .steps[1].perturbation.byObservation.mint > 0
  and .steps[1].perturbation.byObservation.leaf > 0
  and .steps[9].perturbation.byObservation.mint > 0
  and .steps[9].perturbation.byObservation.leaf > 0
  and .steps[0].registry == .steps[1].registry
  and .steps[1].registry == .steps[2].registry
  and .steps[2].registry == .steps[3].registry
  and .steps[4].registry == .steps[5].registry
  and .steps[5].registry == .steps[6].registry
  and .steps[0].registry != .steps[4].registry
  and ([.steps[7,8,9,10].registry] | unique | length) == 1
  and .steps[7].registry == .steps[0].registry
  and ([.steps[7,8,9,10].request.key] | unique | length) == 1
  and (.transactions | length) == 6
  and .transactions == [.steps[] | select(.chain.outcome == "accepted") | .chain.txid]
' "$receipt" >/dev/null || {
  echo 'FAIL: current permanent retirement evidence moved'
  exit 1
}
bash test/ci/replay-evidence.sh steps "$receipt"

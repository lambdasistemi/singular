#!/usr/bin/env bash
# #287: the traced replay a receipt carries, as the workflow asserts it.
#
#   replay-evidence.sh steps RECEIPT        a story receipt (G6)
#   replay-evidence.sh attribution RECEIPT  a refused row's attribution (G7)
#
# Exits 0 when the receipt carries the evidence, 1 when it does not.
set -euo pipefail

# G6: every refused step that carries the model's reason carries the traced
# replay of its transaction. The step's trace is the model's reason; one
# replayed purpose admitted that reason; every replayed purpose names its
# deployed hash, its capture, and a reason with its traced hash or a cause,
# never both; the receipt states once the traced build its reasons rely on.
# A receipt with no such step fails: it proves nothing.
# jq expands its own variables inside these programs.
# shellcheck disable=SC2016
steps_program='
def hex($n): type == "string" and test("^[0-9a-f]{\($n)}$");
def text: type == "string" and length > 0;
[.steps[] | select(.chain.outcome == "refused" and (.model.reason | type) == "string")] as $refused
| ($refused | length) > 0
and all($refused[];
  .model.reason as $reason
  | .chain.refusal.trace == $reason
  and (.chain.refusal.replay | type == "array" and length > 0)
  and any(.chain.refusal.replay[]; .reason == $reason)
  and all(.chain.refusal.replay[];
    (.deployedHash | hex(56)) and (.captureId | hex(64))
    and ((.reason | text) != (.cause | text))
    and (if .reason then (.tracedHash | hex(56)) else true end)))
and (.replayCorrespondence
  | (.source | text) and (.compiler | text) and (.flags | text)
  and (.untracedHashesDigest | hex(64)))
'

# G7: each failing purpose of the rejected transaction names its deployed
# hash and the reason the replay admitted, with its traced hash and capture,
# or the cause it admits none, never both. A named validator branch is a
# reason the replay admitted; a receipt with any reason states the traced
# build once.
# shellcheck disable=SC2016
attribution_program='
def text: type == "string" and length > 0;
.outcome == "refused"
and (.refusal.replay | type == "array" and length > 0)
and all(.refusal.replay[];
  (.deployedHash | text)
  and ((.reason | text) != (.cause | text))
  and (if .reason then (.tracedHash | text) and (.captureId | text) else true end))
and (if .refusal.branch == null then true
  else .refusal.branch as $branch | any(.refusal.replay[]; .reason == $branch) end)
and (if any(.refusal.replay[]; .reason) then
  (.replayCorrespondence.untracedHashesDigest | text) else true end)
'

case "${1:-}" in
  steps) program=$steps_program ;;
  attribution) program=$attribution_program ;;
  *)
    echo 'usage: replay-evidence.sh steps|attribution RECEIPT' >&2
    exit 2
    ;;
esac
[ -f "${2:-}" ] || {
  echo "replay-evidence.sh: no receipt at '${2:-}'" >&2
  exit 2
}
nix run --quiet nixpkgs#jq -- -e "$program" "$2" >/dev/null

#!/usr/bin/env bash
# The generic conformance rows as a packaged app without a dev shell, run from
# conformance/ by the Conformance workflow. Kept as a file rather than an inline
# step: actionlint writes an inline script into a pipe before its checker
# starts reading, which never completes for a script larger than the pipe
# buffer the host grants, and this script is over 12 KB.
set -e
blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
# The receipts directory is invocation-fresh: stale records
# must never supplement a partial or failed run.
CONFORMANCE_RECEIPTS="$(mktemp -d "$RUNNER_TEMP/conformance-receipts.XXXXXX")"
export CONFORMANCE_RECEIPTS
printf 'CONFORMANCE_RECEIPTS=%s\n' "$CONFORMANCE_RECEIPTS" >>"$GITHUB_ENV"
set +e
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run CG02 CG03 CG04 CG05 CG09 CG10 CG11 CG12 CG19 CG21 --receipts-dir "$CONFORMANCE_RECEIPTS" 2>&1 | tee /tmp/generic-rows.log
run_rc=${PIPESTATUS[0]}
set -e
echo "generic session exit: $run_rc (expected: exactly 1, the handled session-debt exit)"
# --- expected-debt assertion over ACTUAL session results
# --- (A-001, NOTE-002: never success from a bare nonzero or
# --- an error label; build/setup/crash/unknown must FAIL)
head_sha="$(git rev-parse HEAD)"
# 1. the EXACT intended session-debt status, never "nonzero":
#    Main.hs maps every handled session failure to exit 1, so
#    exit 1 is the intended result ONLY together with the
#    complete terminal evidence asserted below.
[ "$run_rc" -eq 1 ] || {
  echo "FAIL: session exit $run_rc is not the known session-debt exit 1 — a build/setup/crash exit is an unexamined failure, not expected debt"
  exit 1
}
# 2. complete session evidence: all 10 rows executed...
grep -q 'complete: 10/10 rows ok' /tmp/generic-rows.log || {
  echo 'FAIL: the session did not complete all 10 rows (mid-run failure or crash)'
  exit 1
}
#    ...and the terminal failure is the held-rows debt report
grep -q 'ROWS THE RUN CANNOT REPORT AS PASSING' /tmp/generic-rows.log || {
  echo 'FAIL: the terminal failure is not the held-rows debt report'
  exit 1
}
# 3. exactly the ten rows plus the session CL01, no extras
printf '%s\n' CG02 CG03 CG04 CG05 CG09 CG10 CG11 CG12 CG19 CG21 CL01 | sort >/tmp/expected-rows.txt
nix run --quiet nixpkgs#jq -- -r '.row' "${CONFORMANCE_RECEIPTS}"/receipt-*.json | sort >/tmp/receipt-rows.txt
#    Compared with bash builtins, not diff: this step runs a packaged
#    app without a dev shell, and an absent diff previously reported
#    'receipt set mismatch' — an unavailable tool misattributed as a
#    substantive failure. No external command, so no such path remains.
if [ "$(</tmp/expected-rows.txt)" != "$(</tmp/receipt-rows.txt)" ]; then
  echo 'FAIL: receipt set mismatch (missing or extra row)'
  echo '--- expected rows ---'
  while IFS= read -r l; do echo "$l"; done </tmp/expected-rows.txt
  echo '--- receipt rows ---'
  while IFS= read -r l; do echo "$l"; done </tmp/receipt-rows.txt
  exit 1
fi
# 4. exactly the expected verdict per receipt, EVERY receipt
#    bound to this candidate on a clean tree (dirty:false)
expect_verdict() {
  case "$1" in
    CG02 | CG03 | CG04 | CG05 | CG10 | CG21 | CL01) printf 'agrees-with-model' ;;
    CG09) printf 'unmet-by-ruling' ;;
    CG11 | CG12 | CG19) printf 'held-q002' ;;
    *) printf 'UNKNOWN-ROW' ;;
  esac
}
for row in CG02 CG03 CG04 CG05 CG09 CG10 CG11 CG12 CG19 CG21 CL01; do
  f="${CONFORMANCE_RECEIPTS}/receipt-$row.json"
  test -f "$f" || {
    echo "FAIL: missing receipt for $row"
    exit 1
  }
  v="$(nix run --quiet nixpkgs#jq -- -r '.verdict' "$f")"
  want="$(expect_verdict "$row")"
  [ "$v" = "$want" ] || {
    echo "FAIL: unexpected verdict for $row: got '$v', expected '$want'"
    exit 1
  }
  [ "$(nix run --quiet nixpkgs#jq -- -r '.dirty' "$f")" = "false" ] || {
    echo "FAIL: $row receipt records a dirty tree"
    exit 1
  }
  [ "$(nix run --quiet nixpkgs#jq -- -r '.base' "$f")" = "$head_sha" ] || {
    echo "FAIL: $row receipt is not bound to this candidate ($head_sha)"
    exit 1
  }
done
# 5. CL01 carries the session's measurement evidence: nonzero
#    units and size, folds named — refuse missing or divergent
nix run --quiet nixpkgs#jq -- -e '.mem > 0 and .cpu > 0 and .txSize > 0 and (.transactions | length > 0)' "${CONFORMANCE_RECEIPTS}"/receipt-CL01.json >/dev/null || {
  echo 'FAIL: CL01 measurement evidence missing or divergent'
  exit 1
}
# 6. the run's own accounting must name exactly the expected
#    held and unmet sets, with nothing failing against this candidate
held="$(sed -n 's/^- Held .*held-q002): //p' /tmp/generic-rows.log)"
[ "$held" = "CG11 CG12 CG19" ] || {
  echo "FAIL: held set moved: got '$held', expected 'CG11 CG12 CG19'"
  exit 1
}
unmet="$(sed -n 's/^- Unmet by ruling .*unmet-by-ruling): //p' /tmp/generic-rows.log)"
[ "$unmet" = "CG09" ] || {
  echo "FAIL: unmet set moved: got '$unmet', expected 'CG09'"
  exit 1
}
# nothing may fail against this candidate
failing="$(sed -n 's/^- Failing .*accepted): //p' /tmp/generic-rows.log)"
[ "$failing" = "none" ] || {
  echo "FAIL: rows failing against this candidate: $failing"
  exit 1
}
# 7. Bind observations to full hashes from the compiled
#    blueprint. The human log marker is abbreviated and
#    cannot serve as a script identity.
state_hash="$(nix run --quiet nixpkgs#jq -- -er '.validators[] | select(.title == "state.state.spend" and ((.parameters // []) | length) == 0) | .hash' "$blueprint")"
# #157 C8/C10: `consumer.ak` is deleted and every rule it re-walked
# beside the fold is the cage's own, so there is no consumer hook to
# bind and the cage alone decides. The control below binds the
# refusal to the state script instead.
for row in CG11 CG12; do
  f="${CONFORMANCE_RECEIPTS}/receipt-$row.json"
  # jq expands its own --arg variables inside this program.
  # shellcheck disable=SC2016
  nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
    .outcome == "refused" and .venue == "node-submit"
    and (.rejected | test("^[0-9a-f]{64}$"))
    and .refusal.phase == "phase-2"
    and (.refusal.hashes | index($state) != null)
    and ((.refusal.branch | type == "string" and length > 0)
      or (.refusal.limit | type == "string" and length > 0))
  ' "$f" >/dev/null || {
    echo "FAIL: $row structural refusal evidence moved"
    exit 1
  }
done
# CG19 under the registry-mode cage is REFUSED at the state script
# (A-015): the interface routes a processed request to its own
# destination minus the tip and a refund to the address custody
# records, so a crossed allocation -- one request's value routed to
# another's target, or to a hook the mandate deleted -- is a routing
# the cage refuses. Same structural refusal evidence as CG11/CG12.
# jq expands its own --arg variables inside this program.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  .outcome == "refused" and .venue == "node-submit"
  and (.rejected | test("^[0-9a-f]{64}$"))
  and .refusal.phase == "phase-2"
  and (.refusal.hashes | index($state) != null)
  and ((.refusal.branch | type == "string" and length > 0)
    or (.refusal.limit | type == "string" and length > 0))
' "${CONFORMANCE_RECEIPTS}"/receipt-CG19.json >/dev/null || {
  echo 'FAIL: CG19 structural refusal evidence moved'
  exit 1
}
grep -q '^control: CG11 control: nonempty fold accepted (tx=[0-9a-f]\{64\})' /tmp/generic-rows.log || {
  echo 'FAIL: CG11 accepting control txid missing'
  exit 1
}
grep -q '^control: CG12 control: exact 1:1 fold accepted (tx=[0-9a-f]\{64\})' /tmp/generic-rows.log || {
  echo 'FAIL: CG12 accepting control txid missing'
  exit 1
}
# 8. standalone rejected-floor control receipt mandatory:
#    two nonempty obligations, ordered pair, paid-vs-owed,
#    phase/hash/limit, both txids, counterpart, identity.
c="${CONFORMANCE_RECEIPTS}/control-CG19-rejected-floor.json"
test -f "$c" || {
  echo 'FAIL: missing CG19-rejected-floor control receipt'
  exit 1
}
# jq expands its own --arg/--slurpfile variables.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg base "$head_sha" --arg state "$state_hash" --slurpfile row "${CONFORMANCE_RECEIPTS}"/receipt-CG19.json '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  def text: type == "string" and length > 0;
  .control == "CG19-rejected-floor" and .row == "CG19"
  and .base == $base and .dirty == false
  and .blueprint == $row[0].blueprint and .node == $row[0].node
  and .authority == $state and .actions == ["Rejected", "Rejected"]
  and (.obligations | length == 2)
  and (.obligations | all(.[]; (.owner | text) and (.owed | type == "number" and . > 1000)))
  and (."ordered-requests" | length == 2)
  and ([."ordered-requests"[] | {owner, owed}] == .obligations)
  and (."ordered-requests" | all(.[]; (.outref | text) and (.key | text)))
  and ([."ordered-requests"[].outref] | unique | length == 2)
  and ([.bounds.lowerSlot, .bounds.upperUnderpaid, .bounds.upperFunded] | all(.[]; text))
  and (.pairing | text)
  and .underpaid.outcome == "refused" and .underpaid.phase == "phase-2"
  and (.underpaid.hashes | index($state) != null)
  and (.underpaid.limit | text) and (.underpaid.txid | txid)
  and .underpaid.paid == [(.obligations[0].owed - 1000), .obligations[1].owed]
  and .funded.outcome == "accepted" and (.funded.txid | txid)
  and .funded.txid != .underpaid.txid
  and .funded.paid == [.obligations[].owed]
  and (.funded | .mem > 0 and .cpu > 0 and .size > 0)
' "$c" >/dev/null || {
  echo 'FAIL: CG19-rejected-floor pair evidence moved'
  exit 1
}
# CG05 (#287): the insertion on an occupied key is a compared story.
# An insertAbsent books the key in the row's registry and an
# updateActive makes it active, the state the shared session key has
# when this row runs after CG02; both are accepted by both sides and
# compared on all nine observations, the refusal's connected control.
# The same insertAbsent on that key is then refused by the state
# script and by the model for key-exists, and the traced replay of
# the refused transaction admitted key-exists.
# jq expands its own --arg variables inside this program.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  (.steps | length) == 3
  and ([.steps[] | [.edge, .exit, .tamper]]
    == [["insertAbsent", "insertAbsent", null],
        ["updateActive", "updateActive", null],
        ["insertAbsent", "insertAbsent", null]])
  and ([.steps[].registry] | unique | length) == 1
  and ([.steps[].request.key] | unique | length) == 1
  and (.steps[0:2] | all(.[];
    .model.outcome == "accepted" and .chain.outcome == "accepted"
    and .comparison == "agrees" and (.compared | length) == 9))
  and .steps[2].model == {"outcome": "refused", "reason": "key-exists"}
  and .steps[2].chain.outcome == "refused"
  and (.steps[2].chain.refusal.hashes | index($state) != null)
  and .steps[2].chain.refusal.trace == "key-exists"
  and .steps[2].comparison == "agrees"
  and .transactions == [.steps[0].chain.txid, .steps[1].chain.txid]
' "${CONFORMANCE_RECEIPTS}"/receipt-CG05.json >/dev/null || {
  echo 'FAIL: CG05 occupied-key story evidence moved'
  exit 1
}
# 9. CG21 (#184): the insertActive edge observation, complete or
#    the step fails. The loader already refuses an incomplete
#    CG21 receipt; this asserts the same promises at the CI
#    boundary, against the compiled blueprint's own hashes, so a
#    loader that stopped checking cannot make the row pass here.
#    #228's step registers an extra signer and both sides accept it.
#    The delivery sent to another address and paid one lovelace short
#    is refused by the state script and by the model, whose reason is
#    the one the compiled Aiken suite names for the shape:
#    onchain/validators/registry_rows.tests.ak
#    t6_carrier_at_another_address_refuses (destination) and
#    t6_underfunded_destination_refuses (deposit-returned); the same
#    request untampered is accepted by both. The ledger's own reason
#    comes from the traced replay of each refused transaction (#287).
#    Last, two registrations folded in one transaction whose mint
#    moves both tokens onto the first key are refused by the state
#    script and by the model's fold batch for net-mint-mismatch, the
#    reason the traced replay admits.
open_params="$(nix run --quiet nixpkgs#jq -- -er '[.validators[] | select(.title == "open.open.mint") | (.parameters // []) | length] | first' "$blueprint")"
[ "$open_params" -eq 0 ] || {
  echo "FAIL: open.open.mint declares $open_params parameters; CG21 reports a parameterless open application"
  exit 1
}
e="${CONFORMANCE_RECEIPTS}/receipt-CG21.json"
# jq expands its own --arg variables inside this program.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  def complete: (.compared | length) == 9 and (.unobserved | type) == "array"
    and (.perturbation.refused > 0);
  ([.steps[] | select(.tamper == "other-address") | .request][0]) as $tampered |
  .row == "CG21" and .outcome == "accepted"
  and .verdict == "agrees-with-model" and .venue == "node-submit"
  and (.steps | length) == 8
  and ([.steps[].tamper] == [null,null,null,"other-address","short-by-one",null,"extra-signer","mint-on-first-key"])
  and (.steps[7] | .batch == "foldBatch" and (.requests | length) == 2
    and .model == {"outcome": "refused", "reason": "net-mint-mismatch"}
    and .chain.outcome == "refused" and (.chain.txid | txid)
    and (.chain.refusal.hashes | index($state) != null)
    and .chain.refusal.trace == "net-mint-mismatch"
    and .comparison == "agrees")
  and all(.steps[]; .comparison == "agrees")
  and all(.steps[] | select(.tamper == null and .model.outcome == "accepted"
          and .chain.outcome == "accepted");
          (.chain.txid | txid) and complete)
  and ([.steps[] | select(.tamper == null and .model.outcome == "accepted"
          and .chain.outcome == "accepted")]
       | length) == 3
  and any(.steps[]; .tamper == "extra-signer" and .model.outcome == "accepted"
          and .chain.outcome == "accepted" and (.chain.txid | txid)
          and .differences == [{"observation":"tx","path":"signers"}])
  and any(.steps[]; .edge == "insertActive" and .tamper == null and .model.outcome == "refused"
          and .model.reason == "key-exists"
          and .chain.outcome == "refused" and (.chain.refusal.hashes | index($state) != null))
  and any(.steps[]; .tamper == "other-address" and .model.outcome == "refused"
          and .model.reason == "destination"
          and .chain.outcome == "refused" and (.chain.txid | txid)
          and (.chain.refusal.hashes | index($state) != null))
  and any(.steps[]; .tamper == "short-by-one" and .model.outcome == "refused"
          and .model.reason == "deposit-returned" and .request == $tampered
          and .chain.outcome == "refused" and (.chain.txid | txid)
          and (.chain.refusal.hashes | index($state) != null))
  and any(.steps[]; .tamper == null and .model.outcome == "accepted"
          and .chain.outcome == "accepted" and .request == $tampered)
' "$e" >/dev/null || {
  echo 'FAIL: CG21 step evidence missing or incomplete'
  exit 1
}
# 10. CG09 (#320): the consumer's R9_reject_needs_rejectable forbids
#     a reject inside the processing window; Singular's Lean admits
#     it and the chain accepts it. By operator ruling 2026-10-01 the
#     consumer requirement is kept unmet (alignment:
#     lambdasistemi/cardano-keri#468): the verdict is unmet-by-ruling,
#     never agreement and never held-q002. Its control, the same
#     reject one lovelace short, is refused by the state script first.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e '
  .row == "CG09" and .outcome == "accepted" and .verdict == "unmet-by-ruling"
  and .venue == "node-submit"
  and (.transactions | length) == 1
  and (.transactions[0] | test("^[0-9a-f]{64}$"))
' "${CONFORMANCE_RECEIPTS}"/receipt-CG09.json >/dev/null || {
  echo 'FAIL: CG09 unmet acceptance evidence moved'
  exit 1
}
grep -q '^unmet: CG09 UNMET BY RULING: ' /tmp/generic-rows.log || {
  echo 'FAIL: CG09 unmet requirement not recorded by the run'
  exit 1
}
if grep -q '^held: CG09 ' /tmp/generic-rows.log; then
  echo 'FAIL: CG09 recorded held'
  exit 1
fi
grep -q '^control: CG09 control: REFUSED at submit, attributed to state (phase-2, marker 0x[0-9a-f][0-9a-f]*)' /tmp/generic-rows.log || {
  echo 'FAIL: CG09 refused control not attributed to the state script'
  exit 1
}
# 11. #287: the empty fold and the crossed refunds are compared with
#     the model's batch questions: CG11's receipt carries the fold
#     batch over no request, refused by both for empty-fold, CG19's the
#     reject batch of its two requests judged on the crossed refunds,
#     refused by both for deposit-returned, each with the reason the
#     traced replay admits for the state script.
for row in CG11 CG19; do
  case "$row" in
    CG11) batch=foldBatch requests=0 reason=empty-fold ;;
    CG19) batch=rejectBatch requests=2 reason=deposit-returned ;;
  esac
  # shellcheck disable=SC2016
  nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" --arg batch "$batch" \
    --argjson requests "$requests" --arg reason "$reason" '
    .rejected as $rejected
    | (.steps | length) == 1
    and (.steps[0] | .batch == $batch and (.requests | length) == $requests
      and .model == {"outcome": "refused", "reason": $reason}
      and .chain.outcome == "refused" and .chain.txid == $rejected
      and (.chain.refusal.hashes | index($state) != null)
      and .chain.refusal.trace == $reason
      and .comparison == "agrees")
  ' "${CONFORMANCE_RECEIPTS}/receipt-$row.json" >/dev/null || {
    echo "FAIL: $row batch comparison with the model moved"
    exit 1
  }
done
# 12. #287: the controls of CG09 and CG19 that refuse a reject paying its
#     owner short are compared with the model's reject batch too; their
#     comparisons are in the session's replay index, not in a row receipt.
#     CG09's control: one entry, deposit-returned, agreeing. CG19: its
#     crossed refunds and its rejected-floor control, two entries.
#     The agreement holds for the fixtures' shape only: every output at an
#     owner's key is its refund. The chain judges refunds by position, the
#     model by the owner's summed outputs; that conflict is recorded in
#     specs/287-traced-refusal-reasons/extent.md and escalated.
for pair in CG09:1 CG19:2; do
  row="${pair%%:*}"
  want="${pair##*:}"
  # shellcheck disable=SC2016
  got="$(nix run --quiet nixpkgs#jq -- -r --arg row "$row" '
    [.[] | select(.kind == "refusal" and .row == $row
      and .extentClass == "A" and .modelReason == "deposit-returned"
      and .comparison == "agrees")] | length
  ' "${CONFORMANCE_RECEIPTS}/replay/index.json")"
  [ "$got" = "$want" ] || {
    echo "FAIL: $row reject comparisons in the replay index: $got, expected $want"
    exit 1
  }
done
# 13. #287: every refusal of the session carries the traced replay
#     of its transaction (test/ci/replay-evidence.sh): the story
#     rows' and the batches' refused steps meet the model's reason,
#     and each attribution row names, per failing purpose, the reason
#     the replay admitted or the cause it admits none.
for row in CG05 CG11 CG19 CG21; do
  bash test/ci/replay-evidence.sh steps "${CONFORMANCE_RECEIPTS}/receipt-$row.json" || {
    echo "FAIL: $row refused steps lack the traced replay of their reason"
    exit 1
  }
done
for row in CG10 CG11 CG12 CG19; do
  bash test/ci/replay-evidence.sh attribution "${CONFORMANCE_RECEIPTS}/receipt-$row.json" || {
    echo "FAIL: $row refusal lacks the traced replay"
    exit 1
  }
done
echo 'GREEN = expected-debt assertion held: 10 rows executed on a clean candidate-bound tree; the registration steps, duplicate refusal and the tampered-payment controls are recorded, with held debt exactly CG11 CG12 CG19 and CG09 unmet by ruling. The empty fold, the crossed refunds, the two short reject controls and the registration batch are each refused by the chain and by the model for the reason the traced replay admits.'
echo 'A GREEN STEP IS NOT A FULFILLED CONSUMER PROMISE: R5_plugin_pinned, R8_empty_fold_refused, R9_reject_needs_rejectable and R11_contribute_value stay unmet (upstream #100/#101); strict completion and release stay RED on that debt.'

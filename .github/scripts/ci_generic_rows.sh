#!/usr/bin/env bash
# The registry rows as a packaged app without a dev shell, run from
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
rows="insert-key permanent-retire-active-key insert-occupied-key retract-inside-window reject-after-window reject-before-deadline-consumer-requirement fold-against-superseded-root empty-fold surplus-fold-actions request-value-and-refund-routing register-active-key"
set +e
# The row list is word-split on purpose: one argument per row.
# shellcheck disable=SC2086
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run $rows --receipts-dir "$CONFORMANCE_RECEIPTS" 2>&1 | tee /tmp/generic-rows.log
run_rc=${PIPESTATUS[0]}
set -e
echo "registry session exit: $run_rc (expected: exactly 1, the handled session-debt exit)"
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
# 2. complete session evidence: all 11 rows executed...
grep -q 'complete: 11/11 rows ok' /tmp/generic-rows.log || {
  echo 'FAIL: the session did not complete all 11 rows (mid-run failure or crash)'
  exit 1
}
#    ...and the terminal failure is the held-rows debt report
grep -q 'ROWS THE RUN CANNOT REPORT AS PASSING' /tmp/generic-rows.log || {
  echo 'FAIL: the terminal failure is not the held-rows debt report'
  exit 1
}
# 3. exactly the eleven rows plus the session execution-units-and-transaction-size, no extras
# shellcheck disable=SC2086
printf '%s\n' $rows execution-units-and-transaction-size | sort >/tmp/expected-rows.txt
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
    insert-key | permanent-retire-active-key | insert-occupied-key | retract-inside-window | reject-after-window | register-active-key | execution-units-and-transaction-size) printf 'agrees-with-model' ;;
    reject-before-deadline-consumer-requirement | fold-against-superseded-root | surplus-fold-actions) printf 'unmet-by-ruling' ;;
    empty-fold | request-value-and-refund-routing) printf 'held-q002' ;;
    *) printf 'UNKNOWN-ROW' ;;
  esac
}
# shellcheck disable=SC2086
for row in $rows execution-units-and-transaction-size; do
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
# 5. execution-units-and-transaction-size carries the session's measurement evidence: the worst units and
#    size of the accepting folds of insert-key, register-active-key and permanent-retire-active-key, read off their
#    receipts' steps, those folds named — refuse missing or divergent
# jq expands its own --slurpfile variables.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e \
  --slurpfile cg02 "${CONFORMANCE_RECEIPTS}"/receipt-insert-key.json \
  --slurpfile cg03 "${CONFORMANCE_RECEIPTS}"/receipt-register-active-key.json \
  --slurpfile cg04 "${CONFORMANCE_RECEIPTS}"/receipt-permanent-retire-active-key.json '
  ([$cg02[0], $cg03[0], $cg04[0]] | map(.steps[] | select(.chain.outcome == "accepted") | .chain)) as $folds
  | ($folds | length) == 11
  and .transactions == ($folds | map(.txid))
  and .mem == ($folds | map(.measured.mem) | max) and .mem > 0
  and .cpu == ($folds | map(.measured.cpu) | max) and .cpu > 0
  and .txSize == ($folds | map(.measured.size) | max) and .txSize > 0
' "${CONFORMANCE_RECEIPTS}"/receipt-execution-units-and-transaction-size.json >/dev/null || {
  echo 'FAIL: execution-units-and-transaction-size measurement evidence missing or divergent'
  exit 1
}
# 6. the run's own accounting must name exactly the expected
#    held and unmet sets, with nothing failing against this candidate
held="$(sed -n 's/^- Held .*held-q002): //p' /tmp/generic-rows.log)"
[ "$held" = "empty-fold request-value-and-refund-routing" ] || {
  echo "FAIL: held set moved: got '$held', expected 'empty-fold request-value-and-refund-routing'"
  exit 1
}
unmet="$(sed -n 's/^- Unmet by ruling .*unmet-by-ruling): //p' /tmp/generic-rows.log)"
# fold-against-superseded-root and surplus-fold-actions have no model counterpart: unmet by operator ruling
# 2026-10-02, each naming its follow-up (#346, #345).
[ "$unmet" = "reject-before-deadline-consumer-requirement fold-against-superseded-root surplus-fold-actions" ] || {
  echo "FAIL: unmet set moved: got '$unmet', expected 'reject-before-deadline-consumer-requirement fold-against-superseded-root surplus-fold-actions'"
  exit 1
}
grep -q '^unmet: fold-against-superseded-root UNMET BY RULING: .*lambdasistemi/singular#346' /tmp/generic-rows.log || {
  echo 'FAIL: fold-against-superseded-root unmet without its follow-up'
  exit 1
}
grep -q '^unmet: surplus-fold-actions UNMET BY RULING: .*lambdasistemi/singular#345' /tmp/generic-rows.log || {
  echo 'FAIL: surplus-fold-actions unmet without its follow-up'
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
# bind and the cage alone decides. The rows the model cannot express,
# fold-against-superseded-root and surplus-fold-actions, keep their attributed refusal receipts.
for row in fold-against-superseded-root surplus-fold-actions; do
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
grep -q '^control: fold-against-superseded-root control: the same request folded against the live root is accepted' /tmp/generic-rows.log || {
  echo 'FAIL: fold-against-superseded-root accepting control missing'
  exit 1
}
grep -q '^control: surplus-fold-actions control: exact 1:1 fold accepted (tx=[0-9a-f]\{64\})' /tmp/generic-rows.log || {
  echo 'FAIL: surplus-fold-actions accepting control txid missing'
  exit 1
}
# 8. The supported edge compositions (#232): each row's program, in registries of its
#    own, every request accepted by the chain and by the model and compared
#    on all nine observations, its transactions the envelope's.
#    insert-key registers Active; retract-inside-window retracts an
#    insertion inside phase 2; reject-after-window rejects one after the windows.
for spec in \
  'insert-key:[["insertActive","insertActive"]]' \
  'retract-inside-window:[["insertActive","retract"]]' \
  'reject-after-window:[["insertActive","reject"]]'; do
  row="${spec%%:*}"
  shape="${spec#*:}"
  # shellcheck disable=SC2016
  nix run --quiet nixpkgs#jq -- -e --argjson shape "$shape" '
    def txid: type == "string" and test("^[0-9a-f]{64}$");
    ([.steps[] | [.edge, .exit]] == $shape)
    and all(.steps[]; .tamper == null)
    and ([.steps[].registry] | unique | length) == 1
    and ([.steps[].request.key] | unique | length) == 1
    and all(.steps[];
      .model.outcome == "accepted" and .chain.outcome == "accepted"
      and (.chain.txid | txid) and .comparison == "agrees"
      and (.compared | length) == 9 and (.perturbation.refused > 0))
    and .transactions == [.steps[].chain.txid]
  ' "${CONFORMANCE_RECEIPTS}/receipt-$row.json" >/dev/null || {
    echo "FAIL: $row program evidence moved"
    exit 1
  }
done
# The occupied-key refusal follows an actual registration. The excluded
# update encoding is refused separately and receives no broader update credit.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  (.steps | length) == 3
  and ([.steps[] | [.edge, .exit, .tamper]]
    == [["insertActive", "insertActive", null],
        ["insertActive", "insertActive", null],
        ["updateActive", "updateActive", null]])
  and ([.steps[].registry] | unique | length) == 1
  and ([.steps[].request.key] | unique | length) == 1
  and (.steps[0] | .model.outcome == "accepted" and .chain.outcome == "accepted"
    and .comparison == "agrees" and (.compared | length) == 9 and .perturbation.refused > 0)
  and .steps[1].model == {"outcome": "refused", "reason": "key-exists"}
  and .steps[2].model == {"outcome": "refused", "reason": "edge-inadmissible"}
  and all(.steps[1:3][]; .chain.outcome == "refused"
    and (.chain.refusal.hashes | index($state) != null)
    and .chain.refusal.trace == .model.reason and .comparison == "agrees")
  and .transactions == [.steps[0].chain.txid]
' "${CONFORMANCE_RECEIPTS}/receipt-insert-occupied-key.json" >/dev/null || {
  echo 'FAIL: insert-occupied-key current story evidence moved'
  exit 1
}
bash test/ci/permanent-retirement-evidence.sh "${CONFORMANCE_RECEIPTS}/receipt-permanent-retire-active-key.json" "$head_sha" "$state_hash"
# The real receipt overlay must leave every retained broader requirement
# visible and uncovered, even beside current retirement execution evidence.
nix run --quiet .#conformance -- list --receipts "$CONFORMANCE_RECEIPTS" >"$CONFORMANCE_RECEIPTS/consumer-scope-inventory.tsv"
found=0
while IFS=$'\t' read -r scope_identity _scope_group _scope_expected scope_state scope_requirement; do
  case "$scope_identity" in
    update-existing-key | delete-existing-key | reinsert-deleted-key | retire-active-key)
      [ "$scope_state" = uncovered ] && [ -n "$scope_requirement" ] || {
        echo "FAIL: broader requirement $scope_identity was credited or missing its text"
        exit 1
      }
      found=$((found + 1))
      ;;
  esac
done <"$CONFORMANCE_RECEIPTS/consumer-scope-inventory.tsv"
[ "$found" -eq 4 ] || {
  echo 'FAIL: the broader requirements are missing from the computed inventory'
  exit 1
}
# 9. register-active-key (#184): the insertActive edge observation, complete or
#    the step fails. The loader already refuses an incomplete
#    register-active-key receipt; this asserts the same promises at the CI
#    boundary, against the compiled blueprint's own hashes, so a
#    loader that stopped checking cannot make the row pass here.
#    #228's step registers an extra signer and both sides accept it.
#    The delivery sent to another address and paid one lovelace short
#    is refused by the state script and by the model, whose reason is
#    the one the compiled Aiken suite names for the shape:
#    onchain/validators/registry_rows.tests.ak
#    carrier_at_another_address_refuses (destination) and
#    underfunded_destination_refuses (deposit-returned); the same
#    request untampered is accepted by both. The ledger's own reason
#    comes from the traced replay of each refused transaction (#287).
#    Last, two registrations folded in one transaction whose mint
#    moves both tokens onto the first key are refused by the state
#    script and by the model's fold batch for net-mint-mismatch, the
#    reason the traced replay admits.
open_params="$(nix run --quiet nixpkgs#jq -- -er '[.validators[] | select(.title == "open.open.mint") | (.parameters // []) | length] | first' "$blueprint")"
[ "$open_params" -eq 0 ] || {
  echo "FAIL: open.open.mint declares $open_params parameters; register-active-key reports a parameterless open application"
  exit 1
}
e="${CONFORMANCE_RECEIPTS}/receipt-register-active-key.json"
# Each booking writes its own booking time, so the same request re-submitted in another step is compared without that time.
# jq expands its own --arg variables inside this program.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  def complete: (.compared | length) == 9 and (.unobserved | type) == "array"
    and (.perturbation.refused > 0);
  ([.steps[] | select(.tamper == "other-address") | .request | del(.submittedAt)][0]) as $tampered |
  .row == "register-active-key" and .outcome == "accepted"
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
          and .model.reason == "deposit-returned" and .request.key == $tampered.key
          and .chain.outcome == "refused" and (.chain.txid | txid)
          and (.chain.refusal.hashes | index($state) != null))
  and any(.steps[]; .tamper == null and .model.outcome == "accepted"
          and .chain.outcome == "accepted" and .request.key == $tampered.key)
' "$e" >/dev/null || {
  echo 'FAIL: register-active-key step evidence missing or incomplete'
  exit 1
}
# 10. reject-before-deadline-consumer-requirement (#320): the consumer's R9_reject_needs_rejectable forbids
#     a reject inside the processing window; Singular's Lean refuses it with bound expiry
#     evidence while the chain still accepts the untampered reject. By operator ruling 2026-10-01 the
#     consumer requirement is kept unmet (alignment:
#     lambdasistemi/cardano-keri#468): the verdict is unmet-by-ruling,
#     never agreement and never held-q002. Its program rejects one foldable
#     `insertActive` request for a key not yet registered, owned by a wallet that receives
#     no change, three times while it can still be folded, each asked of the model's reject
#     batch with expiry evidence: first refunding the owner one lovelace short, refused by
#     both for different reasons (model `reject-not-expired`, chain `deposit-returned` with
#     that reason in replay); then the split shape (one lovelace short at the refund's
#     position and two ada more in another output at the owner's key), refused by both
#     for different reasons (model `reject-not-expired`, chain `deposit-returned` in replay),
#     never as the old `361` outcome divergence (the model no longer accepts in-window while
#     protected holds); last the reject itself, refused by the model for `reject-not-expired`
#     and accepted by the chain — three recorded divergences for `lambdasistemi/singular#495`
#     (the validators ticket that must flip the row), never a pass. The row stops matching
#     the day the chain refuses the untampered reject.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  .row == "reject-before-deadline-consumer-requirement" and .outcome == "accepted" and .verdict == "unmet-by-ruling"
  and .venue == "node-submit"
  and (.steps | length) == 3
  and all(.steps[]; .batch == "rejectBatch" and (.requests | length) == 1)
  and ([.steps[].requests[0].request] | unique | length) == 1
  and .steps[0].requests[0].request.deposit == 3000000
  and .steps[0].requests[0].request.edge == "insertActive"
  and ([.steps[] | [.tamper, .shortfall]]
    == [["short-first-refund", 1], ["split-first-refund", 1], [null, null]])
  and (.steps[0] | .model == {"outcome": "refused", "reason": "reject-not-expired"}
    and .chain.outcome == "refused" and (.chain.refusal.hashes | index($state) != null)
    and .chain.refusal.trace == null
    and any(.chain.refusal.replay[]; .reason == "deposit-returned")
    and .comparison == "disagrees"
    and ([.outputs[] | select(.role == "owner") | .lovelace] == [2999999]))
  and (.steps[1] | .model == {"outcome": "refused", "reason": "reject-not-expired"}
    and .chain.outcome == "refused"
    and any(.chain.refusal.replay[]; .reason == "deposit-returned")
    and .chain.refusal.trace == null
    and .comparison == "disagrees")
  and (.steps[2] | .model == {"outcome": "refused", "reason": "reject-not-expired"}
    and .chain.outcome == "accepted"
    and (.chain.txid | txid) and .comparison == "disagrees")
  and .transactions == [.steps[2].chain.txid]
' "${CONFORMANCE_RECEIPTS}"/receipt-reject-before-deadline-consumer-requirement.json >/dev/null || {
  echo 'FAIL: reject-before-deadline-consumer-requirement unmet acceptance, control or divergence evidence moved'
  exit 1
}
grep -q '^unmet: reject-before-deadline-consumer-requirement UNMET BY RULING: ' /tmp/generic-rows.log || {
  echo 'FAIL: reject-before-deadline-consumer-requirement unmet requirement not recorded by the run'
  exit 1
}
if grep -q '^held: reject-before-deadline-consumer-requirement ' /tmp/generic-rows.log; then
  echo 'FAIL: reject-before-deadline-consumer-requirement recorded held'
  exit 1
fi
grep -q '^divergence: reject-before-deadline-consumer-requirement KNOWN DIVERGENCE (lambdasistemi/singular#495): the chain refused it for deposit-returned ' /tmp/generic-rows.log || {
  echo 'FAIL: reject-before-deadline-consumer-requirement tampered divergences not recorded by the run'
  exit 1
}
grep -q '^divergence: reject-before-deadline-consumer-requirement KNOWN DIVERGENCE (lambdasistemi/singular#495): the chain accepted it ' /tmp/generic-rows.log || {
  echo 'FAIL: reject-before-deadline-consumer-requirement untampered divergence not recorded by the run'
  exit 1
}
if grep -q '^divergence: reject-before-deadline-consumer-requirement KNOWN DIVERGENCE (lambdasistemi/singular#361)' /tmp/generic-rows.log; then
  echo 'FAIL: reject-before-deadline-consumer-requirement still records the old 361 divergence'
  exit 1
fi
# 11. empty-fold (#287): the empty fold is compared with the model's fold batch
#     over no request, refused by both for empty-fold with the reason the
#     traced replay admits for the state script, beside its accepting
#     control, an Active registration folded on the same registry.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  (.steps | length) == 2
  and (.steps[0] | .batch == "foldBatch" and (.requests | length) == 0
    and .model == {"outcome": "refused", "reason": "empty-fold"}
    and .chain.outcome == "refused" and (.chain.txid | txid)
    and (.chain.refusal.hashes | index($state) != null)
    and .chain.refusal.trace == "empty-fold"
    and .comparison == "agrees")
  and (.steps[1] | .edge == "insertActive" and .tamper == null
    and .model.outcome == "accepted" and .chain.outcome == "accepted"
    and .comparison == "agrees" and (.compared | length) == 9)
  and ([.steps[].registry] | unique | length) == 1
  and .transactions == [.steps[1].chain.txid]
' "${CONFORMANCE_RECEIPTS}"/receipt-empty-fold.json >/dev/null || {
  echo 'FAIL: empty-fold empty fold or its accepting control moved'
  exit 1
}
# 12. request-value-and-refund-routing: refund routing under the registry-mode cage (A-015). Two
#     requests owned by two wallets that receive no change, holding unequal
#     deposits (4 and 2 ada beside the tip), are rejected together after the
#     windows, each asked of the model's reject batch judged on the refunds
#     the transaction pays: each owner refunded what the other is owed,
#     refused by the state script and by the model for deposit-returned;
#     the same two requests refunded as owed, accepted by both. Then the
#     rejected-action refund floor: two more requests of the same owners,
#     the first refunded a thousand lovelace short, refused by both for
#     deposit-returned, then the same two refunded as owed, accepted by
#     both. A crossed allocation is a routing the cage refuses.
# shellcheck disable=SC2016
nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  def owed: [.requests[].request.deposit];
  def paid: . as $s | [.requests[].request.owner as $o
    | [$s.outputs[] | select(.role == "owner" and .address == $o) | .lovelace] | add];
  (.steps | length) == 4
  and all(.steps[]; .batch == "rejectBatch" and (.requests | length) == 2)
  and ([.steps[] | [.tamper, .shortfall]]
    == [["crossed-refunds", null], [null, null], ["short-first-refund", 1000], [null, null]])
  and all(.steps[]; ([.requests[].request.owner] | unique | length) == 2
    and (owed | sort) == [2000000, 4000000])
  and (.steps[0].requests == .steps[1].requests)
  and (.steps[2].requests == .steps[3].requests)
  and ([.steps[0].requests[].request.key] != [.steps[2].requests[].request.key])
  and (.steps[0] | paid == (owed | reverse))
  and (.steps[2] | paid == [(owed[0] - 1000), owed[1]])
  and all(.steps[1], .steps[3]; paid == owed)
  and all(.steps[0], .steps[2];
    .model == {"outcome": "refused", "reason": "deposit-returned"}
    and .chain.outcome == "refused" and (.chain.txid | txid)
    and (.chain.refusal.hashes | index($state) != null)
    and .chain.refusal.trace == "deposit-returned"
    and .comparison == "agrees")
  and all(.steps[1], .steps[3];
    .model.outcome == "accepted" and .chain.outcome == "accepted"
    and (.chain.txid | txid) and .comparison == "agrees"
    and .chain.measured.mem > 0 and .chain.measured.size > 0)
  and .transactions == [.steps[1].chain.txid, .steps[3].chain.txid]
' "${CONFORMANCE_RECEIPTS}"/receipt-request-value-and-refund-routing.json >/dev/null || {
  echo 'FAIL: request-value-and-refund-routing refund routing or refund-floor evidence moved'
  exit 1
}
# 13. #287: the lawful refund controls that refuse a reject paying its
#     owner short are compared with the model's reject batch; their
#     comparisons are in the session's replay index too. request-value-and-refund-routing:
#     its crossed refunds and its rejected-floor control, two entries, deposit-returned,
#     agreeing. The agreement holds for the fixtures' shape only: every output at an
#     owner's key is its refund. reject-before-deadline-consumer-requirement no longer has an
#     agreeing control in-window while protected holds (its two tampers are refused by both
#     for different reasons); its two tampered refusals are in the index as divergences
#     (model `reject-not-expired`, comparison `differs`, chain `deposit-returned` admitted),
#     and its untampered accept has no refusal entry. The old `361` outcome divergence
#     (model accepted) has no live in-window example while protected holds.
# shellcheck disable=SC2016
got="$(nix run --quiet nixpkgs#jq -- -r --arg row "request-value-and-refund-routing" '
    [.[] | select(.kind == "refusal" and .row == $row
      and .extentClass == "A" and .modelReason == "deposit-returned"
      and .comparison == "agrees")] | length
  ' "${CONFORMANCE_RECEIPTS}/replay/index.json")"
[ "$got" = "2" ] || {
  echo "FAIL: request-value-and-refund-routing reject comparisons in the replay index: $got, expected 2"
  exit 1
}
# shellcheck disable=SC2016
got="$(nix run --quiet nixpkgs#jq -- -r '
    [.[] | select(.kind == "refusal" and .row == "reject-before-deadline-consumer-requirement"
      and .extentClass == "A" and .modelReason == "deposit-returned"
      and .comparison == "agrees")] | length
  ' "${CONFORMANCE_RECEIPTS}/replay/index.json")"
[ "$got" = "0" ] || {
  echo "FAIL: reject-before-deadline-consumer-requirement agreeing controls in the replay index: $got, expected 0 (all three diverge while protected holds)"
  exit 1
}
# shellcheck disable=SC2016
got="$(nix run --quiet nixpkgs#jq -- -r '
    [.[] | select(.kind == "refusal" and .row == "reject-before-deadline-consumer-requirement" and .modelReason == null
      and any(.classes[]; .admitted == "deposit-returned"))] | length
  ' "${CONFORMANCE_RECEIPTS}/replay/index.json")"
[ "$got" = "0" ] || {
  echo "FAIL: reject-before-deadline-consumer-requirement old 361 divergence refusals in the replay index: $got, expected 0"
  exit 1
}
# shellcheck disable=SC2016
got="$(nix run --quiet nixpkgs#jq -- -r '
    [.[] | select(.kind == "refusal" and .row == "reject-before-deadline-consumer-requirement"
      and .extentClass == "A" and .modelReason == "reject-not-expired"
      and .comparison == "differs"
      and any(.classes[]; .admitted == "deposit-returned"))] | length
  ' "${CONFORMANCE_RECEIPTS}/replay/index.json")"
[ "$got" = "2" ] || {
  echo "FAIL: reject-before-deadline-consumer-requirement protected divergence refusals in the replay index: $got, expected 2"
  exit 1
}
# 14. #287: every lawful refusal of the session carries the traced replay
#     of its transaction (test/ci/replay-evidence.sh): the programs'
#     refused steps and batches meet the model's reason, and each
#     attribution row names, per failing purpose, the reason the replay
#     admitted or the cause it admits none. reject-before-deadline-consumer-requirement's
#     three batches are recorded divergences (model `reject-not-expired`, chain `deposit-returned`
#     in replay for the tampers, chain accepted for the untampered), never agreement, so its
#     refusals do not meet the agreement-only replay-evidence check; its replay is asserted
#     in sections 10 and 13 instead.
for row in insert-occupied-key permanent-retire-active-key empty-fold request-value-and-refund-routing register-active-key; do
  bash test/ci/replay-evidence.sh steps "${CONFORMANCE_RECEIPTS}/receipt-$row.json" || {
    echo "FAIL: $row refused steps lack the traced replay of their reason"
    exit 1
  }
done
for row in fold-against-superseded-root surplus-fold-actions; do
  bash test/ci/replay-evidence.sh attribution "${CONFORMANCE_RECEIPTS}/receipt-$row.json" || {
    echo "FAIL: $row refusal lacks the traced replay"
    exit 1
  }
done
echo 'GREEN = expected-debt assertion held: 11 rows executed on a clean candidate-bound tree, each with a program compared step by step with the model except fold-against-superseded-root and surplus-fold-actions, which the model cannot express; held debt exactly empty-fold request-value-and-refund-routing and reject-before-deadline-consumer-requirement fold-against-superseded-root surplus-fold-actions unmet by ruling; reject-before-deadline-consumer-requirement records three protected divergences for ticket 495 (two refused/refused with deposit-returned in replay, one accepted/refused with reject-not-expired). The empty fold, the crossed refunds, the short reject refunds and the registration batch are each refused by the chain and by the model for the reason the traced replay admits, except the unmet row whose divergences turn on admission.'
echo 'A GREEN STEP IS NOT A FULFILLED CONSUMER PROMISE: R5_plugin_pinned, R8_empty_fold_refused, R9_reject_needs_rejectable and R11_contribute_value stay unmet (upstream #100/#101); strict completion and release stay RED on that debt.'

# Gate: the commands that accept the repair

Every row is the command of the CI job that checks it. Rows body-generic-rows-reject-before-deadline-consumer and body-reject-inside-processing-retraction-windows-early are CI changes in this ticket: their full step bodies are fixed here, and the candidate's `.github/workflows/conformance.yml` must carry them byte for byte. body-reject-retract-refund-controls-unchanged's body is fixed here as it stands at the base, and the candidate must leave it byte-identical.

## How to run a row locally

Run from a clean checkout of the candidate. A row whose body reads `RUNNER_TEMP` or `GITHUB_ENV` gets fresh ones:

```sh
export RUNNER_TEMP="$(mktemp -d)" GITHUB_ENV="$(mktemp)"
```

A step body is run with `bash -e` from the repository root, after `cd` into the step's `working-directory` when it names one. The extraction below reads a step from the workflow, so a reviewer can compare it with this page:

```sh
step_body() { awk -v n="$2" 'index($0, "- name: " n)==7 {f=1; print; next} f && /^      - name:/ {exit} f && /^      #/ {exit} f' "$1"; }
```

## Rows

N counts every `nix` invocation, nested ones included: a `nix run nixpkgs#jq` inside a loop counts once per iteration. D counts every command invocation that boots one or more devnets. The run record counts actual invocations; this table is the forecast.

| Row | Checks | Command (directory) | Workflow | Exit | N | D |
|---|---|---|---|---|---|---|
| once | path fence | `git diff --name-only <base>..HEAD` plus `git status --porcelain`, every path inside the plan's fence (root) | owner check | 0 | 0 | 0 |
| aiken-suite-properties-format-registry-identity | Aiken suite, properties, format, registry identity | `nix flake check` (`onchain`) | registry.yml "aiken-suite" job | 0 | 1 | 0 |
| naming-suite-identity | naming suite and identity | `nix flake check` (`naming-onchain`) | registry.yml "naming-validators" job | 0 | 1 | 0 |
| blueprint-nix-build-quiet-no-link-print | naming value refusals | `blueprint="$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)"; NAMING_BLUEPRINT="$blueprint" nix run --quiet .#record-value-tests` (`offchain`) | registry.yml "naming-validators" job | 0 | 2 | 0 |
| nix-build-quiet-build-gate-root | build gate | `nix build --quiet .#build-gate` (root) | ci.yml "build-gate" job | 0 | 1 | 0 |
| deployed-identity-both-ways-naming-scripts-embedded | deployed identity both ways, and the naming scripts' embedded registry hashes | `nix shell --quiet nixpkgs#jq nixpkgs#diffutils -c bash offchain/deployment-identity-check.sh` (root): outer shell 1, three blueprint/app builds, one devnet, four deployment runs. The naming comparison this ticket adds reads the two blueprints it already builds and adds no invocation. | ci.yml "build-gate" job | 0 | 9 | 1 |
| off-chain-lint-build-unit-vectors | off-chain lint, build, unit, vectors | `(cd offchain && nix run --quiet .#lint)`; `nix build --quiet .#component-build`; `nix run --quiet .#cage-tests`; `nix develop --quiet --command just vectors-check` (the last three in `offchain`; vectors-check nests one build and one Aiken shell) | ci.yml, registry.yml | 0 each | 6 | 0 |
| product-builder-on-devnet | product builder on a devnet | `blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"; REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#cage-tests-e2e` (`offchain`) | registry.yml "e2e" job | 0 | 2 | 1 |
| conformance-unit-suite-running-book | conformance unit suite and the running book | `nix run --quiet .#conformance-tests` (`conformance`); it builds the blueprint itself | conformance.yml | 0 | 2 | 1 |
| body-reject-retract-refund-controls-unchanged | reject-and-retract-refund-controls exit row, unchanged | body below | conformance.yml | 0 | 4 | 1 |
| body-generic-rows-reject-before-deadline-consumer | generic rows, reject-before-deadline-consumer-requirement unmet by ruling | body below (CI change in this ticket) | conformance.yml | 0 | 45 | 1 |
| body-reject-inside-processing-retraction-windows-early | reject-inside-processing-and-retraction-windows early rejection row | body below (CI change in this ticket) | conformance.yml | 0 | 4 | 1 |
| nix-run-quiet-release-artifacts-runner-temp | release assembly | `nix run --quiet .#release-artifacts -- "$RUNNER_TEMP/release"` (root); it builds both blueprints | ci.yml "release-artifacts" job | 0 | 3 | 0 |
| nix-develop-quiet-c-just-ci-standard | root CI | `nix develop --quiet -c just ci`, standard input redirected from `/dev/null` (root) | ci.yml "dev-shell" job | 0 | 3 | 0 |

One complete run at the exact head forecasts N83 and D6.

## Falsification

| Row | How it is known to fail |
|---|---|
| aiken-suite-properties-format-registry-identity | red at the base with the validators-identities-reject-before-deadline-consumer-requirement tests that expect a reject in the processing or retraction window to be accepted (`not-rejectable` on the state purpose, the request expectation on the request purpose). Rejects after the windows and future-dated ones already pass at the base; their tests are preservation, not RED. |
| aiken-suite-properties-format-registry-identity, naming-suite-identity, deployed-identity-both-ways-naming-scripts-embedded | red on any manifest not regenerated, and on the witness pin, by the existing checks. Red on a stale naming pin only through the comparison this ticket adds to deployed-identity-both-ways-naming-scripts-embedded, which is seen failing on the stale pin before the naming pins move. |
| product-builder-on-devnet | the new window cases fail at the base builder, which refuses to build ("no rejectable requests") |
| body-generic-rows-reject-before-deadline-consumer | at the base it already exits non-zero for any reject-before-deadline-consumer-requirement verdict but its expected one. After validators-identities-reject-before-deadline-consumer-requirement alone, without the reject-before-deadline-consumer-requirement change, it fails on reject-before-deadline-consumer-requirement's verdict. |
| body-reject-inside-processing-retraction-windows-early | the retained refused processing-window rejection `2d39d638…` (ticket 287) is the live defect at the base. On the base validators every untampered step of reject-inside-processing-and-retraction-windows would disagree with the model. |
| body-reject-retract-refund-controls-unchanged | its assertion is unchanged; a reject-and-retract-refund-controls receipt whose shape moved fails it |
| once | lists any path outside the fence |

No bespoke instrument is added.

## body-reject-retract-refund-controls-unchanged body: reject-and-retract-refund-controls, unchanged

```yaml
      - name: Run the dedicated reject-and-retract-refund-controls exit row as a packaged app
        run: |
          set -e
          cd conformance
          blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
          receipts="$(mktemp -d "$RUNNER_TEMP/cg23-receipts.XXXXXX")"
          REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run reject-and-retract-refund-controls --receipts-dir "$receipts"
          head_sha="$(git rev-parse HEAD)"
          f="$__lookup_path_0__"
          test -f "$f" || { echo 'FAIL: missing reject-and-retract-refund-controls receipt'; exit 1; }
          test "$(wc -c < "$f")" -le 14745 || { echo "FAIL: reject-and-retract-refund-controls receipt exceeds its margin"; exit 1; }
          state_hash="$(nix run --quiet nixpkgs#jq -- -er '.validators[] | select(.title == "state.state.spend" and ((.parameters // []) | length) == 0) | .hash' "$blueprint")"
          # jq expands its own --arg variables inside this program.
          # shellcheck disable=SC2016
          nix run --quiet nixpkgs#jq -- -e --arg base "$head_sha" --arg state "$state_hash" '
            def txid: type == "string" and test("^[0-9a-f]{64}$");
            def text: type == "string" and length > 0;
            def complete: .comparison == "agrees" and .tamper == null
              and (.compared | length) == 9 and .perturbation.refused > 0;
            .row == "reject-and-retract-refund-controls"
            and .verdict == "agrees-with-model"
            and .base == $base and .dirty == false
            and (.blueprint | text) and (.node | text)
            and (.steps | length) == 10
            and ([.steps[].edge] == ["insertActive","insertActive","insertActive","insertActive","insertActive","insertActive","insertActive","updateTerminal","insertActive","insertActive"])
            and ([.steps[].exit] == ["reject","reject","reject","retract","retract","retract","retract","retract","retract","retract"])
            and ([.steps[].tamper] == ["short-by-one","other-address",null,"short-by-one","other-address","other-reference","state-spent",null,"unsigned",null])
            and ([.steps[].model.outcome] == ["refused","refused","accepted","refused","refused","refused","refused","refused","refused","accepted"])
            and ([.steps[].chain.outcome] == ["refused","refused","accepted","refused","refused","refused","refused","refused","refused","accepted"])
            and all(.steps[]; .comparison == "agrees")
            and all(.steps[] | select(.model.outcome == "accepted"); complete and (.chain.txid | txid))
            and all(.steps[] | select(.model.outcome == "refused");
              (.chain.txid | txid) and (.chain.refusal.hashes | length) > 0)
            and all(.steps[0,1]; .model.reason == "deposit-returned"
              and (.chain.refusal.hashes | index($state) != null)
              and (.chain.refusal.scripts | index("state") != null))
            and all(.steps[3,4,5]; .model.reason == "deposit-returned"
              and (.chain.refusal.scripts | index("request") != null))
            and .steps[6].model.reason == "retract-state-spent"
            and (.steps[6].chain.refusal.scripts | index("request") != null)
            and ([.steps[0,1,2].registry] | unique | length) == 1
            and ([.steps[3,4,5,6,7,8,9].registry] | unique | length) == 1
            and .steps[0].registry != .steps[3].registry
            and all(.steps[] | select(.exit == "retract");
              (.request.reference | type) == "number")
            and ([.steps[3,4,5,6,7,8,9].request.reference] | unique | length) == 6
            and .steps[7].model.reason == "withdraw-insert-only"
            and .steps[8].model.reason == "retract-owner"
            and all(.steps[7,8]; .requestScript as $request |
              .chain.outcome == "refused"
              and ($request | type == "string" and test("^[0-9a-f]{56}$"))
              and (.chain.refusal.hashes | index($request) != null)
              and (.chain.refusal.scripts | index("request") != null))
            and .steps[8].request == .steps[9].request
            and (.steps[8].witness | del(.signatories)) == (.steps[9].witness | del(.signatories))
            and .steps[8].witness.signatories == []
            and (.steps[9] | .request.owner as $owner | .witness.signatories | index($owner) != null)
            and (.transactions | length) == 2
          ' "$f" > /dev/null || { echo 'FAIL: reject-and-retract-refund-controls exit evidence moved'; exit 1; }
```

## body-generic-rows-reject-before-deadline-consumer body: generic rows, reject-before-deadline-consumer-requirement unmet by ruling

The changes from the base body are the reject-before-deadline-consumer-requirement verdict group (`unmet-by-ruling`, by operator ruling 2026-10-01), the held set `empty-fold surplus-fold-actions request-value-and-refund-routing` with the unmet set `reject-before-deadline-consumer-requirement`, assertion 10 and the two closing lines. Assertion 10 checks reject-before-deadline-consumer-requirement's accepted receipt, its recorded unmet requirement, that it is not recorded held, and its refused short-refund control. The control goes through the existing `submitExpectRefusedControl`, which fails the run unless the node's refusal is attributed to the state script; the line asserted here is the one that helper logs. Order and units follow: run after the accepted reject, the control's input would already be spent and its refusal could not be attributed to the state script; run with refusal-sized units, the accepted reject would not be accepted.

```yaml
      - name: Run the generic rows as a packaged app without a dev shell
        working-directory: conformance
        run: |
          set -e
          blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
          # The receipts directory is invocation-fresh: stale records
          # must never supplement a partial or failed run.
          CONFORMANCE_RECEIPTS="$(mktemp -d "$RUNNER_TEMP/conformance-receipts.XXXXXX")"
          export CONFORMANCE_RECEIPTS
          printf 'CONFORMANCE_RECEIPTS=%s\n' "$CONFORMANCE_RECEIPTS" >> "$GITHUB_ENV"
          set +e
          REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run update-existing-key delete-existing-key reinsert-deleted-key insert-occupied-key reject-before-deadline-consumer-requirement fold-against-superseded-root empty-fold surplus-fold-actions request-value-and-refund-routing register-active-key --receipts-dir "$CONFORMANCE_RECEIPTS" 2>&1 | tee /tmp/generic-rows.log
          run_rc=${PIPESTATUS[0]}
          set -e
          echo "generic session exit: $run_rc (expected: exactly 1, the handled session-debt exit)"
          # --- expected-debt assertion over ACTUAL session results
          # --- (operator answer (A-001), operator note (NOTE-002): never success from a bare nonzero or
          # --- an error label; build/setup/crash/unknown must FAIL)
          head_sha="$(git rev-parse HEAD)"
          # 1. the EXACT intended session-debt status, never "nonzero":
          #    Main.hs maps every handled session failure to exit 1, so
          #    exit 1 is the intended result ONLY together with the
          #    complete terminal evidence asserted below.
          [ "$run_rc" -eq 1 ] || { echo "FAIL: session exit $run_rc is not the known session-debt exit 1 — a build/setup/crash exit is an unexamined failure, not expected debt"; exit 1; }
          # 2. complete session evidence: all 10 rows executed...
          grep -q 'complete: 10/10 rows ok' /tmp/generic-rows.log || { echo 'FAIL: the session did not complete all 10 rows (mid-run failure or crash)'; exit 1; }
          #    ...and the terminal failure is the held-rows debt report
          grep -q 'ROWS THE RUN CANNOT REPORT AS PASSING' /tmp/generic-rows.log || { echo 'FAIL: the terminal failure is not the held-rows debt report'; exit 1; }
          # 3. exactly the ten rows plus the session execution-units-and-transaction-size, no extras
          printf '%s\n' update-existing-key delete-existing-key reinsert-deleted-key insert-occupied-key reject-before-deadline-consumer-requirement fold-against-superseded-root empty-fold surplus-fold-actions request-value-and-refund-routing register-active-key execution-units-and-transaction-size | sort > /tmp/expected-rows.txt
          nix run --quiet nixpkgs#jq -- -r '.row' "${CONFORMANCE_RECEIPTS}"/receipt-*.json | sort > /tmp/receipt-rows.txt
          #    Compared with bash builtins, not diff: this step runs a packaged
          #    app without a dev shell, and an absent diff previously reported
          #    'receipt set mismatch' — an unavailable tool misattributed as a
          #    substantive failure. No external command, so no such path remains.
          if [ "$(</tmp/expected-rows.txt)" != "$(</tmp/receipt-rows.txt)" ]; then
            echo 'FAIL: receipt set mismatch (missing or extra row)'
            echo '--- expected rows ---'; while IFS= read -r l; do echo "$l"; done < /tmp/expected-rows.txt
            echo '--- receipt rows ---';  while IFS= read -r l; do echo "$l"; done < /tmp/receipt-rows.txt
            exit 1
          fi
          # 4. exactly the expected verdict per receipt, EVERY receipt
          #    bound to this candidate on a clean tree (dirty:false)
          expect_verdict() {
            case "$1" in
              update-existing-key|delete-existing-key|reinsert-deleted-key|insert-occupied-key|fold-against-superseded-root|register-active-key|execution-units-and-transaction-size) printf 'agrees-with-model' ;;
              reject-before-deadline-consumer-requirement) printf 'unmet-by-ruling' ;;
              empty-fold|surplus-fold-actions|request-value-and-refund-routing) printf 'held-q002' ;;
              *) printf 'UNKNOWN-ROW' ;;
            esac
          }
          for row in update-existing-key delete-existing-key reinsert-deleted-key insert-occupied-key reject-before-deadline-consumer-requirement fold-against-superseded-root empty-fold surplus-fold-actions request-value-and-refund-routing register-active-key execution-units-and-transaction-size; do
            f="${CONFORMANCE_RECEIPTS}/receipt-$row.json"
            test -f "$f" || { echo "FAIL: missing receipt for $row"; exit 1; }
            v="$(nix run --quiet nixpkgs#jq -- -r '.verdict' "$f")"
            want="$(expect_verdict "$row")"
            [ "$v" = "$want" ] || { echo "FAIL: unexpected verdict for $row: got '$v', expected '$want'"; exit 1; }
            [ "$(nix run --quiet nixpkgs#jq -- -r '.dirty' "$f")" = "false" ] || { echo "FAIL: $row receipt records a dirty tree"; exit 1; }
            [ "$(nix run --quiet nixpkgs#jq -- -r '.base' "$f")" = "$head_sha" ] || { echo "FAIL: $row receipt is not bound to this candidate ($head_sha)"; exit 1; }
          done
          # 5. execution-units-and-transaction-size carries the session's measurement evidence: nonzero
          #    units and size, folds named — refuse missing or divergent
          nix run --quiet nixpkgs#jq -- -e '.mem > 0 and .cpu > 0 and .txSize > 0 and (.transactions | length > 0)' "${CONFORMANCE_RECEIPTS}"__lookup_path_1__ > /dev/null || { echo 'FAIL: execution-units-and-transaction-size measurement evidence missing or divergent'; exit 1; }
          # 6. the run's own accounting must name exactly the expected
          #    held and unmet sets, with nothing failing against this candidate
          held="$(sed -n 's/^- Held .*held-q002): //p' /tmp/generic-rows.log)"
          [ "$held" = "empty-fold surplus-fold-actions request-value-and-refund-routing" ] || { echo "FAIL: held set moved: got '$held', expected 'empty-fold surplus-fold-actions request-value-and-refund-routing'"; exit 1; }
          unmet="$(sed -n 's/^- Unmet by ruling .*unmet-by-ruling): //p' /tmp/generic-rows.log)"
          [ "$unmet" = "reject-before-deadline-consumer-requirement" ] || { echo "FAIL: unmet set moved: got '$unmet', expected 'reject-before-deadline-consumer-requirement'"; exit 1; }
          # nothing may fail against this candidate
          failing="$(sed -n 's/^- Failing .*accepted): //p' /tmp/generic-rows.log)"
          [ "$failing" = "none" ] || { echo "FAIL: rows failing against this candidate: $failing"; exit 1; }
          # 7. Bind observations to full hashes from the compiled
          #    blueprint. The human log marker is abbreviated and
          #    cannot serve as a script identity.
          state_hash="$(nix run --quiet nixpkgs#jq -- -er '.validators[] | select(.title == "state.state.spend" and ((.parameters // []) | length) == 0) | .hash' "$blueprint")"
          # #157 C8/C10: `consumer.ak` is deleted and every rule it re-walked
          # beside the fold is the cage's own, so there is no consumer hook to
          # bind and the cage alone decides. The control below binds the
          # refusal to the state script instead.
          for row in empty-fold surplus-fold-actions; do
            f="${CONFORMANCE_RECEIPTS}/receipt-$row.json"
            # jq expands its own --arg variables inside this program.
            # shellcheck disable=SC2016
            nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
              .outcome == "refused" and .venue == "node-submit"
              and (.rejected | test("^[0-9a-f]{64}$"))
              and .refusal.phase == "phase-2"
              and (.refusal.hashes | index($state) != null)
              and (.refusal.limit | type == "string" and length > 0)
            ' "$f" > /dev/null || { echo "FAIL: $row structural refusal evidence moved"; exit 1; }
          done
          # request-value-and-refund-routing under the registry-mode cage is REFUSED at the state script
          # (operator answer (A-015)): the interface routes a processed request to its own
          # destination minus the tip and a refund to the address custody
          # records, so a crossed allocation -- one request's value routed to
          # another's target, or to a hook the mandate deleted -- is a routing
          # the cage refuses. Same structural refusal evidence as empty-fold/surplus-fold-actions.
          # jq expands its own --arg variables inside this program.
          # shellcheck disable=SC2016
          nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
            .outcome == "refused" and .venue == "node-submit"
            and (.rejected | test("^[0-9a-f]{64}$"))
            and .refusal.phase == "phase-2"
            and (.refusal.hashes | index($state) != null)
            and (.refusal.limit | type == "string" and length > 0)
          ' "${CONFORMANCE_RECEIPTS}"__lookup_path_2__ > /dev/null || { echo 'FAIL: request-value-and-refund-routing structural refusal evidence moved'; exit 1; }
          grep -q '^control: empty-fold control: nonempty fold accepted (tx=[0-9a-f]\{64\})' /tmp/generic-rows.log || { echo 'FAIL: empty-fold accepting control txid missing'; exit 1; }
          grep -q '^control: surplus-fold-actions control: exact 1:1 fold accepted (tx=[0-9a-f]\{64\})' /tmp/generic-rows.log || { echo 'FAIL: surplus-fold-actions accepting control txid missing'; exit 1; }
          # 8. standalone rejected-floor control receipt mandatory:
          #    two nonempty obligations, ordered pair, paid-vs-owed,
          #    phase/hash/limit, both txids, counterpart, identity.
          c="${CONFORMANCE_RECEIPTS}/control-request-value-and-refund-routing-rejected-floor.json"
          test -f "$c" || { echo 'FAIL: missing request-value-and-refund-routing-rejected-floor control receipt'; exit 1; }
          # jq expands its own --arg/--slurpfile variables.
          # shellcheck disable=SC2016
          nix run --quiet nixpkgs#jq -- -e --arg base "$head_sha" --arg state "$state_hash" --slurpfile row "${CONFORMANCE_RECEIPTS}"__lookup_path_3__ '
            def txid: type == "string" and test("^[0-9a-f]{64}$");
            def text: type == "string" and length > 0;
            .control == "request-value-and-refund-routing-rejected-floor" and .row == "request-value-and-refund-routing"
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
          ' "$c" > /dev/null || { echo 'FAIL: request-value-and-refund-routing-rejected-floor pair evidence moved'; exit 1; }
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
          #    is not observed: the validators are compiled without traces (#287).
          open_params="$(nix run --quiet nixpkgs#jq -- -er '[.validators[] | select(.title == "open.open.mint") | (.parameters // []) | length] | first' "$blueprint")"
          [ "$open_params" -eq 0 ] || { echo "FAIL: open.open.mint declares $open_params parameters; register-active-key reports a parameterless open application"; exit 1; }
          e="${CONFORMANCE_RECEIPTS}__lookup_path_4__"
          # jq expands its own --arg variables inside this program.
          # shellcheck disable=SC2016
          nix run --quiet nixpkgs#jq -- -e --arg state "$state_hash" '
            def txid: type == "string" and test("^[0-9a-f]{64}$");
            def complete: (.compared | length) == 9 and (.unobserved | type) == "array"
              and (.perturbation.refused > 0);
            ([.steps[] | select(.tamper == "other-address") | .request][0]) as $tampered |
            .row == "register-active-key" and .outcome == "accepted"
            and .verdict == "agrees-with-model" and .venue == "node-submit"
            and (.steps | length) == 7
            and ([.steps[].tamper] == [null,null,null,"other-address","short-by-one",null,"extra-signer"])
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
          ' "$e" > /dev/null || { echo 'FAIL: register-active-key step evidence missing or incomplete'; exit 1; }
          # 10. reject-before-deadline-consumer-requirement (#320): the consumer's R9_reject_needs_rejectable forbids
          #     a reject inside the processing window; Singular's Lean admits
          #     it and the chain accepts it. By operator ruling 2026-10-01 the
          #     consumer requirement is kept unmet (alignment:
          #     lambdasistemi/cardano-keri#468): the verdict is unmet-by-ruling,
          #     never agreement and never held-q002. Its control, the same
          #     reject one lovelace short, is refused by the state script first.
          # shellcheck disable=SC2016
          nix run --quiet nixpkgs#jq -- -e '
            .row == "reject-before-deadline-consumer-requirement" and .outcome == "accepted" and .verdict == "unmet-by-ruling"
            and .venue == "node-submit"
            and (.transactions | length) == 1
            and (.transactions[0] | test("^[0-9a-f]{64}$"))
          ' "${CONFORMANCE_RECEIPTS}"__lookup_path_5__ > /dev/null || { echo 'FAIL: reject-before-deadline-consumer-requirement unmet acceptance evidence moved'; exit 1; }
          grep -q '^unmet: reject-before-deadline-consumer-requirement UNMET BY RULING: ' /tmp/generic-rows.log || { echo 'FAIL: reject-before-deadline-consumer-requirement unmet requirement not recorded by the run'; exit 1; }
          if grep -q '^held: reject-before-deadline-consumer-requirement ' /tmp/generic-rows.log; then echo 'FAIL: reject-before-deadline-consumer-requirement recorded held'; exit 1; fi
          grep -q '^control: reject-before-deadline-consumer-requirement control: REFUSED at submit, attributed to state (phase-2, marker 0x[0-9a-f][0-9a-f]*)' /tmp/generic-rows.log || { echo 'FAIL: reject-before-deadline-consumer-requirement refused control not attributed to the state script'; exit 1; }
          echo 'GREEN = expected-debt assertion held: 10 rows executed on a clean candidate-bound tree; the registration steps, duplicate refusal and the tampered-payment controls are recorded, with held debt exactly empty-fold surplus-fold-actions request-value-and-refund-routing and reject-before-deadline-consumer-requirement unmet by ruling.'
          echo 'A GREEN STEP IS NOT A FULFILLED CONSUMER PROMISE: R5_plugin_pinned, R8_empty_fold_refused, R9_reject_needs_rejectable and R11_contribute_value stay unmet (upstream #100/#101); strict completion and release stay RED on that debt.'
```

## body-reject-inside-processing-retraction-windows-early body: reject-inside-processing-and-retraction-windows early rejection

It sits directly after body-reject-retract-refund-controls-unchanged in `conformance.yml`, under a comment stating what the row proves and which Aiken tests name the refusal reason.

```yaml
      - name: Run the dedicated reject-inside-processing-and-retraction-windows early rejection row as a packaged app
        run: |
          set -eo pipefail
          cd conformance
          blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
          receipts="$(mktemp -d "$RUNNER_TEMP/cg24-receipts.XXXXXX")"
          log="$RUNNER_TEMP/cg24.log"
          REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run reject-inside-processing-and-retraction-windows --receipts-dir "$receipts" 2>&1 | tee "$log"
          head_sha="$(git rev-parse HEAD)"
          f="$__lookup_path_6__"
          test -f "$f" || { echo 'FAIL: missing reject-inside-processing-and-retraction-windows receipt'; exit 1; }
          test "$(wc -c < "$f")" -le 14745 || { echo "FAIL: reject-inside-processing-and-retraction-windows receipt exceeds its margin"; exit 1; }
          state_hash="$(nix run --quiet nixpkgs#jq -- -er '.validators[] | select(.title == "state.state.spend" and ((.parameters // []) | length) == 0) | .hash' "$blueprint")"
          # jq expands its own --arg variables inside this program.
          # shellcheck disable=SC2016
          nix run --quiet nixpkgs#jq -- -e --arg base "$head_sha" --arg state "$state_hash" '
            def txid: type == "string" and test("^[0-9a-f]{64}$");
            def text: type == "string" and length > 0;
            def complete: .comparison == "agrees" and .tamper == null
              and (.compared | length) == 9 and .perturbation.refused > 0;
            .row == "reject-inside-processing-and-retraction-windows"
            and .verdict == "agrees-with-model"
            and .base == $base and .dirty == false
            and (.blueprint | text) and (.node | text)
            and (.steps | length) == 6
            and all(.steps[]; .edge == "insertActive" and .exit == "reject")
            and ([.steps[].tamper] == ["short-by-one","other-address",null,"short-by-one","other-address",null])
            and ([.steps[].model.outcome] == ["refused","refused","accepted","refused","refused","accepted"])
            and ([.steps[].chain.outcome] == ["refused","refused","accepted","refused","refused","accepted"])
            and all(.steps[]; .comparison == "agrees")
            and all(.steps[] | select(.model.outcome == "accepted"); complete and (.chain.txid | txid))
            and all(.steps[] | select(.model.outcome == "refused");
              .model.reason == "deposit-returned"
              and (.chain.txid | txid)
              and (.chain.refusal.hashes | index($state) != null)
              and (.chain.refusal.scripts | index("state") != null))
            and ([.steps[].registry] | unique | length) == 1
            and ([.steps[0,1,2].request] | unique | length) == 1
            and ([.steps[3,4,5].request] | unique | length) == 1
            and .steps[0].request != .steps[3].request
            and (.transactions | length) == 2
          ' "$f" > /dev/null || { echo 'FAIL: reject-inside-processing-and-retraction-windows early rejection evidence moved'; exit 1; }
          # Each reject is placed in a named window; the interpreter refuses to
          # submit outside it. The run log states each placement with the
          # transaction's validity interval and the window it lies in.
          p1="$(grep -c "^placement: reject-inside-processing-and-retraction-windows reject in the processing window validity=\[[0-9]*,[0-9]*) window=\[[0-9]*,[0-9]*) tx=[0-9a-f]\{64\}$" "$log" || true)"
          p2="$(grep -c "^placement: reject-inside-processing-and-retraction-windows reject in the owner's retraction window validity=\[[0-9]*,[0-9]*) window=\[[0-9]*,[0-9]*) tx=[0-9a-f]\{64\}$" "$log" || true)"
          if [ "$p1" -ne 3 ] || [ "$p2" -ne 3 ]; then
            echo "FAIL: reject-inside-processing-and-retraction-windows placements moved: processing=$p1 retraction=$p2, expected 3 and 3"
            exit 1
          fi
          echo 'GREEN = early rejection held: inside the processing window and inside the retraction window, the untampered reject is accepted by the chain and the model, refunding the owner and leaving the state as it was; the short and misdirected refunds are refused by both for deposit-returned. The consumer R9_reject_needs_rejectable stays unmet (reject-before-deadline-consumer-requirement, unmet-by-ruling).'
```

## The rows change, exact

Two rows of `conformance/rows.json` change. Every other row, reject-before-deadline-consumer-requirement included, stays byte-identical.

reject-and-retract-refund-controls, two text replacements, nothing else:

- `requirement`: "A reject once the request may no longer be folded must refund its owner the deposit;" becomes "A reject must refund its owner the deposit;".
- `note`: "the rejection registry makes its requests rejectable a second after their retract window opens, the retraction registry keeps them retractable for thirty seconds." becomes "the rejection registry places its rejects after their owner's retraction window, which closes a second after it opens, and the retraction registry keeps its requests retractable for thirty seconds; rejects inside the windows are reject-inside-processing-and-retraction-windows's."

reject-inside-processing-and-retraction-windows, appended after reject-and-retract-refund-controls, keys in the file's order:

```json
{
  "expected": "accept a reject while the request can still be folded and one while its owner can still retract it, each refunding the owner the deposit and leaving the registry state as it was; refuse, in each window, a reject refunding the owner one lovelace short and one refunding another key, `deposit-returned`",
  "group": "CG",
  "id": "reject-inside-processing-and-retraction-windows",
  "note": "#320. Two insertion requests are booked together in a registry of their own. The first is rejected inside its processing window, the second inside its owner's retraction window, each untampered reject after its two tampered ones. The ledger surfaces no Plutus trace, so each refusal is attributed by the state script's hash, and the model reason is the name the compiled Aiken suite asserts for the same refund in the same window. A fold of an update in the retraction window is not a step here: the validator refuses it while the model admits it, a separate tracked discrepancy.",
  "requirement": "On a real devnet, a folder may reject a pending request before its owner's retraction deadline. A reject while the request can still be folded, and one while its owner can still retract it, are each accepted by the chain and by the model, refund the owner the deposit and leave the registry state as it was. In each window a reject refunding the owner one lovelace short or to another key is refused by the chain and by the model.",
  "source": "Singular.exitStep and Singular.exitAdmission: a reject carries no admission; Singular.obligations for a reject; Singular.Statements.admitted_exit_is_the_exit and Singular.Statements.built_transaction_settles; issue #320",
  "state": "uncovered"
}
```

The row's state stays `uncovered` in the file. Its published state is computed from its receipt, like every row's.

# --- expected-debt assertion over ACTUAL session results
# --- (A-001, NOTE-002: never success from a bare nonzero or
# --- an error label; build/setup/crash/unknown must FAIL)
head_sha="$(git rev-parse HEAD)"
# 1. the EXACT intended session-debt status, never "nonzero":
#    Main.hs maps every handled session failure to exit 1, so
#    exit 1 is the intended result ONLY together with the
#    complete terminal evidence asserted below.
[ "$run_rc" -eq 1 ] || { echo "FAIL: session exit $run_rc is not the known session-debt exit 1 — a build/setup/crash exit is an unexamined failure, not expected debt"; exit 1; }
# 2. complete session evidence: all 13 rows executed...
grep -q 'complete: 13/13 rows ok' /tmp/generic-rows.log || { echo 'FAIL: the session did not complete all 13 rows (mid-run failure or crash)'; exit 1; }
#    ...and the terminal failure is the held-rows debt report
grep -q 'ROWS THE RUN CANNOT REPORT AS PASSING' /tmp/generic-rows.log || { echo 'FAIL: the terminal failure is not the held-rows debt report'; exit 1; }
# 3. exactly the thirteen rows plus the session CL01, no extras
printf '%s\n' CG02 CG03 CG04 CG05 CG07 CG09 CG10 CG11 CG12 CG13 CG17 CG19 CG20 CL01 | sort > /tmp/expected-rows.txt
nix run --quiet nixpkgs#jq -- -r '.row' ./conformance-receipts/receipt-*.json | sort > /tmp/receipt-rows.txt
diff /tmp/expected-rows.txt /tmp/receipt-rows.txt || { echo 'FAIL: receipt set mismatch (missing or extra row)'; exit 1; }
# 4. exactly the expected verdict per receipt, EVERY receipt
#    bound to this candidate on a clean tree (dirty:false)
expect_verdict() {
  case "$1" in
    CG02|CG03|CG04|CG05|CG07|CG09|CG10|CG17|CG20|CL01) printf 'agrees-with-model' ;;
    CG11|CG12|CG19) printf 'held-q002' ;;
    CG13) printf 'resolved-by-ruling' ;;
    *) printf 'UNKNOWN-ROW' ;;
  esac
}
for row in CG02 CG03 CG04 CG05 CG07 CG09 CG10 CG11 CG12 CG13 CG17 CG19 CG20 CL01; do
  f="./conformance-receipts/receipt-$row.json"
  test -f "$f" || { echo "FAIL: missing receipt for $row"; exit 1; }
  v="$(nix run --quiet nixpkgs#jq -- -r '.verdict' "$f")"
  want="$(expect_verdict "$row")"
  [ "$v" = "$want" ] || { echo "FAIL: unexpected verdict for $row: got '$v', expected '$want'"; exit 1; }
  [ "$(nix run --quiet nixpkgs#jq -- -r '.dirty' "$f")" = "false" ] || { echo "FAIL: $row receipt records a dirty tree"; exit 1; }
  [ "$(nix run --quiet nixpkgs#jq -- -r '.base' "$f")" = "$head_sha" ] || { echo "FAIL: $row receipt is not bound to this candidate ($head_sha)"; exit 1; }
done
# 5. CL01 carries the session's measurement evidence: nonzero
#    units and size, folds named — refuse missing or divergent
nix run --quiet nixpkgs#jq -- -e '.mem > 0 and .cpu > 0 and .txSize > 0 and (.transactions | length > 0)' ./conformance-receipts/receipt-CL01.json > /dev/null || { echo 'FAIL: CL01 measurement evidence missing or divergent'; exit 1; }
# 6. the run's own accounting must name exactly the expected
#    held set, with nothing failing against this candidate
held="$(sed -n 's/^- Held .*held-q002): //p' /tmp/generic-rows.log)"
[ "$held" = "CG11 CG12 CG19" ] || { echo "FAIL: held set moved: got '$held', expected 'CG11 CG12 CG19'"; exit 1; }
# nothing may fail against this candidate
failing="$(sed -n 's/^- Failing .*accepted): //p' /tmp/generic-rows.log)"
[ "$failing" = "none" ] || { echo "FAIL: rows failing against this candidate: $failing"; exit 1; }
echo 'GREEN = expected-debt assertion held: 13 rows executed on a clean candidate-bound tree, verdicts and CL01 measurement evidence as declared, held debt exactly CG11 CG12 CG19, nothing failing.'
echo 'A GREEN STEP IS NOT A FULFILLED CONSUMER PROMISE: R5_plugin_pinned, R8_empty_fold_refused and R11_contribute_value stay unmet (upstream #100/#101); strict completion and release stay RED on that debt.'

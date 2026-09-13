# --- expected-debt assertion over ACTUAL session results (A-001)
# exactly the thirteen rows plus the session CL01, no extras
printf '%s\n' CG02 CG03 CG04 CG05 CG07 CG09 CG10 CG11 CG12 CG13 CG17 CG19 CG20 CL01 | sort > /tmp/expected-rows.txt
nix run --quiet nixpkgs#jq -- -r '.row' ./conformance-receipts/receipt-*.json | sort > /tmp/receipt-rows.txt
diff /tmp/expected-rows.txt /tmp/receipt-rows.txt || { echo 'FAIL: receipt set mismatch (missing or extra row)'; exit 1; }
# exactly the expected verdict per row, from the receipts
expect_verdict() {
  case "$1" in
    CG02|CG03|CG04|CG05|CG07|CG09|CG10|CG17|CG20) printf 'agrees-with-model' ;;
    CG11|CG12|CG19) printf 'held-q002' ;;
    CG13) printf 'resolved-by-ruling' ;;
    *) printf 'UNKNOWN-ROW' ;;
  esac
}
for row in CG02 CG03 CG04 CG05 CG07 CG09 CG10 CG11 CG12 CG13 CG17 CG19 CG20; do
  f="./conformance-receipts/receipt-$row.json"
  test -f "$f" || { echo "FAIL: missing receipt for $row"; exit 1; }
  v="$(nix run --quiet nixpkgs#jq -- -r '.verdict' "$f")"
  want="$(expect_verdict "$row")"
  [ "$v" = "$want" ] || { echo "FAIL: unexpected verdict for $row: got '$v', expected '$want'"; exit 1; }
done
# the session must not claim success while rows are held
[ "$run_rc" -ne 0 ] || { echo 'FAIL: session exited 0 while held rows are in it — the held-set moved; update this assertion deliberately, never silently'; exit 1; }
# the run's own accounting must name exactly the expected held set
held="$(sed -n 's/^- Held .*held-q002): //p' /tmp/generic-rows.log)"
[ "$held" = "CG11 CG12 CG19" ] || { echo "FAIL: held set moved: got '$held', expected 'CG11 CG12 CG19'"; exit 1; }
# nothing may fail against this candidate
failing="$(sed -n 's/^- Failing .*accepted): //p' /tmp/generic-rows.log)"
[ "$failing" = "none" ] || { echo "FAIL: rows failing against this candidate: $failing"; exit 1; }
echo 'GREEN = expected-debt assertion held: 13 rows executed, verdicts as recorded, held debt exactly CG11 CG12 CG19.'
echo 'A GREEN STEP IS NOT A FULFILLED CONSUMER PROMISE: R5/R8/R11 stay unmet (upstream #100/#101); strict completion and release stay RED on that debt.'

#!/usr/bin/env bash
# The required diagnostic/recovery journey, using explicitly enabled test
# builds. Its original race, crash, node-loss and independent trie assertions
# run separately from the ordinary extracted-release journey.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$(cd "$1" && pwd)"
journey="${DEMO1_TEST_JOURNEY:?explicit test journey implementation required}"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-harness.XXXXXX")"
# The journey owns and joins its held writers and stops its development node.
# This wrapper owns only its scratch and retains all diagnostics on request.
# shellcheck disable=SC2329 # invoked by the EXIT trap
release_scratch() {
  local code=$?
  trap - EXIT
  if [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
    echo "explicit test journey scratch: $scratch" >&2
  else
    chmod -R u+rwx "$scratch" 2>/dev/null || true
    rm -rf "$scratch"
  fi
  exit "$code"
}
trap release_scratch EXIT
build() { nix build --quiet --no-write-lock-file --no-link --print-out-paths "$@"; }
singular="$(build "$root/offchain#singular-test-harness")/bin/singular"
open_datum="$(build "$root/applications/open-datum/offchain#open-datum-test-harness")/bin/open-datum"
devnet="$(build "$root/offchain#devnet")/bin/devnet"
blueprint="$(build "$root/applications/open-datum/onchain#open-datum-blueprint")"
export E2E_GENESIS_DIR="$root/offchain/e2e-test/genesis"
echo "explicit test-build journey: singular=$singular open-datum=$open_datum"
sha256sum "$singular" "$open_datum"
invocations="$scratch/invocations.tsv"
: >"$invocations"
mkdir -p "$scratch/bin"
cat >"$scratch/bin/singular" <<WRAPPER
#!/usr/bin/env bash
harness="\$(env | grep -o '^SINGULAR_HARNESS_[A-Z_]*' | LC_ALL=C sort | paste -sd, - || true)"
holds="\$(env | grep '^SINGULAR_HARNESS_HOLD_' | grep -v '^SINGULAR_HARNESS_HOLD_STEP=' | cut -d= -f2- | paste -sd'|' - || true)"
printf '%s\t%s\t%s\n' "singular \${1:-} \${2:-}" "\$harness" "\$holds" >>$(printf '%q' "$invocations")
exec $(printf '%q' "$singular") "\$@"
WRAPPER
chmod +x "$scratch/bin/singular"
cat >"$scratch/bin/open-datum" <<WRAPPER
#!/usr/bin/env bash
harness="\$(env | grep -o '^SINGULAR_HARNESS_[A-Z_]*' | LC_ALL=C sort | paste -sd, - || true)"
holds="\$(env | grep '^SINGULAR_HARNESS_HOLD_' | grep -v '^SINGULAR_HARNESS_HOLD_STEP=' | cut -d= -f2- | paste -sd'|' - || true)"
printf '%s\t%s\t%s\n' "open-datum \${1:-} \${2:-}" "\$harness" "\$holds" >>$(printf '%q' "$invocations")
exec $(printf '%q' "$open_datum") "\$@"
WRAPPER
chmod +x "$scratch/bin/open-datum"
status=0
bash "$journey" "$scratch/bin/singular" "$scratch/bin/open-datum" "$devnet" "$blueprint" "$scratch/journey" test-harness || status=$?
[ "$status" -eq 0 ] || exit "$status"
refuse() {
  echo "explicit test-build journey: REFUSED: $*" >&2
  exit 1
}
# harness hooks: computed from the run. A hold point that fires writes
# PATH.waiting; the holds that fired must be exactly the ones a process was
# started with a variable for, and every process of the five open-datum
# commands started with no harness variable at all must exist.
for command in create insert update terminate inspect; do
  awk -F'\t' -v c="open-datum $command" 'index($1, c) == 1 && $2 == ""' "$invocations" | grep -q . \
    || refuse "no $command process ran without a harness variable"
done
plain="$(awk -F'\t' '$2 == ""' "$invocations" | wc -l)"
requested="$(awk -F'\t' '$3 != "" { n = split($3, p, "|"); for (i = 1; i <= n; i++) print p[i] ".waiting" }' "$invocations" | LC_ALL=C sort -u)"
[ -n "$requested" ] || refuse "the journey asked for no hold, so firing cannot be observed"
fired="$(find "$scratch" -path "$scratch/journey*" -name '*.waiting' | LC_ALL=C sort -u)"
[ "$fired" = "$requested" ] \
  || refuse "holds fired: [$(echo "$fired" | paste -sd' ' -)], requested: [$(echo "$requested" | paste -sd' ' -)]"
echo "explicit test-build journey: harness hooks: PASS" "$plain processes started with none set; holds fired only where requested ($(echo "$requested" | wc -l))"

echo "explicit test-build journey: exit $status; receipts in $scratch/journey/receipts"
exit "$status"

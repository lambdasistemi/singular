#!/usr/bin/env bash
# The cast validate gate on every cast, plus the key-material checks.
# usage: gate.sh CAST...      exit 0 only if every check holds on every cast.
# Every text check runs twice: on the cast file as written, and on the output stream reassembled from its
# events (escapes removed), because the tour emits long lines in pieces and a word can straddle two events.
# shellcheck disable=SC2015  # the ok/no pairs are one line each: the ok helper prints and cannot fail
set -uo pipefail
: "${REHEARSAL_WORK:?gate.sh needs the run scratch directory}"
RUN="$REHEARSAL_WORK"
play="$RUN/play"
fail=0
ok() { printf '  ok    %s\n' "$1"; }
no() {
  printf '  FAIL  %s\n' "$1"
  fail=1
}
keys=()
# The only key value this run holds is the negative host's funded test wallet (scene 3), which exists once
# the devnet was started; the players keep their keys inside their vaults. The two vault passphrases are
# secrets of the same rank: scene 0 reads them from a descriptor, and neither the casts nor any output may
# carry them.
[ ! -s "$RUN/keys/forger.key" ] || keys+=("$(cat "$RUN/keys/forger.key")")
while IFS= read -r pp; do [ -n "$pp" ] && keys+=("$pp"); done \
  < <(cat "$RUN/play/vault-pass/alice" "$RUN/play/vault-pass/bob" 2>/dev/null)
[ "${#keys[@]}" -ge 2 ] || {
  echo "gate: the run's passphrases are gone; the secret search cannot run" >&2
  exit 3
}
for cast in "$@"; do
  echo "== $cast"
  stream="$(mktemp "${TMPDIR:-/tmp}/stream.XXXXXX")"
  tail -n +2 "$cast" | jq -j '.[2]' | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' >"$stream"
  if tail -n +1 "$cast" | jq -e . >/dev/null 2>&1; then ok "every line parses as JSON"; else no "a line does not parse"; fi
  if head -1 "$cast" | jq -e '(.width >= 100 and .width <= 120) and .height == 34' >/dev/null; then
    ok "width $(head -1 "$cast" | jq .width) (100 to 120) and height $(head -1 "$cast" | jq .height) (34)"
  else no "size"; fi
  if head -1 "$cast" | jq -e '.env.SHELL == "/bin/bash"' >/dev/null; then ok "SHELL=/bin/bash"; else no "SHELL is not /bin/bash"; fi
  zero() { # zero LABEL EXTENDED-REGEX
    local a b
    a=$(grep -cE "$2" "$cast")
    b=$(grep -cE "$2" "$stream")
    if [ "$a" -eq 0 ] && [ "$b" -eq 0 ]; then ok "$1: 0 (file and reassembled stream)"; else no "$1: file $a, stream $b"; fi
  }
  zero "/nix/store" '/nix/store'
  zero "raw exceptions" 'FailureResponse|ClientError|CallStack|HasCallStack|[Ee]xception'
  zero "skey" 'skey'
  zero "key files and cardano-cli" 'cardano-cli|wallet-skey|wallet\.key|forger\.key|\.key\b'
  zero "cborHex" 'cborHex'
  longest=$(tail -n +2 "$cast" | jq -r '.[2]|length' | sort -rn | head -1)
  [ "$longest" -le 400 ] && ok "longest event: $longest characters (limit about 400)" || no "longest event: $longest"
  leak=0
  for k in "${keys[@]}"; do
    grep -qF "$k" "$cast" && leak=1
    grep -qF "$k" "$stream" && leak=1
  done
  [ "$leak" -eq 0 ] && ok "the run's secrets (the funded test key if the devnet started, and the two passphrases) appear nowhere (file and stream)" || no "a key value or a passphrase appears in the cast"
  # a positive control: the search above can fire (a known value planted in a copy is found)
  cp "$stream" "$stream.control"
  printf '%s\n' "${keys[0]}" >>"$stream.control"
  grep -qF "${keys[0]}" "$stream.control" && ok "control: the secret search finds a planted key value" || no "control: the key search cannot fire"
  mapfile -t hex64 < <(grep -oE '[0-9a-f]{64}' "$stream" | sort -u)
  stray=0
  for h in "${hex64[@]}"; do
    grep -rqF "$h" "$play" --include='*.json' --include='*.jsonl' --include='*.txt' || stray=$((stray + 1))
  done
  [ "$stray" -eq 0 ] && ok "64-hex strings in the stream: ${#hex64[@]} distinct, each a public identifier found in this run's receipts, none a key" || no "$stray 64-hex strings are in no receipt"
  last=$(tail -n 1 "$cast" | jq -r '.[0]')
  dur=$(printf '%.0f' "$last")
  if grep -qE 'result: ([0-9]+)/\1 singular commands in [0-9]+m [0-9]{2}s' "$stream"; then ok "ends with its result line: $(grep -E '^result: ' "$stream" | tail -1); duration ${dur}s"; else no "no complete result line"; fi
  rm -f "$stream" "$stream.control"
done
[ "$fail" -eq 0 ] && echo "GATE-PASS" || echo "GATE-FAIL"
exit "$fail"

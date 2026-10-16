#!/usr/bin/env bash
# Lay out the working directories for scene 2 and the scenes after it: links to the two public inputs
# every command needs (the release blueprint and the network time), and each player's own payload,
# beside the vault scene 0 made. Run between scene 0 and scene 2 once the node is up, never on camera;
# scene 2's opening listing names every one of these files.
# WORKAROUND: scene 0's listing must show the vault file alone, and the links and payloads need the running node -> the links and the payloads are laid in after scene 0, off camera; scene 2's opening comment names every file in the listing.
set -euo pipefail
: "${REHEARSAL_WORK:?setup-layout.sh needs the run scratch directory}"
: "${REHEARSAL_EXTRACTED:?setup-layout.sh needs the extracted release}"
RUN="$REHEARSAL_WORK"
extracted="$REHEARSAL_EXTRACTED"
time_directory="$(jq -r '.networkTimeDirectory' <<<"$(head -n1 "$RUN/devnet.out")")"
[ -n "$time_directory" ] && [ -r "$time_directory/time-manifest.json" ] || {
  echo "setup-layout: no time directory" >&2
  exit 3
}
for p in alice bob; do
  ln -sfn "$extracted/onchain" "$RUN/play/$p/onchain"
  ln -sfn "$time_directory" "$RUN/play/$p/time"
done
jq -n '{map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}' >"$RUN/play/alice/payload.json"
jq -n '{map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"626f62"},{constructor:2,fields:[]}]}}]}' >"$RUN/play/bob/payload.json"
ls -la "$RUN/play/alice" "$RUN/play/bob"
echo "setup-layout: done"

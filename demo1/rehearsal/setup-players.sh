#!/usr/bin/env bash
# Make the two players' empty directories and the files scene 0 reads, before any scene runs and before
# any node exists: scene 0's wallet commands need only the network magic.
# The vault passphrases live under play/vault-pass/ and are never printed by any command (wallet
# commands read them from a descriptor). play/holds/ receives the captured address lines of scene 0,
# again outside the players' directories, so each player's listing shows the vault file alone.
set -euo pipefail
: "${REHEARSAL_WORK:?setup-players.sh needs the run scratch directory}"
RUN="$REHEARSAL_WORK"
mkdir -p "$RUN/play/alice" "$RUN/play/bob" "$RUN/play/vault-pass" "$RUN/play/holds" "$RUN/keys"
: >"$RUN/pids"
# Passphrases: fixed strings for the run, read by the wallet commands from descriptor 3 only, never shown.
printf 'alice keeps her vault passphrase to herself\n' >"$RUN/play/vault-pass/alice"
printf 'bob keeps his vault passphrase to himself\n' >"$RUN/play/vault-pass/bob"
echo "setup-players: done"

#!/usr/bin/env bash
# Scene 0, the vault: Alice and Bob each create their wallet as one encrypted
# vault file, passphrase read from a descriptor and never shown, and read the
# address back out of it. The listing shows the vault file and nothing else:
# the key exists only inside the encrypted file. A closing comment says how the
# commands that follow sign: Alice from her vault, Bob the external way.
# Each wallet command opens descriptor 3 itself and reads one line: the passphrase is never an argument,
# never stored beside the vault, and never printed.
# WORKAROUND: a human types the passphrase at the echo-off prompt -> the tour reads it from a file outside the player's directory, one line per command on descriptor 3, never shown, so the listing shows the vault alone.
# WORKAROUND: a descriptor opened once in the shell cannot serve a second wallet command -> each command opens descriptor 3 itself with an inline 3<, shown on screen (the first read consumes the line; the second answers "cannot read the passphrase from descriptor 3").
# WORKAROUND: capturing the printed address with | tee would mask the command's exit status in the tour helper -> the address is captured under play/holds and echoed back with cat, so a failure still fails the tour.
set -euo pipefail
export DEMO_TOTAL=4
# shellcheck disable=SC2016  # the typed commands are shown verbatim on screen and evaluated by the tour helper
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
. "$(dirname "$0")/lib.sh"
play_cd "Alice prepares her wallet, before the story starts. Her directory is empty." alice
play -t -p 6 $'She creates her wallet: one command draws a fresh key, seals it into alice.vault with\nher passphrase, and prints the key\'s address. Her passphrase arrives on descriptor 3:' \
  'singular wallet create --vault alice.vault --network-magic 42 --passphrase-fd 3 3< ../vault-pass/alice > ../holds/alice-create.out && cat ../holds/alice-create.out'
play -t -p 6 $'The file answers only to her passphrase: the address command opens the vault and prints\nthe same address. The passphrase is never an argument, never stored, never shown.' \
  'singular wallet address --vault alice.vault --network-magic 42 --passphrase-fd 3 3< ../vault-pass/alice > ../holds/alice-address.out && cat ../holds/alice-address.out'
play -p 5 "The two address lines are equal: create sealed the key, and address read the same key back." \
  'diff ../holds/alice-create.out ../holds/alice-address.out && echo "the same address"'
play -p 10 $'What the wallet left on disk: the vault file, and nothing else.\nThe key exists only inside this encrypted file.' \
  'ls'
play_cd "Bob prepares his wallet the same way, in a directory of his own." ../bob
play -t -p 6 $'He creates his wallet the same way: a fresh key sealed into bob.vault with his passphrase,\nread once from descriptor 3 and never shown, and the key\'s address printed.' \
  'singular wallet create --vault bob.vault --network-magic 42 --passphrase-fd 3 3< ../vault-pass/bob > ../holds/bob-create.out && cat ../holds/bob-create.out'
play -t -p 6 "And reads the same address back out of his vault." \
  'singular wallet address --vault bob.vault --network-magic 42 --passphrase-fd 3 3< ../vault-pass/bob > ../holds/bob-address.out && cat ../holds/bob-address.out'
play -p 5 "Equal again: his vault opened with his passphrase and remembered his key." \
  'diff ../holds/bob-create.out ../holds/bob-address.out && echo "the same address"'
play -p 10 $'His directory too holds the vault file and nothing else.\nThe key exists only inside this encrypted file.' \
  'ls'
frame
comment_lines $'The devnet is funded to these two addresses and never sees a key. Alice will sign from her\nvault in one command; Bob\'s writes will leave a bundle for his vault to sign: the external way.'
prompt_line
read_pause 8
finish

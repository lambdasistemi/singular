#!/usr/bin/env bash
# Controls for the encrypted wallet vault: the real packaged `singular`
# binary, driven through an inherited descriptor with `cardano-cli`
# absent from the path, keeps every promise the vault makes — and each
# planted defect is shown to be one the controls refuse, before the
# real binary answers green.
#
# The promises, one control each:
#   * create prints the enterprise address on one line and makes a
#     vault file readable by its owner only;
#   * wallet address prints exactly what create printed;
#   * a second create over the existing vault is refused by name, the
#     file's bytes unchanged;
#   * a wrong passphrase is refused with nothing on standard output;
#   * no key envelope appears in the clear in the vault file, which is
#     an age file;
#   * `cardano-cli` is never on the path the commands run with.
#
# The planted defects are wrapper binaries around the real one: an
# overwriting variant that removes a refused create's obstacle and
# retries, and a leaking variant that prints the vault's own bytes
# after the address. Each demonstration requires the defect's
# signature to appear — the control would catch it — and a variant that
# fails to fire is a setup failure, never a pass.
#
# Usage: tools/wallet_vault_controls.sh [repo-root]
#        SINGULAR=/path/to/singular overrides the binary, which is
#        otherwise built from the repository's offchain flake.
set -euo pipefail

repo=${1:-.}
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The commands run with no cardano-cli anywhere on the path: the vault
# never shells out to one, and this proves it by absence. The path
# carries only the utilities the controls themselves name, resolved
# from this host — a NixOS /usr/bin is empty, so a fixed list would
# prove nothing and break the wrappers.
SANITISED_PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v grep)"):$(dirname "$(command -v cat)"):$(dirname "$(command -v rm)"):$(dirname "$(command -v sha256sum)"):$(dirname "$(command -v stat)"):$(dirname "$(command -v wc)"):$(dirname "$(command -v head)")"

# Every run command of this control path is bounded in time and, where
# the host provides a user manager, in memory: a build or a wallet
# process that grows without returning cannot exhaust a shared host
# before the bound stops it. The wall-clock bound always applies; the
# memory cap rides a systemd user scope when one answers, and the
# control runs on, bounded in time alone, where none does.
RUN_TIMEOUT=600
RUN_MEMORY_MAX=12G
have_user_manager() {
  command -v systemd-run >/dev/null 2>&1 \
    && systemd-run --user --scope --quiet -- true </dev/null >/dev/null 2>&1
}
if [ "${WALLET_CONTROLS_NO_SYSTEMD:-}" = 1 ]; then
  bounded() { timeout "$RUN_TIMEOUT" "$@"; }
  BOUND_KIND=fallback
elif have_user_manager; then
  bounded() {
    systemd-run --user --scope --quiet \
      -p MemoryMax="$RUN_MEMORY_MAX" -p MemorySwapMax=0 -- \
      timeout "$RUN_TIMEOUT" "$@"
  }
  BOUND_KIND=memory-capped
else
  bounded() { timeout "$RUN_TIMEOUT" "$@"; }
  BOUND_KIND=fallback
fi

real_singular=${SINGULAR:-}
if [ -z "$real_singular" ]; then
  real_singular="$(bounded nix build --quiet --no-link --print-out-paths "$repo/offchain#singular")/bin/singular"
fi
export real="$real_singular"

passphrase="correct horse battery staple"
wrong="a deliberately wrong passphrase"

# The vault path among a command's arguments.
vault_flagged() { # vault_flagged --vault PATH --network-magic 1 ...
  local prev=""
  for a in "$@"; do
    if [ "$prev" = "--vault" ]; then
      printf '%s' "$a"
      return 0
    fi
    prev=$a
  done
  return 1
}

create_vault() { # create_vault BINARY DIR -> prints create's address line
  local binary=$1 dir=$2
  printf '%s\n' "$passphrase" >"$dir/passphrase"
  exec 9<"$dir/passphrase"
  bounded env PATH="$SANITISED_PATH" "$binary" wallet create --vault "$dir/alice.vault" \
    --network-magic 1 --passphrase-fd 9 >"$dir/create.out" 2>"$dir/create.err"
  exec 9<&-
  cat "$dir/create.out"
}

address_of() { # address_of BINARY DIR PASSPHRASE_FILE -> the address line
  local binary=$1 dir=$2 passfile=$3 rc=0
  exec 9<"$passfile"
  bounded env PATH="$SANITISED_PATH" "$binary" wallet address --vault "$dir/alice.vault" \
    --network-magic 1 --passphrase-fd 9 >"$dir/address.out" 2>"$dir/address.err" || rc=$?
  exec 9<&-
  cat "$dir/address.out"
  return $rc
}

fail() {
  echo "FAIL wallet-vault control '$1': $2" >&2
  exit 1
}
setup_fail() {
  echo "SETUP-FAIL wallet-vault control '$1': $2" >&2
  exit 2
}

fresh() {
  rm -rf "$scratch/run"
  mkdir -p "$scratch/run"
}

# An overwriting variant: a create refused because the vault exists has
# its obstacle removed and the create retried — the defect the
# second-create control refuses.
cat >"$scratch/singular-overwriting" <<'EOF'
#!/usr/bin/env bash
out=$("$real" "$@" 2>"$OW_ERR") || {
  if grep -q "vault already exists" "$OW_ERR"; then
    vault=""; prev=""
    for a in "$@"; do
      if [ "$prev" = "--vault" ]; then vault=$a; fi
      prev=$a
    done
    rm -f "$vault"
  fi
  cat "$OW_ERR" >&2
  exit 1
}
printf '%s' "$out"
EOF
chmod +x "$scratch/singular-overwriting"

# A leaking variant: after a create it prints the vault's own bytes
# after the address — the defect the one-line control refuses.
cat >"$scratch/singular-leaking" <<'EOF'
#!/usr/bin/env bash
out=$("$real" "$@") || exit $?
if [ "$1" = wallet ] && [ "$2" = create ] && [ -n "$out" ]; then
  printf '%s\n' "$out"
  printf '%s\n' 'vault-bytes-would-follow-here'
  exit 0
fi
printf '%s' "$out"
EOF
chmod +x "$scratch/singular-leaking"

# --- the real binary -------------------------------------------------

fresh
address=$(create_vault "$real_singular" "$scratch/run")
[ "$(wc -l <"$scratch/run/create.out")" -eq 1 ] || fail create "printed $(wc -l <"$scratch/run/create.out") lines, not one"
grep -qE '^addr(_test)?1[a-z0-9]+$' <<<"$address" || fail create "printed no bech32 address: $address"
mode=$(stat -c '%a' "$scratch/run/alice.vault")
[ "$mode" = "600" ] || fail owner-only "mode $mode, not 600"
echo "control create: one address line, vault mode 600"

fresh
address=$(create_vault "$real_singular" "$scratch/run")
printed=$(address_of "$real_singular" "$scratch/run" "$scratch/run/passphrase")
[ "$printed" = "$address" ] || fail address-equals-create "'$printed' is not '$address'"
echo "control address: equals create's output"

fresh
address=$(create_vault "$real_singular" "$scratch/run")
before=$(sha256sum "$scratch/run/alice.vault" | cut -d' ' -f1)
printf '%s\n' "$passphrase" >"$scratch/run/passphrase"
set +e
address_of "$real_singular" "$scratch/run" "$scratch/run/passphrase" >/dev/null 2>&1
# second create over the existing vault:
exec 9<"$scratch/run/passphrase"
bounded env PATH="$SANITISED_PATH" "$real_singular" wallet create --vault "$scratch/run/alice.vault" \
  --network-magic 1 --passphrase-fd 9 >"$scratch/run/second.out" 2>"$scratch/run/second.err"
second_rc=$?
set -e
exec 9<&-
after=$(sha256sum "$scratch/run/alice.vault" | cut -d' ' -f1)
[ "$second_rc" -ne 0 ] || fail second-create "exit 0"
[ -s "$scratch/run/second.err" ] || fail second-create "no refusal on standard error"
[ ! -s "$scratch/run/second.out" ] || fail second-create "printed on standard output"
grep -q "vault already exists" "$scratch/run/second.err" || fail second-create "refusal does not name the cause"
[ "$before" = "$after" ] || fail second-create "the vault's bytes changed"
echo "control second-create: refused by name, bytes unchanged"

fresh
address=$(create_vault "$real_singular" "$scratch/run")
printf '%s\n' "$wrong" >"$scratch/run/wrong"
set +e
address_of "$real_singular" "$scratch/run" "$scratch/run/wrong"
wrong_rc=$?
set -e
[ "$wrong_rc" -ne 0 ] || fail wrong-passphrase "exit 0"
[ ! -s "$scratch/run/address.out" ] || fail wrong-passphrase "printed on standard output"
grep -q "cannot open vault" "$scratch/run/address.err" || fail wrong-passphrase "refusal does not name the cause"
grep -q "$wrong" "$scratch/run/address.err" && fail wrong-passphrase "the refusal names the passphrase"
echo "control wrong-passphrase: refused, empty standard output, no secret"

fresh
address=$(create_vault "$real_singular" "$scratch/run")
grep -qaE 'PaymentSigningKeyShelley_ed25519|cborHex' "$scratch/run/alice.vault" \
  && fail no-key-bytes "the key envelope appears in the clear"
head -c 5 "$scratch/run/alice.vault" | grep -qa 'age-e' || fail no-key-bytes "not an age file"
echo "control no-key-bytes: no envelope in the clear, an age file"

PATH="$SANITISED_PATH" command -v cardano-cli >/dev/null 2>&1 \
  && fail no-cardano-cli "found on the sanitised path"
echo "control no-cardano-cli: absent from the path the commands ran with"

# --- the planted defects ---------------------------------------------

# Overwriting: the defect must fire — the second create succeeding, or
# the vault's bytes moving, is exactly what the second-create control
# refuses.
export OW_ERR="$scratch/ow.err"
fresh
address=$(create_vault "$real_singular" "$scratch/run")
before=$(sha256sum "$scratch/run/alice.vault" | cut -d' ' -f1)
printf '%s\n' "$passphrase" >"$scratch/run/passphrase"
set +e
exec 9<"$scratch/run/passphrase"
bounded env PATH="$SANITISED_PATH" "$scratch/singular-overwriting" wallet create --vault "$scratch/run/alice.vault" \
  --network-magic 1 --passphrase-fd 9 >"$scratch/run/ow.out" 2>"$scratch/run/ow.err"
ow_rc=$?
exec 9<&-
set -e
if [ -f "$scratch/run/alice.vault" ]; then
  after=$(sha256sum "$scratch/run/alice.vault" | cut -d' ' -f1)
else
  after=absent
fi
if [ "$ow_rc" -eq 0 ]; then
  setup_fail planted-overwriting "the variant succeeded (rc 0) — unexpected for this defect"
fi
[ "$before" != "$after" ] || setup_fail planted-overwriting "the vault's bytes did not move; the variant did not fire"
echo "control planted-overwriting: the defect moved the vault's bytes and the second-create control refuses exactly that (rc $ow_rc)"

# Leaking: the defect must fire — create printing more than the address
# is exactly what the one-line control refuses.
fresh
leak=$(create_vault "$scratch/singular-leaking" "$scratch/run")
lines=$(wc -l <"$scratch/run/create.out")
[ "$lines" -gt 1 ] || setup_fail planted-leaking "the variant printed $lines line; it did not fire"
echo "control planted-leaking: the defect fired and the one-line control refuses it ($lines lines)"

# Both bound branches execute, each shown once: the wall-clock
# fallback alone runs a command, and the memory-capped scope runs one
# where a user manager answers — the control passes either way.
echo "control bound-runs: this control ran with the $BOUND_KIND branch"
timeout 5 true
echo "control bound-fallback: executed (wall-clock bound alone)"
if have_user_manager; then
  systemd-run --user --scope --quiet \
    -p MemoryMax="$RUN_MEMORY_MAX" -p MemorySwapMax=0 -- \
    timeout 5 true
  echo "control bound-memory-capped: executed (memory-capped scope)"
else
  echo "control bound-memory-capped: no user manager here; the fallback branch carried every run"
fi

echo "PASS wallet-vault-controls"

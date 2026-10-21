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
#   * SINGULAR_PASSPHRASE gives the passphrase on a development network, a
#     descriptor outranks it, and mainnet, preprod and preview refuse it
#     naming the variable and the network, before a vault is read or made,
#     as does an empty one;
#   * no key envelope appears in the clear in the vault file, which is
#     an age file;
#   * `cardano-cli` is never on the path the commands run with;
#   * wallet sign writes one standard witness envelope per transaction,
#     the paths on standard output and a summary on standard error;
#   * a bundle whose recorded identity is not the hash of its body, or
#     whose signers do not include this vault's address, is refused by
#     name and nothing is written;
#   * a second sign over existing witness files is refused by name, the
#     bytes unchanged;
#   * the verb takes no provider or registry option, each refused by
#     name, and opens no connection — under a network namespace where
#     the runner allows one, else by provider refusals plus a counting
#     connection canary.
#   * submit takes no wallet key and no vault, each refused by name, and
#     refuses a witness that verifies against no transaction of the
#     bundle before any connection reaches the node it names; the
#     verifying twin passes the offline checks and reaches it.
#
# The planted defects are wrapper binaries around the real one: an
# overwriting variant that removes a refused create's obstacle and
# retries, and a leaking variant that prints the vault's own bytes
# after the address; for the sign family, an overwriting variant that
# removes a refused witness and retries, and an any-bundle variant
# that writes a witness file after the real binary refused the bundle.
# For submit, a chain-first variant that connects to the node before
# its checks, and a key-ignoring variant that drops the wallet key and
# runs on.
# The sign success check itself keeps no planted twin: its assertions
# are the ones the overwrite control's twin shares.
#
# Each demonstration requires the defect's signature to appear — the
# control would catch it — and a variant that fails to fire is a setup
# failure, never a pass.
#
# Usage: tools/wallet_vault_controls.sh [repo-root]
#        SINGULAR=/path/to/singular overrides the binary, which is
#        otherwise built from the repository's offchain flake.
set -euo pipefail

repo=${1:-.}
scratch="$(mktemp -d)"
# The one exit path: the counting listener's own recorded pid is
# signalled and waited for wherever the control stops — success, a
# failed assertion, an unfulfilled setup — and the scratch directory
# is removed after. No name or pattern kill anywhere.
cleanup() {
  if [ -n "${canary_pid:-}" ]; then
    kill "$canary_pid" 2>/dev/null || true
    wait "$canary_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

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
    && timeout 30 systemd-run --user --scope --quiet -- true </dev/null >/dev/null 2>&1
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

# The create control's refusing assertions, run by the real-binary
# control and by the planted-defect demonstration alike: create's
# observation is exactly one line and that line a bech32 address, so no
# vault bytes or key envelope can appear in the clear beside it.
create_refusal() { # create_refusal OUT OBSERVATION -> the refusal, or none
  local out=$1 observation=$2 lines
  lines=$(wc -l <"$out")
  if [ "$lines" -ne 1 ]; then
    echo "printed $lines lines, not one"
    return 1
  fi
  if ! grep -qE '^addr(_test)?1[a-z0-9]+$' <<<"$observation"; then
    echo "printed no bech32 address: $observation"
    return 1
  fi
  return 0
}

# The second-create control's refusing assertions, shared the same way:
# a create over an existing vault must refuse by name and move nothing.
second_create_refusal() { # second_create_refusal OUT ERR BEFORE AFTER RC -> the refusal, or none
  local out=$1 err=$2 before=$3 after=$4 rc=$5
  if [ "$rc" -eq 0 ]; then
    echo "exit 0"
    return 1
  fi
  if [ ! -s "$err" ]; then
    echo "no refusal on standard error"
    return 1
  fi
  if [ -s "$out" ]; then
    echo "printed on standard output"
    return 1
  fi
  if ! grep -q "vault already exists" "$err"; then
    echo "refusal does not name the cause"
    return 1
  fi
  if [ "$before" != "$after" ]; then
    echo "the vault's bytes changed"
    return 1
  fi
  return 0
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
if ! refusal=$(create_refusal "$scratch/run/create.out" "$address"); then
  fail create "$refusal"
fi
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
if ! refusal=$(second_create_refusal "$scratch/run/second.out" "$scratch/run/second.err" "$before" "$after" "$second_rc"); then
  fail second-create "$refusal"
fi
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

# --- the passphrase from the environment (#716) ----------------------

var_run() { # var_run PASSPHRASE BINARY ARGS... -> the command with SINGULAR_PASSPHRASE set
  local value=$1 binary=$2
  shift 2
  bounded env PATH="$SANITISED_PATH" SINGULAR_PASSPHRASE="$value" "$binary" "$@"
}

fresh
var_run "$passphrase" "$real_singular" wallet create --vault "$scratch/run/dev.vault" \
  --network-magic 42 >"$scratch/run/dev-create.out" 2>"$scratch/run/dev-create.err" \
  || fail variable-development "create exited non-zero: $(head -n 1 "$scratch/run/dev-create.err")"
dev_address=$(cat "$scratch/run/dev-create.out")
if ! refusal=$(create_refusal "$scratch/run/dev-create.out" "$dev_address"); then
  fail variable-development "$refusal"
fi
printed=$(var_run "$passphrase" "$real_singular" wallet address --vault "$scratch/run/dev.vault" \
  --network-magic 42 2>/dev/null) || fail variable-development "address exited non-zero"
[ "$printed" = "$dev_address" ] || fail variable-development "'$printed' is not '$dev_address'"
echo "control variable-development: create and address on network 42 from the variable, one address line"

# The descriptor wins over the variable: a wrong variable beside the right descriptor.
printf '%s\n' "$passphrase" >"$scratch/run/passphrase"
exec 9<"$scratch/run/passphrase"
printed=$(var_run "$wrong" "$real_singular" wallet address --vault "$scratch/run/dev.vault" \
  --network-magic 42 --passphrase-fd 9 2>/dev/null) || fail variable-descriptor-wins "exited non-zero"
exec 9<&-
[ "$printed" = "$dev_address" ] || fail variable-descriptor-wins "'$printed' is not '$dev_address'"
# and that wrong variable alone is a wrong passphrase, the positive control's twin
rc=0
var_run "$wrong" "$real_singular" wallet address --vault "$scratch/run/dev.vault" \
  --network-magic 42 >"$scratch/run/wrong.out" 2>"$scratch/run/wrong.err" || rc=$?
[ "$rc" -ne 0 ] || fail variable-descriptor-wins "a wrong variable alone opened the vault"
grep -q "cannot open vault" "$scratch/run/wrong.err" || fail variable-descriptor-wins "the refusal does not name the cause"
echo "control variable-descriptor-wins: the descriptor outranks the variable, a wrong variable alone is refused"

for network in "preprod 1" "preview 2" "mainnet 764824073"; do
  name=${network% *}
  magic=${network#* }
  fresh
  rc=0
  var_run "$passphrase" "$real_singular" wallet create --vault "$scratch/run/public.vault" \
    --network-magic "$magic" >"$scratch/run/public.out" 2>"$scratch/run/public.err" || rc=$?
  [ "$rc" -ne 0 ] || fail variable-public "create on $name exited 0"
  [ ! -e "$scratch/run/public.vault" ] || fail variable-public "create on $name made a vault"
  [ ! -s "$scratch/run/public.out" ] || fail variable-public "create on $name printed on standard output"
  for word in SINGULAR_PASSPHRASE "$name" "network magic $magic"; do
    grep -qF -- "$word" "$scratch/run/public.err" \
      || fail variable-public "the refusal on $name does not name $word"
  done
  grep -qF -- "$passphrase" "$scratch/run/public.err" \
    && fail variable-public "the refusal on $name names the passphrase"
  # wallet address refuses before it reads the vault: a path that is not there is not named
  rc=0
  var_run "$passphrase" "$real_singular" wallet address --vault "$scratch/run/absent.vault" \
    --network-magic "$magic" >"$scratch/run/public.out" 2>"$scratch/run/public.err" || rc=$?
  [ "$rc" -ne 0 ] || fail variable-public "address on $name exited 0"
  grep -qF -- "SINGULAR_PASSPHRASE" "$scratch/run/public.err" \
    || fail variable-public "the address refusal on $name does not name the variable"
  grep -qF -- "absent.vault" "$scratch/run/public.err" \
    && fail variable-public "the address refusal on $name came after the vault was read"
done
echo "control variable-public: mainnet, preprod and preview refuse the variable by name before a vault is read or made"

fresh
rc=0
var_run "" "$real_singular" wallet create --vault "$scratch/run/empty.vault" \
  --network-magic 42 >"$scratch/run/empty.out" 2>"$scratch/run/empty.err" || rc=$?
[ "$rc" -ne 0 ] || fail variable-empty "an empty variable created a vault"
[ ! -e "$scratch/run/empty.vault" ] || fail variable-empty "an empty variable made a vault"
grep -q "SINGULAR_PASSPHRASE is set but empty" "$scratch/run/empty.err" \
  || fail variable-empty "the refusal does not name the variable"
echo "control variable-empty: an empty variable is refused, not an empty passphrase"

fresh
address=$(create_vault "$real_singular" "$scratch/run")
grep -qaE 'PaymentSigningKeyShelley_ed25519|cborHex' "$scratch/run/alice.vault" \
  && fail no-key-bytes "the key envelope appears in the clear"
head -c 5 "$scratch/run/alice.vault" | grep -qa 'age-e' || fail no-key-bytes "not an age file"
echo "control no-key-bytes: no envelope in the clear, an age file"

PATH="$SANITISED_PATH" command -v cardano-cli >/dev/null 2>&1 \
  && fail no-cardano-cli "found on the sanitised path"
echo "control no-cardano-cli: absent from the path the commands ran with"

# --- the sign family -------------------------------------------------
#
# The bundle the controls witness is the committed fixture — a bundle
# whose signer is a fixed test key's address, so for the fresh vault
# it is also the vault-not-in-signers control as committed. The
# accepted twin inserts the vault's own address into the signers with
# jq; nothing else is touched, so the recorded identities and deadlines
# stay what the committed data says.

fixture="$repo/offchain/test/fixtures/bundle/unsigned-bundle.json"
[ -f "$fixture" ] || setup_fail sign-fixture "no committed bundle fixture at $fixture"
fixture_transactions=$(jq '(.transactions | length)' "$fixture")
[ "$fixture_transactions" -ge 2 ] \
  || setup_fail sign-fixture "the committed fixture holds fewer than two transactions"

# Sign one bundle: the run command bounded, the passphrase on fd 9.
sign_run() { # sign_run BINARY DIR BUNDLE OUT ERR -> rc
  local binary=$1 dir=$2 bundle=$3 out=$4 err=$5 rc=0
  exec 9<"$dir/passphrase"
  bounded env PATH="$SANITISED_PATH" "$binary" wallet sign --vault "$dir/alice.vault" \
    --passphrase-fd 9 "$bundle" >"$out" 2>"$err" || rc=$?
  exec 9<&-
  return $rc
}

# The sign control's refusing assertions, shared with the planted-defect
# demonstrations: a refusal exits non-zero, prints nothing on standard
# output, names its cause on standard error, writes no witness file and
# names no secret.
sign_refusal() { # sign_refusal OUT ERR DIR RC CAUSE -> the refusal, or none
  local out=$1 err=$2 dir=$3 rc=$4 cause=$5 written
  if [ "$rc" -eq 0 ]; then
    echo "exit 0"
    return 1
  fi
  if [ ! -s "$err" ]; then
    echo "no refusal on standard error"
    return 1
  fi
  if [ -s "$out" ]; then
    echo "printed on standard output"
    return 1
  fi
  if ! grep -q "$cause" "$err"; then
    echo "refusal does not name the cause: $cause"
    return 1
  fi
  written=$(find "$dir" -maxdepth 1 -name '*.witness' 2>/dev/null | wc -l)
  if [ "$written" -ne 0 ]; then
    echo "wrote $written witness files"
    return 1
  fi
  if grep -q "$passphrase" "$err"; then
    echo "the refusal names the passphrase"
    return 1
  fi
  return 0
}

# The sign control's success assertions, shared by the real binary's
# section and the planted-leak demonstration: every printed path is a
# standard witness file carrying exactly the fields a witness has, a
# summary exists naming no passphrase, and every 64-hex-digit word in
# the output and the summary is an identity the bundle itself names —
# the spelling a secret leaves when written as hex. Returns a refusal
# reason on stdout when the observation is refused, nothing otherwise.
sign_success_refusal() { # sign_success_refusal OUT ERR -> the refusal, or none
  local out=$1 err=$2 path identities word
  while IFS= read -r path; do
    [ -f "$path" ] || {
      echo "no witness file at $path"
      return 1
    }
    jq -e '.type == "TxWitness ConwayEra" and .description == "Key Witness ShelleyEra" and (.cborHex | length > 0)' "$path" >/dev/null || {
      echo "not a standard witness envelope: $path"
      return 1
    }
    jq -e '(keys | sort) == ["cborHex", "description", "type"]' "$path" >/dev/null || {
      echo "a witness file carries a field no witness has: $path"
      return 1
    }
  done <"$out"
  [ -s "$err" ] || {
    echo "no summary on standard error"
    return 1
  }
  if grep -q "$passphrase" "$err"; then
    echo "the summary names the passphrase"
    return 1
  fi
  identities=$(jq -r '.transactions[].identity' "$fixture" | sort)
  while IFS= read -r word; do
    printf '%s\n' "$identities" | grep -qx "$word" || {
      echo "an unknown 64-hex-digit word in the output or summary: $word"
      return 1
    }
  done < <(grep -ohE '[0-9a-fA-F]{64}' "$out" "$err" | sort -u)
  return 0
}

# --- sign: the accepted twin -----------------------------------------

fresh
address=$(create_vault "$real_singular" "$scratch/run")
bundle="$scratch/run/bundle.json"
jq --arg addr "$address" '.signers = [$addr]' "$fixture" >"$bundle" \
  || setup_fail sign-jq "jq could not rewrite the signers"
sign_run "$real_singular" "$scratch/run" "$bundle" "$scratch/run/sign.out" "$scratch/run/sign.err"
sign_rc=$?
[ "$sign_rc" -eq 0 ] || fail sign "exit $sign_rc: $(head -1 "$scratch/run/sign.err")"
printed_paths=$(grep -c '^' "$scratch/run/sign.out")
[ "$printed_paths" -ge 1 ] || fail sign "printed no witness paths"
if ! refusal=$(sign_success_refusal "$scratch/run/sign.out" "$scratch/run/sign.err"); then
  fail sign "$refusal"
fi
echo "control sign: one standard witness per transaction, paths on standard output, summary on standard error"

# --- sign: the tampered body -----------------------------------------

fresh
address=$(create_vault "$real_singular" "$scratch/run")
bundle="$scratch/run/bundle.json"
jq --arg addr "$address" \
  '(.transactions[0].envelope = .transactions[1].envelope) | .signers = [$addr]' \
  "$fixture" >"$bundle" || setup_fail sign-tamper-jq "jq could not tamper the body"
tamper_rc=0
sign_run "$real_singular" "$scratch/run" "$bundle" "$scratch/run/tamper.out" "$scratch/run/tamper.err" || tamper_rc=$?
if ! refusal=$(sign_refusal "$scratch/run/tamper.out" "$scratch/run/tamper.err" "$scratch/run" "$tamper_rc" "is not the hash of its body"); then
  fail sign-tampered "$refusal"
fi
echo "control sign-tampered: refused by name, nothing written"

# --- sign: the vault not among the signers ---------------------------

fresh
address=$(create_vault "$real_singular" "$scratch/run")
bundle="$scratch/run/bundle.json"
# The committed fixture's signer is a fixed test key's address, not
# this fresh vault's: the bundle as committed is the control.
cp "$fixture" "$bundle"
foreign_rc=0
sign_run "$real_singular" "$scratch/run" "$bundle" "$scratch/run/foreign.out" "$scratch/run/foreign.err" || foreign_rc=$?
if ! refusal=$(sign_refusal "$scratch/run/foreign.out" "$scratch/run/foreign.err" "$scratch/run" "$foreign_rc" "is not among the bundle's signers"); then
  fail sign-foreign "$refusal"
fi
echo "control sign-foreign: refused by name, nothing written"

# --- sign: the existing witness ---------------------------------------

# The second-sign control's refusing assertions, shared by the real
# binary's section and the planted-overwrite demonstration: a second
# sign over existing witnesses refuses by name, prints nothing on
# standard output, and moves no byte. The planted case requires a
# refusal from these same assertions; the real binary's own second run
# requires one too.
second_sign_refusal() { # second_sign_refusal OUT ERR BEFORE AFTER RC -> the refusal, or none
  local out=$1 err=$2 before=$3 after=$4 rc=$5
  if [ "$rc" -eq 0 ]; then
    echo "exit 0"
    return 1
  fi
  if [ ! -s "$err" ]; then
    echo "no refusal on standard error"
    return 1
  fi
  if [ -s "$out" ]; then
    echo "printed on standard output"
    return 1
  fi
  if ! grep -q "already exists" "$err"; then
    echo "refusal does not name the cause"
    return 1
  fi
  if [ "$before" != "$after" ]; then
    echo "the witnesses' bytes changed"
    return 1
  fi
  return 0
}

fresh
address=$(create_vault "$real_singular" "$scratch/run")
bundle="$scratch/run/bundle.json"
jq --arg addr "$address" '.signers = [$addr]' "$fixture" >"$bundle" \
  || setup_fail sign-twice-jq "jq could not rewrite the signers"
sign_run "$real_singular" "$scratch/run" "$bundle" "$scratch/run/first.out" "$scratch/run/first.err"
first_sign_rc=$?
[ "$first_sign_rc" -eq 0 ] || fail sign-twice "first sign exit $first_sign_rc"
before=$(find "$scratch/run" -maxdepth 1 -name '*.witness' -exec sha256sum {} + | sort | sha256sum)
second_sign_rc=0
sign_run "$real_singular" "$scratch/run" "$bundle" "$scratch/run/second.out" "$scratch/run/second.err" || second_sign_rc=$?
after=$(find "$scratch/run" -maxdepth 1 -name '*.witness' -exec sha256sum {} + | sort | sha256sum)
if ! refusal=$(second_sign_refusal "$scratch/run/second.out" "$scratch/run/second.err" "$before" "$after" "$second_sign_rc"); then
  fail sign-twice "$refusal"
fi
echo "control sign-twice: refused by name, bytes unchanged"

# --- sign: offline -----------------------------------------------------
#
# First the namespace: if bwrap can unshare the network on this runner,
# the accepted twin runs inside it — a sign that succeeds with no
# network to open proves the verb needs none. Otherwise the verb's own
# refusal of every provider option plus a connection canary (every
# proxy variable pointed at a counting local listener, zero
# connections observed) carry the control.

offline_kind=""
if command -v bwrap >/dev/null 2>&1 \
  && timeout 30 bwrap --unshare-net --ro-bind / / --dev /dev --proc /proc -- true \
    </dev/null >/dev/null 2>&1; then
  fresh
  address=$(create_vault "$real_singular" "$scratch/run")
  bundle="$scratch/run/bundle.json"
  jq --arg addr "$address" '.signers = [$addr]' "$fixture" >"$bundle" \
    || setup_fail sign-bwrap-jq "jq could not rewrite the signers"
  exec 9<"$scratch/run/passphrase"
  bwrap_rc=0
  bounded bwrap --unshare-net --ro-bind / / --dev /dev --proc /proc --bind "$scratch" "$scratch" -- \
    env PATH="$SANITISED_PATH" "$real_singular" wallet sign \
    --vault "$scratch/run/alice.vault" --passphrase-fd 9 "$bundle" \
    >"$scratch/run/bwrap.out" 2>"$scratch/run/bwrap.err" || bwrap_rc=$?
  exec 9<&-
  [ "$bwrap_rc" -eq 0 ] \
    || fail sign-offline "bwrap run exit $bwrap_rc: $(head -1 "$scratch/run/bwrap.err")"
  [ -n "$(cat "$scratch/run/bwrap.out")" ] \
    || fail sign-offline "bwrap run printed no witness paths"
  offline_kind="network-namespace"
  echo "control sign-offline: the accepted twin signed inside an unshared network namespace"
else
  echo "control sign-offline: no namespace on this runner; the refusals and the canary carry it"
fi

# Every provider and registry option is refused by name.
for flag in --koios-url --koios-token-file --network-time --wallet-skey \
  --state-dir --blueprint --seed --process-time --retract-time --key \
  --key-hex --receipt --confirm-timeout --wallet-address --outputs-at \
  --fund-input --max-outlay --deposit --payload --payload-schema --request --state-token \
  --network-magic; do
  fresh
  address=$(create_vault "$real_singular" "$scratch/run")
  bundle="$scratch/run/bundle.json"
  jq --arg addr "$address" '.signers = [$addr]' "$fixture" >"$bundle" \
    || setup_fail sign-flags-jq "jq could not rewrite the signers"
  exec 9<"$scratch/run/passphrase"
  flag_rc=0
  bounded env PATH="$SANITISED_PATH" "$real_singular" wallet sign \
    --vault "$scratch/run/alice.vault" --passphrase-fd 9 "$flag" x "$bundle" \
    >"$scratch/run/flag.out" 2>"$scratch/run/flag.err" || flag_rc=$?
  exec 9<&-
  [ "$flag_rc" -ne 0 ] || fail sign-flags "$flag was accepted"
  grep -q -- "$flag" "$scratch/run/flag.err" \
    || fail sign-flags "refusal does not name $flag"
done
echo "control sign-flags: every provider and registry option refused by name"

# The connection canary: a counting local listener on a loopback port
# of its own choosing, every proxy variable pointed at it, and the
# accepted twin run — zero connections observed.
canary_script="$scratch/canary.py"
cat >"$canary_script" <<'EOF'
import socket
import sys

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(16)
port = server.getsockname()[1]
state = sys.argv[1]
count = 0
with open(state, "w") as handle:
    handle.write("%d %d\n" % (port, count))
server.settimeout(300)
try:
    while True:
        try:
            connection, _ = server.accept()
            count += 1
            with open(state, "w") as handle:
                handle.write("%d %d\n" % (port, count))
            connection.close()
        except socket.timeout:
            break
except KeyboardInterrupt:
    pass
EOF
fresh
address=$(create_vault "$real_singular" "$scratch/run")
bundle="$scratch/run/bundle.json"
jq --arg addr "$address" '.signers = [$addr]' "$fixture" >"$bundle" \
  || setup_fail sign-canary-jq "jq could not rewrite the signers"
canary_state="$scratch/run/canary.state"
# A direct background child: `timeout` runs python3 itself, so `$!` is
# the process whose exit ends the listener, and the EXIT trap signals
# and waits for exactly that pid on every path.
timeout "$RUN_TIMEOUT" python3 "$canary_script" "$canary_state" &
canary_pid=$!
for _ in $(seq 1 50); do
  [ -f "$canary_state" ] && break
  sleep 0.1
done
[ -f "$canary_state" ] || setup_fail sign-canary "the counting listener never answered"
canary_port=$(cut -d' ' -f1 "$canary_state")
exec 9<"$scratch/run/passphrase"
canary_rc=0
bounded env PATH="$SANITISED_PATH" \
  http_proxy="http://127.0.0.1:$canary_port" \
  https_proxy="http://127.0.0.1:$canary_port" \
  HTTP_PROXY="http://127.0.0.1:$canary_port" \
  HTTPS_PROXY="http://127.0.0.1:$canary_port" \
  all_proxy="socks5://127.0.0.1:$canary_port" \
  ALL_PROXY="socks5://127.0.0.1:$canary_port" \
  "$real_singular" wallet sign --vault "$scratch/run/alice.vault" \
  --passphrase-fd 9 "$bundle" >"$scratch/run/canary.out" 2>"$scratch/run/canary.err" \
  || canary_rc=$?
exec 9<&-
[ "$canary_rc" -eq 0 ] \
  || fail sign-canary "sign through the proxies exit $canary_rc"
canary_count=$(cut -d' ' -f2 "$canary_state")
kill "$canary_pid" 2>/dev/null || true
wait "$canary_pid" 2>/dev/null || true
# The signalled pid is gone, and with it the listener; allow the
# reaping a moment before the check says so.
for _ in $(seq 1 20); do
  kill -0 "$canary_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$canary_pid" 2>/dev/null; then
  echo "SETUP-FAIL wallet-vault control 'sign-canary': the counting listener outlived the control" >&2
  exit 2
fi
canary_pid=""
[ "$canary_count" -eq 0 ] \
  || fail sign-canary "$canary_count connections reached the listener"
echo "control sign-canary: zero connections reached the counting listener"
if [ -z "$offline_kind" ]; then
  echo "control sign-offline: carried by the refusals and the canary (no namespace on this runner)"
fi

# --- submit: the offline refusals -------------------------------------
#
# `singular submit` takes no wallet key and no vault, and refuses a
# witness that verifies against no transaction of the bundle before it
# touches the chain. The node setting points at a counting listener of
# its own: every refusal must leave its count where it was, and the
# accepted twin — the witness that does verify — must reach it, which
# shows the listener counts the command's chain access.

submit_dir="$scratch/submit"
rm -rf "$submit_dir"
mkdir -p "$submit_dir"
fresh
address=$(create_vault "$real_singular" "$scratch/run")
jq --arg addr "$address" '.signers = [$addr]' "$fixture" >"$submit_dir/both.json" \
  || setup_fail submit-jq "jq could not rewrite the signers"
sign_run "$real_singular" "$scratch/run" "$submit_dir/both.json" "$submit_dir/sign.out" "$submit_dir/sign.err" \
  || setup_fail submit-sign "the witnesses were not written: $(head -1 "$submit_dir/sign.err")"
first_identity=$(jq -r '.transactions[0].identity' "$fixture")
second_identity=$(jq -r '.transactions[1].identity' "$fixture")
own_witness="$submit_dir/$first_identity.witness"
foreign_witness="$submit_dir/$second_identity.witness"
[ -f "$own_witness" ] && [ -f "$foreign_witness" ] \
  || setup_fail submit-witnesses "the sign run wrote no witness per transaction"
# The bundle holds the first transaction only: the second's witness
# verifies against nothing in it.
jq '.transactions = [.transactions[0]] | .command = "create"' "$submit_dir/both.json" >"$submit_dir/bundle.json" \
  || setup_fail submit-jq "jq could not cut the bundle"

submit_state="$submit_dir/canary.state"
timeout "$RUN_TIMEOUT" python3 "$canary_script" "$submit_state" &
canary_pid=$!
for _ in $(seq 1 50); do
  [ -f "$submit_state" ] && break
  sleep 0.1
done
[ -f "$submit_state" ] || setup_fail submit-canary "the counting listener never answered"
export SUBMIT_PORT
SUBMIT_PORT=$(cut -d' ' -f1 "$submit_state")
submit_count() { cut -d' ' -f2 "$submit_state"; }

# Submit one bundle against the counting listener: the run bounded.
submit_run() { # submit_run BINARY WITNESS OUT ERR [EXTRA...] -> rc
  local binary=$1 witness=$2 out=$3 err=$4 rc=0
  shift 4
  bounded env PATH="$SANITISED_PATH" "$binary" submit --witnesses "$witness" \
    --koios-url "http://127.0.0.1:$SUBMIT_PORT" --network-magic 1 "$@" \
    "$submit_dir/bundle.json" >"$out" 2>"$err" || rc=$?
  return $rc
}

# The submit refusal's assertions, shared with the planted-defect
# demonstrations: a non-zero exit, the cause named on standard output
# or standard error, no connection reaching the listener, and no
# submission in a printed receipt.
submit_refusal() { # submit_refusal OUT ERR RC CAUSE BEFORE AFTER -> the refusal, or none
  local out=$1 err=$2 rc=$3 cause=$4 before=$5 after=$6
  if [ "$rc" -eq 0 ]; then
    echo "exit 0"
    return 1
  fi
  if ! grep -q -- "$cause" "$out" "$err"; then
    echo "the refusal does not name $cause"
    return 1
  fi
  if [ "$after" -ne "$before" ]; then
    echo "$((after - before)) connections reached the listener"
    return 1
  fi
  if [ -s "$out" ] && ! jq -e '.submissions == []' "$out" >/dev/null 2>&1; then
    echo "the receipt names a submission"
    return 1
  fi
  return 0
}

for flag in --wallet-skey --vault --passphrase-fd; do
  before=$(submit_count)
  flag_rc=0
  submit_run "$real_singular" "$own_witness" "$submit_dir/flag.out" "$submit_dir/flag.err" "$flag" 9 || flag_rc=$?
  if ! refusal=$(submit_refusal "$submit_dir/flag.out" "$submit_dir/flag.err" "$flag_rc" "$flag" "$before" "$(submit_count)"); then
    fail submit-flags "$flag: $refusal"
  fi
done
echo "control submit-flags: the wallet key, the vault and the passphrase descriptor refused by name, nothing reached the chain"

before=$(submit_count)
foreign_rc=0
submit_run "$real_singular" "$foreign_witness" "$submit_dir/foreign.out" "$submit_dir/foreign.err" || foreign_rc=$?
if ! refusal=$(submit_refusal "$submit_dir/foreign.out" "$submit_dir/foreign.err" "$foreign_rc" "witness-for-a-different-body" "$before" "$(submit_count)"); then
  fail submit-foreign-witness "$refusal"
fi
echo "control submit-foreign-witness: refused by name before any connection"

# The accepted twin: the witness that verifies passes every offline
# check and goes on to read the chain — the listener counts it.
before=$(submit_count)
submit_run "$real_singular" "$own_witness" "$submit_dir/twin.out" "$submit_dir/twin.err" || true
[ "$(submit_count)" -gt "$before" ] \
  || fail submit-twin "the accepted witness never reached the chain: $(head -1 "$submit_dir/twin.err")"
echo "control submit-twin: the verifying witness passed the offline checks and reached the listener"

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
if refusal=$(second_create_refusal "$scratch/run/ow.out" "$scratch/run/ow.err" "$before" "$after" "$ow_rc"); then
  setup_fail planted-overwriting "the second-create control's assertions accept the observation; the variant did not fire"
fi
echo "control planted-overwriting: the defect fired and the second-create control refuses it: $refusal (rc $ow_rc)"

# Leaking: the defect must fire — create printing more than the address
# is exactly what the create control refuses.
fresh
leak=$(create_vault "$scratch/singular-leaking" "$scratch/run")
if refusal=$(create_refusal "$scratch/run/create.out" "$leak"); then
  setup_fail planted-leaking "the create control's assertions accept the observation; the variant did not fire"
fi
echo "control planted-leaking: the defect fired and the create control refuses it: $refusal"

# --- the sign family's planted defects --------------------------------
#
# An overwriting variant: a sign refused because a witness file exists
# has its obstacle removed and the sign retried — the defect the
# second-sign control refuses. An any-bundle variant: a sign refused
# for a bundle the checks refused still writes a witness file — the
# defect the tampered and foreign controls refuse.

cat >"$scratch/singular-witness-overwriting" <<'EOF'
#!/usr/bin/env bash
out=$("$real" "$@" 2>"$OW_ERR") || {
  if grep -q "already exists" "$OW_ERR" && [ "$1" = wallet ] && [ "$2" = sign ]; then
    vault=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--vault" ]; then vault=$a; fi
      prev=$a
    done
    dir=${vault%/*}
    rm -f "$dir"/*.witness
    exec 9<"$OW_PASS"
    "$real" "$@" 2>>"$OW_ERR"
    rc=$?
    exec 9<&-
    exit $rc
  fi
  cat "$OW_ERR" >&2
  exit 1
}
printf '%s' "$out"
EOF
chmod +x "$scratch/singular-witness-overwriting"

cat >"$scratch/singular-any-bundle" <<'EOF'
#!/usr/bin/env bash
out=$("$real" "$@" 2>"$AB_ERR") || {
  if grep -q -e "is not the hash of its body" -e "is not among the bundle's signers" "$AB_ERR" \
    && [ "$1" = wallet ] && [ "$2" = sign ]; then
    vault=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--vault" ]; then vault=$a; fi
      prev=$a
    done
    dir=${vault%/*}
    printf 'any-bundle-would-be-signed-here\n' >"$dir/0000.witness"
    printf 'witness/0000.witness\n' >"$OW_STDOUT" 2>/dev/null || true
    cat "$AB_ERR" >&2
    exit 1
  fi
  cat "$AB_ERR" >&2
  exit 1
}
printf '%s' "$out"
EOF
chmod +x "$scratch/singular-any-bundle"

# Overwriting: the defect must fire — the second sign succeeding, or
# the witnesses rewritten, is exactly what the second-sign control
# refuses.
export OW_ERR="$scratch/ow-sign.err"
fresh
address=$(create_vault "$real_singular" "$scratch/run")
bundle="$scratch/run/bundle.json"
jq --arg addr "$address" '.signers = [$addr]' "$fixture" >"$bundle" \
  || setup_fail planted-sign-overwrite "jq could not rewrite the signers"
sign_run "$real_singular" "$scratch/run" "$bundle" "$scratch/run/p1.out" "$scratch/run/p1.err"
p1_rc=$?
[ "$p1_rc" -eq 0 ] || setup_fail planted-sign-overwrite "the first sign failed: $(head -1 "$scratch/run/p1.err")"
before_planted=$(find "$scratch/run" -maxdepth 1 -name '*.witness' -exec sha256sum {} + | sort | sha256sum)
export OW_PASS="$scratch/run/passphrase"
p2_rc=0
sign_run "$scratch/singular-witness-overwriting" "$scratch/run" "$bundle" "$scratch/run/p2.out" "$scratch/run/p2.err" || p2_rc=$?
planted_written=$(find "$scratch/run" -maxdepth 1 -name '*.witness' 2>/dev/null | wc -l)
after_planted=$(find "$scratch/run" -maxdepth 1 -name '*.witness' -exec sha256sum {} + | sort | sha256sum)
if second_sign_refusal "$scratch/run/p2.out" "$scratch/run/p2.err" "$before_planted" "$after_planted" "$p2_rc" >/dev/null; then
  setup_fail planted-sign-overwrite "the second-sign control's assertions accept the observation; the variant did not fire"
fi
refusal_planted=$(second_sign_refusal "$scratch/run/p2.out" "$scratch/run/p2.err" "$before_planted" "$after_planted" "$p2_rc") || true
echo "control planted-sign-overwrite: the defect fired (rc $p2_rc, witnesses $planted_written) and the second-sign control refuses it: $refusal_planted"

# Any-bundle: the defect must fire — a witness file appearing after a
# refused bundle is exactly what the tampered and foreign controls
# refuse.
export AB_ERR="$scratch/ab-sign.err"
fresh
address=$(create_vault "$real_singular" "$scratch/run")
bundle="$scratch/run/bundle.json"
jq --arg addr "$address" \
  '(.transactions[0].envelope = .transactions[1].envelope) | .signers = [$addr]' \
  "$fixture" >"$bundle" || setup_fail planted-any-bundle "jq could not tamper the body"
ab_rc=0
sign_run "$scratch/singular-any-bundle" "$scratch/run" "$bundle" "$scratch/run/ab.out" "$scratch/run/ab.err" || ab_rc=$?
ab_written=$(find "$scratch/run" -maxdepth 1 -name '*.witness' 2>/dev/null | wc -l)
if [ "$ab_rc" -eq 0 ] || [ "$ab_written" -eq 0 ]; then
  setup_fail planted-any-bundle "the tampered control's assertions accept the observation; the variant did not fire"
fi
if refusal=$(sign_refusal "$scratch/run/ab.out" "$scratch/run/ab.err" "$scratch/run" "$ab_rc" "is not the hash of its body"); then
  setup_fail planted-any-bundle "the tampered control's assertions accept the observation"
fi
echo "control planted-any-bundle: the defect fired and the tampered control refuses it: $refusal (rc $ab_rc)"

# Chain-first: a submit that opens a connection to the node before it
# runs its checks — the defect the foreign-witness control refuses.
cat >"$scratch/singular-chain-first" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = submit ]; then
  exec 3<>"/dev/tcp/127.0.0.1/$SUBMIT_PORT" && exec 3>&-
fi
exec "$real" "$@"
EOF
chmod +x "$scratch/singular-chain-first"
before=$(submit_count)
cf_rc=0
submit_run "$scratch/singular-chain-first" "$foreign_witness" "$submit_dir/cf.out" "$submit_dir/cf.err" || cf_rc=$?
if refusal=$(submit_refusal "$submit_dir/cf.out" "$submit_dir/cf.err" "$cf_rc" "witness-for-a-different-body" "$before" "$(submit_count)"); then
  setup_fail planted-submit-chain-first "the foreign-witness control's assertions accept the observation; the variant did not fire"
fi
echo "control planted-submit-chain-first: the defect fired and the foreign-witness control refuses it: $refusal"

# Key-ignoring: a submit that drops the wallet key from its command line
# and runs on — the defect the flags control refuses.
cat >"$scratch/singular-key-ignoring" <<'EOF'
#!/usr/bin/env bash
kept=()
while [ $# -gt 0 ]; do
  if [ "$1" = --wallet-skey ]; then shift 2; continue; fi
  kept+=("$1")
  shift
done
exec "$real" "${kept[@]}"
EOF
chmod +x "$scratch/singular-key-ignoring"
before=$(submit_count)
ki_rc=0
submit_run "$scratch/singular-key-ignoring" "$own_witness" "$submit_dir/ki.out" "$submit_dir/ki.err" --wallet-skey 9 || ki_rc=$?
if refusal=$(submit_refusal "$submit_dir/ki.out" "$submit_dir/ki.err" "$ki_rc" "--wallet-skey" "$before" "$(submit_count)"); then
  setup_fail planted-submit-key-ignoring "the flags control's assertions accept the observation; the variant did not fire"
fi
echo "control planted-submit-key-ignoring: the defect fired and the flags control refuses it: $refusal"
kill "$canary_pid" 2>/dev/null || true
wait "$canary_pid" 2>/dev/null || true
canary_pid=""

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

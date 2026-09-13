#!/usr/bin/env bash
set -euo pipefail

if test "$#" -ne 4; then
  echo 'REBIND RED: usage: rebind.sh PRIOR_V3_RECEIPT FINAL_COMMAND CONTROL_ROOT NEW_RECEIPT_DIR' >&2
  exit 2
fi

prior=$1
command_file=$2
control_root=$3
receipt_dir=$4
identities="$prior/identities.txt"

expected_v3_gate='3e80f70d2a4450edf487f71a9183a2ef669cbc2bf9bb87bbc8139ef179e24749'
expected_prior_identities='3589febbb9b48f0f0742c5cf26226c4905f1fd8a917ffb658bf6c33bdf3f5711'
expected_prior_result='1d1f7b3d5e400039ccf9a0eabb3168b479330cd84f83c1c4c69684489c81cf41'
expected_command='1ce45ec8c3a6c16051929750e497bba35ada89f81c87f0ebb09e2d9885177842'
expected_control_index='c45bb22d9d9ff3c5ea192ba09e72990f85560f4db43c5b5e7f95b481ce80d535'

fail() { echo "REBIND RED: $1" >&2; exit 1; }
hash_of() { sha256sum "$1" | cut -d' ' -f1; }
identity() {
  local key=$1 value
  value=$(sed -n "s/^${key}=//p" "$identities")
  test -n "$value" || fail "missing prior identity $key"
  test "$(printf '%s\n' "$value" | wc -l)" -eq 1 || fail "duplicate prior identity $key"
  printf '%s' "$value"
}

test -f "$identities" || fail "missing prior v3 identities: $identities"
test -f "$prior/result.json" || fail 'missing prior v3 result.json'
test "$(hash_of "$identities")" = "$expected_prior_identities" || fail 'prior identities receipt drifted'
test "$(hash_of "$prior/result.json")" = "$expected_prior_result" || fail 'prior v3 result drifted'
test "$(cat "$prior/refusal-absent.exit")" = 1 || fail 'prior absent refusal exit is not 1'
test "$(cat "$prior/refusal-0.exit")" = 1 || fail 'prior zero refusal exit is not 1'
test "$(cat "$prior/result.exit")" = 0 || fail 'prior result exit is not 0'
test "$(cat "$prior/json-validation.exit")" = 0 || fail 'prior JSON validation exit is not 0'
rg -Fxq 'PREDEVNET CASES PASS: 22/22' "$prior/json-validation.stdout" || fail 'prior 22/22 receipt missing'
rg -Fxq 'PREDEVNET MUTANTS REJECTED: 5/5' "$prior/json-validation.stdout" || fail 'prior 5/5 receipt missing'
test "$(identity gate_sha256)" = "$expected_v3_gate" || fail 'prior receipt is not reviewed v3'

src_root=/tmp/t80e-rival-witness/offchain
test "$(hash_of "$src_root/journey/retirement/Main.hs")" = "$(identity driver_source_sha256)" || fail 'driver source changed since v3'
test "$(hash_of "$src_root/journey/retirement/RivalDriverLogic.hs")" = "$(identity logic_sha256)" || fail 'logic source changed since v3'
test "$(hash_of "$src_root/journey/retirement/RivalDriverPredevnetCheck.hs")" = "$(identity check_source_sha256)" || fail 'check source changed since v3'
test "$(hash_of "$src_root/cardano-mpfs-cage.cabal")" = "$(identity cabal_sha256)" || fail 'cabal file changed since v3'
driver_bin=$(identity driver_binary)
check_bin=$(identity check_binary)
test -x "$driver_bin" || fail 'prior -O0 driver binary is absent'
test -x "$check_bin" || fail 'prior -O0 check binary is absent'
test "$(hash_of "$driver_bin")" = "$(identity driver_binary_sha256)" || fail 'prior -O0 driver binary changed'
test "$(hash_of "$check_bin")" = "$(identity check_binary_sha256)" || fail 'prior -O0 check binary changed'

test -x "$command_file" || fail 'final official command is not executable'
test "$(hash_of "$command_file")" = "$expected_command" || fail 'final official command identity differs'
bash -n "$command_file" || fail 'final official command is not bash syntax clean'
test "$(rg -c '^[[:space:]]*env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL' "$command_file")" -eq 3 || fail 'official command does not have exactly three wrapper env launches'
test "$(rg -c '^[[:space:]]*"\$\{RETIREMENT_ROWS_WRAPPER\}"' "$command_file")" -eq 3 || fail 'official command does not invoke the pinned wrapper exactly three times'
if rg -q 'environment\.txt|env[[:space:]]*\|[[:space:]]*sort' "$command_file"; then
  fail 'official command retains a separate ambient environment dump'
fi

test "$(hash_of "$control_root/rival-command-control-INDEX.txt")" = "$expected_control_index" || fail 'command-control index drifted'
(
  cd "$control_root"
  sha256sum --check --strict <<'CHECKS'
5f939300e301045d24cddd3f3a3a92dc18291f557e837d8044fd18691d3ddf07  rival-command-control-stub.sh
4614844dd28edb264653a69074b5febb5d7ffce9226cfd8e2bc9b25270368458  rival-command-control-harness.sh
ce81363ccf40ada95f91f36e5d90942e217e34d466d73dfe116533fa1e6659ab  rival-command-control-positive.cmd-exit.txt
b1726f3a63b1ed526b10f1eae88e49d9cfa94f593a99ba7583b788618e03968b  rival-command-control-positive.out
c96032a8c375e9f1b0dc37952827a43a09325493df7972395fb617203a67edfe  rival-command-control-broken.cmd-exit.txt
907f344f54641228287f7478f67eff9440013e1a6c0022e14694da6f4705052f  rival-command-control-broken.out
bf20f81eb3b523e7fa40955fdd0ec63f6b0d751cfdddd53537ebebd899d14101  rival-command-control-mutation.cmd-exit.txt
79e800fa43e0f76d33f7b2eddd1c0abd1449f3acf2c2ff92a13c3474f4ecad9b  rival-command-control-mutation.out
c86afa24dbad0a6e07e8f43523898685d1c0ebaaf426d7b0c7088b92f8dc3d5b  rival-command-control-aggregate.cmd-exit.txt
487f7aeea0787965193e3444bbafe2f971ad007d7eb0ce8ed6bf697ef75fe156  rival-command-control-attempt1-failed-NO-CREDIT.txt
ed26ae2a7dea1c40abea913165f2b59916cb5dd5838e8662a41948dd3c7892a2  rival-command-control-stub-fields/copied-policy.fields
1a2efd956cdf67910a43ff0b2ea1d089dbbe181d440d6297c70a74f8aa632dcd  rival-command-control-stub-fields/forged-anchor.fields
6da018b5265e4a5cc5736f5aa8304340e110e8613fb5d8593f52eb76e1f3cbb3  rival-command-control-stub-fields/own-policy.fields
CHECKS
) >/dev/null || fail 'a retained command-control artifact drifted'
rg -Fxq 'PASS all-three-sites: exact declared assignments applied to the wrapper process' "$control_root/rival-command-control-positive.out" || fail 'three-site positive receipt missing'
rg -Fq 'broken-placement-harness-exit=1' "$control_root/rival-command-control-broken.cmd-exit.txt" || fail 'broken-placement rejection receipt missing'
rg -Fq 'mutation-harness-exit=1' "$control_root/rival-command-control-mutation.cmd-exit.txt" || fail 'one-site mutation rejection receipt missing'
rg -Fxq 'aggregate-failure-command-exit=1' "$control_root/rival-command-control-aggregate.cmd-exit.txt" || fail 'aggregate failure exit receipt missing'
rg -Fxq 'variant-exits: own-policy=0 copied-policy=7 forged-anchor=0' "$control_root/rival-command-control-aggregate.cmd-exit.txt" || fail 'aggregate per-variant receipt missing'

test ! -e "$receipt_dir" || fail "receipt directory already exists: $receipt_dir"
mkdir -p "$receipt_dir"
{
  printf 'rebind_gate_sha256=%s\n' "$(hash_of "$0")"
  printf 'prior_v3_gate_sha256=%s\n' "$expected_v3_gate"
  printf 'prior_v3_identities_sha256=%s\n' "$expected_prior_identities"
  printf 'prior_v3_result_sha256=%s\n' "$expected_prior_result"
  printf 'driver_source_sha256=%s\n' "$(identity driver_source_sha256)"
  printf 'logic_sha256=%s\n' "$(identity logic_sha256)"
  printf 'check_source_sha256=%s\n' "$(identity check_source_sha256)"
  printf 'cabal_sha256=%s\n' "$(identity cabal_sha256)"
  printf 'driver_binary_sha256=%s\n' "$(identity driver_binary_sha256)"
  printf 'check_binary_sha256=%s\n' "$(identity check_binary_sha256)"
  printf 'final_command_sha256=%s\n' "$expected_command"
  printf 'control_index_sha256=%s\n' "$expected_control_index"
  printf 'product_compile_executed=false\n'
  printf 'real_wrapper_executed=false\n'
  printf 'node_or_ledger_executed=false\n'
} >"$receipt_dir/identities.txt"
printf 'REBIND GREEN: unchanged v3 source/binaries bound to corrected unexecuted official command and retained shell controls\n' | tee "$receipt_dir/result.txt"

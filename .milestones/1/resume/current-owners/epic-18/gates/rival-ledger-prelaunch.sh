#!/usr/bin/env bash
set -euo pipefail

check_hash() {
  local expected=$1 path=$2 actual
  actual=$(sha256sum "$path" | cut -d' ' -f1)
  test "$actual" = "$expected" || {
    echo "PRELAUNCH RED: hash mismatch $path expected=$expected actual=$actual" >&2
    exit 1
  }
  printf '%s  %s\n' "$actual" "$path"
}

command_file=/tmp/t80e-rival-witness/handoffs/rival-ledger-command.sh
result_root=/tmp/t80e-rival-witness/handoffs/rival-ledger-results
genesis=/tmp/t80e-rival-witness/offchain/e2e-test/genesis

test ! -e "$result_root" || {
  echo "PRELAUNCH RED: guarded result root already exists: $result_root" >&2
  exit 1
}
bash -n "$command_file"
check_hash 1ce45ec8c3a6c16051929750e497bba35ada89f81c87f0ebb09e2d9885177842 "$command_file"
check_hash 87080bed3a39aa145b6415306859ae7fce55284bf1b3bf0cb273f33bab6842c2 /nix/store/phz7qfgh1vrlaxbdyr1qa6r8br8zjd6b-singular-naming-plutus-blueprint-0.1.0
check_hash f17bf35a72ec0ad906068c978d4f1ef2502c3f10a4742af561bec27b89219765 /nix/store/m8rvyvjh2fcz5akmnz4vwilk332n5cn1-mpf-plutus-blueprint-0.0.0
check_hash c594918a91a414366deee19cf33e40bb5624cefbcbaa5fc2a6112ff2c5ea2b72 /nix/store/6dg0qw4ckf4rqypp0svvwr7lxlvj7zdf-retirement-rows/bin/retirement-rows
check_hash 325f712520d79f3defb17ba535a78204053e877018df072f863234da2544f97a /nix/store/ijqlwm0v9sc2z0kwdwvr15hw88dyfkis-cardano-mpfs-cage-exe-retirement-rows-0.1.0.0/bin/retirement-rows
check_hash 30d969c644f758ffbb477f0534518ec0a2e31871478418c92d783e9b42614b88 /tmp/t80e-rival-witness/naming-onchain/script-identity.json
check_hash 5969dabf18248c56c1672e2a033e54bc199fa721e61da663aef723754188d21b /tmp/t80e-rival-witness/offchain/journey/retirement/Main.hs
check_hash db95a2320a6ba779e24e3f78e04c970f36b76771c9ec13e3e233695d333e144b /tmp/t80e-rival-witness/offchain/journey/retirement/RivalDriverLogic.hs
check_hash 9e288ffa96864cc991d1b1482c6123791dfacb85011a61efd348a15a0914fa02 /tmp/t80e-rival-witness/offchain/journey/retirement/RivalDriverPredevnetCheck.hs
check_hash bd85f5c7459937c1248132783cf8a91b39859376e48487180aa15fb5144d954c /tmp/t80e-rival-witness/offchain/cardano-mpfs-cage.cabal

genesis_observed=$(find "$genesis" -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
test "$genesis_observed" = 4f88e5f1d8b378dc92758c8e3d358f86c87d9945226e921c74335ad9d6e9e631 || {
  echo "PRELAUNCH RED: genesis aggregate mismatch actual=$genesis_observed" >&2
  exit 1
}
printf '%s  %s\n' "$genesis_observed" "$genesis"
printf 'PRELAUNCH GREEN: exact reviewed identities; guarded result root absent\n'

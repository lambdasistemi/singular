#!/usr/bin/env bash
# Tool, not a guarantee: fills the table from the hash of Singular's state
# contract to the releases that carry it, from the published release assets,
# so anyone can fill it again and compare. Nothing runs this in CI; the hosted
# check that the table holds the hash of the blueprint being built is the
# guarantee, and this script is how the rows were made.
#
# For each release tag of the repository, the on-chain archive of the GitHub
# release (singular-onchain-<version>.tar.gz) is downloaded and its blueprint
# (onchain/plutus.json) read. The state-contract hash is what a built
# `singular` computes from that blueprint when it loads it for --blueprint:
# the command `singular registry describe` is given the blueprint and a state
# token whose policy is the hash the blueprint states, and the program's own
# answer decides:
#   - a blueprint whose state contract is not the one the program pins is
#     refused with the hash the program computed, which is the row's hash;
#   - a blueprint whose state contract is the pinned one gets as far as the
#     provider, which is not there, so the policy was accepted as its hash.
# The hash the program computed must equal the one the blueprint states, read
# independently with jq, or the script stops.
#
# A release with no on-chain archive, or whose blueprint has no state
# validator, is left out and named with its reason in the file. The sha256 of
# each archive is recorded, so a later fill can be compared with this one.
#
# usage: tools/fill_contract_table.sh --singular BIN [--repo OWNER/NAME]
#          [--work DIR] [--out FILE] [--tags "v0.3.0 v0.4.0 ..."]
set -euo pipefail

repo=lambdasistemi/singular
singular=
work=
out=
tags=

while [ $# -gt 0 ]; do
  case "$1" in
    --singular)
      singular=$2
      shift 2
      ;;
    --repo)
      repo=$2
      shift 2
      ;;
    --work)
      work=$2
      shift 2
      ;;
    --out)
      out=$2
      shift 2
      ;;
    --tags)
      tags=$2
      shift 2
      ;;
    *)
      echo "fill_contract_table: unknown argument $1" >&2
      exit 2
      ;;
  esac
done

[ -x "$singular" ] || {
  echo "fill_contract_table: --singular names a built singular (got: ${singular:-nothing})" >&2
  exit 2
}
root="$(git rev-parse --show-toplevel)"
[ -n "$out" ] || out="$root/offchain/data/contracts/state-contracts.json"
[ -n "$work" ] || work="$(mktemp -d)"
mkdir -p "$work"
pinned_source="$root/offchain/cli/src/Singular/CLI/Permanent.hs"
pinned="$(grep -A1 '"state.state"' "$pinned_source" | grep -o '[0-9a-f]\{56\}')"
[ -n "$pinned" ] || {
  echo "fill_contract_table: no pinned state contract in $pinned_source" >&2
  exit 2
}

if [ -z "$tags" ]; then
  tags="$(gh release list --repo "$repo" --limit 200 --json tagName --jq '.[].tagName' | grep '^v[0-9]' | sort -V | tr '\n' ' ')"
fi

: >"$work/rows.tsv"
: >"$work/left-out.tsv"
: >"$work/archives.tsv"
zero="$(printf '%064d' 0)"

for tag in $tags; do
  version="${tag#v}"
  dir="$work/$tag"
  mkdir -p "$dir"
  asset="singular-onchain-$version.tar.gz"
  if ! gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$dir" --clobber >"$dir/download.log" 2>&1; then
    printf '%s\tthe release has no on-chain archive (%s)\n' "$tag" "$asset" >>"$work/left-out.tsv"
    echo "$tag: left out, no $asset"
    continue
  fi
  sha="$(sha256sum "$dir/$asset" | cut -d' ' -f1)"
  mkdir -p "$dir/archive"
  tar -xzf "$dir/$asset" -C "$dir/archive"
  blueprint="$(find "$dir/archive" -path '*/onchain/plutus.json' | head -n 1)"
  if [ -z "$blueprint" ]; then
    printf '%s\tthe on-chain archive holds no onchain/plutus.json\n' "$tag" >>"$work/left-out.tsv"
    echo "$tag: left out, no blueprint in the archive"
    continue
  fi
  stated="$(jq -r '[.validators[] | select(.title | startswith("state.state")) | .hash] | unique | if length == 1 then .[0] else "" end' "$blueprint")"
  if [ -z "$stated" ]; then
    printf '%s\tthe blueprint states no single state.state validator\n' "$tag" >>"$work/left-out.tsv"
    echo "$tag: left out, no single state.state validator"
    continue
  fi
  printf '%s\n' "$version" >"$(dirname "$blueprint")/version.txt"
  status=0
  "$singular" registry describe --blueprint "$blueprint" \
    --state-token "$stated.$zero" --koios-url http://127.0.0.1:9 \
    --network-magic 42 >"$dir/program.out" 2>&1 || status=$?
  if grep -q 'unknown permanent contract script state.state' "$dir/program.out"; then
    computed="$(grep -o 'unknown permanent contract script state.state: expected [0-9a-f]*, computed [0-9a-f]*' "$dir/program.out" | grep -o 'computed [0-9a-f]*' | cut -d' ' -f2)"
  elif grep -q 'unknown permanent contract script' "$dir/program.out"; then
    # the state contract was checked first and is the one the program pins
    computed="$pinned"
  elif grep -q 'could not be read\|BackendReadFailure\|ConnectionFailure' "$dir/program.out"; then
    # the policy the blueprint states was accepted as the state contract's hash
    computed="$stated"
  else
    echo "fill_contract_table: $tag: the program answered nothing this script knows (exit $status):" >&2
    cat "$dir/program.out" >&2
    exit 1
  fi
  if [ "$computed" != "$stated" ]; then
    echo "fill_contract_table: $tag: the program computed $computed, the blueprint states $stated" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$stated" "$tag" >>"$work/rows.tsv"
  printf '%s\t%s\n' "$tag" "$sha" >>"$work/archives.tsv"
  echo "$tag: the program computed $computed; the blueprint states $stated; archive sha256 $sha"
done

jq -n \
  --rawfile rows "$work/rows.tsv" \
  --rawfile left "$work/left-out.tsv" \
  --rawfile archives "$work/archives.tsv" \
  --arg repo "$repo" '
  def lines: split("\n") | map(select(length > 0) | split("\t"));
  def version: ltrimstr("v") | split(".") | map(tonumber);
  {
    note: ("From the hash of the state contract to the releases that carry it, oldest first. Made by tools/fill_contract_table.sh from the on-chain archive each release of " + $repo + " published (singular-onchain-<version>.tar.gz); the hash is the one a built singular computes from that blueprint, and it was checked against the one the blueprint states. The sha256 of each archive is under archives, so a later fill can be compared with this one. A release that is left out is named under left-out with its reason."),
    archives: ($archives | lines | sort_by(.[0] | version) | map({key: .[0], value: .[1]}) | from_entries),
    "left-out": ($left | lines | map({release: .[0], reason: .[1]})),
    rows: (
      $rows | lines | sort_by(.[1] | version)
      | reduce .[] as $r ([];
          if any(.[]; .["state-contract"] == $r[0])
          then map(if .["state-contract"] == $r[0] then .releases += [$r[1]] else . end)
          else . + [{"state-contract": $r[0], releases: [$r[1]]}]
          end)
    )
  }' >"$out"
echo "table written to $out"

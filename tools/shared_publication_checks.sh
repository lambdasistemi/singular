#!/usr/bin/env bash
# Shared predicates over independently decoded chain facts and command receipts.
# Sourced by the registration journey and the recovery partitions.
# Product predicates use check_shared_; bookkeeping has no such prefix.
# shellcheck disable=SC2016

# This state belongs to one sourced harness, on its calling thread, until
# that harness exits. Both successful and refusing executions are required.
declare -A shared_checks_seen=()
shared_check_result() {
  local name="$1" result=0
  shift
  "$@" || result=$?
  shared_checks_seen["$name:$result"]=1
  return "$result"
}

shared_publication_checks_covered() {
  local name count=0
  while IFS= read -r name; do
    count=$((count + 1))
    [ "${shared_checks_seen["$name:0"]:-}" = 1 ] && [ "${shared_checks_seen["$name:1"]:-}" = 1 ] || return 1
  done < <(compgen -A function check_shared_)
  [ "$count" -gt 0 ]
}

check_shared_independent_creation() { # RECEIPT TRANSACTION PUBLISHER-TRANSACTION REFERENCES-JSON
  shared_check_result "${FUNCNAME[0]}" jq -e -n --slurpfile receipt "$1" --slurpfile tx "$2" --slurpfile publisher "$3" --argjson refs "$4" '
    $receipt[0] as $r | $tx[0] as $t | $publisher[0] as $p
    | $r.outcome == "success"
    and [$r.submissions[].step] == ["create"]
    and all($r.submissions[]; .case == "included" and .observed == true)
    and [$r.scripts[].script] == ["state","application"]
    and all($r.scripts[]; .published == false and .outcome == "reused")
    and ([$t.referenceInputs[].ref] | sort) == ($refs | sort)
    and ($refs | length) == 2
    and all($t.outputs[]; .referenceScript == null)
    and ($t.signers | length) > 0
    and all($t.signers[]; . as $signer | $p.signers | index($signer) == null)
    and all($t.referenceInputs[]; .credential.hash as $owner | $t.signers | index($owner) == null)'
}

check_shared_no_witness_publication() { # ALL-TRANSACTIONS STATE-HASH APPLICATION-HASH
  shared_check_result "${FUNCNAME[0]}" jq -e --arg state "$2" --arg app "$3" '
    (.transactions | length) > 0
    and ([.transactions[].outputs[] | select(.referenceScript != null)] | length) > 0
    and all(.transactions[].outputs[] | select(.referenceScript != null);
      .referenceScript.hash == $state or .referenceScript.hash == $app)
    and ([.transactions[].outputs[] | select(.credential == {type:"script",hash:$app} and .datum.constructor == 0)] | length) > 0
    and all(.transactions[].outputs[] | select(.credential == {type:"script",hash:$app} and .datum.constructor == 0);
      (.datum.fields | length) == 1
      and .datum.fields[0].constructor == 0
      and (.datum.fields[0].fields | length) == 5
      and all(.datum.fields[0].fields[]; keys == ["int"]))' "$1"
}

check_shared_funding_conserved() { # ALL-TRANSACTIONS
  # Genesis values exceed exact IEEE-754 integers; sum native JSON integers.
  shared_check_result "${FUNCNAME[0]}" python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    transactions = json.load(stream)["transactions"]
if not transactions:
    sys.exit(1)
spent = set()
for tx in transactions:
    values = [item["lovelace"] for item in tx["inputs"] + tx["outputs"]]
    values += [tx["fee"], tx["donation"]]
    if any(type(value) is not int for value in values):
        sys.exit(2)
    supplied = sum(item["lovelace"] for item in tx["inputs"])
    paid = sum(item["lovelace"] for item in tx["outputs"]) + tx["fee"] + tx["donation"]
    if supplied != paid:
        print(f"unbalanced transaction {tx['id']}: {supplied} != {paid}")
        sys.exit(1)
    for item in tx["inputs"]:
        if item["ref"] in spent:
            sys.exit(1)
        spent.add(item["ref"])
print(f"funding conserved: {len(transactions)} transactions, {len(spent)} distinct inputs")
PY
}

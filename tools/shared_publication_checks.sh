#!/usr/bin/env bash
# Shared predicates over independently decoded chain facts and command receipts.
# Sourced by the registration journey and the recovery partitions.
# shellcheck disable=SC2016

independent_creation() { # RECEIPT TRANSACTION PUBLISHER-TRANSACTION REFERENCES-JSON
  jq -e -n --slurpfile receipt "$1" --slurpfile tx "$2" --slurpfile publisher "$3" --argjson refs "$4" '
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

no_witness_publication() { # ALL-TRANSACTIONS STATE-HASH APPLICATION-HASH
  jq -e --arg state "$2" --arg app "$3" '
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

funding_conserved() { # ALL-TRANSACTIONS
  jq -e '
    (.transactions | length) > 0
    and all(.transactions[];
      ([.inputs[].lovelace] | add) == (([.outputs[].lovelace] | add) + .fee + .donation))
    and ([.transactions[].inputs[].ref] as $spent | ($spent | length) == ($spent | unique | length))' "$1"
}

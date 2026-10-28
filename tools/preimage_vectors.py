#!/usr/bin/env python3
"""Write the Aiken tests that read the preimage byte vectors.

Usage: preimage_vectors.py TABLE.json OUT.ak

TABLE.json is the one committed table of byte vectors for the hashed-name
preimages of the Singular state (offchain/test/fixtures/preimage-vectors.json).
The off-chain suite reads it directly; the on-chain suite cannot read files, so
this script writes the Aiken module that holds the same bytes. The output is
formatted with the pinned Aiken by the caller, and the freshness check diffs
the formatted output against the committed module.
"""

import json
import sys

SOURCE = "offchain/test/fixtures/preimage-vectors.json"


def hexlit(value):
    return f'#"{value}"'


def snake(vector_id):
    return vector_id.replace("-", "_")


def registry(value):
    return (
        f"RegistryIdentity {{ policy: {hexlit(value['policy'])}, "
        f"name: {hexlit(value['name'])} }}"
    )


def credential(kind, digest):
    constructor = "VerificationKey" if kind == "key" else "Script"
    return f"{constructor}({hexlit(digest)})"


def address(value):
    payment = credential(*value["payment"])
    stake = value["stake"]
    if stake is None:
        stake_credential = "None"
    else:
        stake_credential = f"Some(Inline({credential(*stake)}))"
    return (
        f"Address {{ payment_credential: {payment}, "
        f"stake_credential: {stake_credential} }}"
    )


def state_test(vector):
    seed = vector["input"]["seed"]
    return f"""
test vector_{snake(vector["id"])}() {{
  let seed =
    OutputReference {{
      transaction_id: {hexlit(seed["transactionId"])},
      output_index: {seed["outputIndex"]},
    }}
  and {{
    cbor.serialise(State {{ seed }}) == {hexlit(vector["preimage"])},
    state_token_name(seed) == {hexlit(vector["name"])},
  }}
}}
"""


def active_test(vector):
    given = vector["input"]
    return f"""
test vector_{snake(vector["id"])}() {{
  let registry = {registry(given["registry"])}
  let key = {hexlit(given["key"])}
  and {{
    cbor.serialise(Active {{ registry, key }}) == {hexlit(vector["preimage"])},
    active_token_name(registry, key) == {hexlit(vector["name"])},
  }}
}}
"""


def configuration_test(vector):
    given = vector["input"]
    return f"""
test vector_{snake(vector["id"])}() {{
  let registry = {registry(given["registry"])}
  and {{
    cbor.serialise(ApplicationConfiguration {{ registry }}) == {hexlit(vector["preimage"])},
    configuration_token_name(registry) == {hexlit(vector["name"])},
  }}
}}
"""


def approval_test(vector):
    given = vector["input"]
    return f"""
test vector_{snake(vector["id"])}() {{
  let registry = {registry(given["registry"])}
  let key = {hexlit(given["key"])}
  let holding_address = {address(given["holdingAddress"])}
  let datum_hash = {hexlit(given["datumHash"])}
  let preimage =
    registration_preimage(
      key,
      registry,
      holding_address,
      datum_hash,
      {given["deposit"]},
    )
  and {{
    preimage == {hexlit(vector["preimage"])},
    approval_name(preimage) == {hexlit(vector["name"])},
  }}
}}
"""


def termination_test(vector):
    given = vector["input"]
    return f"""
test vector_{snake(vector["id"])}() {{
  let registry = {registry(given["registry"])}
  let key = {hexlit(given["key"])}
  let preimage = termination_preimage(key, registry)
  and {{
    preimage == {hexlit(vector["preimage"])},
    approval_name(preimage) == {hexlit(vector["name"])},
  }}
}}
"""


TESTS = {
    "state": state_test,
    "active": active_test,
    "configuration": configuration_test,
    "registration-approval": approval_test,
    "termination-approval": termination_test,
}


def distinct_test(label, values):
    items = ",\n    ".join(hexlit(value) for value in values)
    return f"""
test the_{label}_of_the_vectors_are_pairwise_distinct() {{
  let {label} = [
    {items},
  ]
  list.length(list.unique({label})) == list.length({label})
}}
"""


IMPORTS = {
    "state": (
        ["State", "state_token_name"],
        ["use cardano/transaction.{OutputReference}"],
    ),
    "active": (["Active", "RegistryIdentity", "active_token_name"], []),
    "configuration": (
        ["ApplicationConfiguration", "RegistryIdentity", "configuration_token_name"],
        [],
    ),
    "registration-approval": (
        ["RegistryIdentity", "approval_name", "registration_preimage"],
        ["use cardano/address.{Address, Inline, Script, VerificationKey}"],
    ),
    "termination-approval": (
        ["RegistryIdentity", "approval_name", "termination_preimage"],
        [],
    ),
}


def render(table):
    vectors = table["vectors"]
    roles = {vector["role"] for vector in vectors}
    unknown = roles - TESTS.keys()
    if unknown:
        raise SystemExit(f"preimage_vectors: no test for the roles {sorted(unknown)}")
    preimage_names = sorted({n for role in roles for n in IMPORTS[role][0]})
    uses = sorted({line for role in roles for line in IMPORTS[role][1]})
    head = [
        "//// The byte vectors of the hashed-name preimages, as Aiken tests.",
        "////",
        f"//// Generated from {SOURCE} by tools/preimage_vectors.py; do not edit.",
        "//// Every test builds a role's inputs, serialises them with the on-chain",
        "//// functions and compares the bytes and the name with the vector.",
        "",
        "use aiken/cbor",
        "use aiken/collection/list",
        *uses,
        "use singular_state/preimage.{" + ", ".join(preimage_names) + "}",
    ]
    body = [TESTS[vector["role"]](vector) for vector in vectors]
    body.append(distinct_test("preimages", [v["preimage"] for v in vectors]))
    body.append(distinct_test("names", [v["name"] for v in vectors]))
    return "\n".join(head) + "\n" + "".join(body)


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    with open(argv[1], encoding="utf-8") as handle:
        table = json.load(handle)
    with open(argv[2], "w", encoding="utf-8") as handle:
        handle.write(render(table))


if __name__ == "__main__":
    main(sys.argv)

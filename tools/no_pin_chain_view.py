#!/usr/bin/env python3
"""What the chain says, read independently of every command.

Reads the development network's own record of the chain, one block per line on
standard input (the lines whose kind is chain-sync-full-block), and takes
nothing from any command under test: not a receipt, not a journal. Two
questions are answered, each as one JSON document on standard output.

  no_pin_chain_view.py unspent [--asset POLICY[.NAME]] [--address ADDRESS]
      the outputs no later block spends, oldest first, optionally only those
      that carry the asset (every name of the policy when no name is given)
      or sit at the address

  no_pin_chain_view.py tx TXID
      the transaction as the chain holds it: the outputs it spent, read by
      reference, created, the signers whose witnesses it carries, its fee and
      its mint

An output is {ref, address, credential, lovelace, assets, datum, script}; the
credential is the address's payment credential, {type: key|script, hash}, read
from the address itself; the datum is the inline datum decoded to {constructor,
fields}, {int}, {bytes}, {list} or {map}. A script is true when the output
carries a reference script.

The transaction itself is read from its own bytes, which the record keeps next
to the material the facade derived from them.
"""

import hashlib
import json
import sys

BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def decode(data, at=0):
    """Return (value, next offset) of one CBOR item.

    Byte strings, text, arrays, maps (as lists of pairs), tags and the simple
    values a ledger transaction or a Plutus datum holds."""
    head = data[at]
    major, info = head >> 5, head & 31
    at += 1
    if info < 24:
        argument = info
    elif info == 24:
        argument, at = data[at], at + 1
    elif info == 25:
        argument, at = int.from_bytes(data[at : at + 2], "big"), at + 2
    elif info == 26:
        argument, at = int.from_bytes(data[at : at + 4], "big"), at + 4
    elif info == 27:
        argument, at = int.from_bytes(data[at : at + 8], "big"), at + 8
    elif info == 31:
        argument = None
    else:
        raise ValueError("unsupported additional information %d" % info)
    if major == 0:
        return argument, at
    if major == 1:
        return -1 - argument, at
    if major in (2, 3):
        if argument is None:
            chunks = b""
            while data[at] != 0xFF:
                chunk, at = decode(data, at)
                chunks += chunk
            return chunks, at + 1
        return data[at : at + argument], at + argument
    if major == 4:
        items = []
        if argument is None:
            while data[at] != 0xFF:
                item, at = decode(data, at)
                items.append(item)
            return items, at + 1
        for _ in range(argument):
            item, at = decode(data, at)
            items.append(item)
        return items, at
    if major == 5:
        pairs = []
        if argument is None:
            while data[at] != 0xFF:
                key, at = decode(data, at)
                value, at = decode(data, at)
                pairs.append((key, value))
            return ("map", pairs), at + 1
        for _ in range(argument):
            key, at = decode(data, at)
            value, at = decode(data, at)
            pairs.append((key, value))
        return ("map", pairs), at
    if major == 6:
        value, at = decode(data, at)
        if 121 <= argument <= 127:
            return ("constr", argument - 121, value), at
        if 1280 <= argument <= 1400:
            return ("constr", argument - 1280 + 7, value), at
        if argument == 102:
            return ("constr", value[0], value[1]), at
        if argument in (2, 3):
            number = int.from_bytes(value, "big")
            return (number if argument == 2 else -1 - number), at
        # a set (258), an embedded document (24) and the like: the content
        return value, at
    if major == 7:
        if info == 20:
            return False, at
        if info == 21:
            return True, at
        if info == 22:
            return None, at
        raise ValueError("unsupported simple value %d" % info)
    raise ValueError("unsupported major type %d" % major)


def as_data(value):
    """A decoded Plutus datum as JSON."""
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, int):
        return {"int": value}
    if isinstance(value, bytes):
        return {"bytes": value.hex()}
    if isinstance(value, list):
        return {"list": [as_data(item) for item in value]}
    if isinstance(value, tuple) and value[0] == "map":
        return {"map": [[as_data(k), as_data(v)] for k, v in value[1]]}
    if isinstance(value, tuple) and value[0] == "constr":
        return {
            "constructor": value[1],
            "fields": [as_data(field) for field in value[2]],
        }
    raise ValueError("not Plutus data: %r" % (value,))


def get(pairs, key):
    """The value a decoded CBOR map holds for an integer key, else nothing."""
    for k, v in pairs[1]:
        if k == key:
            return v
    return None


def credential(bech32):
    """The payment credential of a Shelley address: {type, hash}."""
    _, _, tail = bech32.rpartition("1")
    five = [BECH32.index(c) for c in tail[:-6]]
    bits = 0
    accumulator = 0
    out = bytearray()
    for group in five:
        accumulator = (accumulator << 5) | group
        bits += 5
        while bits >= 8:
            bits -= 8
            out.append((accumulator >> bits) & 255)
    header = out[0]
    kind = "script" if (header >> 4) in (1, 3, 5, 7) else "key"
    return {"type": kind, "hash": bytes(out[1:29]).hex()}


def output(raw):
    datum = raw.get("inline_datum")
    return {
        "ref": "%s#%d" % (raw["tx_hash"], raw["tx_index"]),
        "address": raw["payment_addr"]["bech32"],
        "credential": credential(raw["payment_addr"]["bech32"]),
        "lovelace": int(raw["value"]),
        "assets": [
            {
                "policy": a["policy_id"],
                "name": a["asset_name"],
                "quantity": int(a["quantity"]),
            }
            for a in raw["asset_list"]
        ],
        "datum": as_data(decode(bytes.fromhex(datum["bytes"]))[0]) if datum else None,
        "script": raw.get("reference_script") is not None,
    }


def blocks():
    for line in sys.stdin:
        if '"kind":"chain-sync-full-block"' not in line:
            continue
        event = json.loads(line)
        yield event["block"]


def unspent(asset, address):
    live = {}
    for block in blocks():
        for transaction in block["transactions"]:
            material = transaction["material"]
            for spent in material["inputs"]:
                live.pop("%s#%d" % (spent["tx_hash"], spent["tx_index"]), None)
            for created in material["outputs"]:
                live["%s#%d" % (created["tx_hash"], created["tx_index"])] = output(
                    created
                )
    wanted = []
    for each in live.values():
        if address is not None and each["address"] != address:
            continue
        if asset is not None:
            policy, _, name = asset.partition(".")
            if not any(
                a["policy"] == policy and (name == "" or a["name"] == name)
                for a in each["assets"]
            ):
                continue
        wanted.append(each)
    return {"outputs": wanted}


def transaction(txid):
    for block in blocks():
        for each in block["transactions"]:
            material = each["material"]
            if material["tx_hash"] != txid:
                continue
            tx, _ = decode(bytes.fromhex(each["cbor"]))
            body, witnesses = tx[0], tx[1]
            signers = []
            for pair in get(witnesses, 0) or []:
                signers.append(hashlib.blake2b(pair[0], digest_size=28).hexdigest())
            mint = []
            for policy, names in (get(body, 9) or ("map", []))[1]:
                for name, quantity in names[1]:
                    mint.append(
                        {
                            "policy": policy.hex(),
                            "name": name.hex(),
                            "quantity": quantity,
                        }
                    )
            return {
                "id": txid,
                "slot": block["slot"],
                "inputs": [output(i) for i in material["inputs"]],
                "referenceInputs": [output(i) for i in material["reference_inputs"]],
                "outputs": [output(o) for o in material["outputs"]],
                "signers": sorted(set(signers)),
                "fee": get(body, 2),
                "mint": mint,
            }
    sys.exit("the chain holds no transaction %s" % txid)


def main():
    arguments = sys.argv[1:]
    if arguments[:1] == ["unspent"]:
        asset = address = None
        rest = arguments[1:]
        while rest:
            if rest[0] == "--asset" and len(rest) > 1:
                asset, rest = rest[1], rest[2:]
            elif rest[0] == "--address" and len(rest) > 1:
                address, rest = rest[1], rest[2:]
            else:
                sys.exit(
                    "usage: no_pin_chain_view.py unspent [--asset P[.N]] [--address A]"
                )
        print(json.dumps(unspent(asset, address)))
    elif len(arguments) == 2 and arguments[0] == "tx":
        print(json.dumps(transaction(arguments[1])))
    else:
        sys.exit(
            "usage: no_pin_chain_view.py (unspent [--asset P[.N]] [--address A] | tx TXID)"
        )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""What a reader that trusts a registry's datum sees on the chain.

Reads the facade's independent record of the chain, one block per line on
standard input (the lines whose blocks carry transactions), and takes nothing
from any command under test. Given a registry's state token (policy and name,
hex) and a key (hex), it finds the registry's state output, reads the active
policy its datum pins, and lists every output that holds a token under that
policy named after the key. Prints one JSON object:

  {"stateOutput": "TXID#IX", "pins": {...}, "tokens": [...]}

The state datum is Plutus data in its CBOR form; the decoder below reads the
shapes Plutus data takes (constructors, lists, maps, integers, byte strings,
definite or indefinite) and nothing else.

usage: forged_pins_reader_view.py STATE_POLICY STATE_NAME KEY_HEX < blocks.jsonl
"""

import json
import sys


def decode(data, at=0):
    """Return (value, next offset) of one CBOR item."""
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
    if major == 2:
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
        count = argument if argument is not None else -1
        while count != 0 and data[at] != 0xFF:
            key, at = decode(data, at)
            value, at = decode(data, at)
            pairs.append((key, value))
            count -= 1
        return pairs, at + (1 if argument is None else 0)
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
        raise ValueError("unsupported tag %d" % argument)
    raise ValueError("unsupported major type %d" % major)


def constructors(value):
    """Every constructor in a decoded datum, outermost first."""
    if isinstance(value, tuple) and value and value[0] == "constr":
        yield value
        for field in value[2]:
            yield from constructors(field)
    elif isinstance(value, list):
        for item in value:
            yield from constructors(item)


def pins_of(datum_hex):
    """The two pinned policies of a state datum: the constructor of six
    fields whose last two are 28-byte policies, in the order the state
    declares them: application, active."""
    value, _ = decode(bytes.fromhex(datum_hex))
    for constr in constructors(value):
        fields = constr[2]
        if len(fields) == 6 and all(
            isinstance(f, bytes) and len(f) == 28 for f in fields[4:]
        ):
            application, active = (f.hex() for f in fields[4:])
            return {
                "application": application,
                "active": active,
            }
    raise ValueError("no state datum of six fields in this datum")


def main():
    state_policy, state_name, key_hex = sys.argv[1:4]
    holders = []
    state = None
    for line in sys.stdin:
        event = json.loads(line)
        for transaction in event["block"]["transactions"]:
            material = transaction["material"]
            for output in material["outputs"]:
                reference = "%s#%d" % (output["tx_hash"], output["tx_index"])
                assets = [
                    (a["policy_id"], a["asset_name"]) for a in output["asset_list"]
                ]
                if (state_policy, state_name) in assets:
                    datum = output.get("inline_datum")
                    if datum:
                        state = (reference, pins_of(datum["bytes"]))
                for policy, name in assets:
                    if name == key_hex:
                        holders.append(
                            {
                                "policy": policy,
                                "assetName": name,
                                "output": reference,
                                "address": output["payment_addr"]["bech32"],
                            }
                        )
    if state is None:
        sys.exit("no state output holds the state token")
    reference, pins = state
    print(
        json.dumps(
            {
                "stateOutput": reference,
                "pins": pins,
                "tokens": [t for t in holders if t["policy"] == pins["active"]],
                "namedAfterTheKey": holders,
            }
        )
    )


if __name__ == "__main__":
    main()

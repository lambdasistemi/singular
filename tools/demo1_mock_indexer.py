#!/usr/bin/env python3
"""A generated stand-in for the public indexers, for a take on a development node.

usage: demo1_mock_indexer.py MODE RECEIPTS_DIR PORTFILE LOG

The development node has no public indexer, so this one answers in the shapes
Koios and Blockfrost return (the ones tools/demo1_readback.sh reads), from the
newest `inspect` receipt a take has written to RECEIPTS_DIR *at the moment each
request arrives*: what the node read of the Active key is what an agreeing
indexer would say. It is a fixture, not a verdict: the comparison is made by
the readback script, and the take's verdict is recomputed from the record the
script keeps.

MODE says how the indexer disagrees, or that it does not:
  honest         answers exactly what the node read
  datum-changed  another datum, its hash recomputed so the answer is consistent
  other-output   another output reference
  behind         a tip far behind the node's chain point
  none           finds no output holding the asset

Every request is logged with the project key it carried; a Blockfrost request
without one is refused with 403, as the public service does.
"""

import glob
import hashlib
import http.server
import json
import os
import sys

mode, receipts, portfile, log = sys.argv[1:5]
ADDRESS = "addr_test1wzmockindexeraddress0000000000000000000000000000000000"


def blake(hex_bytes):
    return hashlib.blake2b(bytes.fromhex(hex_bytes), digest_size=32).hexdigest()


def newest_inspect():
    """The newest inspect receipt that read the key Active: its record."""
    best = None
    for path in sorted(glob.glob(os.path.join(receipts, "step-*.json"))):
        try:
            with open(path) as f:
                r = json.load(f)
        except (OSError, ValueError):
            continue
        cmd = r.get("command") or {}
        if r.get("action") == "run inspect" and cmd.get("leaf") == "active":
            best = r
    return best


def facts():
    r = newest_inspect()
    if r is None:
        return None
    cmd = r["command"]
    out = cmd["applicationOutput"]
    fields = out["envelope"]["fields"][0]["fields"]
    point = cmd["chainPoint"]
    tx, _, ix = out["output"].partition("#")
    cbor, given = out["datumCbor"], out["datumHash"]
    if mode == "datum-changed":
        cbor = cbor[:-2] + ("00" if cbor[-2:] != "00" else "01")
        given = blake(cbor)
    if mode == "other-output":
        tx = ("4d" * 32) if tx != "4d" * 32 else ("5e" * 32)
    slot = int(point.split(".")[0])
    if mode == "behind":
        slot = max(0, slot - 100000)
    return {
        "policy": fields[2]["bytes"],
        "name": cmd["key"],
        "tx": tx,
        "ix": int(ix),
        "cbor": cbor,
        "hash": given,
        "slot": slot,
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=None):
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.end_headers()
        if body is not None:
            self.wfile.write(json.dumps(body).encode())

    def serve(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        key = self.headers.get("project_id")
        with open(log, "a") as f:
            f.write("%s %s project_id=%s\n" % (self.command, self.path, key))
        fx = facts()
        if fx is None:
            return self.reply(404)
        unit = fx["policy"] + fx["name"]
        path = self.path
        if path == "/tip":
            return self.reply(
                200,
                [
                    {
                        "hash": "aa",
                        "epoch_no": 1,
                        "abs_slot": fx["slot"],
                        "block_height": 1,
                        "block_time": 1790796096,
                    }
                ],
            )
        if path == "/asset_utxos":
            asked = json.loads(body or b"{}").get("_asset_list", [])
            if [fx["policy"], fx["name"]] not in asked or mode == "none":
                return self.reply(200, [])
            return self.reply(
                200,
                [
                    {
                        "tx_hash": fx["tx"],
                        "tx_index": fx["ix"],
                        "address": ADDRESS,
                        "value": "2000000",
                        "block_height": 1,
                        "block_time": 1790796000,
                        "datum_hash": fx["hash"],
                        "inline_datum": {"bytes": fx["cbor"], "value": {}},
                        "asset_list": [
                            {
                                "policy_id": fx["policy"],
                                "asset_name": fx["name"],
                                "quantity": "1",
                            }
                        ],
                    }
                ],
            )
        # Blockfrost
        if not key:
            return self.reply(
                403, {"error": "Forbidden", "message": "Invalid project token."}
            )
        if path == "/blocks/latest":
            return self.reply(
                200, {"time": 1790796096, "height": 1, "hash": "aa", "slot": fx["slot"]}
            )
        if path == "/assets/%s/addresses" % unit:
            return self.reply(
                200, [] if mode == "none" else [{"address": ADDRESS, "quantity": "1"}]
            )
        if path == "/addresses/%s/utxos/%s" % (ADDRESS, unit):
            return self.reply(
                200,
                [
                    {
                        "address": ADDRESS,
                        "tx_hash": fx["tx"],
                        "tx_index": fx["ix"],
                        "amount": [
                            {"unit": "lovelace", "quantity": "2000000"},
                            {"unit": unit, "quantity": "1"},
                        ],
                        "block": "bb",
                        "data_hash": fx["hash"],
                        "inline_datum": fx["cbor"],
                        "reference_script_hash": None,
                    }
                ],
            )
        if path.startswith("/txs/"):
            return self.reply(
                200,
                {
                    "hash": fx["tx"],
                    "block_height": 1,
                    "block_time": 1790796000,
                    "slot": 1,
                },
            )
        return self.reply(404)

    do_GET = do_POST = serve


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()

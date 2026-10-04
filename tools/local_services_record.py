#!/usr/bin/env python3
"""Capture read-only local-service inputs; never submit a transaction.

HTTP observations are separate acquisitions. A successful capture requires the
same ledger tip and identical era/parameter bytes before and after the queries.
This is a content check, not an atomic-snapshot claim. Raw responses are retained
even when the capture refuses; an existing output directory is never replaced.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import urllib.request


def digest(content):
    return hashlib.sha256(content).hexdigest()


def save(root, name, content):
    path = root / name
    with path.open("xb") as handle:
        handle.write(content)
    return {"path": name, "sha256": digest(content), "bytes": len(content)}


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def capture(args):
    root = pathlib.Path(args.output)
    root.mkdir(parents=True, exist_ok=False)
    records = []

    def rpc(name, method, params=None):
        request = {"jsonrpc": "2.0", "method": method, "id": name}
        if params is not None:
            request["params"] = params
        records.append(save(root, name + ".request.json", encoded(request)))
        query = urllib.request.Request(
            args.endpoint,
            data=encoded(request),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(query, timeout=30) as response:
            content = response.read()
        records.append(save(root, name + ".response.json", content))
        result = json.loads(content)
        if result.get("id") != name or result.get("method") != method:
            raise ValueError("ResponseIdentityMismatch: " + name)
        if "error" in result:
            raise ValueError("SourceRefused: " + json.dumps(result["error"]))
        if "result" not in result:
            raise ValueError("MissingSourceResult: " + name)
        return result["result"]

    before = rpc("tip-before", "queryLedgerState/tip")
    start = rpc("system-start", "queryNetwork/startTime")
    eras = rpc("era-history", "queryLedgerState/eraSummaries")
    parameters = rpc("parameters", "queryLedgerState/protocolParameters")
    genesis = rpc("shelley-genesis", "queryNetwork/genesisConfiguration", {"era": "shelley"})
    if genesis.get("networkMagic") != args.network_magic:
        raise ValueError("WrongNetwork: source genesis magic differs")
    if not eras or "end" not in eras[-1]:
        raise ValueError("MissingFiniteHorizon: source did not supply a bound")
    after_eras = rpc("era-history-after", "queryLedgerState/eraSummaries")
    after_parameters = rpc("parameters-after", "queryLedgerState/protocolParameters")
    after = rpc("tip-after", "queryLedgerState/tip")
    if before != after:
        raise ValueError("SourcePointMoved: retain this refused capture and retry at a new path")
    if eras != after_eras or parameters != after_parameters:
        raise ValueError("SourceContextMoved: retained observations disagree")

    manifest = {
        "networkMagic": args.network_magic,
        "source": {"endpoint": args.endpoint, "identity": args.source_id},
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "observedPoint": before,
        "binding": "separate HTTP acquisitions with equal before/after context",
        "systemStart": start,
        "horizon": eras[-1]["end"],
        "records": records,
        "limits": [
            "No script evaluation captured by this command.",
            "No independent slot-conversion answer captured by this command.",
            "No atomic acquisition claimed.",
        ],
    }
    saved = save(root, "source-manifest.json", encoded(manifest))
    print(json.dumps(saved, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--network-magic", type=int, required=True)
    parser.add_argument("--output", required=True)
    capture(parser.parse_args())


if __name__ == "__main__":
    main()

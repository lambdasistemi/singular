#!/usr/bin/env python3
"""Record independent evaluation while the primary recorder holds its view.

Only read-only JSON-RPC methods are sent. Synthetic additional inputs are
explicit fixture facts, not chain UTxO or evidence of phase-one acceptance.
"""

import argparse
import hashlib
import json
import pathlib
import re
import urllib.error
import urllib.request


def capture(args):
    root = pathlib.Path(args.output)
    root.mkdir(exist_ok=False)
    fixtures = pathlib.Path(args.fixtures)
    context = pathlib.Path(args.context)
    records = []

    def save(name, content):
        with (root / name).open("xb") as handle:
            handle.write(content)
        records.append({"path": name, "sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)})

    def rpc(name, method, params=None, allow_script_error=False):
        request = {"jsonrpc": "2.0", "id": name, "method": method}
        if params is not None:
            request["params"] = params
        body = (json.dumps(request, sort_keys=True) + "\n").encode()
        save(name + ".request.json", body)
        query = urllib.request.Request(args.endpoint, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(query, timeout=30) as response:
                raw = response.read()
        except urllib.error.HTTPError as response:
            raw = response.read()
        save(name + ".response.json", raw)
        answer = json.loads(raw)
        if answer.get("id") != name or answer.get("method") != method:
            raise ValueError("ResponseIdentityMismatch: " + name)
        if "error" in answer and allow_script_error and answer["error"].get("code") == 3010:
            return answer
        if "error" in answer or "result" not in answer:
            raise ValueError("SourceRefused: " + name + " " + json.dumps(answer))
        return answer["result"]

    primary = json.loads((context / "node-source.json").read_bytes())
    point = re.fullmatch(r"Point \(At \(Block \{blockPointSlot = SlotNo (\d+), blockPointHash = ([0-9a-f]+)\}\)\)", primary["point"])
    if not point or primary["networkMagic"] != 1:
        raise ValueError("UnsupportedPrimarySourceIdentity")
    expected_point = {"slot": int(point[1]), "id": point[2]}
    before = rpc("tip-before", "queryLedgerState/tip")
    if before != expected_point:
        raise ValueError("SourcePointMoved: primary and independent evaluator differ")
    start = rpc("system-start", "queryNetwork/startTime")
    eras = rpc("era-history", "queryLedgerState/eraSummaries")
    parameters = rpc("parameters", "queryLedgerState/protocolParameters")
    genesis = rpc("network-genesis", "queryNetwork/genesisConfiguration", {"era": "shelley"})
    if genesis.get("networkMagic") != primary["networkMagic"]:
        raise ValueError("WrongEvaluatorNetwork")
    answers = []
    references = [{"transaction": {"id": char * 64}, "index": 0} for char in "abc"]
    chain_inputs = rpc("synthetic-input-collision-check", "queryLedgerState/utxo", {"outputReferences": references})
    if chain_inputs:
        raise ValueError("AdditionalInputConflictsWithChain")
    for name in ["success", "script-failure"]:
        params_raw = (fixtures / (name + ".params.json")).read_bytes()
        tx_raw = (fixtures / (name + ".cbor")).read_bytes()
        params = json.loads(params_raw)
        if params["transaction"]["cbor"] != tx_raw.hex() or len(params["additionalUtxo"]) != 3:
            raise ValueError("FixtureInputExtentMismatch")
        save(name + ".cbor", tx_raw)
        save(name + ".params.json", params_raw)
        answers.append(rpc(name, "evaluateTransaction", params, allow_script_error=True))
    after_parameters = rpc("parameters-after", "queryLedgerState/protocolParameters")
    after_eras = rpc("era-history-after", "queryLedgerState/eraSummaries")
    after = rpc("tip-after", "queryLedgerState/tip")
    if before != after or parameters != after_parameters or eras != after_eras:
        raise ValueError("SourceContextMoved: observations retained, no comparison accepted")
    for name in ["resolved-inputs.cbor"]:
        save(name, (fixtures / name).read_bytes())
    for name in ["protocol-parameters.cbor", "era-history.cbor", "node-source.json", "node-time-answers.json", "node-slot-starts.json"]:
        save(name, (context / name).read_bytes())
    manifest = {"networkMagic": 1, "sourceIdentity": args.source_id, "endpoint": args.endpoint,
                "point": before, "systemStart": start, "records": records,
                "binding": "primary view held; independent HTTP tip/context equal before and after",
                "limits": ["Additional inputs are synthetic fixture facts.", "No signature, phase-one acceptance, submission or inclusion claim."]}
    save("evaluation-manifest.json", (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode())
    print(json.dumps({"answers": answers, "point": before}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ["endpoint", "source-id", "output", "fixtures", "context"]:
        parser.add_argument("--" + option, required=True)
    capture(parser.parse_args())


if __name__ == "__main__":
    main()

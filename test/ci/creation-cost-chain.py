#!/usr/bin/env python3
"""Check the chain reader's creation measurements against full transaction bytes."""

import hashlib
import json
import runpy
import subprocess
import sys
from pathlib import Path


def main():
    reader = Path(__file__).resolve().parents[2] / "tools/no_pin_chain_view.py"
    decode = runpy.run_path(str(reader))["decode"]
    get = runpy.run_path(str(reader))["get"]
    source = Path(sys.argv[1]).read_text()
    transactions = [
        transaction
        for line in source.splitlines()
        if (event := json.loads(line))["kind"] == "chain-sync-full-block"
        for transaction in event["block"]["transactions"]
    ]
    measured = scripts = 0

    def reference_script(output):
        return get(output, 3) if isinstance(output, tuple) and output[0] == "map" else None

    for transaction in transactions:
        raw = bytes.fromhex(transaction["cbor"])
        decoded, end = decode(raw)
        assert end == len(raw), "transaction bytes were truncated"
        outputs = get(decoded[0], 1)
        if not any(reference_script(output) for output in outputs):
            continue
        result = subprocess.run(
            [sys.executable, "-I", str(reader), "tx", transaction["material"]["tx_hash"]],
            input=source,
            text=True,
            capture_output=True,
            check=True,
        )
        observed = json.loads(result.stdout)
        assert observed.get("sizeBytes") == len(raw), (
            "the chain reader does not report the complete transaction size"
        )
        assert len(observed["outputs"]) == len(outputs)
        for actual, output in zip(observed["outputs"], outputs, strict=True):
            embedded = reference_script(output)
            if embedded is None:
                assert actual.get("referenceScript") is None
                continue
            (language, script), script_end = decode(embedded)
            assert script_end == len(embedded)
            assert actual.get("referenceScript") == {
                "hash": hashlib.blake2b(bytes([language]) + script, digest_size=28).hexdigest(),
                "sizeBytes": len(script),
                "language": language,
            }, "the reference script's identity and size must come from its carried bytes"
            scripts += 1
        measured += 1
    assert measured > 1 and scripts > 1, "the chain-reader check exercised too little"
    print(f"creation-cost-chain: {measured} transactions and {scripts} scripts agree with chain bytes")


if __name__ == "__main__":
    main()

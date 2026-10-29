#!/usr/bin/env python3
"""Compare a measurement node with the recorded target's limits and prices.

The development node retains its own execution model. Only evaluation under
the recorded preprod parameters can decide the target's batch limit.
"""

import copy
import json
import sys
import urllib.request
from pathlib import Path


BOUNDING_FIELDS = (
    "maxTxSize",
    "maxTxExecutionUnits",
    "executionUnitPrices",
    "txFeeFixed",
    "txFeePerByte",
    "utxoCostPerByte",
    "minFeeRefScriptCostPerByte",
    "maxCollateralInputs",
    "collateralPercentage",
    "maxValueSize",
)


def differences(target, node):
    return [
        {"parameter": field, "target": target[field], "node": node.get(field)}
        for field in BOUNDING_FIELDS
        if target[field] != node.get(field)
    ]


def check_parameters(source, provider, output):
    recorded = json.loads(Path(source).read_text())
    target = json.loads(recorded["answer"]["body"])
    with urllib.request.urlopen(provider + "/cli_protocol_params", timeout=60) as reply:
        node = json.load(reply)
    # The control first restores all compared fields, then changes one real
    # parameter. This proves a permissive comparator cannot pass the job.
    equal = copy.deepcopy(node)
    equal.update({field: target[field] for field in BOUNDING_FIELDS})
    assert not differences(target, equal)
    changed = copy.deepcopy(equal)
    changed["maxTxExecutionUnits"]["memory"] += 1
    assert differences(target, changed), "altered node memory was not refused"
    report = {
        "target": target,
        "node": node,
        "sourceDate": dict(recorded["answer"]["headers"])["date"],
        "differences": differences(target, node),
        "control": "an altered node memory limit is refused",
    }
    Path(output).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    for item in report["differences"]:
        print(json.dumps(item, sort_keys=True), file=sys.stderr)
    assert not report["differences"], "the node's bounding parameters differ"


if __name__ == "__main__":
    check_parameters(*sys.argv[1:])

#!/usr/bin/env bash
# Receipt and page checks, including altered-chain, altered-figure, mismatched-leg
# and hosted-candidate controls, run by the packaged creation-cost-check app.
set -euo pipefail
python3 tools/creation-cost.py check
python3 tools/creation-cost.py controls
python3 test/ci/creation-carrying.py
for design in previous candidate; do
  python3 test/ci/creation-cost-chain.py "specs/745-shared-publications/evidence/$design-chain.jsonl"
done

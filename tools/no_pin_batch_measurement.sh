#!/usr/bin/env bash
# A private node's actual parameter answer is the first measurement boundary.
# shellcheck disable=SC2034 # the sourced rig consumes these arguments
set -euo pipefail
open_datum="$1"
devnet="$2"
blueprint_source="$3"
chain_view="$4"
parameter_source="$5"
work="$6"
rig_name=batch-measurement
# shellcheck source=tools/no_pin_rig.sh
source "$(dirname "$chain_view")/no_pin_rig.sh"

python3 -I "$(dirname "$chain_view")/no_pin_batch_measurement.py" \
  "$parameter_source" "$provider_url" "$work/node-parameters.json"

# No maximum is inferred from this parameter check. The kept transactions,
# their target evaluation and node corroboration are the remaining boundary.
say 'COULD-NOT-EVALUATE: batch limit, kept transactions, deterministic claim and committed receipt'
exit 1

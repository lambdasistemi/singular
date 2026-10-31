# Functions for hand-built transactions refused by the deployed validators

Issue 764, first slice. New and changed signatures only. Responsibilities are in [the modules model](modules-model.md) and
records in [the data model](data-model.md).

## Harness subcommands (`no-pin-refusals`, test-only)

| Name | Arguments | Result |
| --- | --- | --- |
| `fold` (existing) | `--case` one of `honest`, `second-registration`; `--pending` a booked registration, repeatable; shared flags | one JSON object: case, altered fact, outcome, answer, transaction |
| `update` (new) | `--case` one of `honest`, `no-controller-signature`; `--holding` the live holding reference; `--payload` the new payload file; shared flags | the same object |
| `leave` (new) | `--case` one of `honest`, `token-out`; `--holding` the live holding reference; shared flags | the same object |

The shared flags are those the existing subcommands take: the provider address, the network time, the network magic, the
wallet key, the blueprint and the state token. `honest` is the control of its case.

## Driver functions (`tools/no_pin_hand_built_refusals.sh`, new)

| Name | Arguments | Constraint |
| --- | --- | --- |
| `refused_by_script` | receipt, expected script hash | passes only on an explicit failure of that script's code, not an exhausted budget |
| `accepted` | receipt | passes only on the node's acceptance |
| `chain_holds_tx`, `chain_lacks_tx` | transaction identifier | read from the chain's own record; a missing identifier is never "lacks" |
| `register_key` | name, key | makes a registered key and returns its holding reference through the packaged commands |

The judging functions follow those of the termination refusals driver.

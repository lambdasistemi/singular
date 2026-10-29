# Fold pending requests from public data

As a folder, you find a registry's pending requests from public data without a
file from anyone who booked them. You fold as many as fit, keep each request's
value above what the application requires, and can read the measured limit
before deciding what to fold.

## Read the measured limits

These are evaluations of kept transactions under the preprod parameters
recorded on 4 October 2026 in
`offchain/test/fixtures/koios/preprod/cli_protocol_params-b777448425778d13.json`.
A development node given the same limits, prices and fees corroborates the
accepted size and refusal of the next. This is not a submission to preprod.
The packaged node cannot run preprod's current execution model; the ledger
evaluator uses the recorded target model separately. Protocol parameters can
change by governance.

The transaction slots use the captured development network's time. The result
is script evaluation under the recorded parameters, not preprod transaction
validation or inclusion. The fees are those of the kept node-balanced bodies,
not a quote for another network. Re-evaluating the same kept bytes reproduces
the figures; fresh captures may vary and publish their differences separately.

<!-- batch-limits:start -->

These figures are generated from the [kept measurement receipt](https://github.com/lambdasistemi/singular/blob/main/test/fixtures/batch-measurement/receipt.json).

| Binding | Recorded value |
|---|---|
| Receipt SHA-256 | `488ed245c81ad8cdfd0824358e9ea5d288de6a86e4ca9f77367a02562da1c25b` |
| Parameter recording date | Sun, 04 Oct 2026 18:06:12 GMT |
| Parameter source | [offchain/test/fixtures/koios/preprod/cli_protocol_params-b777448425778d13.json](https://github.com/lambdasistemi/singular/blob/main/offchain/test/fixtures/koios/preprod/cli_protocol_params-b777448425778d13.json) |
| Parameter source SHA-256 | `9df0ddb2f85a7fae3df18039bdd476d911605a680299e4d9228d59f232cb5276` |
| Evaluated parameter bytes SHA-256 | `49e19000ee0c4b8f7d289378b639693a987793fa5066f3080a83ad4013d6ef09` |
| Applied request script | `ScriptHash "67bb50e5aab678b9955e1d8981050a14e0f93da912b3a8b4a7161ca7"` |
| Applied state script | `ScriptHash "499291dbc77fb84b590e4f2d728788aa06191627a2c5c95b6bc4d679"` |
| Maximum transaction memory | 17500000 |
| Maximum transaction steps | 10000000000 |
| Maximum ledger-counted bytes | 16384 |

The largest accepted named prefix and the next refused size follow.
Bytes are the complete signed transaction length; ledger-counted bytes are listed separately. Fees are lovelace from the development-node-balanced transaction body.

| Kind | Accepted requests | Next refused requests | Exceeded limit | Memory | Steps | Signed bytes | Fee (lovelace) | Ledger-counted bytes |
|---|---|---|---|---|---|---|---|---|
| registrations | 4 | 5 | memory | 13885061 | 5776027854 | 3219 | 1778984 | 3218 |
| terminations | 7 | 8 | memory | 15700180 | 6342099593 | 4360 | 1974726 | 4359 |
| mixed | 6 | 7 | memory | 17100822 | 7047786150 | 4318 | 2104579 | 4317 |

Per-request figures are exact total divided by accepted count, including transaction overhead. A fraction is exact, not a rounded price.

| Kind | Memory per request | Steps per request | Signed bytes per request | Fee per request (lovelace) |
|---|---|---|---|---|
| registrations | 13885061/4 | 5776027854/4 | 3219/4 | 1778984/4 |
| terminations | 15700180/7 | 6342099593/7 | 4360/7 | 1974726/7 |
| mixed | 17100822/6 | 7047786150/6 | 4318/6 | 2104579/6 |

The marginal last request is the difference from the preceding kept prefix. It is an observation for this ordered workload, not a constant cost per request.

| Kind | Last-request memory | Last-request steps | Last-request signed bytes | Last-request fee (lovelace) |
|---|---|---|---|---|
| registrations | 5278981 | 2181128735 | 723 | 493675 |
| terminations | 3299339 | 1384499244 | 536 | 313780 |
| mixed | 3156357 | 1318646751 | 468 | 297789 |

The workload starts from the registry sizes below. The listed sequence is the accepted named prefix; the mixed result concerns that alternating order only. The digest binds the full initial datum shapes in the receipt, alongside the kept trie inputs.

| Kind | Pending pool | Registry size before fold | Key bytes | Accepted kind order | Initial datum shapes SHA-256 |
|---|---|---|---|---|---|
| registrations | 12 | 0 | 10 | registration, registration, registration, registration | d4754712e4097fd3acda3aa98bbb0b8004aa824be54824b34997b03b1a6f0f33 |
| terminations | 12 | 12 | 10 | termination, termination, termination, termination, termination, termination, termination | a17291318b46dbd97e13151f681e134e67617c6ee6db95065795e1dd9eb62b25 |
| mixed | 12 | 6 | 10 | registration, termination, registration, termination, registration, termination | 4864cdd37ec32e5d745738367f3a662ef49c0eac5d6690bf5df1f638637dbacb |

<!-- batch-limits:end -->

## What the measurement does not cover

The figures concern exactly the registry sizes, trie inputs, scripts, keys,
payload shapes and parameters in the receipt. They say nothing about another
registry size, trie depth, scripts, key or payload shapes, or parameters. The
mixed figure does not cover every ordering or every ratio of registrations to
terminations. The trie library's proofs are assumed sound.

The measurement job re-evaluates the kept transactions and captures a fresh
boundary for each kind. The documentation check regenerates the marked block
and refuses differences in either the page or the receipt. To refresh the
block explicitly, run `python3 tools/batch_limits.py --write`, then regenerate
the page's speech and changed narration. The [command reference](registry-commands.md#fold-registrations-and-terminations-into-the-registry)
describes discovery, explicit batches and receipts.

# Local verification receipt

Candidate: uncommitted worktree on `feat/protected-rejection`, based on
`6efe1f119a2332484e690b4c128c4bc5fd4d689b`.
Model.lean SHA-256: `d8aac373c739029eb80fb1d5bddaceaa0a8009d2cc851351863a075bf75a4d14`.
Toolchain: Lean 4.25.0.

- `lake build`: exit 0, all 35 jobs completed.
- `python3 tools/check_model.py`: exit 0 without export. All 58 registry
  statements and 79 total statements have compiled proofs using only standard
  axioms. The corpus contains 63 single-request cases and 20 batch cases.
- `check_transport.py`: exit 0; all 83 exported rows replayed through the real
  JSON entry point with matching outcomes, reasons and observations. A refused
  rejection cannot be converted into a settlement-only answer. Fourteen missing/null
  metadata controls fail decoding; rejection evidence on a fold also fails.
- `check_mutations.py`: exit 0; isolated baseline passed, and all eight definition
  mutants compiled through Model/Driver then failed executable corpus guards.
- `reproduce-historical.sh`: exit 0 against the immutable original model; the
  foldable request was rejected without a signer, returning only its deposit.
- `node simulator/mirror-check.mjs`: exit 0; 24 sources/manifests and the embedded
  corpus match their canonical bytes.
- `git diff --check`: exit 0.

The detailed [model gate output](model-check-receipt.txt),
[mutation receipt](mutation-receipt.json), [transport receipt](transport-receipt.json)
and [historical output](historical-receipt.txt) are retained beside this file.
Mutation and transport hashes were checked against the final sources.

These are local author checks. The first Opus source review found the timestamp
coherence gap; the repair and dispositions are in [review-followup.md](review-followup.md).
No full repository/hosted CI, exhaustive independent audit,
compiled-validator execution, live-chain protection, merge or release is claimed.
Refund correspondence remains unresolved under #361. See [the contract and
limits](README.md) before consuming this model candidate.

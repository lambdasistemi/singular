# Rival driver predevnet gate v1

This owner-owned gate admits a rival-driver source for renewed owner review. It is offline driver evidence only, never ledger or validator acceptance.

Inputs:

- isolated source root (normally `/tmp/t80e-rival-witness`);
- exact later ledger command file;
- `offchain/journey/retirement/Main.hs`;
- shared pure runtime module `offchain/journey/retirement/RivalDriverLogic.hs`;
- offline executable `rival-driver-predevnet-check` whose main imports that same module.

The production driver and the offline check must both call these shared decisions: `planMode`, `selectAnchor`, `checkRefusalLiveness`, `checkCopiedSuccessor`, and `selectLiveFunding`. Parallel copies or printed verdicts do not satisfy the gate.

The executable emits one JSON object with `schema = rival-driver-predevnet-v1`, `offline = true`, and arrays `cases` and `mutants`. Every case has `id` and `passed`; every mutant has `id` and `rejected`. Required cases:

- `normal-single-path`, `own-terminal-no-fallthrough`, `copied-terminal-no-fallthrough`, `forged-terminal-no-fallthrough`;
- `forged-no-rivalctx-reaches-submit`, `own-authentic-anchor`, `copied-authentic-anchor`;
- `refusal-both-inputs-live`, `refusal-record-missing`, `refusal-anchor-missing`;
- `successor-exact`, `successor-wrong-policy`, `successor-wrong-token`, `successor-wrong-quantity`, `successor-a-token-present`, `successor-wrong-txid`, `successor-wrong-address`, `successor-wrong-root`, `successor-old-anchor-live`;
- `funding-live-clean`, `funding-stale-input`, `funding-consumed-b-seed`.

The negative cases pass only when the shared runtime function refuses the bad observation. Required controlled mutants, each rejected by the same check:

- `drop-terminal-separation`;
- `ignore-record-liveness`;
- `ignore-anchor-liveness`;
- `ignore-successor-identity`;
- `accept-stale-funding`.

The gate statically binds both callers to the shared module, runs the offline executable, validates the complete denominator, and prints SHA-256 identities for the driver, shared logic, check source, cabal file, executable, JSON output, and exact later ledger command. Any missing/duplicate/unexpected result, non-boolean verdict, failed case, surviving mutant, source-binding failure, build/run failure, or absent command file is RED.

The gate must run with `RIVAL_OFFLINE_ONLY=1`; the check must refuse any other value. It must not start a node, query a socket, or submit a transaction. Passing this gate only returns the source for owner review; it does not lift the devnet fence.

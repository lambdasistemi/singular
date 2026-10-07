# Public-history replay verification, October 7

As a registry user, I want public history to rebuild the selected chain root
and supply valid proofs, or refuse incomplete or altered history by name.
This record establishes the independent replay checks. The two users joining
and operating through the actual CLI remain unexecuted under the stopped
token-joining dependency; see the [tasks](tasks.md).

## Source and model binding

The tested base is `d13a9594bc017dca98b786e73af6f22803c19ff8`, branch
`feat/381-two-terminals`. The tested source tree is
`1692101c7960420ebbc73fcffd4aa5ea43ad6823`: that base plus the fixture-only
repair in `offchain/test/Singular/CLI/IndependentActorsSpec.hs`, replacing
the former empty datum-hash argument with `Nothing`, the current representation
of a request carrying no datum. Assertions and production behavior are unchanged.
The fixture SHA256 is
`518a64952b458c12bc23e2d01dac46b4f5522896db495e1a34eebbd27467ad1f`.
The verification page, task marks and their speech companions follow execution;
they are not part of this tested source tree. No commit was created by this worker.

Lean revision is `bb9c21fa9f09eafb0cf8b69ee2ab3cd010762713`, binding
`Singular.step`, `exitStep`, `foldActions`, `buildFold` and the public-fold-input
statements. Replay calls `walkEdge`; rejected actions leave the trie unchanged.
A mixed fold's oracle is the compiled state validator accepting its submitted
transaction on the devnet. No whole-transaction Lean correspondence is claimed
for a mixture of applied and rejected requests.

## Commands and observed results

All commands ran serially. From the repository root, each focused component
used the following command with the exact description in the table:

```bash
nix run ./offchain#cage-tests -- --match "$description" --fail-on=empty
```

| Exact description | Examples | Failures | Exit | Runtime log |
| --- | ---: | ---: | ---: | --- |
| Two actors use public component facts without a joining fixture | 11 | 0 | 0 | independent-actors.log |
| An acquired session supplies the registry trie | 21 | 0 | 0 | lineage.log |
| TrieState capability contract (pure State over MPF nodes) | 36 | 0 | 0 | trie-contract.log |

The compiled-validator scope used a freshly resolved blueprint:

```bash
# From the repository root:
nix build --no-link --print-out-paths ./onchain#plutus-blueprint
# Build output (a blueprint file):
# /nix/store/7q89jqqn42jhfgg7g5scvinh9zmk51n1-mpf-plutus-blueprint-0.0.0
cd offchain
REGISTRY_BLUEPRINT=/nix/store/7q89jqqn42jhfgg7g5scvinh9zmk51n1-mpf-plutus-blueprint-0.0.0 \
  nix run /code/singular-381-registry-replay/offchain#cage-tests-e2e -- \
  --match "Rebuilding a registry's trie from its public history" --fail-on=empty
```

Blueprint build exit was zero. Its SHA256 is
`c3d2074d399ed0f6b98a87465128e31732ef9283e5119c67dbeb577cd212cbae`.
The E2E command exited zero: **48 examples, zero failures, no pending examples**,
in 41.8457 seconds. `replay-e2e-offchain.log` retains submitted transaction
identifiers and all example outcomes. Its SHA256 is
`ef7e39cc229c80d20d3a45c5ab2d2750f173af36baeb2f69782609134aa9ea9c`.
This is the same packaged wrapper and `offchain` working directory used by
the hosted registry workflow; this execution is local, not a hosted CI receipt.

## What the executed replay establishes

`ReplayHistory.recordHistory` makes a registry on the development network,
then records insertion, termination, rejection and mixed folds. Expected roots
come from their accepted state outputs. `ReplaySpec` compares replay to those
roots at create and after every fold; its acquired-session backend also checks
coverage, immutable speculation and fresh history reads after accepted folds.

The mixed fold applies one own-token request and rejects the others. Applying
every request or pairing actions in booking order produces a different root.
Booking order differs from ledger input order; another registry's spent request
and an own-token reference input are present without consuming these actions.
Reordered actions are refused by the root check.

The altered-edge control returns `RootDoesNotChain` and identifies the fold.
Dropped folds, missing create and withheld history return `HistoryIncomplete`;
the backend serves no prior snapshot when a fold is withheld. Forked history,
unresolved inputs, wrong identities, stale selections and invalid material are
also refused by the executed scope. Failed-script copies are excluded using
their CBOR validity flag.

At every state output, every history key has exactly one verifying membership
or non-membership result under the independent proof verifier. Proofs from a
previous trie fail to establish a changed root; a proof with one corrupted step
fails verification. The 36 capability examples separately exercise all seven
edge cases with MPF producer fixtures, proof negatives and unchanged snapshots.
Those fixtures are component evidence, not seven-edge ledger lifecycles.

## Appendix: actor controls and setup failures

Each wired actor control ran from the repository root with:

```bash
SINGULAR_TWO_ACTOR_UNIT_CONTROL="$control" nix run ./offchain#cage-tests -- \
  --match 'Two actors use public component facts without a joining fixture' \
  --fail-on=empty
```

| Control | Examples | Failures | Exit | Observed detection |
| --- | ---: | ---: | ---: | --- |
| withhold-fold | 11 | 1 | 1 | HistoryIncomplete instead of a successful root |
| fold-own-key | 11 | 2 | 1 | Wrong speculative root or already-terminal leaf |
| foreign-controller | 11 | 2 | 1 | Controller ClientRefusal |
| foreign-reclaim-owner | 11 | 2 | 1 | NotOwner instead of admitted bounds |
| refund-to-folder | 11 | 2 | 1 | WrongRecipient instead of the owner's refund |

These are expected behavioral failures, retained as `fault-<control>.log`.
With the control unset, the restored actor check exited zero with 11 examples
and zero failures (`actors-restored.log`). They exercise component decisions;
they do not submit cross-actor CLI folds or prove joining and refunds on chain.

The historical pre-repair compilation failed at the fixture argument and ran
zero tests (`pre-repair-build.log`). An initial E2E invocation used
`nix run ./offchain#cage-tests-e2e` from the repository root with the same
blueprint and match. It exited one because the before-all hook could not locate
`e2e-test/genesis/alonzo-genesis.json`: 48 selected examples, one setup failure,
47 pending and zero behavioral passes (`replay-e2e.log`). The successful retry
changed only the working directory and flake path, matching hosted CI.
Neither setup failure is behavioral RED. A local automation attempt also found
`python3` absent before invoking any test; the serial checks then used Bash.

Logs, exit files, `components.sh`, `tested-source.tree` and the SHA256 manifest
`logs.sha256` are retained under
`/home/paolino/.orch-runtime/singular/epic-371/finish-381-20261007/sol-replay`.

## Remaining acceptance

The executed scope establishes the replay and proof verification tasks only.
Token-only joining, both users' real CLI lifecycles and cross-actor insertion
folding, actual actor-provider fault controls, public row receipts, remaining
documentation reconciliation, the complete packaged journey, repository-wide
checks and exact-head hosted CI remain outstanding. This is a worker handback
for owner verification, with no independent auditor commissioned and no
ticket-wide acceptance, push or merge claimed.

# journey — the bounded MPFS cage journey, narrated

One command runs the bounded journey against a real devnet node and
narrates it, one line per step. This is epic 16's runnable artifact.

**Scope, stated plainly.** What runs today is the **MPFS cage journey**
— boot a cage, submit a request, apply it, read the resulting state
back. It is the vehicle for Singular's naming claim, **not the claim**:
nothing this runner prints describes a name as claimed, registered or
maintained, because no Singular naming-claim behaviour exists yet.
Later epic children put Singular's journey inside this runner; until
then the artifact demonstrates the substrate, and says so.

## What it does today, step by step

Every step below is performed by `offchain/journey/Main.hs` in this
exact order. A step that failed to happen here would be a defect in
this document.

0. **Identity header.** Reads `onchain/script-identity.json` (path
   from `MPFS_SCRIPT_IDENTITY`, default `../onchain/script-identity.json`)
   and prints the upstream source revision and every pinned validator
   hash, each labelled **unapplied** with the validator's parameter
   count. The pins are the reviewable blueprint identities (#34) —
   not the hashes a transaction carries: the on-chain scripts are
   parameterized (state 1 parameter, request 2, staking 0), and
   applying parameters changes the hash.
1. **Start a real devnet.** Spawns `cardano-node` (found on `PATH`;
   the Nix wrapper supplies the locked node) with generated genesis,
   connects over node-to-client, and verifies the connection by
   querying protocol parameters and the genesis wallet.
2. **boot.** Builds the boot transaction with the library's
   `bootTokenImpl` (state and request validator bytes come from the
   blueprint at `MPFS_BLUEPRINT`), signs with the genesis key,
   submits, waits for confirmation, derives the cage token id from the
   mint, registers the token's trie, and observes the state UTxO at
   the cage address. It reads the boot state datum and records the
   trie root.
3. **request.** Builds an insert request (`key=hello`, `value=world`,
   fee 1,000,000 lovelace) with `requestInsertImpl`, signs, submits,
   and observes exactly one request UTxO at the token's request
   address.
4. **verify-absent.** Before the insert is applied, proves the key is
   absent from the authenticated state: builds the key's exclusion
   proof, folds it to the root it implies, and compares that root
   against the root read back from the chain's state datum. Prints
   `proved absent` with the matched root; any mismatch fails the run.
5. **apply.** Acts as the oracle: builds the update with
   `updateTokenImpl` (proof from the trie manager), signs, submits,
   and observes the request UTxO being consumed.
6. **derived-applied-identity.** Ties the two identity layers
   together. First requires each pinned unapplied hash to equal the
   hash of the blueprint's raw code this run actually loaded. Then
   applies this instance's parameters to the unapplied code —
   `previousPolicies=[]` for the state validator; `statePolicyId`
   (the applied state hash) and `cageToken` for the request
   validator; nothing for staking — hashes the result, and requires
   the boot transaction's script witness to hold exactly the derived
   state script and the update transaction's witness exactly the
   derived state and request scripts. Prints each validator's
   **applied** hash alongside its unapplied pin and its parameters;
   any mismatch fails the run naming both hashes and the parameters
   used.
7. **verify-present and the negative case.** After the apply, proves
   the key is present with the expected value: replays the applied
   insert into the proof mirror, binds the claimed value into the
   inclusion proof, folds it, and compares against the chain-read
   root (`proved present`). Then asserts a value the state does not
   hold and requires the fold to differ from that root
   (`rejected false claim`) — a negative case that would pass is
   itself a defect and fails the run.
8. **read-back.** Queries the cage address, decodes the state UTxO's
   inline datum, and prints the resulting on-chain state: the trie
   root (verifying it moved from the boot root — the applied request
   is on chain), max fee, processing window, retract window and stake
   script.
9. **negative section — the validators must refuse.** These are
   **MPFS cage** negative cases, exercised against a real devnet in
   the same run; no Singular naming behaviour is involved. A second,
   unapplied insert request is submitted (`reject-request`), the
   applied insert is replayed into the trie manager so its proofs
   stand on the root the chain actually has, and the valid oracle
   update is built but never submitted. Four single-defect mutants
   of it are derived and each must be refused by the node for the
   matched reason (a phase-2 `PlutusFailure` naming the expected
   validator's script hash):
   - `reject-forged-identity` — the request's `Contribute` redeemer
     is rewritten to name the request UTxO itself as the state UTxO;
     it carries no state token, and `request.request.spend` refuses
     it (the script-integrity hash is re-stamped so ledger phase 1
     stays valid).
   - `reject-tampered-output` — the new state output keeps the exact
     `StateDatum` shape but its root is the byte complement of the
     root the proofs certify; `state.state.spend` refuses it (same
     size, so fee and min-UTxO rules still hold).
   - `reject-missing-proof` — the Merkle proof witness is dropped
     from the `Modify` action (re-cut under issue #79 from
     `reject-missing-witness`, which dropped the owner signature and
     required a refusal the repaired validator rightly no longer
     gives: Lean's `.fold` states no owner hypothesis). A fold whose
     demanded witness is absent must be refused, and
     `state.state.spend` refuses it.
   - `reject-end-without-owner` — the owner signature is dropped from
     an `End` spend, so the ledger no longer demands the vkey witness
     and phase 1 passes; `state.state.spend`'s ownership check (kept
     on `End` by the repair) refuses it. After the repair this is the
     only owner-authorization negative control.
   A transaction accepted by the node fails the run naming the guard
   that did not hold; a rejection that does not match the expected
   reason fails the run naming what came back. Afterwards
   (`reject-control`) the authenticated state is re-read and must be
   **unchanged** — a rejected evaluation never applies, so the
   rejected transactions left no trace.

Every verification compares a folded proof against the root read back
from the chain (D-013) — never against a root this runner derived
from the same trie.

Each step prints one line: what was done and the observable result
(transaction id, UTxO counts, roots). Exit status is `0` only when all
journey steps — including all three verifications — succeed; any
failure — a rejected transaction, a verification mismatch, a missing
observable, a bad blueprint — prints `journey: FAILED: ...` and exits
non-zero.

## Running it

The hermetic path (D-011) — no ambient `cabal`, no package index, no
warm developer state. From `offchain/`:

```sh
blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
MPFS_BLUEPRINT="$blueprint" nix run --quiet .#journey
```

The app is the Nix-built `journey` binary wrapped with the locked
`cardano-node` on its `PATH` (same wrapping as `cage-tests-e2e`).
The blueprint is always built fresh from the onchain flake at run
time; no store path is baked in.

Environment:

| Variable              | Required | Meaning                                              |
|-----------------------|----------|------------------------------------------------------|
| `MPFS_BLUEPRINT`      | yes      | Path to the built `plutus.json` blueprint            |
| `MPFS_SCRIPT_IDENTITY`| no       | Path to `script-identity.json` (default `../onchain/script-identity.json`) |

CI runs the same thing as the `journey` job in
`.github/workflows/mpfs.yml`, after the blueprint job, and fails when
the run fails.

## What it is not

- It is **not** a Singular demonstration. No output line names
  anything as claimed, registered or maintained.
- It is **not** a test suite. The E2E suite in `e2e-test/` covers the
  six cage scenarios; the journey runs one happy-path narrative using
  the same builders and a real node.
- It does not touch the onchain tree: the blueprint and the identity
  manifest are read at run time.

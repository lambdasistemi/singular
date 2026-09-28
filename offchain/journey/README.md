# journey — the bounded registry journey, narrated

One command runs the bounded journey against a real devnet node and
narrates it, one line per step. This is epic 16's runnable artifact.

**Scope, stated plainly.** What runs today is the **registry journey**
— boot a cage, submit a request, apply it, read the resulting state
back. It is the vehicle for Singular's naming claim, **not the claim**:
nothing this runner prints describes a name as claimed, registered or
maintained, because no Singular naming-claim behaviour exists yet.
Later epic children put Singular's journey inside this runner; until
then the artifact demonstrates the substrate, and says so.

## What it does today, step by step

Every step below is performed by the `journey` command in this exact
order. Its entry file `offchain/journey/Main.hs` only reports failure;
the order lives in `Journey.Scenario`, and each step in the module that
owns it: the identity header and step 6 in `Journey.Identity`, boot,
request, apply and read-back in `Journey.Steps`, the two proof checks
and the false claim in `Journey.Proofs`, and the refused transactions
and their unchanged-state control in `Journey.Controls` (all under
`offchain/journey/Journey/`; see
[Who owns a registry command](../../docs/offchain-command-entrypoints.md)).
A step that failed to happen here would be a defect in this document.

0. **Identity header.** Reads `onchain/script-identity.json` (path
   from `REGISTRY_SCRIPT_IDENTITY`, default `../onchain/script-identity.json`)
   and prints the upstream source revision and every pinned validator
   hash, each labelled **unapplied** with the validator's parameter
   count. The pins are the reviewable blueprint identities (#34) —
   not the hashes a transaction carries: of the on-chain scripts only
   the request validator is parameterized (state 0 parameters,
   request 2, staking 0), and applying its parameters changes its
   hash.
1. **Start a real devnet.** Spawns `cardano-node` (found on `PATH`;
   the Nix wrapper supplies the locked node) with generated genesis,
   connects over node-to-client, and verifies the connection by
   querying protocol parameters and the genesis wallet.
2. **boot.** First publishes the state validator as a reference
   output and picks the boot seed from a wallet output that is not
   that publication. Then builds the boot transaction with the
   library's `bootTokenImpl` (state and request validator bytes come
   from the blueprint at `REGISTRY_BLUEPRINT`), signs with the funding
   key, submits, waits for confirmation, derives the cage token id from
   the mint, registers the token's trie, and observes the state UTxO at
   the cage address. It reads the boot state datum and records the
   trie root. It then publishes the reference outputs every later
   transaction resolves its scripts through (`references`).
3. **request.** Books the insert with `Edges.bookEdge`: an
   `insertAbsent` edge for `key=hello` whose leaf value is the
   library's absent leaf (printed `value=00`), certified by the approval
   the open application mints, carried to the request address by the
   request transaction. Observes exactly one request UTxO at the
   token's request address.
4. **verify-absent.** Before the insert is applied, proves the key is
   absent from the authenticated state: builds the key's exclusion
   proof, folds it to the root it implies, and compares that root
   against the root read back from the chain's state datum. Prints
   `proved absent` with the matched root; any mismatch fails the run.
5. **apply.** Acts as the oracle: folds the booked request with
   `updateTokenWithDuties`, its registry context resolved through the
   published references by `Edges.registryContextFor` (proof from the
   trie manager), signs, submits, and observes the request UTxO being
   consumed.
6. **derived-applied-identity.** Ties the two identity layers
   together. First requires each pinned unapplied hash to equal the
   hash of the blueprint's raw code this run actually loaded. Then
   applies this instance's parameters to the unapplied code —
   `statePolicyId` (the state hash) and `cageToken` for the request
   validator; nothing for the state and staking validators, whose
   applied hash is the raw code's hash — hashes the result, and
   requires the scripts the boot transaction carried (in its witness
   set or through the reference outputs it resolved) to be exactly the
   state script, and those the update transaction carried to be
   exactly the state and request scripts and the three witness
   policies this registry pins. Prints each validator's **applied**
   hash alongside its unapplied pin; any mismatch fails the run naming
   both hashes and the parameters used. The state line still prints
   `previousPolicies=[]` and `(1 parameter)`: existing narration kept
   byte for byte, not the state validator's arity, which the manifest
   pins as 0.
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
   is on chain), max fee, processing window and retract window.
9. **negative section — the validators must refuse.** These are
   **registry** negative cases, exercised against a real devnet in
   the same run; no Singular naming behaviour is involved. A second,
   unapplied insert request is submitted (`reject-request`), the
   applied insert is replayed into the trie manager so its proofs
   stand on the root the chain actually has, and the valid oracle
   update is built but never submitted. Three single-defect mutants
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

   The journey runs no owner-authorization control. Under the
   ownerless ruling `End` refuses for every party; that evidence
   belongs to the separate, retained `repair-rows` runner
   (`ownerless-end`), currently unverified under #172, not to this
   journey.
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
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#journey
```

The app is the Nix-built `journey` binary wrapped with the locked
`cardano-node` on its `PATH` (same wrapping as `cage-tests-e2e`).
The blueprint is always built fresh from the onchain flake at run
time; no store path is baked in.

Environment:

| Variable              | Required | Meaning                                              |
|-----------------------|----------|------------------------------------------------------|
| `REGISTRY_BLUEPRINT`      | yes      | Path to the built `plutus.json` blueprint            |
| `REGISTRY_SCRIPT_IDENTITY`| no       | Path to `script-identity.json` (default `../onchain/script-identity.json`) |

CI runs the same thing as the `journey` job in
`.github/workflows/registry.yml`, after the blueprint job, and fails when
the run fails.

## What it is not

- It is **not** a Singular demonstration. No output line names
  anything as claimed, registered or maintained.
- It is **not** a test suite. The E2E suite is the `e2e-tests`
  component in [`offchain/e2e-test/`](../e2e-test/main.hs), whose specs
  are
  [`CageSpec`](../e2e-test/Singular/Registry/E2E/CageSpec.hs),
  [`ConfigSpec`](../e2e-test/Singular/Registry/E2E/ConfigSpec.hs),
  [`Criterion3Spec`](../e2e-test/Singular/Registry/E2E/Criterion3Spec.hs),
  [`DriverSpec`](../e2e-test/Singular/Registry/E2E/DriverSpec.hs),
  [`Fork81Spec`](../e2e-test/Singular/Registry/E2E/Fork81Spec.hs),
  [`NodeSpec`](../e2e-test/Singular/Registry/E2E/NodeSpec.hs),
  [`InsertActiveSpec`](../e2e-test/Singular/Registry/E2E/InsertActiveSpec.hs),
  [`UpdateTerminalSpec`](../e2e-test/Singular/Registry/E2E/UpdateTerminalSpec.hs)
  and
  [`OpenBootSpec`](../e2e-test/Singular/Registry/E2E/OpenBootSpec.hs);
  the journey is one narrated run, its refusals included, using the
  same builders and a real node.
- It does not touch the onchain tree: the blueprint and the identity
  manifest are read at run time.

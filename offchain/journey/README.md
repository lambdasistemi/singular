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

Every step below is performed by `offchain/journey/Main.hs` in this
exact order. A step that failed to happen here would be a defect in
this document.

0. **Identity header.** Reads `onchain/script-identity.json` (path
   from `REGISTRY_SCRIPT_IDENTITY`, default `../onchain/script-identity.json`)
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
   blueprint at `REGISTRY_BLUEPRINT`), signs with the genesis key,
   submits, waits for confirmation, derives the cage token id from the
   mint, registers the token's trie, and observes the state UTxO at
   the cage address. It reads the boot state datum and records the
   trie root.
3. **request.** Books one edge of the registry's transition table with
   `bookEdgeTx`: `insertAbsent` (edge 0) on `key=hello`. The value is
   not free text — a registry leaf is one of exactly three bytes — and
   edge 0 writes the absent leaf `0x00`. The booking mints the approval
   that certifies the edge under the registry's pinned application
   policy, whose asset name IS the binding of the edge, key, owner and
   destination; the request output carries that approval and names the
   destination the approval bound. Signs, submits, and observes exactly
   one request UTxO at the token's request address.
4. **verify-absent.** Before the insert is applied, proves the key is
   absent from the authenticated state: builds the key's exclusion
   proof, folds it to the root it implies, and compares that root
   against the root read back from the chain's state datum. Prints
   `proved absent` with the matched root; any mismatch fails the run.
5. **apply.** Acts as the oracle: builds the update with
   `updateTokenWithDuties` (proof from the trie manager), signs,
   submits, and observes the request UTxO being consumed. A fold does
   not move the root alone: it mints the token delta the edge owes
   under one of the registry's three token policies, writes the custody
   the edge creates, and returns the spent approval to whoever booked
   it. Before the first booking the run publishes the cage, the request
   validator and the three token policies as reference outputs — the
   state validator alone is fifteen kilobytes — so every fold resolves
   its scripts through reference inputs and attaches none.
6. **derived-applied-identity.** Ties the two identity layers
   together. First requires each pinned unapplied hash to equal the
   hash of the blueprint's raw code this run actually loaded. Then
   applies this instance's parameters to the unapplied code —
   `previousPolicies=[]` for the state validator; `statePolicyId`
   (the applied state hash) and `cageToken` for the request
   validator; nothing for staking — hashes the result, and requires
   the boot transaction's script witness to hold exactly the derived
   state script. The update attaches nothing at all, so the same claim
   is made of what it resolves: its reference inputs must carry exactly
   the derived state and request scripts beside this registry's three
   token policies. Prints each validator's
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
   The owner-authorization negative control is gone with the owner role
   itself: `End` refuses for every party under the ownerless ruling,
   and that evidence lives in `repair-rows` instead.

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
naming="$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)"
REGISTRY_BLUEPRINT="$blueprint" NAMING_BLUEPRINT="$naming" nix run --quiet .#journey
```

The naming blueprint is an input even though no naming behaviour runs
here: a cage boots with four derived pins, and the edge this journey
folds is certified by the naming application's policy and witnessed by
one of the registry's three token policies. What the journey takes from
that partition are identities, not records.

The app is the Nix-built `journey` binary wrapped with the locked
`cardano-node` on its `PATH` (same wrapping as `cage-tests-e2e`).
The blueprint is always built fresh from the onchain flake at run
time; no store path is baked in.

Environment:

| Variable              | Required | Meaning                                              |
|-----------------------|----------|------------------------------------------------------|
| `REGISTRY_BLUEPRINT`      | yes      | Path to the built registry `plutus.json` blueprint   |
| `NAMING_BLUEPRINT`        | yes      | Path to the built naming `plutus.json` blueprint     |
| `REGISTRY_SCRIPT_IDENTITY`| no       | Path to `script-identity.json` (default `../onchain/script-identity.json`) |

CI runs the same thing as the `journey` job in
`.github/workflows/registry.yml`, after the blueprint job, and fails when
the run fails.

## What it is not

- It is **not** a Singular demonstration. No output line names
  anything as claimed, registered or maintained.
- It is **not** a test suite. The E2E suite in `e2e-test/` covers the
  six cage scenarios; the journey runs one happy-path narrative using
  the same builders and a real node.
- It does not touch the onchain tree: the blueprint and the identity
  manifest are read at run time.

## The other runners in this directory, and what #157 changed

`journey/` holds more than the bounded journey. Beside it live the
contract-row runners that execute Singular's own rows against a real
devnet: `li01` and `li-refusals` (the `LI` initialization rows), `lmlc`
(the `LM` maintenance rows, built as the `naming-rows` app), `recovery`
(the `LR` recovery rows), `retirement` (the `LT` termination rows) with
`retire-verify` replaying its public evidence, and `repair` (the
ownerless-model rows). Each has a job of its own in
`.github/workflows/registry.yml`.

#157 changed the contract those runners consume, so #157 re-cut them.
Four things moved, and every runner here follows all four:

- **A cage boots with four derived pins.** The application policy is the
  naming application validator's own hash; the absent, active and
  terminal policies are `witness(kind, registry)` applied at kinds 0, 1
  and 2 to this registry's own asset identity. None of the four is
  typed in; a runner that cannot derive them cannot boot.
- **A request carries an approval and a destination.** The approval is
  minted at booking under the application policy and its asset name IS
  the binding — the edge, the key, the owner and the destination hashed
  together — and the cage recomputes the same bytes from the request it
  rides. The destination says where what the edge creates must land.
- **A fold creates records rather than claims.** A record is what a fold
  of `insertActive` delivers: an output at the naming application's own
  address holding the registry's active witness token for the key, under
  the datum the approval bound. Nothing else can make one.
- **A retirement is proved by the recovery key or by a quorum.** The
  committed recovery key, revealed and signing, or a distinct-member
  quorum of the record's own retirement quorum.

### Retired rows

Three design rows went with those changes. They are retired, not
skipped, and not stubbed green: the transactions they described cannot
be built against the #157 contract at all, so there is nothing left for
them to assert.

Retired row IDs: LC01 LC02 LC03 LC04 LC06 LT01 WR01

| Retired | What it asserted | Why it is retired | Where the proposition went |
|---|---|---|---|
| `WR01` | the refund recorded at request time is readable back as the withdraw approval's asset name | the withdraw approval is retired with the claim mechanism; an approval's asset name is now the edge binding, not a refund address | the destination an approval binds, checked by the cage at every fold (`journey`, `naming-rows`) |
| `LC01` | cancelling a claim with the stored refund accepts, burning the approval | **claim-and-cancel is retired**: there is no claim to cancel, and a fold does not burn the approval it consumed | absence custody and its refund leg (`repair-rows` retract rows, the cage's own `SpendCustody`) |
| `LC02` | a cancellation redirecting the refund refuses | retired with claim-and-cancel | the approval binding: a destination that is not the one bound refuses at the fold |
| `LC03` | a claim carrying no approval cannot be cancelled | retired with claim-and-cancel | a request with no approval never folds: the cage recomputes the binding and finds nothing |
| `LC04` | a folded record carries no approval, so cancellation refuses | retired with claim-and-cancel, and with **pending-claim `Fold`**: no claim is left pending for a fold to consume | a record is created by the fold, not converted from a claim (`naming-rows` setup) |
| `LC06` | replaying an accepted cancellation refuses | retired with claim-and-cancel | — |
| `LT01` | a name is retired by the control key alone | **control-key-only retirement is retired** (D-TERMINATE): a thief holding the current control key can redirect a name's payments, but must not be able to end it | `LT02`/`LT03` and the quorum rows: retirement is proved by the recovery key or by a quorum |

`LC05` was never a row.

### Surviving rows

`LI`, `LM`, `LR` and `LT` rows replay against the #157 blueprint with
their attribution controls intact — each refusal still has to come back
as a phase-2 failure naming the validator the row names, and each runner
still has a wrong-reason control that must fail the run. What changed
under them is how the object they act on comes to exist, never what they
assert about it:

| Family | Runner | Rows | What #157 changed under them |
|---|---|---|---|
| `LI` | `li01`, `li-refusals` | `LI01`; `LI02`–`LI08` | the boot datum carries the four derived pins; `LI05` and `LI08` meet the application policy's approval binding where they used to meet a withdraw-approval shape |
| `LM` | `naming-rows` | `LM01`–`LM04` | the record they maintain is created by a real registry fold, and `maintain` preserves its active witness token |
| `LR` | `recovery-rows` | `LR01`–`LR11` | the record they recover is created by a real registry fold; `recover` reads its one non-ADA asset, which is now the active witness token |
| `LT` | `retirement-rows`, `retirement-verify` | `LT02`, `LT03`, `LT05`, `LT06`, `LT08`, `LT09` | retirement co-creates the completion request that folds `updateTerminal`, and is proved by the recovery key or a quorum |

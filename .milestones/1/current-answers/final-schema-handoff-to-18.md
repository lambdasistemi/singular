# Epic 17 → epic 18 — accepted COMPONENT identity set (NOT the final M1 tuple)

**Status: RELEASED as an accepted COMPONENT, 2026-09-12T18:42Z. This is NOT the final A-001/value-repaired M1 tuple** — the approved empty-fold refusal and the operation-specific value routing are a commissioned later revision that will move `state` and everything downstream of it, and this table will be superseded a final time. Nobody should read this release as that revision being done. The acceptance it waited on has completed at the candidate below. It supersedes BOTH earlier versions of `ownerless-schema-handoff-to-18.md` in full — the original four-field `State` table and its SUPERSEDED addendum. Nothing in either is current.

Candidate: **`ddfc4e961d530ee4e62361aabbcc730a9b9809ed`**
(`feat/real-representative-fold`, `/code/singular-e17-issue-77`, clean tree,
local only — not pushed, no PR). Acceptance ran against an immutable detached
checkout at `/code/singular-e17-accept`, which no worker can write.

It supersedes the `617e434` draft of this file: `617e434` -> `fe89e68` (E-001
refusal-cause obligation, producer identity, release source binding) -> `ddfc4e9`
(git in the assembler closure). **Every script identity below is unchanged across
those three commits** — they touched runners, the verifier, `tools/` and
`nix/release.nix`, never a validator — and that is measured below, not assumed.

Every identity below is read out of the blueprints **built from that candidate**
by S3 itself, not out of prose or a manifest checked into the tree.

## Compiler and blueprints

| | |
|---|---|
| compiler | `Aiken v1.1.21+unknown`, Plutus `v3` |
| naming blueprint | `/nix/store/phz7qfgh1vrlaxbdyr1qa6r8br8zjd6b-singular-naming-plutus-blueprint-0.1.0` (`singular/naming-onchain` 0.1.0) |
| mpfs blueprint | `/nix/store/m8rvyvjh2fcz5akmnz4vwilk332n5cn1-mpf-plutus-blueprint-0.0.0` (`hal/mpf` 0.0.0) |
| build | `nix build ./naming-onchain#plutus-blueprint`, `nix build ./onchain#plutus-blueprint` |

## Script identities, with parameter counts

`params` is the count of blueprint `parameters`; an unapplied hash is only the
identity of the *program*, and a parameterized script's on-chain policy/address
is the hash **after** application.

| validator | purpose | params | hash (unapplied) |
|---|---|---|---|
| `state.state.{mint,spend,else}` | MPFS registry state | **0** | `2bf61b131e8910d467b0d0a43f61b66c347b5ac90f934268808bf8c0` |
| `request.request.{spend,else}` | MPFS request | **2** | `c3eec4102ba4c5b1456d6e37c630669e2526f0def2d697225d134193` |
| `staking.staking.{withdraw,else}` | MPFS staking | 0 | `4ab26c95029067185f709d140300cccb15b0b20bbd62a7e9aa2e2e10` |
| `application.application.{spend,mint,else}` | naming application | **0** | `52dbf57b2bf7f168c1ab1c06a19a6bb6ed32ecf56de49949f79901b0` |
| `representative.representative.{mint,else}` | representative | **1** (the application policy) | `6f14bdea9ab880c3b6934f43942ace2b971d13a8f4123f090677f1dc` |
| `retirement_custody.retirement_custody.{spend,else}` | retirement custody | 0 | `0a92d14aa73db354d7468f0f09352cfedb6169adf32ea74e82666954` |
| `e001_attacker.e001_attacker.{mint,else}` | **test fixture only** — always-true mint used to prove the E-001 refusal; never production | 0 | `1ab2c5f451c798474d7476355230e5123095426d2a0b96a10213051f` |

Moves against the last set epic 18 saw: `state` `e51b…` → `2bf61b…`, `request`
`44420f…` → `c3eec4…`, `application` `a49c…` → `703c…` → `52dbf5…`. The
representative's unapplied hash `6f14bdea…` is unchanged and does not depend on
the application hash. `state` and `application` are **parameterless**: the earlier
suggestion that `state.ak` takes parameters was stale and is void.

## `State` — final constructor

Constructor index 0, five fields, **appended never reordered** (the first four
keep their indices):

| # | field | type |
|---|---|---|
| 0 | `root` | `ByteArray` (32-byte MPF root) |
| 1 | `tip` | `Int` (lovelace per request) |
| 2 | `process_time` | `Int` (ms, phase 1) |
| 3 | `retract_time` | `Int` (ms, phase 2) |
| 4 | **`representative_policy`** | `PolicyId` |

`representative_policy` is `Singular.representativePolicy` refined on chain: set
at bootstrap from the honest **applied** representative policy, preserved
immutable across every `Modify` (a fold altering it refuses), and read from the
spent state by naming `fold()`/`retire()`, which require the moved
representative's policy to equal it. A foreign-policy representative refuses with
`representative-policy`. This closes E-001, an executable defect proven by
accepted attack tx `ae4fb32d6a860bb0a6f2d94d0e54bea69844e9fe38e7f8ed8061c9ccc5206d2a`
(witness retained at `ticket-77/commit-owner-2/handoffs/e001-witness/`).

## SDK codec — a hard break, no legacy acceptance

`offchain/lib/Cardano/MPFS/Cage/Types.hs`, `OnChainTokenState`:

```haskell
Constr 0 [ root, I stateMaxFee, I stateProcessTime, I stateRetractTime, repPolicyBytes ]
```

`FromData` matches **only** the five-field `Constr 0`; a four-field datum returns
`Nothing`, and `UnsafeFromData` errors on `OnChainTokenState.repPolicy`. There is
no tolerant path, by intent. Field accessor `stateRepPolicy`, byte accessor
`stateRepPolicyBytes`. Cage construction takes `cfgRepPolicy` in `CageConfig`
with `bootStateFromCfg` (naming cages: the honest applied representative policy;
MPFS-only cages: 28 zero bytes).

## What epic 18 must reconcile

Companion `7816305` was prepared against the four-field shape. Against this set
it needs: the five-field `State` codec, the moved `state`/`request`/`application`
identities, and the parameter counts above. Epic 18 still owes its final affected
devnet checks. Serial integration into my branch remains mine and mine only — no
parallel writers.

Unchanged from the previous handoff, and still true: `owner`/`stake_script` are
removed from the head of the record and `validator state()` is parameterless
(the two breaks already described); request/refund and application/name authority
are untouched; ordinary funding signatures are untouched; superseded owner
behaviour is preserved as history; no permanence is claimed beyond the approved
M1 action set.

## What this handoff does not establish

Blaster validation of the compiled invariants (#87) is **NOT ESTABLISHED** by
anything here. These identities are what epic 18 needs to point Blaster at the
repaired production blueprint; they are not evidence about its compiled
behaviour.

## Producer identity — the applied representative policy

Owner 18's #87b Q-001 waits on exactly this, and it is now pinned.

| | |
|---|---|
| production tool | `offchain/lib/Cardano/MPFS/Cage/Blueprint.hs:applyBytesParam` (lines 412–419), which applies a raw-bytes parameter to a flat-encoded UPLC program via `applyDataParam` in the same module |
| callers | every naming journey and the verifier take this same path — e.g. `offchain/journey/register/Main.hs` `repAppliedBytes = applyBytesParam (scriptHashBytes appHash) repBytes`, identical shapes in `recovery`, `retirement` and the verifier's `loadIdentities`/`assemble`. `Blueprint.hs` is untouched by the repair batch, so the path is identical at `ddfc4e9` |
| input 1 | application program bytes from the naming blueprint above; application hash `52dbf57b2bf7f168c1ab1c06a19a6bb6ed32ecf56de49949f79901b0` (0 parameters) |
| input 2 | representative unapplied bytes from the same blueprint, `6f14bdea9ab880c3b6934f43942ace2b971d13a8f4123f090677f1dc` (1 parameter) |
| parameter applied | `scriptHashBytes appHash` — 28 raw bytes |
| **applied representative bytes** | `ticket-77/commit-owner-2/evidence/producer-identity/representative-applied.flat`, 1080 bytes, retained |
| **applied representative policy** | `53828b962561757a51caab42a0891a9ebe0c6abb3fdfa87aa993b5b6` |

The applied hash is independently recomputed by the `connected-verifier` —
`representative.applied` on the smoke evidence, and the
`refusal.representative-policy` verdict whose detail names the same pinned
policy while the attacker mint sits under `1ab2c5f4…`. `applyBytesParam` is pure
over its two pinned inputs, so any holder of the blueprint and the library at
this commit recomputes byte-identical output.

## What the acceptance of this candidate actually establishes

Run against the immutable detached checkout, `HEAD` and `git status` verified
before and after:

| instrument | result |
|---|---|
| `gate-77-v3` (frozen) | 17 legs exit 0 including `no-standin`, `active-by-fold`, `representative-minted-by-fold`, `occupied-key`, `fold-permissionless` and `release-artifacts`; both must-fail controls exit 1 **after executing rows**; one leg fails — `recovery-preserved`, a gate-side missing `MPFS_BLUEPRINT`, corrected by amendment A1 v2 |
| A2 (S3 steps 4–5) | 17/17 obligations ESTABLISHED |
| A3 | the E-001 refusal **cause** ESTABLISHED, and REFUTED under the removed-check mutant where the foreign fold was accepted on chain |
| fault controls | four independent faults each refuted while the run's own wording was unchanged |
| S4 v4 | release bound to declared source under a contaminated workspace; production checker refuses inner file and manifest corruption by its inner assertion; packaged entrypoint exits 0 with `PATH=/var/empty` |
| A1 v2 | recovery preservation, clean-bound at this candidate |

Every RED in that table is an instrument defect with a separately versioned
amendment that is itself GREEN and shown able to fail. No product leg failed.
The frozen instruments were never edited.

## Limits — what is still owed, and by whom

- **#87 Blaster validation of the compiled invariants is NOT ESTABLISHED** by
  anything here, and remains an M1 blocker. This handoff is what lets epic 18
  point Blaster at the repaired production blueprint; it says nothing about its
  compiled behaviour.
- `key3` naming-only negatives refuse on missing state rather than isolating
  `identity`; devnet per-check splits (mint-alone, value-alone,
  retire-input-alone, retire-custody-alone, preservation-devnet) remain open with
  hooks in the worker's `census-devnet-mutant.log`; retire runs `cfaSkipEval=True`.
- A **later** candidate will refuse empty folds (stakeholder-approved) and will
  carry the operation-specific value routing with it. Both move `state.ak`, so
  `state` → the `mpfs_state_hash` constant in `naming.ak:202` → `application` →
  the applied representative policy will all rebind once more, and this table
  will be superseded a final time. `retirement_custody` and `staking` are not on
  that chain and will not move.

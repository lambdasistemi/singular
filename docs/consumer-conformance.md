# Consumer conformance (epic 18, issues #63 and #69)

## The contract and its binding

The rows answer to the consumer contract source-bound to
`lambdasistemi/cardano-keri@14a64a4681d3e429fab5877062b5c476c2a4bfe2`:
`docs/design/registry-as-mpfs.md` (eleven operator rulings and fourteen registry theorems) and
`docs/user/consumer-checklist.md`. cardano-keri consumes the
**generic** registry — Insert, Update, Delete — not the naming
application, whose restriction refuses Delete and reuse by design.
No naming evidence can establish any row here, and none is claimed.

The canonical identity rows (#69) carry the correction epic 16
executed: cardano-keri's ruling is that the registry provides
identity uniqueness, but a permissionless ledger **cannot prohibit a
rival registry** — a consistent initialization from a second seed
passes every frozen check and the node accepts it
(`offchain/naming-correspondence.md`, "What t50 settled"). Canonical
identity is therefore **a derivation the consumer authenticates**,
not a refusal the chain performs: the canonical registry token's
name is SHA-256 of the canonical seed's outRef, that seed can never
be spent twice, and a rival from another seed can never carry that
name.

## The denominator

`conformance/rows.json` carries **41 rows, 40 owned**: CA01–CA05,
CG01–CG19, CS01–CS08, CK01–CK05, CL01–CL03, plus CK06 (bonds, poison,
the juvenility window `W`, the signature threshold) recorded as
**out of scope** — it belongs to cardano-keri's checkpoint machine
and treasury, explicitly never claimed by Singular. `list` prints the
owned denominator separately so the boundary stays visible.

`rows.json` never carries `executed`: the declared field is the
coverage plan and the parser rejects the string. A row prints as
executed only when a run receipt for it exists and matches the
current base (`--receipts DIR` or `CONFORMANCE_RECEIPTS`).

## What this slice executes

Two devnet sessions run in order, each on an isolated node with its
own published world: the generic registry rows first, then the
canonical identity rows.

### The generic registry rows

Against a real devnet, one cage, one key, in order:

| row | outcome | evidence |
|---|---|---|
| CG02 generic Update v1→v2 | accept | inclusion proof for v2 implies the chain-read root; forged-value proof does not (control) |
| CG03 generic Delete | accept | exclusion proof verifies against the chain-read root (empty trie); pre-delete proof bound to the deleted value does not (control) |
| CG04 re-Insert v3 | accept | inclusion proof for v3 implies the chain-read root; forged-value proof does not (control) |
| CG05 Insert on occupied key | **refuse** | hand-built fold submitted; node refuses in phase 2, attributed to the state script (`874e476d…`, `CekError`); fresh cage accepts a valid insert (control) |

CG05's refusal is a node verdict on a submitted transaction, the
li-refusals bar: the fold is hand-built (the library builder cannot
emit a transaction whose scripts do not evaluate) and calibrated
against the library builder on every valid fold — same inputs,
state output, refund destinations and Modify proofs — so the refused
shape differs from a library fold only in the operation under test.
The eval-time refusal the builder reports first is kept as a log
line, never as the verdict. Each receipt records where its refusal
was observed (`venue`: `node-submit` for every row here), and
refusal reasons are trimmed to their attribution (failure class,
script hash, machine error) — receipts stay under a run-enforced
16KB bound, because a receipt nobody can open is weak evidence.

Had the chain accepted the occupied insert, that would be a
**finding** reported with the accepted transaction — never relabelled
as a refusal.

### The canonical identity rows

A designation split publishes the canonical seed; CA01 boots the
canonical registry from it; CA02 initializes a rival from a second
seed through the same bootstrap path; a second split publishes the
rival seed, so no boot can ever consume the wrong UTxO as its
funder.

| row | outcome | evidence |
|---|---|---|
| CA01 derived name recomputed and matched | accept | the state UTxO carries exactly the SHA-256 of the published seed's outRef, quantity 1; a fabricated outRef's derivation does not match (control) |
| CA02 rival registry from a second seed | **rival accepted on chain; authentication rejects** | the node accepts the rival's bootstrap tx; both token names read back from the chain differ (each SHA-256 of its own seed's outRef); the canonical registry is unaffected — same UTxO, value and datum bytes as the CA01 snapshot; the derived name accepts the canonical and rejects the rival |
| CA03 policy+address-only authenticator | control must fail the run | the weak authenticator accepts the rival read back from the chain while the full authenticator rejects the same value — the name is the only discriminator; armed (`naive-authenticator`), the run fails naming the accepted rival |
| CA04 applied-address derivation | accept | the manifest pins unapplied `64d1afbfe585…` with 1 declared parameter; applied in Haskell to `874e476d7408…`; the derived address equals the address the chain reports and the library's; the unapplied address does not pass (control; armed run fails) |
| CA05 forged output at the canonical address | authentication rejects; no script ran | a forged output carrying the canonical address and datum but no token is accepted by the ledger with **no script executed** — no witness, no redeemer, no mint, empty node evaluation — and the same detector fires on the boot tx (control); authentication rejects it on the missing token |

CA02 asserts an **acceptance**: the ledger takes the rival, and the
consumer's authentication is what excludes it. The receipt records
the ledger's verdict (accepted, with the rival's txid and
measurements); the rejection is asserted on chain-read assets and
named in the run — never relabelled as a refusal, never skipped
because the outcome reads oddly. The acceptance is the finding, and
it is the accepted design. CA03 is what makes CA02 worth anything:
a check that cannot fail proves nothing, so the weak authenticator's
acceptance of the rival is itself executed and required.

### Measurements

Ship run: base `e56c7c1`, clean tree, cardano-node 10.7.0.

Maxima queried from the running node, never hardcoded:
`maxTxExUnits` 140000000 mem / 10000000000 cpu,
`maxTxSize` 16384 bytes.

| fold | mem (headroom) | cpu (headroom) | size (headroom) |
|---|---|---|---|
| CG02 Update | 641698 (139358302) | 208152036 (9791847964) | 11423 (4961) |
| CG03 Delete | 631100 (139368900) | 204773757 (9795226243) | 11423 (4961) |
| CG04 re-Insert | 629296 (139370704) | 204228993 (9795771007) | 11423 (4961) |
| CA01 canonical boot | 143440 (139856560) | 46848478 (9953151522) | 8502 (7882) |
| CA02 rival boot | 143440 (139856560) | 46848478 (9953151522) | 8502 (7882) |
| CA05 forged payment | 0 (140000000) | 0 (10000000000) | 333 (16051) |

Execution units stay under 3% of the maxima for every row (CA05
reports zeros honestly: no script purpose exists to evaluate).
Serialized size is the tight dimension at ~70% of `maxTxSize` for
folds and ~52% for boots; larger batches (CL02) may press against it
first. The worst case across each session is recorded in that
session's CL01 receipt (generic folds; canonical boots).

## What this slice does not establish

- **Bound, not re-executed**: CG01, CG06, CG08, CG16, CG18 rest on
  epic 16's `CageSpec` runs, cited per row. Nothing else in the
  inventory has ledger evidence.
- **Uncovered**: all CS, CK(01–05), CL02–CL03 and the remaining CG
  rows print `uncovered`. CG11–CG13 and CG19 are expected consumer
  **gaps** (upstream `#100`/`#101`): unobserved here, recorded as gaps
  to observe, not as passes.
- **Out of scope**: CK06 (cardano-keri), the naming rows (epic 16
  demonstration, not consumer evidence), LR/LT rows (epic 17).
- The CA rows authenticate the canonical registry as the consumer
  derives it from the published seed. They do not evidence the
  serialization boundary (CS), the constructor coverage (CS03–CS05)
  or the batch limits (CL02).
- The measurements above are devnet folds of single requests. They
  say nothing about batch limits (CL02) or any other environment
  (CL03 records the observed one below).

## Commands

```sh
# the inventory with each row's state
nix run ./conformance#conformance -- list
# the generic rows, with measurements, controls and receipts
mpfs="$(nix build --quiet --no-link --print-out-paths ./onchain#plutus-blueprint)"
MPFS_BLUEPRINT="$mpfs" nix run ./conformance#conformance -- run CG02 CG03 CG04 CG05 --receipts-dir ./conformance-receipts
# the canonical identity rows, as their own session
MPFS_BLUEPRINT="$mpfs" nix run ./conformance#conformance -- run CA01 CA02 CA03 CA04 CA05 --receipts-dir ./conformance-receipts
# rows print executed only against matching receipts
nix run ./conformance#conformance -- list --receipts ./conformance-receipts
```

CA and CG rows run as separate sessions, one devnet each; a mixed
request is refused. Armed controls (each must exit non-zero; all do):

```sh
CONFORMANCE_CONTROL=wrong-reason ... -- run CG02 CG03 CG04 CG05    # CG05 reason mismatch
CONFORMANCE_CONTROL=false-claim ... -- run CG02 CG03 CG04 CG05     # forged value fails the chain check
CONFORMANCE_CONTROL=false-claim ... -- run CA01 ... CA05           # fabricated derivation bound to CA01
CONFORMANCE_CONTROL=naive-authenticator ... -- run CA01 ... CA05   # the weak authenticator must reject the rival; it cannot
CONFORMANCE_CONTROL=unapplied-address ... -- run CA01 ... CA05     # the unapplied layer's address must pass; it cannot
```

The runner sets its own unique `TMPDIR` before starting a node and
never touches the default path, so concurrent devnet lanes on one
host keep their databases. Receipts live under the run's output
directory, never in the tracked tree.

## Observed environment

cardano-node 10.7.0, GHC 9.12.3, Aiken compiler v1.1.21
(blueprint `hal/mpf 0.0.0`), unapplied state script pinned
`64d1afbfe585b496a325ecacf2600210ff773368010bbab96e5cf1ce` with one
declared parameter, applied state script
`874e476d7408de769e07a4ebf34f3c7379ebd7bd35ab8aad426b41d5`,
unapplied request script hash `6b5ce7…`. Environments other than
this devnet shape are explicitly not covered.

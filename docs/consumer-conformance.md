# Consumer conformance (epic 18, issues #63, #69 and #68)

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

Three devnet sessions run in order, each on an isolated node with its
own published world: the generic registry rows first, then the
canonical identity rows, then the serialization boundary rows. Two
further checks, CS01 and CS06, never start a node at all: they compare
Haskell values against the compiled blueprint read at run time, so a
reader totalling "rows executed on a real devnet" must count the five
devnet rows below, not seven. The counts are kept visibly separate
for exactly that reason.

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
| CA04 applied-address derivation | accept | the manifest pins unapplied `d42860fa97…` with 1 declared parameter; applied in Haskell to `ce7615f6ba4…`; the derived address equals the address the chain reports and the library's; the unapplied address does not pass (control; armed run fails) |
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

### The serialization boundary rows (devnet session)

One fresh cage per row (two where a row needs two phases), each cage
booted, exercised and — except where the row says otherwise — closed
on the same isolated node, in canonical order:

| row | outcome | evidence |
|---|---|---|
| CS02 datum bytes submitted and read back | accept | boot `StateDatum` plus one request `RequestDatum`, byte-compared submitted `Datum` versus chain-observed `Datum` for both; units from the boot minting, size the larger of the two transactions; corrupted comparison fails the run (control) |
| CS03 every `UpdateRedeemer` constructor executed | accept | one executing witness per constructor — `End` 0, `Contribute` 1, `Modify` 2, `Retract` 3, `Sweep` 4 — each read back from the redeemer of a submitted transaction the validator executed (the `Modify` fold carries `Modify` and `Contribute` together); four witness transactions named; a skipped witness fails the run (control) |
| CS04 redeemer at a wrong constructor index | **refuse** | valid fold retargeted to `Constr` 5 keeping its fields (same CBOR size, so fee and collateral stay sufficient and any refusal attributes to the script); node refuses in phase 2 with `CekError`, attributed to **both** cage scripts (`state+request`, ledger order, unstable — the tamper breaks fold consistency the request script also checks); fresh cage accepts a valid fold (control); impossible marker fails the run (control) |
| CS05 `RequestAction` and `MintRedeemer` coverage | accept, with one recorded gap | `Update`, `Rejected` (phase-3 reject), `Minting` (boot), `Burning` (end) each executed and read back from its redeemer; `Migrating` is unreachable on the imported partition (`previousPolicies=[]`, so `has(previousPolicies, oldPolicy)` fails at `state.ak` `validateMigration` FR1) and is recorded as a gap with that reason in `gap-CS05-Migrating.txt` — never a pass, never omitted; a skipped witness fails the run (control) |
| CS08 `OnChainTokenState` six fields round trip | accept | two boots, `stake_script` `None` and `Some` (staking hash), all six fields byte-identical submitted versus chain-observed; corrupted comparison fails the run (control) |

### The serialization checks that need no node

No transaction, no node, no execution units — hence `mem`/`cpu` zero
and no transactions named. What is measured is stated per row, and
these rows never appear in a devnet-executed count.

| row | outcome | evidence |
|---|---|---|
| CS01 Haskell encodings against the blueprint schema | accept (`blueprint-check`) | all thirteen `ToData` types round-trip **and** each constructor index and field order matches the compiled blueprint's declared schema read at run time (`MPFS_BLUEPRINT`), including field-title order; no type needed a gap; `Constr` 99 validates against nothing and index 99 demanded for `End` fails the run (control); `txSize` is the blueprint file size in bytes, 92048 |
| CS06 parameter application derived in Haskell | accept (`param-check`) | parameter counts and encodings published from the blueprint — state 1 (`previousPolicies`), request 2 (`statePolicyId`, `cageTokenName`, in source order), staking 0 — unapplied hashes match the pinned blueprint hashes, the applied state hash is `874e476d…`, non-empty allowlists and swapped request params discriminate; 2 demanded for state fails the run (control); `txSize` is the largest applied script size in bytes, 7805 |

### CS07: unmarked and escalated

CS07 carries no receipt and prints `uncovered`: `Branch` and `Leaf`
are witnessed on chain across many accepted folds, but no accepted
fold has ever carried a `Fork`, and two independently ground
lone-`Fork` absence proofs — each verified by the mts Haskell stack
against its own root — are refused by the compiled validator with a
bare `CekError` at build-time evaluation. The full bundle (keys, trie
shape, both verdicts, the refusal bytes, what could not be
determined, and the bounded consumer consequence) is filed as a user
story escalation; the offline oracle (`find-fork-keys`,
`check-fork-exclusion`) and shape probes (`show-nibbles`,
`show-d-proof`, `show-all-proofs`) reproduce every offline claim.
This is a finding held open, not a gap and not a pass.

### Measurements

Ship run: base `b3f4b5a`, clean tree, cardano-node 10.7.0.

Serialization ship run: base `b2201c3`, clean tree, cardano-node
10.7.0 — every receipt below names that base with `dirty: false`.
Each invocation observes the tree before creating its output, and
ships from a fresh output directory, so no run ever measures the
previous run's receipts. The defect this guards against reported
`dirty: true` on clean trees; its direction is conservative — it can
block a valid ship, it can never let a dirty tree pass as clean — and
no merged receipt ever claimed clean while dirty.

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
| CS02 datum round trip | 143440 (139856560) | 46848478 (9953151522) | 8466 (7918) |
| CS03 five witnesses | 629296 (139370704) | 204228993 (9795771007) | 11423 (4961) |
| CS05 four witnesses | 649502 (139350498) | 217245659 (9782754341) | 11423 (4961) |
| CS08 state None+Some | 147634 (139852366) | 49473955 (9950526045) | 8497 (7887) |

Execution units stay under 3% of the maxima for every row (CA05
reports zeros honestly: no script purpose exists to evaluate).
Serialized size is the tight dimension at ~70% of `maxTxSize` for
folds and ~52% for boots; larger batches (CL02) may press against it
first. The worst case across each session is recorded in that
session's CL01 receipt (generic folds; canonical boots); the CS rows
carry their worst cases in the row receipts, and no CS CL01 is
claimed yet. Refusal reasons keep every failing script hash in ledger
order — a tampered fold can fail two scripts, and trimming volume
never trims identities — under the same run-enforced 16KB bound.

## What this slice does not establish

- **Bound, not re-executed**: CG01, CG06, CG08, CG16, CG18 rest on
  epic 16's `CageSpec` runs, cited per row. Nothing else in the
  inventory has ledger evidence.
- **Uncovered**: CS07, CK(01–05), CL02–CL03 and the remaining CG
  rows print `uncovered`. CS07 is not merely uncovered: its `Fork`
  finding is filed for a user story and the row stays unmarked until
  that story resolves — an unmarked row with a finding, never a gap
  and never a pass. CG11–CG13 and CG19 are expected consumer
  **gaps** (upstream `#100`/`#101`): unobserved here, recorded as gaps
  to observe, not as passes. CS05's `Migrating` gap is of that
  recorded kind, with its validator-read reason beside the receipts.
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
# the serialization rows: local checks need no node, the rest run devnet
MPFS_BLUEPRINT="$mpfs" nix run ./conformance#conformance -- run CS01 CS02 CS03 CS04 CS05 CS06 CS08 --receipts-dir ./conformance-receipts
# rows print executed only against matching receipts
nix run ./conformance#conformance -- list --receipts ./conformance-receipts
```

CA, CG and CS rows run as separate sessions, one devnet each (CS01
and CS06 run local inside the CS invocation); a mixed CA/CG request
is refused. Each family ships from a fresh receipts directory —
receipts from one invocation would otherwise mark the next run dirty.
Armed controls (each must exit non-zero; all do):

```sh
CONFORMANCE_CONTROL=wrong-reason ... -- run CG02 CG03 CG04 CG05    # CG05 reason mismatch
CONFORMANCE_CONTROL=false-claim ... -- run CG02 CG03 CG04 CG05     # forged value fails the chain check
CONFORMANCE_CONTROL=false-claim ... -- run CA01 ... CA05           # fabricated derivation bound to CA01
CONFORMANCE_CONTROL=naive-authenticator ... -- run CA01 ... CA05   # the weak authenticator must reject the rival; it cannot
CONFORMANCE_CONTROL=unapplied-address ... -- run CA01 ... CA05   # the unapplied layer's address must pass; it cannot
CONFORMANCE_CONTROL=wrong-index ... -- run CS01                   # index 99 demanded for End
CONFORMANCE_CONTROL=wrong-params ... -- run CS06                  # two params demanded for state
CONFORMANCE_CONTROL=false-datum ... -- run CS02 CS08              # corrupted bytes demanded to match
CONFORMANCE_CONTROL=missing-witness ... -- run CS03 CS05          # a skipped witness demanded present
CONFORMANCE_CONTROL=wrong-reason ... -- run CS04                  # impossible marker demanded in the reason
```

The offline Fork oracle and its probes need no node and no blueprint:

```sh
nix run ./conformance#conformance -- find-fork-keys     # ground keys plus pure-trie proof shapes
nix run ./conformance#conformance -- check-fork-exclusion # cage/mirror roots plus mts-core exclusion verdict
nix run ./conformance#conformance -- show-all-proofs     # present-key proofs over the seven-key set     # the unapplied layer's address must pass; it cannot
```

The runner sets its own unique `TMPDIR` before starting a node and
never touches the default path, so concurrent devnet lanes on one
host keep their databases. Receipts live under the run's output
directory, never in the tracked tree.

## Observed environment

cardano-node 10.7.0, GHC 9.12.3, Aiken compiler v1.1.21
(blueprint `hal/mpf 0.0.0`), unapplied state script pinned
`d42860fa972c8a325daae773adc372795c48cf365d0a72b137c749d3` with one
declared parameter, applied state script
`ce7615f6ba4de80dfa9b9c6aef680666472ba4ed7e640ff55aad7c6e`,
unapplied request script hash `8970c286…` (re-pinned from
`64d1afbfe585…`/`874e476d7408…`/`6b5ce7…` by the issue-#79
imported-validator repair; `onchain/REPAIR.patch` records the change,
`PROVENANCE.md` the authority). Environments other than
this devnet shape are explicitly not covered.

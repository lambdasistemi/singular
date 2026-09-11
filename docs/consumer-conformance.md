# Consumer conformance (epic 18, issue #63)

## The contract and its binding

The rows answer to the consumer contract source-bound to
`lambdasistemi/cardano-keri@14a64a4681d3e429fab5877062b5c476c2a4bfe2`:
`docs/design/registry-as-mpfs.md` (rulings 1–11, theorems R1–R14) and
`docs/user/consumer-checklist.md`. cardano-keri consumes the
**generic** registry — Insert, Update, Delete — not the naming
application, whose restriction refuses Delete and reuse by design.
No naming evidence can establish any row here, and none is claimed.

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

Against a real devnet, one cage, one key, in order:

| row | outcome | evidence |
|---|---|---|
| CG02 generic Update v1→v2 | accept | inclusion proof for v2 implies the chain-read root; forged-value proof does not (control) |
| CG03 generic Delete | accept | exclusion proof verifies against the chain-read root (empty trie); pre-delete proof bound to the deleted value does not (control) |
| CG04 re-Insert v3 | accept | inclusion proof for v3 implies the chain-read root; forged-value proof does not (control) |
| CG05 Insert on occupied key | **refuse** | hand-built fold submitted; node refuses in phase 2, attributed to the state script (`874e476d…`, `CekError`); fresh cage accepts a valid insert (control) |
| CL01 (these rows) | recorded | worst case across the three accepting folds (see below); per-row values in the row receipts |

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

### Measurements (ship run: base `8cd9ef0`, clean tree, cardano-node 10.7.0)

Maxima queried from the running node, never hardcoded:
`maxTxExUnits` 140000000 mem / 10000000000 cpu,
`maxTxSize` 16384 bytes.

| fold | mem (headroom) | cpu (headroom) | size (headroom) |
|---|---|---|---|
| CG02 Update | 641698 (139358302) | 208152036 (9791847964) | 11423 (4961) |
| CG03 Delete | 631100 (139368900) | 204773757 (9795226243) | 11423 (4961) |
| CG04 re-Insert | 629296 (139370704) | 204228993 (9795771007) | 11423 (4961) |

Execution units use under 3% of the maxima. Serialized size is the
tight dimension at ~70% of `maxTxSize`; larger batches (CL02) may
press against it first.

## What this slice does not establish

- **Bound, not re-executed**: CG01, CG06, CG08, CG16, CG18 rest on
  epic 16's `CageSpec` runs, cited per row. Nothing else in the
  inventory has ledger evidence.
- **Uncovered**: all CA, CS, CK(01–05), CL02–CL03 and the remaining
  CG rows print `uncovered`. CG11–CG13 and CG19 are expected consumer
  **gaps** (upstream `#100`/`#101`): unobserved here, recorded as gaps
  to observe, not as passes.
- **Out of scope**: CK06 (cardano-keri), the naming rows (epic 16
  demonstration, not consumer evidence), LR/LT rows (epic 17).
- The measurements above are devnet folds of single requests. They
  say nothing about batch limits (CL02) or any other environment
  (CL03 records the observed one below).

## Commands

```sh
# the inventory with each row's state
nix run ./conformance#conformance -- list
# the four rows, with measurements, controls and receipts
mpfs="$(nix build --quiet --no-link --print-out-paths ./onchain#plutus-blueprint)"
MPFS_BLUEPRINT="$mpfs" nix run ./conformance#conformance -- run CG02 CG03 CG04 CG05 --receipts-dir ./conformance-receipts
# rows print executed only against matching receipts
nix run ./conformance#conformance -- list --receipts ./conformance-receipts
```

Armed controls (each must exit non-zero; both do):

```sh
CONFORMANCE_CONTROL=wrong-reason ... -- run CG02 CG03 CG04 CG05  # CG05 reason mismatch
CONFORMANCE_CONTROL=false-claim ... -- run CG02 CG03 CG04 CG05   # forged value fails the chain check
```

The runner sets its own unique `TMPDIR` before starting a node and
never touches the default path, so concurrent devnet lanes on one
host keep their databases. Receipts live under the run's output
directory, never in the tracked tree.

## Observed environment

cardano-node 10.7.0, GHC 9.12.3, Aiken compiler v1.1.21
(blueprint `hal/mpf 0.0.0`), applied state script
`874e476d7408de769e07a4ebf34f3c7379ebd7bd35ab8aad426b41d5`,
unapplied request script hash `6b5ce7…`. Environments other than
this devnet shape are explicitly not covered.

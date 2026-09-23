# Theorem manifest

As a proof reviewer, use this register to identify exactly which statements the
registry-mode model supplies, that each one is proved, and from which axioms.
Every declaration keeps its qualified name and a digest of its statement text, so
a changed or missing obligation is detectable rather than merely unlikely.

All 28 declarations of the registry's own statement module are **PROVED**
from the standard axioms — `propext`, `Classical.choice`, `Quot.sound` — and
nothing else. The naming instance adds 7, its lifecycle 9
and its wire encoding 5, for **49** in total, each with its own
manifest and its own compiled gate.

## What the eleven promises are

The interface states eleven guarantees the registry makes for *every*
application, and the model proves each one over states reachable from genesis by
folds. Reachability is a hypothesis, not a weakening: over an arbitrary `State`
value the supply laws are simply false.

```mermaid
flowchart TD
    G["Reachable state<br/>(genesis, closed under accepted folds)"] --> C["Consistent:<br/>root commits the map,<br/>supply laws, custody soundness"]
    C --> S3["S3 sync<br/>W1 active unique<br/>W2 absent unique<br/>W4 kinds exclude"]
    C --> S1["S1 soundness"]
    S1 --> S2["S2 permanence"]
    C --> O1["O1 occupancy"]
    O1 --> T1["T1 termination"]
    C --> P1["P1 policing"]
    C --> L1["L1 atomicity"]
    S1 --> W3["W3 plurality"]
```

Every promise is reached through one invariant — `Consistent` — that the model
proves survives each of the seven edges. That is why the statements read as
consequences rather than as separate arguments.

## Exact declaration inventory

| Qualified declaration | What it states | Statement SHA-256 | Status |
| --- | --- | --- | --- |
| `Singular.Statements.absent_witness_unique` | W2 — the absent witness is unique | `968c72784fe79c81a9296e74e23df3d4afa19f99a3ed616fc73d417f3e24053a` | PROVED |
| `Singular.Statements.active_witness_unique` | W1 — the active witness is unique | `76745382fd82c31a71125904f0c9e558e2ee4b770df5224ceaf41aac93ef3879` | PROVED |
| `Singular.Statements.biconditional_supply_sync` | S3 — sync: biconditional supply is 1 iff the key is in that token's state | `7f1089607f7d6578eac69fb4b68bb4147853f29c6b6ac4067eb0db9e667f3f68` | PROVED |
| `Singular.Statements.booked_at_most_once` | L1 — a key is booked at most once at a time; the batch is atomic; a request is spent once | `1c8b3268586a2ca2aaf930c3a45b0f8fde24c061f0ff63bf8962afbb42eb1ec2` | PROVED |
| `Singular.Statements.delete_absent_inversion` | — | `b040a97d18406c2a0be100516a5f9f5ea3f7c1bcc606a0c26eab4eb38828bce5` | PROVED |
| `Singular.Statements.delete_active_inversion` | — | `39b91a52340027b5062725a24c38ee9cb5e568518b6c44727946556be0a903f8` | PROVED |
| `Singular.Statements.empty_fold_error` | — | `8bd6ec570fbda5220c7d841d4396605cf637e094bdeb275d7495f7169a4a1f06` | PROVED |
| `Singular.Statements.fold_batch_claimed_mint_by_kind_key` | T1 — the fold's mint guard is per `(TokenKind, Key)`, strictly finer than a per-kind one, witnessed by a reachable state whose equal-per-kind batch is observed to be refused | `9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988` | PROVED |
| `Singular.Statements.fold_batch_cons` | — | `9e8c6a06d60361ae94b24f50f014c7830bfdd5d22aa8b7a62a8ca9230f689153` | PROVED |
| `Singular.Statements.insert_absent_inversion` | — | `b2ca14e3aa29caef0841c246964e5e64b600eef9ff64c0865677a1219d31525d` | PROVED |
| `Singular.Statements.insert_absent_transaction_row` | Complete absent-insertion transaction: refund-only custody, sole-asset key, deposit, root and custody effects, keyed mint, no required signers or immediate refunds | `cbe444a5bddadef89cba2f1459a597a010531e396a90be4a798fdccc5633fb46` | PROVED |
| `Singular.Statements.insert_active_inversion` | — | `8b5794d17bf859cb01ceae53f2c487cbb22a251464c51364778234f978a9f98b` | PROVED |
| `Singular.Statements.insert_active_transaction_row` | T1 — the transaction an admitted `insertActive` builds: the whole constructed value — two inputs, two outputs, their datums, addresses and assets, the keyed mint, no refunds, no required signer — plus universal open admission and the duplicate-key refusal | `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737` | PROVED |
| `Singular.Statements.no_tree_change_without_approval` | P1 — no tree change without an approval under the pinned policy; the pins never move | `a2fa6756fc4504f0ee55be8013dfb05cf94fde2ae06777cf62c25cfd5352ca1b` | PROVED |
| `Singular.Statements.occupancy` | O1 — a booking edge succeeds only on a key that is not taken | `f73130188c3bb9170d2a56dfaa4c965d1cd7ea93b31077d5b13f0c6b136aa876` | PROVED |
| `Singular.Statements.occupancy_free_key_succeeds` | O1, converse — a booking edge on an untaken key succeeds | `4ee0061a9b764b5548095be259818f55f9beb79907770d850ab4c082b2bbe350` | PROVED |
| `Singular.Statements.readAt_true_iff` | — | `69c6c811a286c3436e0b230319f762de5c3c89e977a8a1d075859159e87d5916` | PROVED |
| `Singular.Statements.read_changes_nothing` | — | `0a53256f91fbd4e8d4de2e8e2b9add39fc6a04ad10327d594d3f74acabdb6120` | PROVED |
| `Singular.Statements.terminal_attestation_permanent` | S2 — permanence: an attestation holds in every later state | `e133aaa076a248d60fc059e2698069b69485c9ba6f3c5a7aa4a209e224c888e2` | PROVED |
| `Singular.Statements.terminal_attestation_sound` | S1 — soundness: no attestation of an Active, Absent or Unknown key exists | `9cd4b73c811ee93427ae8eab5a96db956d0934eb20f3558117426f5b740b12ef` | PROVED |
| `Singular.Statements.terminal_mint_only_by_read` | S1 — provenance: a terminal token is minted only by a folded, verified read | `287bddd3ed1888a07b163f247fb4bdda6a4de049f26d815c5d52be9c82617639` | PROVED |
| `Singular.Statements.terminal_witness_plural` | W3 — the terminal witness is plural | `68beea77527a148a61f7f055d065aec3d1d2c3acdb25231c5c8db851a747efff` | PROVED |
| `Singular.Statements.termination` | T1 — a Terminal leaf is never moved, so the key is never re-booked | `daae0dd7f3dbce91850f546e619f4247a3a7688fbdaf6018f96e7213b5f91027` | PROVED |
| `Singular.Statements.update_active_inversion` | — | `fccc7684da82d92656d5ea79fe3d80749245000052a088a97742ae1df7b20982` | PROVED |
| `Singular.Statements.update_terminal_inversion` | — | `55610f5a33da76d49c9f8e5eee2170af33700b0222530d6548629960133bc470` | PROVED |
| `Singular.Statements.update_terminal_transaction_row` | T1 — the transaction an admitted `updateTerminal` builds: three inputs, the third spending the key's one active witness so the burn has a source, two outputs of which the destination holds no token, the keyed mint of `-1`, no refunds, no required signer — plus the `terminal-immutable`, `key-unknown`, `not-booked` and `token-missing` refusals, each exhibited | `c85a4eb0a61907d71a0861658097e7ab839655023e39bfc4e11a8209553e31c2` | PROVED |
| `Singular.Statements.witness_kinds_exclude` | W4 — the three kinds exclude each other | `7013211d47dd903d511e417866114e9beac7d125ce81f40d3a08efbe996bfd1a` | PROVED |
| `Singular.Statements.witness_terminal_inversion` | — | `1c7af35ddacb820a451811ad329012ea5e45797da9878d2d8681b31589b02288` | PROVED |

The naming, lifecycle and wire declarations are listed in their own manifests:
[naming-theorem-debt.json](../lean/naming-theorem-debt.json),
[lifecycle-theorem-debt.json](../lean/lifecycle-theorem-debt.json) and
[wire-theorem-debt.json](../lean/wire-theorem-debt.json).

## How this register is kept honest

A compiled gate in [Audit.lean](../lean/Singular/Audit.lean) runs while the
library elaborates: it collects the axioms of every theorem in the frozen module
and fails the build if any lies outside the three standard ones. Re-admitting a
single theorem turns the build red, so a `sorry` cannot reach this page.

`tools/check_model.py` then cross-checks three things that are easy to let drift
apart: the source declarations against the manifests, the compiled axiom report
against both, and — added by this ticket — **this page against the manifest**.
The last one exists because it was missing: before it, the page claimed 41
declarations while the manifest held 44, and three proved statements appeared
nowhere. The check is set equality, and the total above is derived from the
manifest rather than typed by hand.

## What this establishes, and what it does not

These proofs establish **properties of the model**. They do not establish that
the model is the right model, and no build ever will: that is what the operator's
rulings, the interface and the simulation are for. A theorem can also be true and
narrower than its name, so the column above says what each one states rather than
leaving the name to imply it.

The model is abstract where the chain is concrete. Commitments stand for
collision-free canonical commitments, the trie is a logical authenticated map,
and an approval's asset name is a commitment over the tuple it scopes rather than
a real BLAKE2b digest. The executable consumer supplies the real hashes; the
model fixes the complete preimages.

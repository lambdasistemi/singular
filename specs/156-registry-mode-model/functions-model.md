# #156 — functions model

New and changed declarations: names, explicit argument names, argument and result
types, and signature-level constraints. No bodies, no proofs, no tactics.

Qualified names are binding: the manifests, the compiled axiom report and the
audit bind to these exact identities.

## Model — the alphabet and the leaf

| declaration | shape | constraint |
|---|---|---|
| `Singular.State` | inductive: `absent`, `active`, `terminal` | decidable equality; the only leaf vocabulary |
| `Singular.Leaf` | inductive: `unknown`, `known (s : State)` | one leaf per key |
| `Singular.encodeState` | `(s : State) → ByteArray` | total, injective |
| `Singular.decodeState` | `(bytes : ByteArray) → Option State` | defined on exactly the three codec bytes; `none` elsewhere |

## Model — the edges

| declaration | shape | constraint |
|---|---|---|
| `Singular.Edge` | inductive: `insertAbsent`, `insertActive`, `updateActive`, `updateTerminal`, `deleteAbsent`, `deleteActive`, `witnessTerminal` | exactly seven; no free-form `update` |
| `Singular.TokenKind` | inductive: `active`, `absent`, `terminal` | exactly three |
| `Singular.delta` | `(e : Edge) → List (TokenKind × Int)` | equals the R2 table; read off the edge and nothing else |
| `Singular.transition` | `(e : Edge) → (before : Leaf) → Option Leaf` | `none` is refusal; totals the R2 from→to column; `none` for every edge out of `known terminal` |

## Model — admission, routing, the fold

| declaration | shape | constraint |
|---|---|---|
| `Singular.Config` | structure with the eight fields of `data-model.md` | no `consumerPin`; equal before and after every fold |
| `Singular.admits` | `(c : Config) → (e : Edge) → (approval : Option Approval) → Bool` | true for `witnessTerminal` with `none`; for the six tree edges requires an approval under `c.applicationPolicy` |
| `Singular.route` | `(k : TokenKind) → (request : Request) → Destination` | `absent` to cage custody, whose datum records the `insertAbsent` refund address; `active` and `terminal` to the request's named output. On consumption the absent token's value goes to that refund address (R-ADA) |
| `Singular.step` | `(s : RegistryState) → (a : Action) → Except String Result` | refuses every `(primitive, value, before-leaf)` triple outside the R2 table, the refused reads included; reasons distinct where the distinction is observable (R3) |
| `Singular.foldBatch` | `(s : RegistryState) → (batch : List Action) → Except String Result` | atomic; refuses a zero-request batch; threads the root so the k-th proof is verified against the root at position k; refuses any mint differing from the summed delta |
| `Singular.readAt` | `(s : RegistryState) → (position : Nat) → (key : Key) → (value : State) → Bool` | verifies against the intermediate root at `position`; leaf unchanged; true only for `value = terminal` |

## Statements

The eleven identities are fixed in `plan.md` and are repeated here as the binding
list for the manifest and the axiom report:

```
Singular.Statements.no_tree_change_without_approval     -- P1
Singular.Statements.booked_at_most_once                 -- L1
Singular.Statements.terminal_attestation_sound          -- S1
Singular.Statements.terminal_attestation_permanent      -- S2
Singular.Statements.biconditional_supply_sync           -- S3
Singular.Statements.occupancy                           -- O1
Singular.Statements.termination                         -- T1
Singular.Statements.active_witness_unique               -- W1
Singular.Statements.absent_witness_unique               -- W2
Singular.Statements.terminal_witness_plural             -- W3
Singular.Statements.witness_kinds_exclude               -- W4
```

Edge inversions accompany them, one per edge, exposing the exact guards and
effects rather than restating a success boolean. Their identities are the commit
owner's to choose within `Singular.Statements`; they are inventoried by the
manifest like any other declaration.

## Open application

| declaration | shape | constraint |
|---|---|---|
| `Singular.OpenApp.policy` | the approval policy that certifies every edge for every key | carries no naming vocabulary |
| `Singular.OpenApp.*` | one instantiation per registry promise | every statement in the list above holds at `policy` |

## Naming — preserved identities

`Singular.NamingStatements.naming_delete_refused`, `Singular.Naming.WellFormed`
and the recovery rows keep their qualified names and their meaning, re-stated over
the new alphabet.

**Correction (A-002):** `over_terminal` is **not** in the naming layer. It is
`Singular.Statements.over_terminal` (Statements.lean:142), and the interface
**supersedes** it with T1 rather than preserving it — as it does
`over_no_representative`, `resolve_over` and the `consumer` theorems in that same
module. Every one of the 44 base generic declarations therefore needs an explicit
disposition: see R12's retirement map in `plan.md`. A declaration that appears in
neither the new manifest nor the map is a finding, not an oversight.

Under ruling A-001 `tools/check_model.py` is **opened to the new identities**, so
its previous corpus-id and source-extent lists are not constraints on this
deliverable. Its discipline is: exact identity matching against the manifests,
PROVED only from the standard axioms, STATED for admitted declarations,
byte-for-byte corpus regeneration, and the keyword/proof-hole audit over `lean/`.
Weakening any of those is a finding, not a repair.

Naming's approval policy follows **R-NM4** (operator ruling) for all six edges:
`insertAbsent` for anyone; `updateActive` on the signature of the controller who
will own the record; `deleteAbsent` on the signature of the refund address the
`insertAbsent` request named; `insertActive` on the controller's;
`updateTerminal` on the quorum's; `deleteActive` never.

## Removed

`Singular.Value`, `Singular.Entry.incarnation`,
`Singular.Representative.assetScope`, `Singular.Config.reuseIdentity`,
`Singular.Config.consumerPin`, `Singular.Operation` with its free-form `update`,
and `Singular.Config.representativePolicy` — renamed to `activePolicy`, so the
old name must not survive either. Removal, not deprecation: a rename would
preserve a distinction the registry does not make.

All seven are checked against the **elaborated environment**, never by a source
grep: a declaration left in place under a new alias passes a grep and must fail
here.

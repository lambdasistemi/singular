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
| `Singular.delta` | `(e : Edge) → List (TokenKind × Int)` | equals the seven-edges-interface table; read off the edge and nothing else |
| `Singular.transition` | `(e : Edge) → (before : Leaf) → Option Leaf` | `none` is refusal; totals the seven-edges-interface from→to column; `none` for every edge out of `known terminal` |

## Model — admission, routing, the fold

| declaration | shape | constraint |
|---|---|---|
| `Singular.Config` | structure with the eight fields of `data-model.md` | no `consumerPin`; equal before and after every fold |
| `Singular.admits` | `(c : Config) → (e : Edge) → (approval : Option Approval) → Bool` | true for `witnessTerminal` with `none`; for the six tree edges requires an approval under `c.applicationPolicy` **whose `(edge, key, owner, destination)` tuple matches the request** (approval-asset-binding). The approval's asset name is `blake2b_256(edge ‖ key ‖ owner ‖ destination)` and it is **not burned at the fold** |
| `Singular.route` | `(k : TokenKind) → (request : Request) → Destination` | `absent` to cage custody, whose datum records the `insertAbsent` refund address; `active` and `terminal` to the request's named output. On consumption the absent token's value goes to that refund address (custody-lovelace-refund) |
| `Singular.step` | `(s : RegistryState) → (a : Action) → Except String Result` | refuses every `(primitive, value, before-leaf)` triple outside the seven-edges-interface table, the refused reads included; reasons distinct where the distinction is observable (refused-combinations-as-complement) |
| `Singular.foldBatch` | `(s : RegistryState) → (batch : List Action) → Except String Result` | atomic; refuses a zero-request batch; threads the root so the k-th proof is verified against the root at position k; refuses any mint differing from the summed delta |
| `Singular.readAt` | `(s : RegistryState) → (position : Nat) → (key : Key) → (value : State) → Bool` | verifies against the intermediate root at `position`; leaf unchanged; true only for `value = terminal` |

## The oracle observation surface — required, and read-only to the author

The gate's frozen oracle (leg independent-model-oracle) evaluates the model **at inputs the ticket
owner fixed before any code existed** and compares to expected outputs the author
cannot regenerate. That is what makes the gate measure correspondence instead of
self-consistency, and it is the repair for the UNFIT verdict the blind gate audit
returned on gate `a3`.

So the model must expose these total observations. They are the contract the
oracle reads; everything behind them is the author's to shape freely.

| declaration | shape | constraint |
|---|---|---|
| `Singular.Oracle.Approval` | inductive: `none`, `application`, `other`, `mismatched` | the four admission cases the oracle distinguishes. `mismatched` is an approval under the **correct** pinned policy whose `(edge, key, owner, destination)` tuple does not match — the case that makes approval-asset-binding observable, and the one a model gets wrong by checking only the policy |
| `Singular.Oracle.Destination` | inductive: `cageCustody`, `requestOutput` | where a minted token goes |
| `Singular.Oracle.RefundTarget` | inductive: `insertRefundAddress`, `requestOutput`, `folder` | the three candidate deposit destinations; only the first is correct (custody-lovelace-refund), and the other two exist so a wrong answer is *expressible* and therefore detectable |
| `Singular.Oracle.transition` | `(e : Edge) → (before : Leaf) → Option Leaf` | `none` is refusal |
| `Singular.Oracle.delta` | `(e : Edge) → (k : TokenKind) → Int` | total: a kind the edge does not move is `0` |
| `Singular.Oracle.encode` | `(s : State) → List UInt8` | the leaf codec, three-state-leaf-codec |
| `Singular.Oracle.decode` | `(bytes : List UInt8) → Option State` | `none` off the three codec bytes |
| `Singular.Oracle.admits` | `(e : Edge) → (a : Approval) → Bool` | admission-interface and application-decides-absence-booking |
| `Singular.Oracle.route` | `(k : TokenKind) → Destination` | token-custody-routing, fold-minting-absent-token-it-completes-absent |
| `Singular.Oracle.refund` | `(e : Edge) → Option RefundTarget` | custody-lovelace-refund: the two edges that consume an absent token pay `insertRefundAddress`; every other edge is `none` |

These are **observations, not a second model.** Each must be defined in terms of
the real model — the fold, the transition, the routing the cage performs — never
as an independent table written to satisfy the oracle. A surface that hard-codes
the oracle's answers while the model does something else is the exact defect the
anti-cheat pass looks for, and obligation definition-mutant-controls's mutants are what catch it: mutate
the model and the observations must move with it.

The oracle itself lives **outside the repository**, in the ticket runtime root.
Gate leg frozen-scope-check refuses any diff that touches the mandate or the oracle, so the
author cannot see the expected values, edit them, or regenerate them.

## Statements

The eleven identities are fixed in `plan.md` and are repeated here as the binding
list for the manifest and the axiom report:

```
Singular.Statements.no_tree_change_without_approval     -- tree-change-requires-approval
Singular.Statements.booked_at_most_once                 -- request-spent-once-in-order
Singular.Statements.terminal_attestation_sound          -- terminal-attestation-sound
Singular.Statements.terminal_attestation_permanent      -- terminal-attestation-permanent
Singular.Statements.biconditional_supply_sync           -- supply-matches-leaf-state
Singular.Statements.occupancy                           -- booking-requires-untaken-key
Singular.Statements.termination                         -- terminal-key-cannot-change
Singular.Statements.active_witness_unique               -- active-witness-unique
Singular.Statements.absent_witness_unique               -- absent-witness-unique
Singular.Statements.terminal_witness_plural             -- terminal-witnesses-plural
Singular.Statements.witness_kinds_exclude               -- witness-kinds-exclude
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

**Correction (operator answer (A-002)):** `over_terminal` is **not** in the naming layer. It is
`Singular.Statements.over_terminal` (Statements.lean:142), and the interface
**supersedes** it with terminal-key-cannot-change rather than preserving it — as it does
`over_no_representative`, `resolve_over` and the `consumer` theorems in that same
module. Every one of the 44 base generic declarations therefore needs an explicit
disposition: see retirement-map-for-generic-statements's retirement map in `plan.md`. A declaration that appears in
neither the new manifest nor the map is a finding, not an oversight.

Under ruling operator answer (A-001) `tools/check_model.py` is **opened to the new identities**, so
its previous corpus-id and source-extent lists are not constraints on this
deliverable. Its discipline is: exact identity matching against the manifests,
PROVED only from the standard axioms, STATED for admitted declarations,
byte-for-byte corpus regeneration, and the keyword/proof-hole audit over `lean/`.
Weakening any of those is a finding, not a repair.

Naming's approval policy follows **naming-approval-rules** (operator ruling) for all six edges:
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

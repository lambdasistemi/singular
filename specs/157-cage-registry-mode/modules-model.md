# #157 — modules model

Responsibility and dependency direction only. No bodies.

## Dependency direction

```
onchain/validators
  types.ak        State (8), Operation (+Read), Request (+destination), CageDatum (+AbsentCustody)
  lib.ak          codec helpers: decodeState, approvalName, destinationMatches
  state.ak        the cage: admissibility, read, admission, delta, custody, coverage
  request.ak      Contribute / Retract (reads retractable)
  shared.ak       unchanged
  staking.ak      unchanged
  consumer.ak     DELETED
  consumer.tests  DELETED

naming-onchain/validators
  naming.ak             NamingRecord and helpers; value vocabulary DELETED
  witness.ak            NEW: witness(kind, registry) — the three token policies
  representative.ak     DELETED (replaced by witness kind 1)
  application.ak        parameter: applied ordinary request-validator hash;
                        spend: Maintain | Retire | Recover; mint: Approve {..}
  retirement_custody.ak completion-only custody, unchanged rules

conformance/            encodings and rows re-baselined against the new blueprint; X1 executable here
offchain/lib            ToData/FromData for the changed types, plus Config.hs and the four TxBuilder
                        files the encodings force to compile (D-BOOT); journeys are #158
docs/                   consumer-conformance.md; naming-lifecycle.md; naming-demo.md; recovery-retirement.md
```

The cage depends on nothing of naming's and has no `RequestDatum` spending arm.
Naming depends on the cage's state token and policy ids, and on the applied
ordinary request-validator hash for that same registry; nothing of naming runs
at fold time.

## Changed responsibilities

| module | responsibility after this ticket |
|---|---|
| `types.ak` | Owns the eight-field `State`, `Operation` with `Read`, `Request` with `destination`, `CageDatum` with `AbsentCustody`. Indices appended, never reordered. |
| `lib.ak` | Owns the pure helpers the cage and the tests share: codec decode, the approval-name formula, destination matching, custody-datum shape. |
| `state.ak` | Owns admissibility (C2), the read (C3), admission (C4), the delta (C5), destinations and custody (C6), field preservation (C7), coverage (C8). Loses the consumer pin, the withdrawal requirement and the representative-policy-only check. |
| `request.ak` | Owns ordinary `Contribute` and Retract; the completion request remains here, and Retract admits `Read` beside `Insert`. |
| `witness.ak` | **New.** One parametrised policy, three instances; co-presence with a `Modify`; terminal burns free. |
| `application.ak` | Is applied to the immutable ordinary request-validator hash derived for the same registry. Owns the record's own moves (`Maintain`, `Retire`, `Recover`) and the approval mint arm for six edges. `Retire` co-creates the bound completion request at that validator but does not write terminal. Loses `Fold`, `Cancel`, `WithdrawApproval`, `InsertApproval` and the claim lifecycle. |
| `retirement_custody.ak` | Unchanged rules; the burned asset is under the active policy (`witness` kind 1). |
| `naming.ak` | Loses `over_marker_for` and the naming leaf vocabulary; keeps the record codec and the mirror helpers, updated to the eight-field state. |
| `conformance/` | Re-baselines CS01/CS02/CS08 and the address rows; records the contract change. |
| `offchain/` encodings and what they force | `offchain/lib/Singular/Registry/Types.hs` follows the blueprint, and the library/runner files the new encodings force to compile under `-Werror` follow it: `Config.hs` (four derived pins, D-BOOT; `cfgConsumerPin` deleted), `TxBuilder/ConnectedFold.hs`, `TxBuilder/Reject.hs`, `TxBuilder/Update.hs`, `TxBuilder/Internal.hs`, `Deployment.hs` (derives cage/token → applied request hash → applied NYA/policy as one checked tuple; `CageParts` carries the resulting identities and drops legacy fields), `TxBuilder/Register.hs` (consumer registration deleted), `Blueprint.hs` (fixed-tuple schema `STuple [Schema]` for D-DEST's pair; `SList` unchanged; arity and element types still enforced). |
| `offchain/journey/**` existing journeys and their CI jobs | Re-cut to the registry-mode contract (X3): boot with four pins, approval + destination requests, fold-created record, recovery-key retirement; retired rows mapped in the README, never stubbed. No new journey — `witness-rows` is #158's. |

## Out of this ticket's surface

All Lean outside the bounded D-157 repair, `simulator/**` (#163), `offchain/journey/**` and the
release archive (#158), the escrow (#152), the CLI (#139), `docs/preprod*`
(#153), the interface page (#159). Touching any is a Q to the epic owner.

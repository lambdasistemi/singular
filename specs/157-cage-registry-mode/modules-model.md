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
  application.ak        spend: Maintain | Retire | Recover; mint: Approve {..}
  retirement_custody.ak completion-only custody, unchanged rules

conformance/            encodings and rows re-baselined against the new blueprint; compiled-wire-conformance executable here
offchain/lib            ToData/FromData for the changed types, plus Config.hs and the four TxBuilder
                        files the encodings force to compile (genesis-policy-pins)
offchain/journey/Main.hs bounded registry journey, adapted here; seven Naming Your Assets journeys re-cut in #172 under #174
docs/                   consumer-conformance.md; naming-lifecycle.md; naming-demo.md; recovery-retirement.md
```

The cage depends on nothing of naming's. Naming depends on the cage's state
token and policy ids, and on nothing at fold time.

## Changed responsibilities

| module | responsibility after this ticket |
|---|---|
| `types.ak` | Owns the eight-field `State`, `Operation` with `Read`, `Request` with `destination`, `CageDatum` with `AbsentCustody`. Indices appended, never reordered. |
| `lib.ak` | Owns the pure helpers the cage and the tests share: codec decode, the approval-name formula, destination matching, custody-datum shape. |
| `state.ak` | Owns admissibility (seven-admitted-edges), the read (read-preserves-intermediate-root), admission (tree-edge-admission-by-approval), the delta (mint-matches-edge-deltas), destinations and custody (token-destinations-and-refunds), field preservation (state-datum-fields), coverage (request-covers-tip). Loses the consumer pin, the withdrawal requirement and the representative-policy-only check. |
| `request.ak` | Owns Contribute and Retract; Retract admits `Read` beside `Insert`. |
| `witness.ak` | **New.** One parametrised policy, three instances; co-presence with a `Modify`; terminal burns free. |
| `application.ak` | Owns the record's own moves (`Maintain`, `Retire`, `Recover`) and the approval mint arm for six edges. Loses `Fold`, `Cancel`, `WithdrawApproval`, `InsertApproval` and the claim lifecycle. |
| `retirement_custody.ak` | Unchanged rules; the burned asset is under the active policy (`witness` kind 1). |
| `naming.ak` | Loses `over_marker_for` and the naming leaf vocabulary; keeps the record codec and the mirror helpers, updated to the eight-field state. |
| `conformance/` | Re-baselines blueprint-encoding-round-trip/submitted-datum-byte-round-trip/state-fields-chain-round-trip and the address rows; records the contract change. |
| `offchain/` encodings and what they force | `offchain/lib/Singular/Registry/Types.hs` follows the blueprint, and the library/runner files the new encodings force to compile under `-Werror` follow it: `Config.hs` (four derived pins, genesis-policy-pins; `cfgConsumerPin` deleted), `TxBuilder/ConnectedFold.hs`, `TxBuilder/Reject.hs`, `TxBuilder/Update.hs`, `TxBuilder/Internal.hs`, `Deployment.hs` (`CageParts` carries the four derived identities, legacy fields dropped), `TxBuilder/Register.hs` (consumer registration deleted), `Blueprint.hs` (fixed-tuple schema `STuple [Schema]` for request-destination-binding's pair; `SList` unchanged; arity and element types still enforced). |
| `offchain/journey/Main.hs` | The bounded registry journey is #157's and is adapted here to the registry-mode contract. |
| The seven Naming Your Assets journey sources and their six CI jobs | `li01`, `li-refusals`, `lmlc`, `recovery`, `retirement`, `retire-verify` and `repair` stay at `main`; their re-cut is #172 under #174. Their six CI job blocks are retired here under singular-step-refusal-reasons with seven surfaces mapped, never stubbed. |

## Out of this ticket's surface

`lean/**` (#156, frozen), `simulator/**` (#163), the seven Naming Your Assets journey
sources named above (#172 under #174) and the release archive (#158), the
escrow (#152), the CLI (#139), `docs/preprod*`
(#153), the interface page (#159). Touching any is a Q to the epic owner.

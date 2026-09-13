# Consumer registration tranche gate v1

Frozen by the epic-18 owner before compositor implementation under NOTE-110.
This is the post-change world for registration E0/E1/E4. It is intentionally
RED until the final epic-17 tuple is available; a scaffold can make progress but
cannot be accepted as this tranche.

## Candidate and fence

- pre-slice base: `0100012b1afa318df3bae6cf40d6d9ee3507110e`;
- writable slice: `conformance/consumer-adapter/**` only;
- producer paths `onchain/**`, `naming-onchain/**`, `offchain/**`, release tools
  and cardano-keri are read-only inputs;
- the candidate must be a clean local commit descended from the base;
- runner interface:
  `conformance/consumer-adapter/run-registration-gate <evidence-dir>`;
- parent executable:
  `owner-sol-20260912/gates/consumer-registration-v1.sh`.

The runner is implementation-owned and therefore not its own oracle. The parent
gate checks its fresh machine record. Independent compiled-code review and
mutation/anti-fit review remain required before owner acceptance.

## Frozen registration interpretation

On this registry instance a processed generic `Insert` is registration. The
adapter derives the obligation from the exact processed request and transaction,
not from a separate operation flag:

- the request input is under the pinned registry state policy/token and is one of
  the exact `Modify` batch inputs;
- its `requestKey` equals the checkpoint asset name derived by
  `deriveAidAssetName` from the lifecycle-validated checkpoint datum;
- its inserted value is the canonical active-leaf encoding of the complete
  checkpoint native asset identity, policy plus asset name;
- the state input's appended native script hash equals the actually executed
  adapter withdrawal credential and is preserved in the successor;
- the lifecycle observer withdrawal is zero, uses the exact applied registered
  credential, and its envelope is register for the same checkpoint policy;
- the checkpoint policy mints exactly one token with that derived name and the
  unique checkpoint output at its script address carries it with the exact
  lifecycle-validated datum and required registration bond;
- the processed request's bond is locked there and its tip is paid to the folder;
  owner, folder and checkpoint destinations are checked from authenticated inputs
  and the fold transaction, not supplied totals;
- the complete mint map has no other checkpoint-policy entry. Receipt-policy
  accounting is a separate future tranche and is not invented here;
- `Delete`, `End`, an uncorrelated request, altered pin, omitted/swapped adapter,
  and surplus action are refused.

The concrete Aiken types and CBOR vectors must expose the constructor/field order
and width checks. A perfect implementation may choose internal helpers freely;
the gate binds behavior and native identities, not helper names.

## Required identity record

Fresh `identity.json` must bind:

- candidate commit and clean tree;
- consumer source commit exactly
  `14a64a4681d3e429fab5877062b5c476c2a4bfe2`;
- actual Aiken/compiler and dependency lock identities;
- Plutus V3 and live protocol major; for the commissioned PV10 devnet the CEK
  variant is explicitly `defaultFunSemanticsVariantC`; any PV11+ run without
  Variant E is `COULD-NOT-EVALUATE`;
- final epic-17 state/request/application and applied-representative bytes/hashes;
- adapter unapplied/applied bytes, parameters and hashes;
- checkpoint policy plus lifecycle observer source, unapplied/applied bytes,
  parameter values, hashes and registered credentials;
- all declared artifacts from an explicit inventory. Missing, duplicate or
  unclassified artifacts fail.

## Whole-operation results

`results.json` contains these exact rows. `ESTABLISHED` and `REFUTED` mean the
actual compiled programs ran. Setup, decode, unsupported-builtin, opaque error,
timeout or missing trace is `COULD-NOT-EVALUATE` and fails.

| id | expected | required stage/purpose |
|---|---|---|
| `E0-register-valid-cek` | `ESTABLISHED` | all final producer, adapter, lifecycle and checkpoint programs on one coherent context |
| `E0-register-valid-ledger` | `ESTABLISHED` | registered credentials, submitted valid transaction, queried checkpoint/state/folder outputs |
| `E1-missing-inception-cek` | `REFUTED` | lifecycle withdrawal purpose; otherwise E0-identical |
| `E1-missing-inception-ledger` | `REFUTED` | submitted transaction, attributable lifecycle script failure; not builder-only |
| `E4-wrong-allocation-cek` | `REFUTED` | adapter withdrawal; totals equal E0, checkpoint bond misrouted |
| `E4-wrong-allocation-ledger` | `REFUTED` | submitted transaction, attributable adapter failure; not builder-only |
| `register-omitted-adapter` | `REFUTED` | producer state spend |
| `register-swapped-adapter` | `REFUTED` | producer state spend/pin |
| `register-extra-checkpoint-mint` | `REFUTED` | adapter withdrawal |
| `register-wrong-aid-name` | `REFUTED` | adapter withdrawal or lifecycle, precisely attributed |
| `register-delete` | `REFUTED` | adapter withdrawal |
| `register-surplus-action` | `REFUTED` | producer state spend |

Every negative retains the same setup and a nearby positive. Ledger rows retain
raw bodies, submissions, txids, queried pre/post UTxOs, registration certificates
and exact script-failure attribution.

## Per-class falsification controls

Each source mutant is rebuilt by the production compiler; the record proves the
mutated source changed the tested compiled bytes, then restores and rechecks the
clean artifact. The inventory-removal control changes the enumerated artifact
set rather than compiled bytes and records that separately. `controls.json`
reports `REFUTED` for:

- `always-refuse`: E0 stops establishing, proving the positive is reachable;
- `always-accept`: E4 and the unsupported-operation negative become accepted,
  proving those refusals are not setup failures (E1 remains independently owned
  by the lifecycle observer);
- `remove-inception-observer-check`: E1 becomes accepted;
- `remove-allocation-check`: E4 becomes accepted;
- `remove-unaccounted-checkpoint-check`: the extra-mint row becomes accepted;
- `remove-mandatory-adapter-invocation`: omitted adapter becomes accepted;
- `inventory-remove-one`: artifact completeness fails by the missing name, with
  `inventory_changed=true` rather than a compiled-byte-change claim.

One mutation does not license another class. Mutation discrimination is not the
real-ledger layer.

## Not certified by v1

Revive, goDormant, goConvicted and dormant conviction; receipt mint/burn; the
dormant rotation bridge; dormant duplicity; snapshot burning; or the rest of the
192-obligation board. Those remain separately named debt.

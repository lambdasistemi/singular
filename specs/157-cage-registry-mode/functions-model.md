# #157 — functions model

New and changed declarations: names, arguments, results, signature-level
constraints. No bodies.

## `onchain/validators/lib.ak`

| declaration | shape | constraint |
|---|---|---|
| `decodeState(bytes: ByteArray) -> Option<Int>` | `0x00`→0, `0x01`→1, `0x02`→2, else `None` | total; the only codec |
| `edgeOf(op: Operation, before: Option<Int>) -> Option<Int>` | the C2 row index or `None` | `None` for every refused shape; pure |
| `deltaOf(edge: Int) -> List<(Int, Int)>` | `(kind, quantity)` pairs per C2 | read off the edge and nothing else |
| `approvalName(edge: Int, key, owner, destination) -> ByteArray` | `blake2b_256(edge ‖ key ‖ owner ‖ destination)` | D-APPROVAL; shared with naming's tests |
| `destinationMatches(dest: (ByteArray, ByteArray), out: Output) -> Bool` | address equality and inline-datum hash equality | D-DEST |

## `onchain/validators/state.ak`

| declaration | shape | constraint |
|---|---|---|
| `mkAction(...)` | fold step over inputs | admits only C2 shapes (`edgeOf`); `Read` via `mpf.update(root, key, proof, v, v) == root`; accumulates the per-key delta and the destination obligations |
| `validModify(state, input, policyId, tokenId, tx, actions)` | the fold | preserves seven fields; requires the approval on each tree edge (`approvalName` recomputed); checks the summed delta against `tx.mint` under the three policies; checks each destination and custody output; checks `lovelace_of(request) ≥ tip`; refuses zero consumed requests; no withdrawal requirement |
| `validCustodySpend(datum: AbsentCustody, tx)` | the cage's spending path for a custody UTxO | spent only inside a `Modify` consuming `Update(0x00,0x01)` or `Delete(0x00)` for its key; refund output at `refund` ≥ held lovelace |
| `validateMint(seed, policyId, tx)` | genesis | sets the four policies; no pin width check |

## `onchain/validators/request.ak`

| declaration | change |
|---|---|
| `validateRetract` | admits `Read(_)` beside `Insert(_)` |

## `naming-onchain/validators/witness.ak`

| declaration | shape | constraint |
|---|---|---|
| `validator witness(kind: Int, registry: ByteArray)` | mint purpose | any movement under this policy requires a spent registry state input with a `Modify` redeemer; for `kind == 2` a pure burn needs nothing |

## `naming-onchain/validators/application.ak`

| declaration | shape | constraint |
|---|---|---|
| `ApplicationRedeemer` | `Maintain`, `Retire { key }`, `Recover { revealed_control, registry }` | `Fold`, `Cancel` removed |
| `ApplicationMintRedeemer` | `Approve { edge, key, owner, destination }` | asset name `== approvalName(..)`; exactly one asset moves |
| `approve(edge, key, owner, destination, tx) -> Bool` | the six arms of R-NM4 | `insertAbsent` unconditional; `insertActive`/`updateActive` owner signs and `destination` is the application address with a well-formed record datum hash; `updateTerminal` controller or quorum from the record input; `deleteAbsent` refund key signs, custody as reference input; `deleteActive` `False` |
| `retire(record, custody_out, key, tx)` | as today plus: the same transaction mints `Approve { updateTerminal, key, .. }` and creates the completion request | authorization unchanged (LT01/LT02/LT03) |

## `naming-onchain/validators/naming.ak`

| declaration | change |
|---|---|
| `over_marker_for` | deleted |
| `MpfsState`, `mpfs_state_datum*` | eight fields |
| `mrequest`, `MOperation` | `Read` and `destination` |

## Removed

`consumer.ak` and `consumer.tests.ak`; `representative.ak` and its tests
(replaced by `witness.ak` and `witness.tests.ak`); `Fold`, `Cancel`,
`WithdrawApproval`, `InsertApproval` and their rows (`LC*`, the claim
`fold_*` rows); `consumer_pin` in every builder and fixture.

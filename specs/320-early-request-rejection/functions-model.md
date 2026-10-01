# Functions: new and changed signatures

Only signatures and their constraints. Bodies, helpers and tests belong to the implementation.

## Removed

| ID | Function | Where | Constraint |
|---|---|---|---|
| F-01 | `is_rejectable(validity_range, submitted_at, process_time, retract_time) -> Bool` | `onchain/validators/shared.ak` | removed in the same change as its last caller |
| F-02 | `is_rejectable(validity_range, submitted_at, process_time, retract_time) -> Bool` | `onchain/validators/cage.ak` | removed with F-01 |
| F-03 | `reject :: reg -> EdgeRequest wal -> Story reg wal step obs cmp step` | `conformance/lib/Conformance/Story/Live.hs` | replaced by F-06; every caller moves in the same change. `tamperExit` keeps serving folds and retractions; applied to a reject, story validation refuses it (F-07 replaces that use). |

## Changed, same signature

| ID | Function | Where | Change |
|---|---|---|---|
| F-04 | `validateContribute(statePolicyId: PolicyId, cageToken: TokenId, request: Request, stateRef: OutputReference, tx: Transaction)` | `onchain/validators/request.ak` | admission per data model D-02. It may take the request's own `OutputReference` if locating its matching action needs it. That is the only signature change permitted here. |
| F-05 | `stepRequest(acc: Fold, pins: State, request: Request, input: Input, validity_range) -> Fold` | `onchain/validators/registry/fold.ak` | `Rejected` arm per D-01 |
| F-09 | `rejectRequestsImpl :: CageConfig -> Provider IO -> TokenId -> Addr -> IO ConwayTx`, `rejectRequestsWithRefs :: CageConfig -> Provider IO -> TokenId -> Addr -> [(TxIn, TxOut ConwayEra)] -> IO ConwayTx` | `offchain/lib/Singular/Registry/TxBuilder/Reject.hs` | selection per D-06; validity not bound to any deadline. The exported signatures are unchanged, so no caller changes. |
| F-10 | `runCG09 :: Env -> IO ()` | `conformance/app/Conformance/Run/CgRows.hs` | records the chain's acceptance with verdict held, after its refused short-refund control on the same request (D-05) |

## Added

| ID | Function | Where | Constraint |
|---|---|---|---|
| F-06 | `rejectWithin :: Placement -> reg -> EdgeRequest wal -> Story reg wal step obs cmp step` | `conformance/lib/Conformance/Story/Live.hs` | D-04. The book renders the placement. |
| F-07 | `tamperRejectWithin :: Tamper -> Placement -> reg -> EdgeRequest wal -> Story reg wal step obs cmp step` | same | a tampered reject placed in a window, for the refund-floor controls |
| F-08 | `data Placement` with three constructors (D-04), deriving `Eq`, `Show`, `Enum`, `Bounded` | same | `Enum`/`Bounded` is what the totality control quantifies over |
| F-11 | `runCG24 :: Env -> IO ()` and its story `story :: Context reg wal -> Story reg wal step obs cmp ()` in a new `Conformance.Edge.EarlyReject` | `conformance/app/Conformance/Run/CgRows.hs`, `conformance/lib/Conformance/Edge/EarlyReject.hs` | the row is CG24, added to the dispatcher, the book's chapters and the row count |

The interpreter's internal realization of F-06/F-07 in `conformance/app/Conformance/Run/Live.hs` is not part of this model. Its observable rule is in D-04.

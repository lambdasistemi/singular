# Functions: new and changed signatures

Only signatures and their constraints. Bodies, helpers and tests belong to the implementation.

## Removed

| ID | Function | Where | Constraint |
|---|---|---|---|
| shared-is-rejectable | `is_rejectable(validity_range, submitted_at, process_time, retract_time) -> Bool` | `onchain/validators/shared.ak` | removed in the same change as its last caller |
| cage-is-rejectable | `is_rejectable(validity_range, submitted_at, process_time, retract_time) -> Bool` | `onchain/validators/cage.ak` | removed with shared-is-rejectable |
| reject | `reject :: reg -> EdgeRequest wal -> Story reg wal step obs cmp step` | `conformance/lib/Conformance/Story/Live.hs` | replaced by reject-within; every caller moves in the same change. `tamperExit` keeps serving folds and retractions; applied to a reject, story validation refuses it (tamper-reject-within replaces that use). |

## Changed, same signature

| ID | Function | Where | Change |
|---|---|---|---|
| validate-contribute | `validateContribute(statePolicyId: PolicyId, cageToken: TokenId, request: Request, stateRef: OutputReference, tx: Transaction)` | `onchain/validators/request.ak` | admission per data model request-s-matching-action. It may take the request's own `OutputReference` if locating its matching action needs it. That is the only signature change permitted here. |
| step-request | `stepRequest(acc: Fold, pins: State, request: Request, input: Input, validity_range) -> Fold` | `onchain/validators/registry/fold.ak` | `Rejected` arm per reject-s-admission |
| reject-requests-impl | `rejectRequestsImpl :: CageConfig -> Provider IO -> TokenId -> Addr -> IO ConwayTx`, `rejectRequestsWithRefs :: CageConfig -> Provider IO -> TokenId -> Addr -> [(TxIn, TxOut ConwayEra)] -> IO ConwayTx` | `offchain/lib/Singular/Registry/TxBuilder/Reject.hs` | selection per builder-selection; validity not bound to any deadline. The exported signatures are unchanged, so no caller changes. |
| run-reject-before-deadline-consumer-requirement | `runRejectBeforeDeadlineConsumerRequirement :: Env -> IO ()` | `conformance/app/Conformance/Run/CgRows.hs` | records the chain's acceptance with verdict `unmet-by-ruling` (operator ruling 2026-10-01), after its refused short-refund control on the same request (reject-before-deadline-consumer-requirement-s-result) |

## Added

| ID | Function | Where | Constraint |
|---|---|---|---|
| reject-within | `rejectWithin :: Placement -> reg -> EdgeRequest wal -> Story reg wal step obs cmp step` | `conformance/lib/Conformance/Story/Live.hs` | reject-placement-in-story-language. The book renders the placement. |
| tamper-reject-within | `tamperRejectWithin :: Tamper -> Placement -> reg -> EdgeRequest wal -> Story reg wal step obs cmp step` | same | a tampered reject placed in a window, for the refund-floor controls |
| rejection-placement | `data Placement` with three constructors (reject-placement-in-story-language), deriving `Eq`, `Show`, `Enum`, `Bounded` | same | `Enum`/`Bounded` is what the totality control quantifies over |
| run-reject-inside-processing-and-retraction-windows | `runRejectInsideProcessingAndRetractionWindows :: Env -> IO ()` and its story `story :: Context reg wal -> Story reg wal step obs cmp ()` in a new `Conformance.Edge.EarlyReject` | `conformance/app/Conformance/Run/CgRows.hs`, `conformance/lib/Conformance/Edge/EarlyReject.hs` | the row is reject-inside-processing-and-retraction-windows, added to the dispatcher, the book's chapters and the row count |

The interpreter's internal realization of reject-within/tamper-reject-within in `conformance/app/Conformance/Run/Live.hs` is not part of this model. Its observable rule is in reject-placement-in-story-language.

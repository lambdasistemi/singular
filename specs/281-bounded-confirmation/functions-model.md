# Wait bound function boundaries

As a maintainer, I want the bounded forms injectable for tests while the public confirmation functions keep their signatures.

## Signatures

| ID | Signature-level obligation |
| --- | --- |
| F281-W | `boundWait :: WaitStage -> TxId -> Int -> IO a -> IO a` runs the whole action. If the action has not returned after `bound` seconds, it cancels the action and throws the wait failure with the measured elapsed time. It does not mask asynchronous exceptions from the caller. |
| F281-B | `submissionBound :: Int` is the production submission bound in seconds. |
| F281-S | `boundedSubmitter :: Int -> Submitter IO -> Submitter IO` returns a prompt `Submitted` or `Rejected` unchanged and throws the wait failure (stage submission) when there is no verdict within the bound. |
| F281-I | `awaitIndexedWithin :: Int -> ConwayTx -> IO ()` is indexed confirmation under an explicit window. `awaitIndexed :: ConwayTx -> IO ()` keeps its signature and applies the production window. |
| F281-C | `confirmWithin :: Int -> NodeSession -> String -> TxId -> SlotNo -> IO ()` is session confirmation under an explicit wall-clock limit, exported from `node-internal` for tests. `awaitTx`, `awaitTxId` and `awaitTxWindow` keep their signatures and apply the derived production limit. |

The coder chooses local helper names inside these owners. A placement or signature conflict goes to the ticket owner as a question before the RED commit. The mandate is versioned, not worked around.

# Wait bound function boundaries

As a maintainer, I want the bounded forms injectable for tests while the public confirmation functions keep their signatures.

## Signatures

| ID | Signature-level obligation |
| --- | --- |
| bound-wait | `boundWait :: WaitStage -> TxId -> Int -> IO a -> IO a` runs the whole action. If the action has not returned after `bound` seconds, it cancels the action and throws the wait failure with the measured elapsed time. It does not mask asynchronous exceptions from the caller. |
| submission-bound | `submissionBound :: Int` is the production submission bound in seconds. |
| bounded-submitter | `boundedSubmitter :: Int -> Submitter IO -> Submitter IO` returns a prompt `Submitted` or `Rejected` unchanged and throws the wait failure (stage submission) when there is no verdict within the bound. |
| await-indexed-within | `awaitIndexedWithin :: Int -> ConwayTx -> IO ()` is indexed confirmation under an explicit window. `awaitIndexed :: ConwayTx -> IO ()` keeps its signature and applies the production window. |
| confirm-within | `confirmWithin :: Int -> NodeSession -> String -> TxId -> SlotNo -> IO ()` is session confirmation under an explicit wall-clock limit, exported from `node-internal` for tests. It raises the wait failure both when the limit fires and when the tip passes the deadline. `awaitTx`, `awaitTxId` and `awaitTxWindow` keep their signatures and apply the derived production limit. Every node read they make, including the ones that compute the deadline and the limit, runs inside a bound. |
| try-outcome | `tryOutcome :: IO a -> IO (Either SomeException a)` returns `Left` for any synchronous exception the action throws, except the wait failure, which it rethrows. Asynchronous exceptions propagate. Every classifier in exception-classifiers-that-reach-submission-or-confirmation uses it in place of a catch-all. |

The coder chooses local helper names inside these owners. A placement or signature conflict goes to the ticket owner as a question before the RED commit. The mandate is versioned, not worked around.

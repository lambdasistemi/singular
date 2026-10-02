{- | What a take on an existing registry decides before it acts.

A take on a registry that already exists cannot be reset, so every decision
that keeps it from doing the wrong thing is made here, from values, before a
transaction is built, signed or sent:

* a node-judged transaction goes out only under an explicit collateral
  allowance, stating a total within it and returning the rest of its funding
  output ('submissionProblem');
* an action's outcome lets the take go on to its own checks only when it is
  an answer the story can judge, and any other outcome stops the take
  ('continues', 'TakeStopped');
* a retraction names the one request the take's own insertion left pending,
  and spends it only while the registry still looks as that insertion's
  readback saw it ('reclaimTarget').
-}
module Conformance.Cli.Attach
    ( LiveRequest (..)
    , TakeStopped (..)
    , continues
    , fundingProblem
    , reclaimTarget
    , submissionProblem
    ) where

import Control.Exception (Exception)
import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Tx.Ledger (ConwayTx)

import Conformance.Cli.Controls
    ( Observation (..)
    , Receipt (..)
    )

{- | The take stopped, naming the step and why: an action's outcome that no
clause of the story judges, or a requirement of the story that did not hold.
Nothing after it ran.
-}
newtype TakeStopped = TakeStopped Text
    deriving stock (Show)

instance Exception TakeStopped

{- | Whether a take goes on after an action that ended this way. Only
outcomes the story's own requirements can judge: a command's success or its
partial stop, a transaction the chain accepted or the node refused, a
readback. Anything else — a client error, an unknown submission, an
unconfirmed transaction, a timeout, a lost node, a concurrent writer — is
uncertainty, and an uncertain take stops.
-}
continues :: Text -> Bool
continues outcome =
    outcome
        `elem` ["success", "partial", "accepted", "ledger-refused", "observed"]

{- | Why a transaction may not be sent. A take must have an explicit
allowance; a transaction that puts collateral at risk must state a total
within it and a return of the rest of its funding output. The rule is
checked on the body, before it is signed.
-}
submissionProblem
    :: Bool
    -- ^ Whether the run must have an allowance
    -> Maybe Integer
    -- ^ The explicit allowance, if the run set one
    -> ConwayTx
    -> Maybe Text
submissionProblem required Nothing _
    | required =
        Just
            "no collateral allowance was set, so nothing is signed: the exposure of a node-judged transaction is not bounded"
    | otherwise = Nothing
submissionProblem _ (Just allowance) tx
    | Set.null (tx ^. bodyTxL . collateralInputsTxBodyL) = Nothing
    | otherwise = case tx ^. bodyTxL . totalCollateralTxBodyL of
        SNothing ->
            Just
                "the transaction puts collateral at risk and states no total collateral, so its exposure is not bounded"
        SJust (Coin total)
            | total > allowance ->
                Just
                    ( "the transaction states a total collateral of "
                        <> T.pack (show total)
                        <> ", over the bound of "
                        <> T.pack (show allowance)
                    )
            | otherwise -> case tx ^. bodyTxL . collateralReturnTxBodyL of
                SNothing ->
                    Just
                        "the transaction states a total collateral and returns no part of its collateral input"
                SJust _ -> Nothing

{- | Whether the wallet can fund the take. A write spends the wallet's largest
ada-only output, and a booking's approval asset returns to the wallet when its
request is folded or retracted and rides in the change output from then on
(the retraction of the request the take's own refused insertion left: its
retained body has the request's bond as one output and the change, carrying
the approval asset, as the other). That output is no longer ada-only, so the
next write needs another. A refusal draws its collateral from the largest
ada-only output too, and the balancer takes a whole output as collateral, with
no return, when what is left of it cannot carry one. So before anything is
written the wallet must hold as ada-only outputs, each large enough to carry
what the take may put out of it and still leave the ledger's minimum output,
one for every action of the story that returns an approval, and one more for
the actions that do not.
-}
fundingProblem
    :: Int
    -- ^ The actions of the story that return an approval to the wallet
    -> Integer
    {- ^ The least size of an output that can fund one: the most it may put out
    (the larger of the collateral allowance and the outlay bound) and the
    ledger's minimum output, which its change or collateral return must be
    able to carry
    -}
    -> [(Bool, Integer)]
    -- ^ The wallet's outputs: whether each is ada-only, and its lovelace
    -> Maybe Text
fundingProblem returning floorSize outputs
    | have >= need = Nothing
    | otherwise =
        Just
            ( "the wallet holds "
                <> T.pack (show have)
                <> " ada-only outputs of at least "
                <> T.pack (show floorSize)
                <> " lovelace; the take has "
                <> T.pack (show returning)
                <> " actions that return an approval to the wallet, each of which can leave its funding output holding an asset, and needs one ada-only output more: "
                <> T.pack (show need)
            )
  where
    need = returning + 1
    have = length [() | (True, c) <- outputs, c >= floorSize]

-- | A request live at the registry's request address, as the datum reads.
data LiveRequest = LiveRequest
    { lrRef :: Text
    -- ^ The output reference, as receipts print it
    , lrKey :: ByteString
    , lrOwner :: ByteString
    }
    deriving stock (Eq, Show)

{- | The request a retraction spends: the one the insertion's own receipt
names, in the state its readback saw, or nothing at all. The insertion's
receipt and the readback must be this take's, for this key; the readback
must have seen that request pending; and the registry as read now must be
that readback's registry — the same root, the same set of pending
requests — with the named request still pending, for this key, owned by this
wallet. A request that is missing, replaced or another's is refused; no other
is ever substituted.
-}
reclaimTarget
    :: ByteString
    -- ^ The key the take retracts for
    -> ByteString
    -- ^ This wallet's payment key hash
    -> Receipt
    -- ^ The insertion's receipt, which names the pending request
    -> Receipt
    -- ^ The readback that saw it pending
    -> Text
    -- ^ The registry's root, read now
    -> [Text]
    -- ^ Every output at the request address, read now
    -> [LiveRequest]
    -- ^ Those that read as requests
    -> Either Text Text
reclaimTarget key owner partial seen root refs requests = do
    named <- case rcPendingRequest partial of
        Nothing -> Left "the insertion's receipt names no pending request"
        Just p -> Right p
    observed <- case rcObservation seen of
        Nothing -> Left "the readback carries no observation"
        Just o -> Right o
    unlessLeft
        ((rcTarget partial, rcKey partial) == (rcTarget seen, rcKey seen))
        "the insertion's receipt and the readback are of different registries or keys"
    unlessLeft
        (rcOutcome partial == "partial")
        ( "the insertion's outcome is "
            <> rcOutcome partial
            <> ", not partial"
        )
    unlessLeft
        (named `elem` obPending observed)
        ("the readback did not see " <> named <> " pending")
    unlessLeft
        (obRoot observed == root)
        "the registry's root is not the one the readback saw"
    unlessLeft
        (sort (obPending observed) == sort refs)
        ( "the pending requests are not those the readback saw: now "
            <> T.intercalate ", " (sort refs)
        )
    case [r | r <- requests, lrRef r == named] of
        [r]
            | lrKey r /= key -> Left (named <> " is a request for another key")
            | lrOwner r /= owner -> Left (named <> " is another owner's request")
            | otherwise -> Right named
        [] -> Left (named <> " is not a request pending now")
        _ -> Left (named <> " is named by more than one request")
  where
    unlessLeft ok why = if ok then Right () else Left why

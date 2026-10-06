{-# LANGUAGE LambdaCase #-}

{- | Stable bounded-wait failure identity, shared during the provider migration.
Existing failure fields and rendering are preserved for callers and journals.
-}
module Singular.Registry.WaitTypes (WaitStage (..), WaitFailure (..)) where

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Control.Exception (Exception)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC

{- | The wait a bound ended, named by the wait itself and never by its
caller: exactly one stage per failure.
-}
data WaitStage
    = -- | Waiting for the node's verdict on a submitted transaction.
      SubmissionWait
    | {- | Waiting for the followed indexer to show a submitted
      transaction's first output.
      -}
      IndexedConfirmationWait
    | {- | Waiting for a session confirmation: the output, or the
      chain's tip passing the confirmation window.
      -}
      SessionConfirmationWait
    deriving stock (Eq, Show)

{- | A wait on a submitted transaction that did not end within its
bound. It is an exception, never a submit result: a stalled node is
infrastructure failure, and the run that sees it has no verdict, no
refusal and no acceptance to report.
-}
data WaitFailure = WaitFailure
    { waitStage :: WaitStage
    -- ^ The wait that gave up
    , waitTxId :: TxId
    -- ^ The transaction the wait was on
    , waitElapsed :: Double
    {- ^ Seconds measured on the monotonic clock from the start of the
    whole wait
    -}
    , waitBound :: Int
    -- ^ The bound the wait was under, in seconds
    , waitClosedAt :: Maybe Integer
    {- ^ The POSIX deadline in milliseconds reached by the latest observed block, when a session
    confirmation ended because its window closed before the bound
    -}
    }

instance Show WaitFailure where
    show
        WaitFailure
            { waitStage
            , waitTxId
            , waitElapsed
            , waitBound
            , waitClosedAt
            } =
            "the "
                <> stageLabel waitStage
                <> " wait for transaction "
                <> txIdHex waitTxId
                <> " gave up after "
                <> seconds waitElapsed
                <> " s against its "
                <> show waitBound
                <> " s bound: "
                <> stageDetail waitStage waitClosedAt

instance Exception WaitFailure

-- | The stage's own name, as its failure renders it.
stageLabel :: WaitStage -> String
stageLabel = \case
    SubmissionWait -> "submission"
    IndexedConfirmationWait -> "indexed confirmation"
    SessionConfirmationWait -> "session confirmation"

-- | What the stage's wait was still waiting for when it gave up.
stageDetail :: WaitStage -> Maybe Integer -> String
stageDetail stage closedAt = case (stage, closedAt) of
    (SubmissionWait, _) ->
        "the node returned no verdict for the transaction"
    (IndexedConfirmationWait, _) ->
        "the node accepted the transaction but its first output never \
        \reached the followed indexer"
    (SessionConfirmationWait, Nothing) ->
        "the chain neither showed the transaction's first output nor \
        \closed its confirmation window in time"
    (SessionConfirmationWait, Just deadline) ->
        "the transaction was accepted by the node but has not appeared \
        \in a block: its confirmation window closed at POSIX milliseconds "
            <> show deadline

-- | A transaction id's hex rendering.
txIdHex :: TxId -> String
txIdHex (TxId h) =
    BC.unpack (B16.encode (hashToBytes (extractHash h)))

-- | A duration in seconds, to a tenth.
seconds :: Double -> String
seconds s = show (fromIntegral (round (s * 10) :: Integer) / 10 :: Double)

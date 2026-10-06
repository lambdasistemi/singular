{-# LANGUAGE RankNTypes #-}

{- |
Module      : Singular.Registry.LedgerProvider
Description : Generic ledger capabilities over the consumer's effect
License     : Apache-2.0

Capabilities supply raw Conway facts and generic reconstruction material.
They neither interpret registry commands nor assert verification or snapshot
binding. One acquisition identifies all reads used to prepare a transaction.
-}
module Singular.Registry.LedgerProvider
    ( LedgerProvider (..)
    , Session (..)
    , Network (..)
    , ChainPoint (..)
    , Acquisition (..)
    , AcquireFailure (..)
    , ReadFailure (..)
    , SubmitResult (..)
    , OutputQuery (..)
    , MintRecord (..)
    , Outputs
    , Asset
    , TipObservation (..)
    , HistoryRange (..)
    , HistoryFailure (..)
    , HistoricalTransaction (..)
    , HistoryBlock (..)
    , HistoryStream (..)
    ) where

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (AssetName, PolicyID)
import Cardano.Ledger.TxIn (TxId, TxIn)
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (Exception)
import Control.Tracer (Tracer)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Singular.Registry.Evidence
    ( Evidenced
    , SessionBinding
    , SessionId
    )
import Singular.Registry.Ledger (Addr)
import Singular.Registry.NetworkTime (NetworkTime, NetworkTimeFailure)
import Singular.Registry.Signing (SignedTx)
import Singular.Registry.Trace (Evaluation, ReadEvent)

-- | Explicit network magic; no process-global network choice.
newtype Network = Network Word32 deriving stock (Eq, Ord, Show)

-- | A requested chain point. It does not establish a binding by observation.
data ChainPoint = Genesis | At SlotNo ByteString
    deriving stock (Eq, Show)

-- | Acquisition always names its network.
data Acquisition = Latest Network | AtPoint Network ChainPoint
    deriving stock (Eq, Show)

-- | Named acquisition refusal, distinct from an empty query result.
data AcquireFailure
    = WrongNetwork Network Network
    | PointNotSupported ChainPoint
    | AcquisitionReadFailure ReadFailure
    deriving stock (Eq, Show)

instance Exception AcquireFailure

-- | Read refusals retain the missing/conflicting identity or backend reason.
data ReadFailure
    = ReleasedSession SessionId
    | MissingOutput TxIn
    | ConflictingOutput TxIn
    | BackendReadFailure Text
    | NetworkTimeRefusal NetworkTimeFailure
    deriving stock (Eq, Show)

instance Exception ReadFailure

-- | Signed submission's actual backend outcome.
data SubmitResult
    = SubmitAccepted TxId
    | SubmitRefused Text
    | SubmitFailed Text
    | SubmitWrongNetwork Network Network
    deriving stock (Eq, Show)

-- | Exact output references and full ledger outputs.
type Outputs = [(TxIn, TxOut ConwayEra)]

-- | A ledger asset, independent of registry interpretation.
type Asset = (PolicyID, AssetName)

-- | Nonempty composed queries; an absent exact reference refuses by name.
data OutputQuery
    = AtAddress Addr
    | HoldingAsset Asset
    | AtTxIn TxIn
    | {- | Live outputs carrying this reference script. An empty answer
      means not found by this provider, never not on chain; a consumer
      checks each candidate's script itself.
      -}
      CarryingReferenceScript ScriptHash
    | AnyOf (NonEmpty OutputQuery)
    | AllOf (NonEmpty OutputQuery)
    deriving stock (Eq, Show)

{- | How an asset came to be: the transaction that minted it, every input
that transaction spent, and the asset's current total supply.
-}
data MintRecord = MintRecord
    { mintTransaction :: TxId
    , mintSpentInputs :: [TxIn]
    , mintSupply :: Integer
    }
    deriving stock (Eq, Show)

-- | Latest observed block facts, with raw POSIX seconds independent of slots.
data TipObservation = TipObservation
    { observedSlot :: SlotNo
    , observedHash :: ByteString
    , observedHeight :: Word64
    , observedBlockTime :: Word64
    }
    deriving stock (Eq, Show)

-- | Inclusive block-height bounds; absent bounds leave that side open.
data HistoryRange = HistoryRange
    { fromHeight :: Maybe Word64
    , throughHeight :: Maybe Word64
    }
    deriving stock (Eq, Show)

-- | History refuses incomplete or inconsistent reconstruction material.
data HistoryFailure
    = HistoryReadFailure ReadFailure
    | HistoryDependencyCycle (NonEmpty TxId)
    | MissingInBlockParent TxId TxId
    | DuplicateSpend TxIn
    | HistoryMaterialMismatch TxId Text
    | HistoryOrderMismatch Word64 Word64
    deriving stock (Eq, Show)

instance Exception HistoryFailure

{- | Complete CBOR plus resolved inputs, references and outputs, with validity.
These are reconstruction material, without an evidence verdict.
-}
data HistoricalTransaction = HistoricalTransaction
    { historicalId :: TxId
    , historicalCbor :: ByteString
    , historicalTx :: ConwayTx
    , spentOutputs :: Outputs
    , referenceOutputs :: Outputs
    , createdOutputs :: Outputs
    , scriptValid :: Bool
    }

-- | One complete block, in creator-before-spender order within its height.
data HistoryBlock = HistoryBlock
    { blockHeight :: Word64
    , blockTransactions :: NonEmpty HistoricalTransaction
    }

-- | Deferred complete-block consumption; never joins the entire history first.
newtype HistoryStream m = HistoryStream
    { nextBlock
        :: m (Either HistoryFailure (Maybe (HistoryBlock, HistoryStream m)))
    }

-- | Facts consumed within one acquired scope and its named network.
data Session w m = Session
    { sessionNetwork :: Network
    , sessionId :: SessionId
    , sessionBinding :: SessionBinding
    , sessionTracer :: Tracer m ReadEvent
    {- ^ Where the local services report what they do under this session:
    the tracer of the scope that acquired it
    -}
    , sessionEvaluated :: Evaluation -> m ()
    {- ^ Where the local evaluator records the outcome of each evaluation under
    this session, typed: the build that owns the session reads it to say
    whether its scripts failed. Not a tracer: nothing renders it.
    -}
    , outputs :: OutputQuery -> m (Either ReadFailure (Evidenced w Outputs))
    , protocolParameters
        :: m (Either ReadFailure (Evidenced w (PParams ConwayEra)))
    , tipObservation :: m (Either ReadFailure (Evidenced w TipObservation))
    , networkTime :: m (Either ReadFailure (Evidenced w NetworkTime))
    , scriptRegistered
        :: ScriptHash -> m (Either ReadFailure (Evidenced w Bool))
    , mintRecord
        :: Asset -> m (Either ReadFailure (Evidenced w (Maybe MintRecord)))
    -- ^ No record for an asset the provider does not know
    , history
        :: Asset -> HistoryRange -> m (Either HistoryFailure (HistoryStream m))
    }

-- | Reading and signed submission in the caller's monad and witness domain.
data LedgerProvider w m = LedgerProvider
    { acquire
        :: forall a
         . Acquisition -> (Session w m -> m a) -> m (Either AcquireFailure a)
    , submitTx :: Network -> SignedTx -> m SubmitResult
    }

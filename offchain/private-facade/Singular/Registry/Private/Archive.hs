{-# LANGUAGE GADTs #-}

{- | Private devnet source archive. Full blocks arrive from ChainSync,
independently of every terminal submission and receipt. Inputs are resolved
against the ledger UTxO before each transaction, in block order. Invalid
transactions retain their attempted inputs and full CBOR but change only
collateral. Rollback restores both material and UTxO to the retained point.
-}
module Singular.Registry.Private.Archive
    ( Archive
    , ArchivedBlock (..)
    , ArchivedTransaction (..)
    , ArchiveFailure (..)
    , emptyArchive
    , archiveBlocks
    , archiveOutputs
    , appendFetched
    , appendBlock
    , rollbackArchive
    ) where

import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , inputsTxBodyL
    , isValidTxL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , txIdTx
    )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (txIxFromIntegral)
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Node.Client.N2C.ChainSync (Fetched (..), HeaderPoint)
import Cardano.Read.Ledger.Block.Block (Block, fromConsensusBlock)
import Cardano.Read.Ledger.Block.Txs (getEraTransactions)
import Cardano.Read.Ledger.Eras.EraValue (applyEraFun)
import Cardano.Read.Ledger.Eras.KnownEras (Era (..), IsEra, theEra)
import Cardano.Read.Ledger.Tx.Tx qualified as Read
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (Exception)
import Control.Monad (foldM, unless)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word64)
import Lens.Micro ((^.))
import Ouroboros.Network.Block qualified as Chain

data ArchivedTransaction = ArchivedTransaction
    { archivedId :: TxId
    , archivedCBOR :: ByteString
    , archivedInputs :: Map TxIn (TxOut ConwayEra)
    , archivedReferences :: Map TxIn (TxOut ConwayEra)
    , archivedCollateral :: Map TxIn (TxOut ConwayEra)
    , archivedBodyOutputs :: [(TxIn, TxOut ConwayEra)]
    , archivedValid :: Bool
    }
    deriving stock (Eq, Show)

data ArchivedBlock = ArchivedBlock
    { archivedPoint :: HeaderPoint
    , archivedSlot :: SlotNo
    , archivedHeight :: Word64
    , archivedTransactions :: [ArchivedTransaction]
    }
    deriving stock (Eq, Show)

data ArchiveFailure
    = ArchiveMissingInput TxId TxIn
    | ArchiveDuplicateTransaction TxId
    | ArchiveOutputCollision TxIn
    | ArchiveOutputIndexOutOfRange Int
    | ArchiveNonIncreasingBlock Word64 Word64
    | ArchiveUnsupportedEra
    | ArchiveUnknownRollback HeaderPoint
    deriving stock (Eq, Show)

instance Exception ArchiveFailure

data Archive = Archive
    { archiveGenesis :: Map TxIn (TxOut ConwayEra)
    , archiveFrames :: [(ArchivedBlock, Map TxIn (TxOut ConwayEra))]
    }

-- | The composition supplies independently checked, actual genesis UTxO.
emptyArchive :: Map TxIn (TxOut ConwayEra) -> Archive
emptyArchive genesis = Archive genesis []

archiveBlocks :: Archive -> [ArchivedBlock]
archiveBlocks = map fst . archiveFrames

archiveOutputs :: Archive -> Map TxIn (TxOut ConwayEra)
archiveOutputs archive = case reverse (archiveFrames archive) of
    [] -> archiveGenesis archive
    (_, outputs) : _ -> outputs

appendFetched :: Fetched -> Archive -> Either ArchiveFailure Archive
appendFetched fetched archive = do
    transactions <-
        applyEraFun
            conwayTransactions
            (fromConsensusBlock (fetchedBlock fetched))
    appendBlock
        (fetchedPoint fetched)
        (Chain.blockSlot (fetchedBlock fetched))
        (Chain.unBlockNo (Chain.blockNo (fetchedBlock fetched)))
        transactions
        archive
  where
    conwayTransactions
        :: forall era
         . (IsEra era) => Block era -> Either ArchiveFailure [ConwayTx]
    conwayTransactions block = case theEra @era of
        Conway -> Right (map Read.unTx (getEraTransactions block))
        _ -> Left ArchiveUnsupportedEra

{- | Preserve the source's transaction order, including transactions that
never came through the facade. This function is also the pure control seam;
only appendFetched feeds the live archive.
-}
appendBlock
    :: HeaderPoint
    -> SlotNo
    -> Word64
    -> [ConwayTx]
    -> Archive
    -> Either ArchiveFailure Archive
appendBlock point slot height transactions archive = do
    case reverse (archiveFrames archive) of
        (previous, _) : _ ->
            unless (height > archivedHeight previous) $
                Left (ArchiveNonIncreasingBlock (archivedHeight previous) height)
        [] -> pure ()
    let seen =
            Set.fromList
                [ archivedId tx
                | block <- archiveBlocks archive
                , tx <- archivedTransactions block
                ]
    (outputs, _, material) <-
        foldM apply (archiveOutputs archive, seen, []) transactions
    let block = ArchivedBlock point slot height material
    pure
        archive{archiveFrames = archiveFrames archive <> [(block, outputs)]}
  where
    apply (outputs, seen, material) tx = do
        let identity = txIdTx tx
            body = tx ^. bodyTxL
            IsValid valid = tx ^. isValidTxL
        namedOutputs <-
            traverse
                (\(index, output) -> (,output) <$> outputReference identity index)
                (zip [0 :: Int ..] (toList (body ^. outputsTxBodyL)))
        unless
            (Set.notMember identity seen)
            (Left (ArchiveDuplicateTransaction identity))
        inputs <- resolve identity outputs (body ^. inputsTxBodyL)
        references <-
            resolve identity outputs (body ^. referenceInputsTxBodyL)
        collateral <-
            resolve identity outputs (body ^. collateralInputsTxBodyL)
        created <-
            if valid
                then pure namedOutputs
                else case body ^. collateralReturnTxBodyL of
                    SNothing -> pure []
                    SJust output -> do
                        reference <- outputReference identity (length namedOutputs)
                        pure [(reference, output)]
        let consumed = if valid then Map.keysSet inputs else Map.keysSet collateral
            afterSpend = Map.withoutKeys outputs consumed
        afterCreate <- foldM create afterSpend created
        let record =
                ArchivedTransaction
                    identity
                    (serialize' (eraProtVerHigh @ConwayEra) tx)
                    inputs
                    references
                    collateral
                    namedOutputs
                    valid
        pure (afterCreate, Set.insert identity seen, material <> [record])
    create outputs (reference, output) = do
        unless
            (Map.notMember reference outputs)
            (Left (ArchiveOutputCollision reference))
        pure (Map.insert reference output outputs)

outputReference :: TxId -> Int -> Either ArchiveFailure TxIn
outputReference identity index =
    maybe
        (Left (ArchiveOutputIndexOutOfRange index))
        (Right . TxIn identity)
        (txIxFromIntegral index)

resolve
    :: TxId
    -> Map TxIn (TxOut ConwayEra)
    -> Set TxIn
    -> Either ArchiveFailure (Map TxIn (TxOut ConwayEra))
resolve identity outputs references =
    Map.fromAscList <$> traverse lookupInput (Set.toAscList references)
  where
    lookupInput reference =
        maybe
            (Left (ArchiveMissingInput identity reference))
            (Right . (reference,))
            (Map.lookup reference outputs)

rollbackArchive
    :: HeaderPoint -> Archive -> Either ArchiveFailure Archive
rollbackArchive Chain.GenesisPoint archive = Right archive{archiveFrames = []}
rollbackArchive point archive = case break ((== point) . archivedPoint . fst) (archiveFrames archive) of
    (_, []) -> Left (ArchiveUnknownRollback point)
    (before, frame : _) -> Right archive{archiveFrames = before <> [frame]}

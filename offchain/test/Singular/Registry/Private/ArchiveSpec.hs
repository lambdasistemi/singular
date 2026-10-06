module Singular.Registry.Private.ArchiveSpec (spec) where

import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.Tx
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , isValidTxL
    , mkBasicTx
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , txIdTx
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.N2C.ChainSync (HeaderPoint)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Sequence.Strict qualified as Seq
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((&), (.~))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Singular.Provider.Koios.Scripted (txIdOfByte)
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.Private.Archive
import Singular.Registry.TxBuilder.BookingFixture (payer)
import Test.Hspec

-- These controls use real ledger bodies and CBOR, with synthetic blocks.
-- Only the live ChainSync producer can establish inclusion or admission.
spec :: Spec
spec = describe "Private full-block source archive" $ do
    it
        "resolves a spender after its creator despite opposite transaction hash order"
        $ do
            let (parent, child) = dependentPair
                parentReference = TxIn (txIdTx parent) (TxIx 0)
                referenceOnly = TxIn (txIdTx parent) (TxIx 1)
            Wire.txIdHex (txIdTx child)
                `shouldSatisfy` (< Wire.txIdHex (txIdTx parent))
            archive <- reached (appendBlock (point 1) 1 1 [parent, child] initial)
            block <- single "source block" (archiveBlocks archive)
            let records = archivedTransactions block
            map archivedId records `shouldBe` map txIdTx [parent, child]
            map decodeArchived records `shouldBe` map Right [parent, child]
            childRecord <-
                single
                    "source child"
                    (filter ((== txIdTx child) . archivedId) records)
            archivedInputs childRecord
                `shouldBe` Map.singleton parentReference (output 8_000_000)
            archivedReferences childRecord
                `shouldBe` Map.singleton referenceOnly (output 1_000_000)
            Map.member parentReference (archiveOutputs archive) `shouldBe` False
            Map.lookup referenceOnly (archiveOutputs archive)
                `shouldBe` Just (output 1_000_000)
            case appendBlock (point 1) 1 1 [child, parent] initial of
                Left failure ->
                    failure `shouldBe` ArchiveMissingInput (txIdTx child) parentReference
                Right _ -> expectationFailure "spender-before-creator material was accepted"
    it
        "keeps attempted normal inputs of a failed script and applies only collateral"
        $ do
            let transaction =
                    mkBasicTx
                        ( mkBasicTxBody
                            & inputsTxBodyL
                                .~ Set.singleton funding
                            & collateralInputsTxBodyL
                                .~ Set.singleton collateral
                            & outputsTxBodyL
                                .~ Seq.fromList [output 4_000_000, output 5_000_000]
                            & collateralReturnTxBodyL
                                .~ SJust (output 900_000)
                        )
                        & isValidTxL
                            .~ IsValid False
                identity = txIdTx transaction
            archive <- reached (appendBlock (point 1) 1 1 [transaction] initial)
            block <- single "failed-script source block" (archiveBlocks archive)
            record <-
                single "failed-script source transaction" (archivedTransactions block)
            let live = archiveOutputs archive
            decodeArchived record `shouldBe` Right transaction
            archivedValid record `shouldBe` False
            archivedInputs record
                `shouldBe` Map.singleton funding (output 10_000_000)
            Map.lookup funding live `shouldBe` Just (output 10_000_000)
            Map.member collateral live `shouldBe` False
            Map.lookup (TxIn identity (TxIx 2)) live
                `shouldBe` Just (output 900_000)
            Map.member (TxIn identity (TxIx 0)) live `shouldBe` False
            Map.member (TxIn identity (TxIx 1)) live `shouldBe` False
    it
        "rolls back complete material and spent outputs, then accepts a different branch"
        $ do
            let (parent, child) = dependentPair
            first <- reached (appendBlock (point 1) 1 1 [parent] initial)
            second <- reached (appendBlock (point 2) 2 2 [child] first)
            restored <- reached (rollbackArchive (point 1) second)
            archiveBlocks restored `shouldBe` archiveBlocks first
            archiveOutputs restored `shouldBe` archiveOutputs first
            alternative <- reached (appendBlock (point 3) 3 2 [child] restored)
            map archivedPoint (archiveBlocks alternative)
                `shouldBe` [point 1, point 3]
            genesis <- reached (rollbackArchive Chain.GenesisPoint alternative)
            archiveBlocks genesis `shouldBe` []
            archiveOutputs genesis `shouldBe` archiveOutputs initial
            case rollbackArchive (point 9) alternative of
                Left failure -> failure `shouldBe` ArchiveUnknownRollback (point 9)
                Right _ -> expectationFailure "unknown source rollback was accepted"
    it
        "refuses missing references and duplicate source transactions by their identity"
        $ do
            let missing = TxIn (txIdOfByte 88) (TxIx 9)
                transaction =
                    mkBasicTx
                        (mkBasicTxBody & referenceInputsTxBodyL .~ Set.singleton missing)
            case appendBlock (point 1) 1 1 [transaction] initial of
                Left failure ->
                    failure `shouldBe` ArchiveMissingInput (txIdTx transaction) missing
                Right _ -> expectationFailure "unresolved reference material was accepted"
            let (parent, _) = dependentPair
            case appendBlock (point 1) 1 1 [parent, parent] initial of
                Left failure -> failure `shouldBe` ArchiveDuplicateTransaction (txIdTx parent)
                Right _ -> expectationFailure "duplicate source transaction was accepted"

reached :: Either ArchiveFailure a -> IO a
reached = either (fail . show) pure

single :: String -> [a] -> IO a
single _ [value] = pure value
single label values = fail (label <> ": expected one, got " <> show (length values))

funding, collateral :: TxIn
funding = TxIn (txIdOfByte 10) (TxIx 0)
collateral = TxIn (txIdOfByte 11) (TxIx 0)

output :: Integer -> TxOut ConwayEra
output amount = mkBasicTxOut payer (MaryValue (Coin amount) (MultiAsset Map.empty))

initial :: Archive
initial =
    emptyArchive
        ( Map.fromList
            [(funding, output 10_000_000), (collateral, output 1_000_000)]
        )

point :: Word8 -> HeaderPoint
point byte =
    Chain.BlockPoint
        (SlotNo (fromIntegral byte))
        (OneEraHash (SBS.toShort (BS.replicate 32 byte)))

decodeArchived :: ArchivedTransaction -> Either String ConwayTx
decodeArchived record =
    either
        (Left . show)
        Right
        ( decodeFullAnnotator
            (eraProtVerHigh @ConwayEra)
            "archived actual Conway bytes"
            decCBOR
            (LBS.fromStrict (archivedCBOR record))
        )

dependentPair :: (ConwayTx, ConwayTx)
dependentPair = choose [1 .. 10000]
  where
    choose [] = error "no opposite source hash order"
    choose (salt : rest) =
        let parent =
                mkBasicTx
                    ( mkBasicTxBody
                        & inputsTxBodyL
                            .~ Set.singleton funding
                        & outputsTxBodyL
                            .~ Seq.fromList [output 8_000_000, output 1_000_000]
                        & feeTxBodyL
                            .~ Coin salt
                    )
            child =
                mkBasicTx
                    ( mkBasicTxBody
                        & inputsTxBodyL
                            .~ Set.singleton (TxIn (txIdTx parent) (TxIx 0))
                        & referenceInputsTxBodyL
                            .~ Set.singleton (TxIn (txIdTx parent) (TxIx 1))
                        & outputsTxBodyL
                            .~ Seq.singleton (output 7_000_000)
                    )
        in  if Wire.txIdHex (txIdTx child) < Wire.txIdHex (txIdTx parent)
                then (parent, child)
                else choose rest

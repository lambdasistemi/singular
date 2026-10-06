{- | A private, bounded boundary check. Reads and signed writes use the
actual shipping HTTP/client/Wire and generic provider. The separate full-
block archive supplies the comparison bytes; a spent-input control must
reach the node's ledger refusal. This is not the registry journey gate.
-}
module Singular.Registry.Private.Smoke (runFacadeSmoke) where

import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr, genesisSignKey)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (finally, throwIO)
import Control.Monad (unless)
import Control.Tracer (nullTracer)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Lens.Micro ((&), (.~), (^.))
import Singular.Registry.Capabilities
    ( Capabilities (..)
    , sessionReceipt
    )
import Singular.Registry.Evidence qualified as Evidence
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    , SubmitResult (..)
    )
import Singular.Registry.Private.Archive
import Singular.Registry.Private.Facade
import Singular.Registry.SessionIO qualified as Session
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Terminal (withReads)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

runFacadeSmoke :: FilePath -> FilePath -> IO ()
runFacadeSmoke genesisDirectory outputDirectory = do
    createDirectoryIfMissing True outputDirectory
    journalLock <- newMVar ()
    let observe event =
            withMVar
                journalLock
                ( \_ ->
                    LBS.appendFile
                        (outputDirectory </> "independent-facade-sources.jsonl")
                        (encode event <> "\n")
                )
    withGeneratedFacade FundGenesis genesisDirectory observe $ \_ facade ->
        withReads
            nullTracer
            nullTracer
            (facadeSettings facade)
            (exercise facade)
            `finally` ( facadeSources facade
                            >>= LBS.writeFile (outputDirectory </> "independent-facade-sources.json")
                                . encode
                      )
  where
    exercise facade capabilities = do
        (funding, output, liveInput, liveOutput, prepared) <- Session.withLatest (capReads capabilities) $ \scope -> do
            available <- Session.outputsAt scope genesisAddr
            _ <- Session.parameters scope
            _ <- networkTime scope >>= either throwIO pure
            _ <- Session.tip scope
            case available of
                [] -> fail "private facade smoke has no funding output"
                (reference, value) : (otherReference, otherValue) : _ -> do
                    receipt <- sessionReceipt capabilities scope
                    pure (reference, value, otherReference, otherValue, receipt)
                _ ->
                    fail
                        "private facade smoke needs two independently visible funding outputs"
        let Coin available = output ^. coinTxOutL
            body fee =
                mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton funding
                    & outputsTxBodyL
                        .~ Seq.singleton
                            ( mkBasicTxOut
                                genesisAddr
                                (MaryValue (Coin (available - fee)) (MultiAsset Map.empty))
                            )
                    & feeTxBodyL .~ Coin fee
            accepted = signTx genesisSignKey (mkBasicTx (body 2_000_000))
            transaction = signedTx accepted
            identity = txIdTx transaction
        result <- capSubmit capabilities accepted
        unless
            (result == SubmitAccepted identity)
            (fail ("private facade smoke signed submission: " <> show result))
        capConfirm capabilities transaction
        found <- Session.withLatest (capReads capabilities) $ \scope ->
            outputs scope (AtTxIn (TxIn identity (TxIx 0)))
                >>= either throwIO (pure . Evidence.value)
        unless
            (length found == 1)
            (fail "private facade smoke exact confirmed output missing")
        archive <- facadeArchive facade
        let recorded =
                [ tx
                | block <- archiveBlocks archive
                , tx <- archivedTransactions block
                , archivedId tx == identity
                ]
            bytes = serialize' (eraProtVerHigh @ConwayEra) transaction
        case recorded of
            [material] -> do
                unless
                    (archivedCBOR material == bytes)
                    (fail "private independent CBOR differs from submitted bytes")
                unless
                    (archivedInputs material == Map.singleton funding output)
                    ( fail
                        "private independent resolved input differs from consumed funding"
                    )
            _ ->
                fail
                    "private independent full-block archive lacks unique submitted transaction"
        -- Mix the spent input with an independently observed live input.
        -- An all-spent body hits the node's early mempool shortcut rather
        -- than UTxO validation. Keep the actual ledger refusal criterion.
        let Coin liveAmount = liveOutput ^. coinTxOutL
            staleBody =
                body 2_000_001
                    & inputsTxBodyL .~ Set.fromList [funding, liveInput]
                    & outputsTxBodyL
                        .~ Seq.singleton
                            ( mkBasicTxOut
                                genesisAddr
                                ( MaryValue
                                    (Coin (available + liveAmount - 2_000_001))
                                    (MultiAsset Map.empty)
                                )
                            )
            stale = signTx genesisSignKey (mkBasicTx staleBody)
        refusal <- capSubmit capabilities stale
        case refusal of
            SubmitRefused reason ->
                unless
                    ("BadInputsUTxO" `Text.isInfixOf` reason)
                    ( fail
                        ( "private spent-input control missed actual ledger boundary: "
                            <> Text.unpack reason
                        )
                    )
            _ ->
                fail
                    ("private spent-input control was not ledger-refused: " <> show refusal)
        facts <- capFacts capabilities
        trace <- capTrace capabilities
        LBS.writeFile
            (outputDirectory </> "shared-provider-smoke.json")
            ( encode
                ( object
                    [ "prepared" .= prepared
                    , "funding" .= show funding
                    , "spentInputControlLiveReference" .= show liveInput
                    , "acceptedTransactionId" .= show identity
                    , "acceptedCBOR" .= decodeUtf8 (B16.encode bytes)
                    , "spentInputControlCBOR"
                        .= decodeUtf8
                            (B16.encode (serialize' (eraProtVerHigh @ConwayEra) (signedTx stale)))
                    , "spentInputRefusal" .= show refusal
                    , "facts" .= facts
                    , "rawSources" .= trace
                    , "limit"
                        .= ( "Private native payment/source boundary only; full registry/proof/registration/history/deletion/package/CI acceptance remains unestablished"
                                :: Text.Text
                           )
                    ]
                )
            )

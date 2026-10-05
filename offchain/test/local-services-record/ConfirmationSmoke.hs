{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Actual confirmations and named missing-transaction timeouts on the
existing generated private devnet. Only its fixture wallet can submit.
-}
module ConfirmationSmoke (confirmationSmoke) where

import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (SlotNo (..), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as Node
import Cardano.Slotting.Time (SystemStart (..))
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Serialise (deserialiseOrFail)
import Control.Concurrent.Async (concurrently, withAsync)
import Control.Exception (try)
import Control.Monad (unless)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraEnd (..)
    , EraSummary (..)
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.Registry.NetworkTime (NetworkTimeFailure)
import Singular.Registry.Node
    ( NodeMode (..)
    , NodeSession (..)
    , SubmitResult (..)
    , WaitFailure (..)
    , WaitStage (..)
    , Wallet (..)
    , adaptProvider
    , awaitConnection
    , awaitTx
    , boundedSubmitter
    , confirmDeadline
    , signTx
    , signedSubmitter
    , signedTx
    , submissionBound
    , submitSigned
    , walletForMode
    , withDevnetIndexer
    )
import Singular.Registry.Node.Confirmation (windowReadBound)
import Singular.Registry.Node.Options (Backend (NodeBackend))
import Singular.Registry.Node.RawView
    ( RawProvider (..)
    , RawView (..)
    , rawNodeProvider
    )
import Singular.Registry.Node.Session
    ( guardRawConnection
    , serveSession
    )
import Singular.Registry.PhaseLog (noPhaseLog, startTimer)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TimeMaterial (loadTimeMaterial)
import System.FilePath (takeDirectory, (</>))

confirmationSmoke :: FilePath -> FilePath -> IO ()
confirmationSmoke output sock = withDevnetIndexer sock $ do
    opened <- startTimer
    lsq <- newLSQChannel 16
    ltxs <- newLTxSChannel 16
    let magic = NetworkMagic 42
    withAsync (runNodeClient magic sock lsq ltxs) $ \client -> do
        (node, submit, raw) <-
            guardRawConnection
                client
                (mkN2CProvider lsq)
                (boundedSubmitter submissionBound (mkN2CSubmitter ltxs))
                (rawNodeProvider lsq)
        material <- loadTimeMaterial 42 (takeDirectory sock)
        let provider = adaptProvider magic material raw
        awaitConnection magic sock client provider
        -- Retain only the missing confirmation context, not the completed
        -- independent evaluation/conversion recording campaign.
        (startMs, horizon) <- withRawView raw $ \view -> do
            SystemStart start <- rawSystemStart view
            bytes <- rawEraHistory view
            snapshot <- rawSnapshot view
            BS.writeFile (output </> "confirmation-era-history.cbor") bytes
            LBS.writeFile (output </> "confirmation-point.json") $
                encode
                    ( object
                        [ "point" .= show (Node.ledgerChainPoint snapshot)
                        , "era" .= Node.ledgerCurrentEra snapshot
                        , "tipSlot" .= Cage.unSlotNo (Node.ledgerTipSlot snapshot)
                        ]
                    )
            summaries <-
                either (fail . show) pure (deserialiseOrFail (LBS.fromStrict bytes))
            end <- case reverse summaries of
                EraSummary{eraEnd = EraEnd bound} : _ -> pure (boundSlot bound)
                _ -> fail "ConfirmationSmokeMissingFiniteHorizon"
            pure (floor (utcTimeToPOSIXSeconds start * 1000), end)
        serveSession
            noPhaseLog
            opened
            Nothing
            NodeBackend
            Devnet
            magic
            sock
            provider
            (node, submit)
            $ \session -> do
                wallet <- walletForMode Devnet
                point <- Cage.withView (nsProvider session) (pure . Cage.viewPoint)
                let upper = SlotNo (Cage.unSlotNo (Cage.cpSlot point) + 50)
                    -- Independent arithmetic for this exact generated fixture:
                    -- 100ms slots and an unchanged finite raw history.
                    initialEnd = startMs + 100 * toInteger (Cage.unSlotNo horizon)
                    finiteDeadline = startMs + 100 * toInteger (Cage.unSlotNo upper) + 120_000
                unless (upper < horizon && finiteDeadline > initialEnd) $
                    fail "ConfirmationSmokeNotShortHorizon"
                finite <- payment session wallet (SJust upper)
                confirmDeadline (nsProvider session) finite >>= \actual ->
                    unless
                        (actual == finiteDeadline)
                        (fail "ConfirmationSmokeFiniteDeadlineMismatch")
                landedFinite <- sendAndConfirm session wallet finite
                unbounded <- payment session wallet SNothing
                landedUnbounded <- sendAndConfirm session wallet unbounded
                -- Refusal at the actual finite ledger bound must never fall
                -- back to the local wait margin.
                refusal <-
                    try @NetworkTimeFailure $
                        confirmDeadline
                            (nsProvider session)
                            ( finite
                                & bodyTxL . vldtTxBodyL
                                    .~ ValidityInterval SNothing (SJust (SlotNo (Cage.unSlotNo horizon + 1)))
                            )
                case refusal of
                    Left _ -> pure ()
                    Right _ -> fail "ConfirmationSmokeAcceptedPastHorizonLedgerBound"
                let missingFinite = finite & bodyTxL . feeTxBodyL .~ Coin 1_000_001
                    missingUnbounded = unbounded & bodyTxL . feeTxBodyL .~ Coin 1_000_002
                (finiteFailure, unboundedFailure) <-
                    concurrently
                        (expectTimeout session missingFinite (Just finiteDeadline) initialEnd)
                        (expectTimeout session missingUnbounded Nothing initialEnd)
                LBS.writeFile (output </> "confirmation-smoke.json") $
                    encode $
                        object
                            [ "networkMagic" .= (42 :: Int)
                            , "initialPoint" .= show point
                            , "initialHorizonSlot" .= Cage.unSlotNo horizon
                            , "initialHorizonEndMs" .= initialEnd
                            , "finiteUpperSlot" .= Cage.unSlotNo upper
                            , "finiteDeadlineMs" .= finiteDeadline
                            , "confirmedFiniteTx" .= show (txIdTx landedFinite)
                            , "confirmedNoUpperTx" .= show (txIdTx landedUnbounded)
                            , "finiteMissingTx" .= show (txIdTx missingFinite)
                            , "noUpperMissingTx" .= show (txIdTx missingUnbounded)
                            , "finiteTimeout" .= show finiteFailure
                            , "noUpperTimeout" .= show unboundedFailure
                            , "ledgerPastHorizonRefusal"
                                .= either show (const "unexpected acceptance") refusal
                            , "limit"
                                .= ( "Private key payments and confirmation waits only; registry journey remains separately required"
                                        :: String
                                   )
                            ]

payment :: NodeSession -> Wallet -> StrictMaybe SlotNo -> IO ConwayTx
payment session wallet upper = Cage.withView (nsProvider session) $ \view -> do
    held <- Cage.viewUTxOsAt view (walletAddr wallet)
    case held of
        [] -> fail "ConfirmationSmokeEmptyFixtureWallet"
        _ -> do
            let value = foldMap ((^. valueTxOutL) . snd) held
            pure $
                mkBasicTx
                    ( mkBasicTxBody
                        & inputsTxBodyL .~ Set.fromList (map fst held)
                        & outputsTxBodyL
                            .~ StrictSeq.singleton
                                (mkBasicTxOut (walletAddr wallet) (value <-> inject (Coin 1_000_000)))
                        & feeTxBodyL .~ Coin 1_000_000
                        & vldtTxBodyL .~ ValidityInterval SNothing upper
                    )

sendAndConfirm :: NodeSession -> Wallet -> ConwayTx -> IO ConwayTx
sendAndConfirm session wallet tx = do
    let signed = signTx (walletSignKey wallet) tx
    submitSigned (signedSubmitter (nsSubmitter session)) signed >>= \case
        Submitted _ -> awaitTx (signedTx signed) >> pure (signedTx signed)
        Rejected reason -> fail ("ConfirmationSmokePrivatePaymentRejected " <> show reason)

expectTimeout
    :: NodeSession -> ConwayTx -> Maybe Integer -> Integer -> IO WaitFailure
expectTimeout session tx exact initialEnd = do
    before <- nowMs
    result <- try @WaitFailure (awaitTx tx)
    after <- nowMs
    failure <-
        either
            pure
            (const (fail "ConfirmationSmokeMissingTransactionAppeared"))
            result
    tip <- nsTipTime session
    let expected = fromMaybe (before + 300_000) exact
        -- The no-upper clock is read after the bounded acquired-context
        -- read. Bracket it by that public bound, including acquisition time.
        upperExpected =
            fromMaybe
                (before + fromIntegral windowReadBound * 1000 + 300_000)
                exact
    unless
        ( waitStage failure == SessionConfirmationWait
            && waitTxId failure == txIdTx tx
            && maybe
                False
                ( \deadline ->
                    deadline >= expected
                        && deadline <= upperExpected
                        && deadline > initialEnd
                        && tip >= deadline
                )
                (waitClosedAt failure)
            && after >= expected
            && maybe
                (waitBound failure == 304 && waitElapsed failure >= 300)
                (const True)
                exact
        )
        (fail ("ConfirmationSmokeTimeoutMismatch " <> show failure))
    pure failure
  where
    nowMs = floor . (* 1000) <$> getPOSIXTime

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

-- | Actual HTTP confirmations and missing-output waits on a private devnet.
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
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Node.Client.E2E.Setup qualified as Setup
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.Provider qualified as Node
import Cardano.Slotting.Time (SystemStart (..))
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Serialise (deserialiseOrFail)
import Control.Concurrent.Async (concurrently, link, withAsync)
import Control.Exception (try)
import Control.Monad (forM, unless)
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
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Confirmation
    ( ConfirmationFailure (..)
    , confirmationWindow
    , newIOConfirmationRuntime
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.Private.Facade
    ( Facade (..)
    , GenesisFunding (..)
    , withGeneratedFacade
    )
import Singular.Registry.Private.RawFacts
    ( RawFacts (..)
    , withRawFacts
    )
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Terminal (withWrites)
import Singular.Registry.Wait (WaitFailure (..), WaitStage (..))
import Singular.Registry.Wallet (Wallet (..))
import System.Directory (copyFile)
import System.FilePath (takeDirectory, (</>))

confirmationSmoke :: FilePath -> FilePath -> IO ()
confirmationSmoke output genesisDirectory =
    withGeneratedFacade FundGenesis genesisDirectory (const (pure ())) $ \_ facade -> do
        let socket = facadeSocket facade
            wallet = Wallet Setup.genesisAddr Setup.genesisSignKey Testnet
        mapM_
            (\name -> copyFile (takeDirectory socket </> name) (output </> name))
            [ "byron-genesis.json"
            , "shelley-genesis.json"
            , "alonzo-genesis.json"
            , "conway-genesis.json"
            , "dijkstra-genesis.json"
            , "node-config.json"
            ]
        lsq <- newLSQChannel 16
        unusedSubmission <- newLTxSChannel 16
        withAsync
            (runNodeClient (NetworkMagic 42) socket lsq unusedSubmission)
            $ \client -> do
                link client
                (startMs, horizon, point) <- withRawFacts lsq $ \facts -> do
                    SystemStart start <- factSystemStart facts
                    bytes <- factEraHistory facts
                    snapshot <- factSnapshot facts
                    BS.writeFile (output </> "confirmation-era-history.cbor") bytes
                    LBS.writeFile (output </> "confirmation-point.json") $
                        encode $
                            object
                                [ "point" .= show (Node.ledgerChainPoint snapshot)
                                , "era" .= Node.ledgerCurrentEra snapshot
                                , "tipSlot" .= Node.ledgerTipSlot snapshot
                                ]
                    summaries <-
                        either (fail . show) pure (deserialiseOrFail (LBS.fromStrict bytes))
                    end <- case reverse summaries of
                        EraSummary{eraEnd = EraEnd bound} : _ -> pure (boundSlot bound)
                        _ -> fail "ConfirmationSmokeMissingFiniteHorizon"
                    pure (floor (utcTimeToPOSIXSeconds start * 1000), end, snapshot)
                withWrites mempty mempty (facadeSettings facade) wallet $ \caps -> do
                    let SlotNo tip = Node.ledgerTipSlot point
                        upper = SlotNo (tip + 50)
                        SlotNo horizonSlot = horizon
                        SlotNo upperSlot = upper
                        -- Independent arithmetic for the retained generated fixture.
                        initialEnd = startMs + 100 * toInteger horizonSlot
                        finiteDeadline = startMs + 100 * toInteger upperSlot + 120_000
                        (network, provider) = capReads caps
                        window tx = do
                            runtime <- newIOConfirmationRuntime
                            confirmationWindow runtime provider network tx
                    unless (upper < horizon && finiteDeadline > initialEnd) $
                        fail "ConfirmationSmokeNotShortHorizon"
                    finite <- payment caps wallet (SJust upper)
                    selected <- window finite >>= either (fail . show) pure
                    unless (fst selected == finiteDeadline) $
                        fail "ConfirmationSmokeFiniteDeadlineMismatch"
                    finiteStarted <- getPOSIXTime
                    landedFinite <- sendAndConfirm caps wallet finite
                    finiteFinished <- getPOSIXTime
                    unbounded <- payment caps wallet SNothing
                    unboundedStarted <- getPOSIXTime
                    landedUnbounded <- sendAndConfirm caps wallet unbounded
                    unboundedFinished <- getPOSIXTime
                    -- Parent NOTE-030 opens the pinned final era. The former
                    -- raw-history-end refusal is retired, not counted as passed.
                    beyondRecorded <-
                        window
                            ( finite
                                & bodyTxL . vldtTxBodyL
                                    .~ ValidityInterval SNothing (SJust (SlotNo (horizonSlot + 1)))
                            )
                            >>= either (fail . show) pure
                    let beyondDeadline = startMs + 100 * toInteger (horizonSlot + 1) + 120_000
                    unless (fst beyondRecorded == beyondDeadline) $
                        fail "ConfirmationSmokeOpenedFinalEraMismatch"
                    runtime <- newIOConfirmationRuntime
                    refusal <-
                        confirmationWindow runtime provider (Cage.Network 999) finite
                    case refusal of
                        Left (ConfirmationAcquireFailure (Cage.WrongNetwork actual requested))
                            | actual == network && requested == Cage.Network 999 -> pure ()
                        _ -> fail "ConfirmationSmokeWrongNetworkWindowDidNotRefuse"
                    samples <- forM [1 :: Int .. 10] $ \sample -> do
                        tx <- payment caps wallet SNothing
                        firstEvent <- length <$> capTrace caps
                        started <- getPOSIXTime
                        landed <- sendAndConfirm caps wallet tx
                        finished <- getPOSIXTime
                        lastEvent <- length <$> capTrace caps
                        pure $
                            object
                                [ "sample" .= sample
                                , "transaction" .= show (txIdTx landed)
                                , "seconds" .= (realToFrac (finished - started) :: Double)
                                , "firstEvent" .= firstEvent
                                , "lastEvent" .= lastEvent
                                ]
                    LBS.writeFile
                        (output </> "confirmation-latency.json")
                        (encode samples)
                    capTrace caps
                        >>= LBS.writeFile (output </> "provider-trace.json") . encode
                    let missingFinite = finite & bodyTxL . feeTxBodyL .~ Coin 1_000_001
                        missingUnbounded = unbounded & bodyTxL . feeTxBodyL .~ Coin 1_000_002
                    (finiteFailure, unboundedFailure) <-
                        concurrently
                            (expectTimeout caps missingFinite (Just finiteDeadline) initialEnd)
                            (expectTimeout caps missingUnbounded Nothing initialEnd)
                    trace <- capTrace caps
                    LBS.writeFile (output </> "provider-trace.json") (encode trace)
                    LBS.writeFile (output </> "confirmation-smoke.json") $
                        encode $
                            object
                                [ "networkMagic" .= (42 :: Int)
                                , "finiteSubmitConfirmSeconds"
                                    .= (realToFrac (finiteFinished - finiteStarted) :: Double)
                                , "unboundedSubmitConfirmSeconds"
                                    .= (realToFrac (unboundedFinished - unboundedStarted) :: Double)
                                , "initialPoint" .= show (Node.ledgerChainPoint point)
                                , "initialHorizonSlot" .= horizonSlot
                                , "initialHorizonEndMs" .= initialEnd
                                , "finiteUpperSlot" .= upperSlot
                                , "finiteDeadlineMs" .= finiteDeadline
                                , "confirmedFiniteTx" .= show (txIdTx landedFinite)
                                , "confirmedNoUpperTx" .= show (txIdTx landedUnbounded)
                                , "finiteMissingTx" .= show (txIdTx missingFinite)
                                , "noUpperMissingTx" .= show (txIdTx missingUnbounded)
                                , "finiteTimeout" .= show finiteFailure
                                , "noUpperTimeout" .= show unboundedFailure
                                , "wrongNetworkWindowRefusal"
                                    .= either show (const "unexpected acceptance") refusal
                                , "pastRecordedHorizonDeadlineMs" .= fst beyondRecorded
                                , "retiredLedgerPastHorizonRefusal"
                                    .= ( "Parent NOTE-030 opens the final era; a raw recording end is not a conversion refusal. Ledger body upper bounds remain capped under NOTE-031."
                                            :: String
                                       )
                                , "limit"
                                    .= ( "Private HTTP key payments and confirmation waits only; registry journey remains separately required"
                                            :: String
                                       )
                                ]

payment
    :: Capabilities NoWitness IO
    -> Wallet
    -> StrictMaybe SlotNo
    -> IO ConwayTx
payment caps wallet upper = Cage.withLatest (capReads caps) $ \session -> do
    held <- Cage.outputsAt session (walletAddr wallet)
    case held of
        [] -> fail "ConfirmationSmokeEmptyFixtureWallet"
        _ -> do
            let value = foldMap ((^. valueTxOutL) . snd) held
            pure $
                mkBasicTx $
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.fromList (map fst held)
                        & outputsTxBodyL
                            .~ StrictSeq.singleton
                                (mkBasicTxOut (walletAddr wallet) (value <-> inject (Coin 1_000_000)))
                        & feeTxBodyL .~ Coin 1_000_000
                        & vldtTxBodyL .~ ValidityInterval SNothing upper

sendAndConfirm
    :: Capabilities NoWitness IO -> Wallet -> ConwayTx -> IO ConwayTx
sendAndConfirm caps wallet tx = do
    let signed = signTx (walletSignKey wallet) tx
    capSubmit caps signed >>= \case
        Cage.SubmitAccepted _ -> capConfirm caps (signedTx signed) >> pure (signedTx signed)
        other -> fail ("ConfirmationSmokePrivatePaymentRejected " <> show other)

expectTimeout
    :: Capabilities NoWitness IO
    -> ConwayTx
    -> Maybe Integer
    -> Integer
    -> IO WaitFailure
expectTimeout caps tx exact initialEnd = do
    before <- nowMs
    result <- try @WaitFailure (capConfirm caps tx)
    after <- nowMs
    failure <-
        either
            pure
            (const (fail "ConfirmationSmokeMissingTransactionAppeared"))
            result
    tip <- Cage.withLatest (capReads caps) Cage.tip
    let expected = fromMaybe (before + 300_000) exact
        upperExpected = fromMaybe (before + 30_000 + 300_000) exact
    unless
        ( waitStage failure == SessionConfirmationWait
            && waitTxId failure == txIdTx tx
            && maybe
                False
                ( \deadline ->
                    deadline >= expected
                        && deadline <= upperExpected
                        && deadline > initialEnd
                        && toInteger (Cage.observedBlockTime tip) * 1000 >= deadline
                )
                (waitClosedAt failure)
            && after >= expected
            && maybe
                (waitBound failure == 310 && waitElapsed failure >= 300)
                (const True)
                exact
        )
        (fail ("ConfirmationSmokeTimeoutMismatch " <> show failure))
    pure failure
  where
    nowMs = floor . (* 1000) <$> getPOSIXTime

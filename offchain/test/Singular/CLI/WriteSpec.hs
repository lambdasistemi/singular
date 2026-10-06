{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.WriteSpec
Description : A singular write on injected capabilities, over the in-memory chain
License     : Apache-2.0

One write of the ordinary CLI, driven through 'submitBuilt' over the
in-memory adapter with a recording submitter and a recording
confirmation: no node, no process-wide session.

Every compared value is obtained at run time: the session identity and
consumed raw facts are the ones the build reports, the signed body is the one the build
returned signed by the wallet's key, and the moved chain's point is read
back by a fresh acquisition. The chain is moved inside the build, after
the session is acquired and before the body is signed. The reached control
requires the fresh tip to differ. Unbound is retained; an observed tip is
never promoted to an atomic chain-point binding.
-}
module Singular.CLI.WriteSpec (spec) where

import Control.Exception
    ( SomeException
    , bracket
    , fromException
    , throwIO
    , try
    )
import Control.Monad (forM_, void, when)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Char (toUpper)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust, mapMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
    ( UTCTime
    , addUTCTime
    , defaultTimeLocale
    , getCurrentTime
    , parseTimeM
    )
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import Singular.Registry.SyntheticTime (syntheticTime)
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , listDirectory
    , removeFile
    , withCurrentDirectory
    )
import System.FilePath (takeDirectory, (</>))
import System.IO
    ( hClose
    , hFlush
    , hPrint
    , openTempFile
    , stderr
    , stdout
    )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , dup
    , dupTo
    , openFd
    , stdError
    , stdOutput
    )
import System.Posix.Types (Fd)
import Test.Hspec hiding (context)

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (addrTxWitsL, rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Singular.Registry.AssetName (deriveAssetName)

import Control.Tracer (Tracer (..), nullTracer)
import Data.Aeson.KeyMap qualified as KeyMap
import Singular.CLI.Attached (Attached (..))
import Singular.CLI.Fold (FoldOrigin (..), FoldSpec (..), foldPending)
import Singular.CLI.Live
    ( Live (..)
    , Saved (..)
    , TrieContext
    , openTrie
    , requireTrieSelection
    , selectedTrieRoot
    , txInText
    )
import Singular.CLI.Plan (planTerminate, planUpdate)
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , appendJournal
    , outcomeName
    , readJournal
    , unresolved
    )
import Singular.CLI.Registry
    ( hexT
    , mkRegistryConfig
    , pinsOf
    )
import Singular.CLI.RejectRules (rejectGate, renderRejectRefusal)
import Singular.CLI.RequestWindow (retractEnds, windowOf)
import Singular.CLI.Session
    ( CommandFailure (..)
    , WriteContext (..)
    , expecting
    , failWith
    , journalObserved
    , submitBuilt
    , txIdHex
    )
import Singular.CLI.Trace
    ( ConfirmVerdict (..)
    , EdgeAction (..)
    , Ended (..)
    , Event (..)
    , How (..)
    , Output (..)
    , RefusalKind (..)
    , Scope (..)
    , SubmitVerdict (..)
    , Trace (..)
    , TraceFormat (..)
    , TraceLevel (..)
    , TraceSink (..)
    , TxEvent (..)
    , What (..)
    , fanOut
    , outputSink
    , phaseLogSink
    , renderJsonLine
    , renderPhaseLog
    , renderText
    )
import Singular.Registry.Capabilities
    ( Capabilities (..)
    , sessionReceipt
    )
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Deployment
    ( Deployment (..)
    , parseOutRef
    )
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , newRawChain
    , rawChainProvider
    )
import Singular.Registry.SessionEvidence (FactRecord, observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing
    ( signTx
    , signedTx
    )
import Singular.Registry.StubSession
    ( servingSession
    , stubSession
    , withAddressOutputs
    )
import Singular.Registry.Trace
    ( ErrorClass (..)
    , Evaluation (..)
    )
import Singular.Registry.TxBuilder.BookingFixture qualified as Booking
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , mkInlineDatum
    , mkRequestDatumWith
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , MintRedeemer (..)
    , OnChainRoot (..)
    , edgeName
    )
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec = writeRows >> phaseLogRows >> inputRows >> narrationRows

writeRows :: Spec
writeRows = describe "a singular write on injected capabilities (#323)" $ do
    it
        "journals the actual build session and consumed raw facts, though the chain moved before signing"
        $ withFixture
        $ \fx -> do
            _ <- try @SomeException (write fx)
            built <- readIORef (fxBuiltAt fx)
            (scope, builtTip) <- maybe (fail "the build never ran") pure built
            fresh <-
                SessionIO.withLatest (rawChainProvider (fxChain fx)) SessionIO.tip
            Cage.observedSlot fresh `shouldNotBe` Cage.observedSlot builtTip
            prepared <- preparedLines (fxDir fx)
            map (field "journalSession") prepared `shouldBe` [Just scope]
            map (field "journalNetwork") prepared `shouldBe` [Just viewNetwork]
            map (field "journalEra") prepared `shouldBe` [Just ("Conway" :: Text)]
            map (field "journalChainPoint") prepared
                `shouldBe` [Nothing :: Maybe Text]
            case scope of
                Aeson.Object fields -> do
                    field "networkMagic" fields `shouldBe` Just viewNetwork
                    (field "facts" fields :: Maybe [Aeson.Value])
                        `shouldSatisfy` maybe False (not . null)
                    field "binding" fields
                        `shouldBe` Just (Aeson.object ["kind" Aeson..= ("Unbound" :: Text)])
                _ -> expectationFailure "the build session is not a computed object"
    it
        "confirms through the confirmation it was given, with no node \
        \session open"
        $ withFixture
        $ \fx -> do
            (signed, ()) <- write fx
            confirmed <- readIORef (fxConfirmed fx)
            confirmed `shouldBe` [T.unpack (txIdHex signed)]
            events <- map journalEvent <$> readJournal (fxDir fx)
            events `shouldBe` ["prepared", "submitted", "confirmed"]
    it "hands the node only the body the caller's key signed" $
        withFixture $ \fx -> do
            _ <- try @SomeException (write fx)
            unsigned <- readIORef (fxUnsigned fx)
            sent <- readIORef (fxSent fx)
            let expected =
                    signedTx . signTx (walletSignKey (fxWallet fx)) <$> unsigned
            sent `shouldBe` maybe [] pure expected
            map (Set.size . (^. witsTxL . addrTxWitsL)) sent `shouldBe` [1]
    it
        "still reads a journal written before the view point was journalled"
        $ withSystemTempDirectory "singular-write"
        $ \dir -> do
            BS.writeFile (dir </> "journal.jsonl") preS2Journal
            entries <- readJournal dir
            map journalEvent entries `shouldBe` ["prepared", "submitted"]
            fmap journalTxId (unresolved entries) `shouldBe` Just "ab"

-- ---------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------

-- Execute the command's actual early refusal on an injected pending output.
-- The boot is signed and recorded through submitBuilt, so selection checks the
-- real saved body and empty MPF nodes. Confirmation here is a recording test
-- capability: these cases establish command behavior, never ledger admission.
inputRows :: Spec
inputRows = describe "TrieState command input refusals on injected capabilities" $ do
    it
        "removing or corrupting journal trie records does not change the public trie"
        $ withInputFixture
        $ \fx saved live context _ -> do
            entries <- readJournal (fxDir fx)
            BS.writeFile (fxDir fx </> "journal.jsonl") ""
            requireTrieSelection saved live context
            selectedTrieRoot context `shouldReturn` BS.replicate 32 0
            BS.writeFile (fxDir fx </> "journal.jsonl") "corrupt local history"
            requireTrieSelection saved live context
            selectedTrieRoot context `shouldReturn` BS.replicate 32 0
            BS.writeFile
                (fxDir fx </> "journal.jsonl")
                (BL.toStrict (foldMap (\e -> Aeson.encode e <> "\n") entries))
    forM_ [0, 2, 4, 5, 6, 7, 42] $ \edge ->
        forM_ [False, True] $ \combined ->
            it
                ( "names pending "
                    <> edgeName edge
                    <> " before speculation, combined="
                    <> show combined
                )
                $ withInputFixture
                $ \fx saved live mirror boot -> do
                    let request = TxIn (txIdTx boot) (TxIx 0)
                        requestAddr = requestAddrFromCfg (savedCfg saved) (savedToken saved) Testnet
                        requestOut =
                            mkBasicTxOut requestAddr (MaryValue (Coin 3_000_000) mempty)
                                & datumTxOutL
                                    .~ mkInlineDatum
                                        ( mkRequestDatumWith
                                            (savedToken saved)
                                            (walletAddr (fxWallet fx))
                                            "missing-key"
                                            edge
                                            2_000_000
                                            0
                                            ("", Nothing)
                                        )
                        ctx =
                            (writeContext fx)
                                { wcCommand = "fold"
                                , wcCapabilities =
                                    (wcCapabilities (writeContext fx))
                                        { capReads =
                                            servingSession $
                                                withAddressOutputs
                                                    ( \addr ->
                                                        if addr == requestAddr
                                                            then pure [(request, requestOut)]
                                                            else fail "an inadmissible request reached a later provider read"
                                                    )
                                                    stubSession
                                        }
                                }
                        action =
                            foldPending
                                (Attached ctx live mirror)
                                FoldSpec
                                    { fsOrigin = if combined then Combined boot else Standalone
                                    , fsRequest = Just request
                                    , fsFund = Nothing
                                    , fsAllowance = Nothing
                                    }
                    journalBefore <- readJournal (fxDir fx)
                    sentBefore <- readIORef (fxSent fx)
                    confirmedBefore <- readIORef (fxConfirmed fx)
                    result <- try @CommandFailure action
                    case result of
                        Left (CommandFailure cls why fields) -> do
                            cls `shouldBe` if combined then Partial else ClientRefusal
                            why `shouldSatisfy` isInfixOf (edgeName edge)
                            why `shouldSatisfy` isInfixOf "registry fold does not fold"
                            lookup "pendingRequest" fields
                                `shouldBe` Just (Aeson.toJSON (txInText request))
                        Right _ -> expectationFailure "an unsupported pending edge folded"
                    readJournal (fxDir fx) `shouldReturn` journalBefore
                    readIORef (fxSent fx) `shouldReturn` sentBefore
                    readIORef (fxConfirmed fx) `shouldReturn` confirmedBefore
                    let bounds =
                            windowOf
                                0
                                (defaultProcessTime (savedCfg saved))
                                (defaultRetractTime (savedCfg saved))
                        deadline = retractEnds bounds
                        booked = [(request, bounds, Just deadline)]
                    -- Reject's unchanged shared gate depends on the windows,
                    -- not on whether this edge has a fold route. It still
                    -- names this retained request early and takes it later.
                    case rejectGate 0 booked of
                        Left why ->
                            renderRejectRefusal why
                                `shouldSatisfy` isInfixOf (T.unpack (txInText request))
                        Right _ -> expectationFailure "an open request was rejected"
                    rejectGate deadline booked `shouldBe` Right [(request, bounds)]
    it
        "refuses an absent source holding in the shared write/preview update and termination plans"
        $ withInputFixture
        $ \fx _ live _ _ -> do
            let key = "missing-key"
                controller = BS.replicate 28 0x5a
                check action = do
                    result <- try @CommandFailure action
                    case result of
                        Left (CommandFailure cls why _) -> do
                            cls `shouldBe` ClientRefusal
                            why `shouldBe` "no live output holds key 0x6d697373696e672d6b6579"
                        Right _ -> expectationFailure "an absent holding produced a plan"
            entries <- readJournal (fxDir fx)
            check (planUpdate live controller key [])
            check (planTerminate live controller key [])
            readJournal (fxDir fx) `shouldReturn` entries

withInputFixture
    :: (Fixture -> Saved -> Live -> TrieContext -> ConwayTx -> IO a) -> IO a
withInputFixture use = withFixture $ \fx -> do
    let cfg = Booking.cfg
        seed = either error id (parseOutRef (T.pack (replicate 64 '1' <> "#0")))
        seedOut =
            mkBasicTxOut
                (walletAddr (fxWallet fx))
                (MaryValue (Coin 10_000_000) mempty)
        tid@(TokenId name) =
            TokenId (AssetName (SBS.toShort (deriveAssetName (txInToRef seed))))
        policy = cagePolicyIdFromCfg cfg
        emptyRoot = BS.replicate 32 0
        stateOut =
            mkBasicTxOut
                (cageAddrFromCfg cfg Testnet)
                ( MaryValue
                    (Coin 2_000_000)
                    (MultiAsset (Map.singleton policy (Map.singleton name 1)))
                )
                & datumTxOutL
                    .~ mkInlineDatum
                        (toPlcData (StateDatum (bootStateFromCfg cfg (OnChainRoot emptyRoot))))
        unsigned =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton seed
                    & outputsTxBodyL .~ StrictSeq.fromList [stateOut]
                    & mintTxBodyL
                        .~ MultiAsset (Map.singleton policy (Map.singleton name 1))
                )
                & witsTxL . rdmrsTxWitsL
                    .~ Redeemers
                        ( Map.singleton
                            (ConwayMinting (AsIx 0))
                            (Data (toPlcData (Minting (txInToRef seed))), ExUnits 0 0)
                        )
        deployment =
            Deployment
                { depRelease = "injected-command-fixture"
                , depLeanRevision = "no-ledger-admission-claim"
                , depNetworkMagic = magic
                , depSeedOutRef = T.pack (replicate 64 '1' <> "#0")
                , depCageToken = "743234302d7265676973747279"
                , depStatePolicy = hexT (scriptHashBytes (cfgScriptHash cfg))
                , depRequestHash = ""
                , depApplicationHash = hexT (SBS.fromShort (cfgApplicationPolicy cfg))
                , depRepresentativePolicy = hexT (SBS.fromShort (cfgActivePolicy cfg))
                , depProcessTime = defaultProcessTime cfg
                , depRetractTime = defaultRetractTime cfg
                , depTip = 1_000_000
                , depReferenceScripts = []
                , depBootstrapTxs = []
                }
        saved =
            Saved
                (fxDir fx)
                ( mkRegistryConfig
                    magic
                    (walletAddr (fxWallet fx))
                    (pinsOf cfg)
                    deployment
                )
                cfg
                Booking.codes
                tid
                []
    (boot, ()) <-
        submitBuilt
            (writeContext fx)
            "boot"
            (const (expecting "state"))
            (const (pure (unsigned, ())))
    journalObserved
        (writeContext fx)
        "boot"
        boot
        "fixture state output recorded"
    SessionIO.withLatest (capReads (wcCapabilities (writeContext fx))) $ \actualSession -> do
        let record =
                Cage.HistoricalTransaction
                    { Cage.historicalId = txIdTx boot
                    , Cage.historicalCbor =
                        BL.toStrict (serialize (eraProtVerHigh @ConwayEra) boot)
                    , Cage.historicalTx = boot
                    , Cage.spentOutputs = [(seed, seedOut)]
                    , Cage.referenceOutputs = []
                    , Cage.createdOutputs = [(TxIn (txIdTx boot) (TxIx 0), stateOut)]
                    , Cage.scriptValid = True
                    }
            session =
                actualSession
                    { Cage.history = \_ _ ->
                        pure
                            ( Right
                                ( Cage.HistoryStream
                                    ( pure
                                        ( Right
                                            ( Just
                                                ( Cage.HistoryBlock 1 (record :| [])
                                                , Cage.HistoryStream (pure (Right Nothing))
                                                )
                                            )
                                        )
                                    )
                                )
                            )
                    }
            live = Live session saved [] (TxIn (txIdTx boot) (TxIx 0), stateOut)
        mirror <- openTrie saved
        requireTrieSelection saved live mirror
        use fx saved live mirror boot

data Fixture = Fixture
    { fxDir :: FilePath
    , fxChain :: RawChain
    , fxWallet :: Wallet
    , fxSent :: IORef [ConwayTx]
    , fxConfirmed :: IORef [String]
    , fxBuiltAt :: IORef (Maybe (Aeson.Value, Cage.TipObservation))
    , fxUnsigned :: IORef (Maybe ConwayTx)
    , fxFacts :: IORef [FactRecord]
    , fxConfirmations :: IORef (Map.Map Text (IO Double))
    , fxPlacements :: IORef (Map.Map Text [Scope])
    }

magic :: Word32
magic = 42

{- | The configured provider network differs from the wallet's loading magic,
so writing the wallet's magic into the acquired session receipt fails.
The transaction era is read from the actual Conway body type.
-}
viewNetwork :: Word32
viewNetwork = 2_323

withFixture :: (Fixture -> IO a) -> IO a
withFixture k = withSystemTempDirectory "singular-write" $ \dir -> do
    let keyPath = dir </> "payment.skey"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    w <- loadWallet magic keyPath
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = viewNetwork
                , csTip = Nothing
                , csPParams = emptyPParams
                , csUTxO =
                    Map.singleton
                        (outRef 'f')
                        (mkBasicTxOut (walletAddr w) (MaryValue (Coin 50_000_000) mempty))
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    advanceChain chain id
    Fixture (dir </> "registry") chain w
        <$> newIORef []
        <*> newIORef []
        <*> newIORef Nothing
        <*> newIORef Nothing
        <*> newIORef []
        <*> newIORef Map.empty
        <*> newIORef Map.empty
        >>= k

{- | The write context a command would get from composition, over the
fixture's chain, recording what is submitted and confirmed.
-}
writeContext :: Fixture -> WriteContext
writeContext fx =
    WriteContext
        { wcDir = fxDir fx
        , wcCommand = "insert"
        , wcWallet = fxWallet fx
        , wcCapabilities =
            Capabilities
                { capReads =
                    let (network, provider) = rawChainProvider (fxChain fx)
                    in  ( network
                        , observeProvider
                            unverifiedVerifier
                            (\fact -> modifyIORef' (fxFacts fx) (<> [fact]))
                            provider
                        )
                , capSubmit = \signed -> do
                    let tx = signedTx signed
                    modifyIORef' (fxSent fx) (<> [tx])
                    pure (Cage.SubmitAccepted (txIdTx tx))
                , capConfirm = \tx -> modifyIORef' (fxConfirmed fx) (<> [T.unpack (txIdHex tx)])
                , capFacts = readIORef (fxFacts fx)
                , capTrace = pure []
                }
        , wcTimeout = Just 5
        , wcTracer = nullTracer
        , wcSource = "fixture"
        , wcConfirmed = fxConfirmations fx
        , wcPlaced = fxPlacements fx
        }

{- | One write: spend the wallet's output as the view shows it, moving the
chain after the view is acquired.
-}
write :: Fixture -> IO (ConwayTx, ())
write fx = writeVia (writeContext fx) id fx

{- | The same write through a given context, shaping the transaction it
builds with a function.
-}
writeVia
    :: WriteContext -> (ConwayTx -> ConwayTx) -> Fixture -> IO (ConwayTx, ())
writeVia ctx shape fx =
    submitBuilt ctx "fold" (const (expecting "state")) $ \v -> do
        utxos <- SessionIO.outputsAt v (walletAddr (fxWallet fx))
        observed <- SessionIO.tip v
        scope <- sessionReceipt (wcCapabilities ctx) v
        writeIORef (fxBuiltAt fx) (Just (scope, observed))
        advanceChain (fxChain fx) id
        let tx =
                shape $
                    mkBasicTx
                        ( mkBasicTxBody
                            & inputsTxBodyL .~ Set.fromList (map fst utxos)
                            & outputsTxBodyL .~ StrictSeq.fromList (map snd utxos)
                        )
        writeIORef (fxUnsigned fx) (Just tx)
        pure (tx, ())

-- ---------------------------------------------------------
-- The journal as written
-- ---------------------------------------------------------

-- | The journal's @prepared@ lines, as the JSON objects on disk.
preparedLines :: FilePath -> IO [Aeson.Object]
preparedLines dir = do
    raw <- BS.readFile (dir </> "journal.jsonl")
    let objects = mapMaybe (Aeson.decodeStrict @Aeson.Object) (BC.lines raw)
    pure
        [ o | o <- objects, field "journalEvent" o == Just ("prepared" :: Text)
        ]

field :: (Aeson.FromJSON a) => Aeson.Key -> Aeson.Object -> Maybe a
field k = Aeson.parseMaybe (.: k)

{- | Two lines as a write before the view point was journalled left them:
a tip slot, a two-part point, no network or era.
-}
preS2Journal :: BS.ByteString
preS2Journal =
    BC.unlines
        [ "{\"journalCommand\":\"insert\",\"journalStep\":\"fold\",\"journalTxId\":\"ab\",\"journalEvent\":\"prepared\",\"journalDetail\":null,\"journalInputs\":[],\"journalTipSlot\":7,\"journalBody\":null,\"journalBodyHash\":null,\"journalChainPoint\":\"7.00\",\"journalKey\":null,\"journalExpect\":\"state\",\"journalEdge\":null,\"journalRootBefore\":null,\"journalRootAfter\":null}"
        , "{\"journalCommand\":\"insert\",\"journalStep\":\"fold\",\"journalTxId\":\"ab\",\"journalEvent\":\"submitted\",\"journalDetail\":null,\"journalInputs\":null,\"journalTipSlot\":null,\"journalBody\":null,\"journalBodyHash\":null,\"journalChainPoint\":null,\"journalKey\":null,\"journalExpect\":null,\"journalEdge\":null,\"journalRootBefore\":null,\"journalRootAfter\":null}"
        ]

outRef :: Char -> TxIn
outRef c =
    either
        (error . ("WriteSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#0")))

-- ---------------------------------------------------------
-- The phase log of a write (#363)
-- ---------------------------------------------------------

{- | The write of the ordinary CLI with the phase log on or off. Every
compared value is obtained at run time: the transaction id from the
signed body, the tip from a fresh acquisition after the write, the
validity interval from the body that was built, and the secrets from the
wallet's own key.
-}
phaseLogRows :: Spec
phaseLogRows = describe "the phase log of a write (#363)" $ do
    it
        "unset: no log file, nothing on stdout or stderr and nothing else \
        \in either directory — while the same write with the variable set \
        \does log"
        $ do
            (files, cwdFiles, out, err) <- withFixture $ \fx ->
                -- the process runs in a directory of its own, so a log written
                -- to a default path would show there
                withSystemTempDirectory "singular-cwd" $ \cwd ->
                    withCurrentDirectory cwd $ do
                        ((), out, err) <- captured (void (write fx))
                        here <- listDirectory (takeDirectory (fxDir fx))
                        there <- listDirectory (fxDir fx)
                        inCwd <- listDirectory cwd
                        pure ((sort here, sort there), inCwd, out, err)
            cwdFiles `shouldBe` []
            files
                `shouldBe` ( ["payment.skey", "registry"]
                           , ["journal.jsonl", "submissions"]
                           )
            (out, err) `shouldBe` ("", "")
            -- the control: the phase-log tracer is what makes the file appear
            logged <- withFixture $ \fx -> do
                let path = takeDirectory (fxDir fx) </> "phase.log"
                do
                    _ <- writeVia (loggedTo path (writeContext fx)) id fx
                    doesFileExist path
            logged `shouldBe` True
    it
        "set: a build, a signing, a submission with the tip it met and \
        \the validity it carried, and a confirmation, each once and in \
        \that order, for the one transaction"
        $ withFixture
        $ \fx -> do
            let path = takeDirectory (fxDir fx) </> "phase.log"
                bounded =
                    bodyTxL . vldtTxBodyL
                        .~ ValidityInterval (SJust (SlotNo 10)) (SJust (SlotNo 99))
            (signed, ()) <-
                writeVia (loggedTo path (writeContext fx)) bounded fx
            built <- readIORef (fxBuiltAt fx)
            builtPoint <- maybe (fail "the build never ran") pure built
            tip <-
                Cage.observedSlot
                    <$> SessionIO.withLatest (rawChainProvider (fxChain fx)) SessionIO.tip
            -- the build's own view is not the tip the submission met
            Cage.observedSlot (snd builtPoint) `shouldNotBe` tip
            objects <- logObjects path
            let phased p = [o | o <- objects, field "phase" o == Just (p :: Text)]
                txid = txIdHex signed
                vldt = signed ^. bodyTxL . vldtTxBodyL
                strict = \case SJust (SlotNo s) -> Just s; SNothing -> Nothing
            map (field "step") (phased "build") `shouldBe` [Just ("fold" :: Text)]
            map (field "tx") (phased "sign") `shouldBe` [Just txid]
            map (field "tx") (phased "submit") `shouldBe` [Just txid]
            map (field "tx") (phased "confirm") `shouldBe` [Just txid]
            map (field "outcome") (phased "submit")
                `shouldBe` [Just ("submitted" :: Text)]
            map (field "outcome") (phased "confirm")
                `shouldBe` [Just ("confirmed" :: Text)]
            map (field "tip_slot") (phased "submit")
                `shouldBe` [Just (unSlotNo tip)]
            map (field "validity_lower") (phased "submit")
                `shouldBe` [strict (invalidBefore vldt)]
            map (field "validity_upper") (phased "submit")
                `shouldBe` [strict (invalidHereafter vldt)]
            forM_ ["build", "sign", "submit", "confirm"] $ \p ->
                map (isNumber "duration_ms") (phased p) `shouldBe` [True]
            [ p
              | o <- objects
              , Just p <- [field "phase" o :: Maybe Text]
              , p `elem` ["build", "sign", "submit", "confirm"]
              ]
                `shouldBe` ["build", "sign", "submit", "confirm"]
            let stamps = mapMaybe (field "ts") objects :: [Text]
            stamps `shouldBe` sort stamps
    it
        "a confirmation that fails is logged as failed, once, with no text \
        \of the failure"
        $ withFixture
        $ \fx -> do
            let path = takeDirectory (fxDir fx) </> "phase.log"
                ctx = loggedTo path (writeContext fx)
                caps = wcCapabilities ctx
                broken =
                    ctx
                        { wcCapabilities =
                            caps
                                { capConfirm = \_ ->
                                    throwIO (userError "403 for project_id=CRED-5c1d2")
                                }
                        }
            _ <- try @SomeException (writeVia broken id fx)
            objects <- logObjects path
            outcomesOf "confirm" objects `shouldBe` [Just "failed"]
            raw <- BS.readFile path
            BC.unpack raw `shouldNotSatisfy` ("CRED-5c1d2" `isInfixOf`)
    it
        "never writes the signing key, in any of its renderings, nor a \
        \credential an operation failed with"
        $ withFixture
        $ \fx -> do
            let path = takeDirectory (fxDir fx) </> "phase.log"
                ctx = loggedTo path (writeContext fx)
                caps = wcCapabilities ctx
                key = rawSerialiseSignKeyDSIGN (walletSignKey (fxWallet fx))
                hex = B16.encode key
                secrets =
                    [ key
                    , hex
                    , BC.map toUpper hex
                    , "5820" <> hex
                    , BC.map toUpper ("5820" <> hex)
                    , bech32Of "addr_sk" key
                    , bech32Of "ed25519_sk" key
                    ]
                rejecting =
                    ctx
                        { wcCapabilities =
                            caps
                                { capSubmit = \_ ->
                                    throwIO (userError "401 for project_id=CRED-9e4b7")
                                }
                        }
            _ <- do
                _ <- writeVia ctx id fx
                try @SomeException (writeVia rejecting id fx)
            raw <- BS.readFile path
            -- the log has the signing and the submission it must not leak from
            objects <- logObjects path
            length [o | o <- objects, field "phase" o == Just ("sign" :: Text)]
                `shouldBe` 2
            [s | s <- secrets, s `BS.isInfixOf` raw] `shouldBe` []
            BC.unpack raw `shouldNotSatisfy` ("CRED-9e4b7" `isInfixOf`)
            outcomesOf "submit" objects
                `shouldBe` [Just "submitted", Just "failed"]
    it
        "enabled: standard output and error stay empty, the journal is the \
        \unset run's but for its times and body paths, and the log is a file \
        \of its own"
        $ do
            let normal e =
                    e
                        { journalBody = Nothing
                        , journalTime = Nothing
                        , journalSession = normalizeSessionIds <$> journalSession e
                        }
                run logPath = withFixture $ \fx -> do
                    ((), out, err) <- captured $ do
                        _ <-
                            writeVia
                                ( maybe
                                    (writeContext fx)
                                    (\p -> loggedTo p (writeContext fx))
                                    logPath
                                )
                                id
                                fx
                        pure ()
                    entries <- readJournal (fxDir fx)
                    raw <- BS.readFile (fxDir fx </> "journal.jsonl")
                    pure (map normal entries, out, err, raw)
            (plain, _, _, _) <- run Nothing
            (logged, out, err, journalRaw) <-
                withSystemTempDirectory "phase-log" $ \d -> run (Just (d </> "phase.log"))
            (out, err) `shouldBe` ("", "")
            logged `shouldBe` plain
            length logged `shouldBe` 3
            -- the journal holds journal lines only: no phase line is among them
            [ o
              | o <- mapMaybe (Aeson.decodeStrict @Aeson.Object) (BC.lines journalRaw)
              , isJust (field "phase" o :: Maybe Text)
              ]
                `shouldBe` []
    it
        "a log that cannot be written changes nothing the command does: the \
        \same journal and the same outcome, whether the confirmation holds or \
        \fails"
        $ withSystemTempDirectory "phase-log"
        $ \dir -> do
            let destinations =
                    [ dir -- a directory is not a file to append to
                    , dir </> "no-such-directory" </> "phase.log"
                    ]
                run logPath failing = withFixture $ \fx -> do
                    let ctx0 =
                            maybe
                                (writeContext fx)
                                (\p -> loggedTo p (writeContext fx))
                                logPath
                        caps = wcCapabilities ctx0
                        ctx
                            | failing =
                                ctx0
                                    { wcCapabilities =
                                        caps{capConfirm = \_ -> throwIO (userError "the wait broke")}
                                    }
                            | otherwise = ctx0
                    r <- try @SomeException (writeVia ctx id fx)
                    events <- map journalEvent <$> readJournal (fxDir fx)
                    pure
                        ( events
                        , case r of
                            Right _ -> "completed"
                            Left e -> case fromException e of
                                Just (CommandFailure c _ _) -> outcomeName c
                                Nothing -> "unclassified: " <> T.pack (show e)
                        )
            forM_ [False, True] $ \failing -> do
                plain <- run Nothing failing
                forM_ destinations $ \d -> run (Just d) failing `shouldReturn` plain
            -- the destinations really were unwritable
            doesDirectoryExist (dir </> "no-such-directory") `shouldReturn` False
            run Nothing True
                `shouldReturn` (["prepared", "submitted", "unconfirmed"], "partial")
            run Nothing False
                `shouldReturn` (["prepared", "submitted", "confirmed"], "completed")
    it
        "stamps every journal line it appends, from the clock at the append, \
        \whatever the line carried"
        $ withFixture
        $ \fx -> do
            t0 <- getCurrentTime
            (signed, ()) <- write fx
            let ctx = writeContext fx
            journalObserved ctx "fold" signed "read back"
            earlier <-
                readJournal (fxDir fx) >>= \case e : _ -> pure e; [] -> fail "no journal"
            -- a line copied from an earlier one carries its time: appending it again
            -- must not keep the stale stamp
            appendJournal
                (fxDir fx)
                earlier{journalTime = Just "2000-01-01T00:00:00.000Z"}
            t1 <- getCurrentTime
            raw <- BS.readFile (fxDir fx </> "journal.jsonl")
            let objects = mapMaybe (Aeson.decodeStrict @Aeson.Object) (BC.lines raw)
                stamps = map (field "journalTime") objects :: [Maybe Text]
            length objects `shouldBe` 5
            forM_ stamps $ \s -> do
                at <-
                    maybe
                        (fail "a journal line without journalTime")
                        pure
                        (s >>= parseIso)
                (at >= addUTCTime (-0.001) t0 && at <= t1) `shouldBe` True
            catMaybes stamps `shouldBe` sort (catMaybes stamps)
    it
        "reads a journal written before the lines carried a time, with none"
        $ withSystemTempDirectory "singular-write"
        $ \dir -> do
            BS.writeFile (dir </> "journal.jsonl") preS2Journal
            entries <- readJournal dir
            map journalTime entries `shouldBe` [Nothing, Nothing]
            fmap journalTxId (unresolved entries) `shouldBe` Just "ab"
            -- and a line appended after them is stamped, the old ones untouched
            appendJournal dir (last entries){journalEvent = "confirmed"}
            raw <- BS.readFile (dir </> "journal.jsonl")
            BS.take (BS.length preS2Journal) raw `shouldBe` preS2Journal
            appended <- readJournal dir
            map (isJust . journalTime) appended `shouldBe` [False, False, True]

-- | The outcome each line of this phase records.
outcomesOf :: Text -> [Aeson.Object] -> [Maybe Text]
outcomesOf p objects =
    [field "outcome" o | o <- objects, field "phase" o == Just p]

-- | The bech32 text of some bytes under a human-readable part.
bech32Of :: Text -> BS.ByteString -> BS.ByteString
bech32Of hrp bytes =
    either (error . show) TE.encodeUtf8 $ do
        h <- first show (Bech32.humanReadablePartFromText hrp)
        first show (Bech32.encode h (Bech32.dataPartFromBytes bytes))

{- | Compare independent acquisitions up to their fresh opaque identity,
retaining every binding, raw fact, verdict and source field.
-}
normalizeSessionIds :: Aeson.Value -> Aeson.Value
normalizeSessionIds = \case
    Aeson.Object fields ->
        Aeson.Object $
            KeyMap.mapWithKey
                ( \key value ->
                    if key == "session"
                        then Aeson.String "alpha-session"
                        else normalizeSessionIds value
                )
                fields
    Aeson.Array values -> Aeson.Array (fmap normalizeSessionIds values)
    value -> value

-- | The write's context with its events also written to the phase log at a path.
loggedTo :: FilePath -> WriteContext -> WriteContext
loggedTo path ctx = ctx{wcTracer = phaseLogSink path}

-- | The log's lines, each a JSON object.
logObjects :: FilePath -> IO [Aeson.Object]
logObjects path = do
    raw <- BS.readFile path
    either fail pure $
        traverse Aeson.eitherDecodeStrict' (BC.lines raw)

parseIso :: Text -> Maybe UTCTime
parseIso =
    parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" . T.unpack

isNumber :: Aeson.Key -> Aeson.Object -> Bool
isNumber k o = case field k o :: Maybe Aeson.Value of
    Just (Aeson.Number _) -> True
    _ -> False

{- | Run an action with standard output and standard error redirected to
files, returning what it wrote to each.
-}
captured :: IO a -> IO (a, BS.ByteString, BS.ByteString)
captured act = withSystemTempDirectory "singular-captured" $ \dir -> do
    let outPath = dir </> "stdout"
        errPath = dir </> "stderr"
    a <- redirecting stdOutput outPath (redirecting stdError errPath act)
    (,,) a <$> BS.readFile outPath <*> BS.readFile errPath

redirecting :: Fd -> FilePath -> IO a -> IO a
redirecting target path act =
    bracket
        ( do
            hFlush stdout >> hFlush stderr
            saved <- dup target
            f <-
                openFd
                    path
                    WriteOnly
                    defaultFileFlags{creat = Just 0o644, trunc = True}
            _ <- dupTo f target
            closeFd f
            pure saved
        )
        ( \saved -> do
            hFlush stdout >> hFlush stderr
            _ <- dupTo saved target
            closeFd saved
        )
        (const act)

-- ---------------------------------------------------------
-- The narration of a write (#416)
-- ---------------------------------------------------------

{- | The typed events a write reports, collected from the tracer its context
carries. Every compared value is the producer's: the transaction id from the
signed body, the steps and the journal from the journal on disk.
-}
narrationRows :: Spec
narrationRows = describe "the narration of a write (#416)" $ do
    it
        "reports each transaction's build, signing, submission, confirmation and \
        \readback under its own step, naming the transaction the journal names"
        $ withFixture
        $ \fx -> do
            (seen, collect) <- traceCollector
            let ctx = (writeContext fx){wcTracer = collect}
                later =
                    bodyTxL . vldtTxBodyL
                        .~ ValidityInterval (SJust (SlotNo 10)) (SJust (SlotNo 99))
            (folded, ()) <- writeStepVia "fold" ctx id fx
            journalObserved ctx "fold" folded "read back"
            (booked, ()) <- writeStepVia "book" ctx later fx
            journalObserved ctx "book" booked "read back"
            events <- readIORef seen
            prepared <- readJournal (fxDir fx)
            let journalled =
                    [ (journalStep e, journalTxId e)
                    | e <- prepared
                    , journalEvent e == "prepared"
                    ]
                txOf = \case
                    TxBuilt{} -> Nothing
                    TxSigned _ t _ _ _ -> Just t
                    TxSubmitted{submitTxId = t} -> Just t
                    TxConfirmed _ t _ _ -> Just t
                    TxObserved _ t _ -> Just t
                stepOf = \case
                    TxBuilt s _ _ -> s
                    TxSigned s _ _ _ _ -> s
                    TxSubmitted{submitStep = s} -> s
                    TxConfirmed s _ _ _ -> s
                    TxObserved s _ _ -> s
                txEvents = [(scope, e) | Trace scope (How (Tx e)) <- events]
            journalled
                `shouldBe` [("fold", txIdHex folded), ("book", txIdHex booked)]
            txIdHex folded `shouldNotBe` txIdHex booked
            forM_ [("fold", folded), ("book", booked)] $ \(step, signed) -> do
                let mine = [e | (scope, e) <- txEvents, scope == [InTransaction step]]
                map stepOf mine `shouldSatisfy` all (== step)
                [() | TxBuilt{} <- mine] `shouldBe` [()]
                mapMaybe txOf mine `shouldBe` replicate 4 (txIdHex signed)
                [v | TxSubmitted{submitVerdict = v} <- mine] `shouldBe` [Accepted]
                [v | TxConfirmed _ _ _ v <- mine] `shouldBe` [Confirmed]
                [t | TxObserved _ t _ <- mine] `shouldBe` [txIdHex signed]
            length txEvents `shouldBe` 10
    it
        "names the four places a failure happens as four distinct events, \
        \leaving every outcome class as it was"
        $ do
            let refusing = \case
                    ClientRefused -> \fx ctx -> writeBuilding ctx fx $ \_ ->
                        failWith ClientRefusal "no fold is built"
                    EvaluationRefused -> \fx ctx -> writeBuilding ctx fx $ \v -> do
                        -- the build's session records a failed evaluation, as the local
                        -- evaluator does (the real path: CommandRunSpec)
                        Cage.sessionEvaluated v (Evaluation 3 2 1 0 0)
                        failWith ClientRefusal "its fold could not be built"
                    LedgerRejected -> \fx ctx ->
                        writeVia
                            (submitting (pure (Cage.SubmitRefused "the ledger said no")) ctx)
                            id
                            fx
                    TransportFailed -> \fx ctx ->
                        writeVia
                            (submitting (pure (Cage.SubmitFailed "connection refused")) ctx)
                            id
                            fx
                run kind = withFixture $ \fx -> do
                    (seen, collect) <- traceCollector
                    r <-
                        try @CommandFailure
                            (refusing kind fx (writeContext fx){wcTracer = collect})
                    events <- readIORef seen
                    pure
                        ( [k | Trace _ (What (Refused k _)) <- events]
                        , either (\(CommandFailure c _ _) -> Just c) (const Nothing) r
                        , ()
                        , mapMaybe renderText [t | t@(Trace _ (What (Refused{}))) <- events]
                        )
            results <- mapM run [minBound .. maxBound]
            map (\(k, _, _, _) -> k) results
                `shouldBe` map pure [minBound .. maxBound]
            map (\(_, c, _, _) -> c) results
                `shouldBe` [ Just ClientRefusal
                           , Just ClientRefusal
                           , Just LedgerRefusal
                           , Just Partial
                           ]
            let lines' = concatMap (\(_, _, _, l) -> l) results
            length lines' `shouldBe` 4
            length (nub lines') `shouldBe` 4
    it
        "never carries the signing key, in any of its renderings, nor a \
        \credential an operation failed with, in any renderer"
        $ withFixture
        $ \fx -> do
            (seen, collect) <- traceCollector
            let ctx = (writeContext fx){wcTracer = collect}
                caps = wcCapabilities ctx
                key = rawSerialiseSignKeyDSIGN (walletSignKey (fxWallet fx))
                hex = B16.encode key
                secrets =
                    [ key
                    , hex
                    , BC.map toUpper hex
                    , "5820" <> hex
                    , BC.map toUpper ("5820" <> hex)
                    , bech32Of "addr_sk" key
                    , bech32Of "ed25519_sk" key
                    , "CRED-9e4b7"
                    , "CRED-5c1d2"
                    ]
                throwingSubmit =
                    ctx
                        { wcCapabilities =
                            caps
                                { capSubmit = \_ -> throwIO (userError "401 for project_id=CRED-9e4b7")
                                }
                        }
                throwingConfirm =
                    ctx
                        { wcCapabilities =
                            caps
                                { capConfirm = \_ -> throwIO (userError "403 for project_id=CRED-5c1d2")
                                }
                        }
            _ <- writeVia ctx id fx
            _ <-
                try @SomeException
                    ( writeVia
                        throwingSubmit
                        (bodyTxL . vldtTxBodyL .~ ValidityInterval SNothing (SJust (SlotNo 77)))
                        fx
                    )
            _ <-
                try @SomeException
                    ( writeVia
                        throwingConfirm
                        (bodyTxL . vldtTxBodyL .~ ValidityInterval SNothing (SJust (SlotNo 88)))
                        fx
                    )
            events <- readIORef seen
            let texts = BS.concat [TE.encodeUtf8 l | Just l <- map renderText events]
                jsons = BS.concat (map renderJsonLine events)
                phases =
                    BS.concat
                        [ BL.toStrict
                            (Aeson.encode (Aeson.object (("phase", Aeson.toJSON p) : fs)))
                        | Just (p, fs) <- map renderPhaseLog events
                        ]
            -- the stream holds the steps a leak would come from
            [() | Trace _ (How (Tx TxSigned{})) <- events] `shouldBe` [(), (), ()]
            [ c
              | Trace _ (How (Tx TxSubmitted{submitVerdict = SubmitThrew c})) <-
                    events
              ]
                `shouldSatisfy` ((== 1) . length)
            [v | Trace _ (How (Tx (TxConfirmed _ _ _ v))) <- events]
                `shouldBe` [Confirmed, ConfirmFailed (ErrorClass "IOException")]
            forM_
                [("text" :: Text, texts), ("json", jsons), ("phase log", phases)]
                $ \(renderer, bytes) -> do
                    (renderer, BS.null bytes) `shouldBe` (renderer, False)
                    (renderer, [s | s <- secrets, s `BS.isInfixOf` bytes])
                        `shouldBe` (renderer, [])
    it
        "narrates on standard error and leaves standard output to the receipt"
        $ withFixture
        $ \fx -> do
            let ctx =
                    (writeContext fx)
                        { wcTracer =
                            outputSink (Just stderr) TraceHow (Output ToStderr TextFormat)
                        }
            ((), out, err) <- captured (void (writeVia ctx id fx))
            out `shouldBe` ""
            err `shouldSatisfy` ("how  sign " `BS.isInfixOf`)
    it
        "keeps tracing total: a sink that throws and one on a closed handle change \
        \no outcome, journal or exception, and the other sinks still see every event"
        $ do
            let scenarios :: [(String, WriteContext -> Fixture -> IO (ConwayTx, ()))]
                scenarios =
                    [ ("submitted, confirmed", (`writeVia` id))
                    ,
                        ( "the build fails"
                        , \ctx fx ->
                            writeBuilding ctx fx (\_ -> failWith ClientRefusal "no fold is built")
                        )
                    ,
                        ( "the confirmation fails"
                        , \ctx ->
                            writeVia
                                ctx
                                    { wcCapabilities =
                                        (wcCapabilities ctx)
                                            { capConfirm = \_ -> throwIO (userError "the wait broke")
                                            }
                                    }
                                id
                        )
                    ]
                outcome = \case
                    Right _ -> "completed"
                    Left e -> case fromException e of
                        Just (CommandFailure c why _) -> outcomeName c <> ": " <> T.pack why
                        Nothing -> "uncaught: " <> T.pack (show e)
                run act tracing = withFixture $ \fx -> do
                    tracer <- tracing
                    r <- try @SomeException (act (writeContext fx){wcTracer = tracer} fx)
                    events <- map journalEvent <$> readJournal (fxDir fx)
                    pure (outcome r, events)
            forM_ scenarios $ \(name, act) -> do
                plain <- run act (pure nullTracer)
                (seen, collect) <- traceCollector
                closed <- closedHandleSink
                traced <- run act (fanOut [throwingSink, closed, collect])
                (name, traced) `shouldBe` (name, plain)
                events <- readIORef seen
                -- the live sink saw the write, after its submission and around its failure
                (name, null events) `shouldBe` (name, False)
                when (name /= "the build fails") $
                    [() | Trace _ (How (Tx TxSubmitted{})) <- events] `shouldBe` [()]
                when (name == "the build fails") $
                    [() | Trace _ (How (Tx (TxBuilt _ _ (FailedWith _)))) <- events]
                        `shouldBe` [()]
    forM_ [(2, "key-two"), (5, "key-five")] $ \(edge, key) ->
        it
            ( "a fold names the request, its key and its edge before it refuses "
                <> edgeName edge
                <> ", as its receipt does"
            )
            $ withInputFixture
            $ \fx saved live mirror boot -> do
                (seen, collect) <- traceCollector
                let request = TxIn (txIdTx boot) (TxIx 0)
                    requestAddr = requestAddrFromCfg (savedCfg saved) (savedToken saved) Testnet
                    requestOut =
                        mkBasicTxOut requestAddr (MaryValue (Coin 3_000_000) mempty)
                            & datumTxOutL
                                .~ mkInlineDatum
                                    ( mkRequestDatumWith
                                        (savedToken saved)
                                        (walletAddr (fxWallet fx))
                                        key
                                        edge
                                        2_000_000
                                        0
                                        ("", Nothing)
                                    )
                    ctx =
                        (writeContext fx)
                            { wcCommand = "fold"
                            , wcTracer = collect
                            , wcCapabilities =
                                (wcCapabilities (writeContext fx))
                                    { capReads =
                                        servingSession $
                                            withAddressOutputs
                                                ( \addr ->
                                                    if addr == requestAddr
                                                        then pure [(request, requestOut)]
                                                        else fail "an inadmissible request reached a later provider read"
                                                )
                                                stubSession
                                    }
                            }
                result <-
                    try @CommandFailure $
                        foldPending
                            (Attached ctx live mirror)
                            FoldSpec
                                { fsOrigin = Standalone
                                , fsRequest = Just request
                                , fsFund = Nothing
                                , fsAllowance = Nothing
                                }
                events <- readIORef seen
                fields <- case result of
                    Left (CommandFailure _ _ fs) -> pure fs
                    Right _ -> fail "an unsupported pending edge folded"
                let named = lookup "pendingRequest" fields
                    seenRequests =
                        [ (r, e, k)
                        | Trace _ (What (RequestSeen r e k _ _)) <- events
                        ]
                named `shouldBe` Just (Aeson.toJSON (txInText request))
                seenRequests
                    `shouldBe` [(txInText request, T.pack (edgeName edge), key)]
                [k | Trace _ (What (Refused k _)) <- events]
                    `shouldBe` [ClientRefused]
                -- every event inside a request is inside this one
                [ r
                  | Trace scope _ <- events
                  , InRequest r <- scope
                  ]
                    `shouldSatisfy` all (== txInText request)
                [() | Trace scope _ <- events, InEdge (Folding _) <- scope]
                    `shouldBe` []

-- | A tracer collecting every event, in order.
traceCollector :: IO (IORef [Trace], Tracer IO Trace)
traceCollector = do
    ref <- newIORef []
    pure (ref, Tracer (\t -> modifyIORef' ref (<> [t])))

-- | The fixture's write under another journal step.
writeStepVia
    :: Text
    -> WriteContext
    -> (ConwayTx -> ConwayTx)
    -> Fixture
    -> IO (ConwayTx, ())
writeStepVia step ctx shape fx =
    submitBuilt ctx step (const (expecting "state")) $ \v -> do
        utxos <- SessionIO.outputsAt v (walletAddr (fxWallet fx))
        let tx =
                shape $
                    mkBasicTx
                        ( mkBasicTxBody
                            & inputsTxBodyL .~ Set.fromList (map fst utxos)
                            & outputsTxBodyL .~ StrictSeq.fromList (map snd utxos)
                        )
        pure (tx, ())

-- | A write whose build does this instead of building.
writeBuilding
    :: WriteContext
    -> Fixture
    -> (Cage.Session NoWitness IO -> IO ConwayTx)
    -> IO (ConwayTx, ())
writeBuilding ctx _ build =
    submitBuilt
        ctx
        "fold"
        (const (expecting "state"))
        (fmap (,()) . build)

-- | The context with the provider answering every submission so.
submitting :: IO Cage.SubmitResult -> WriteContext -> WriteContext
submitting answer ctx =
    ctx{wcCapabilities = (wcCapabilities ctx){capSubmit = const answer}}

-- | A sink that throws on every event.
throwingSink :: Tracer IO Trace
throwingSink = Tracer (\_ -> throwIO (userError "the sink broke"))

-- | A sink writing to a handle that is already closed.
closedHandleSink :: IO (Tracer IO Trace)
closedHandleSink = do
    (path, h) <- openTempFile "/tmp" "closed-sink"
    hClose h
    removeFile path
    pure (Tracer (hPrint h))

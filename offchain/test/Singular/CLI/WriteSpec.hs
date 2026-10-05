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

Every compared value is obtained at run time: the chain point is the one
the build's own view reports, the signed body is the one the build
returned signed by the wallet's key, and the moved chain's point is read
back by a fresh acquisition. The chain is moved inside the build, after
the view is acquired and before the body is signed, so a journal that
re-read the chain would name another point; the reached control requires
the fresh point to differ.
-}
module Singular.CLI.WriteSpec (spec) where

import Control.Exception
    ( SomeException
    , bracket
    , bracket_
    , fromException
    , throwIO
    , try
    )
import Control.Monad (forM_, void)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Char (toUpper)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, sort)
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
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , listDirectory
    , withCurrentDirectory
    )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush, stderr, stdout)
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
import Test.Hspec

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (addrTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32

import Singular.CLI.Attached (Attached (..))
import Singular.CLI.Fold (FoldOrigin (..), FoldSpec (..), foldPending)
import Singular.CLI.Live
    ( Live (..)
    , Mirror
    , Saved (..)
    , newStatePoint
    , openMirror
    , requireMirrorSelection
    , savedIdentity
    , txInText
    )
import Singular.CLI.Node (Capabilities (..))
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
    ( configPath
    , hexT
    , mkRegistryConfig
    , pinsOf
    )
import Singular.CLI.RejectRules (rejectGate, renderRejectRefusal)
import Singular.CLI.RequestWindow (retractEnds, windowOf)
import Singular.CLI.Session
    ( CommandFailure (..)
    , WriteContext (..)
    , expecting
    , journalObserved
    , submitBuilt
    , txIdHex
    )
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Deployment
    ( Deployment (..)
    , mirrorPathFor
    , parseOutRef
    )
import Singular.Registry.Ledger (Coin (..), Root (..), TokenId (..))
import Singular.Registry.Node (Wallet (..), loadWallet)
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , MemoryChain
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Node.PhaseLog
    ( PhaseLog
    , loggedProvider
    , phaseLogAt
    )
import Singular.Registry.Node.Submit
    ( signTx
    , signedSubmitter
    , signedTx
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.StubView (servingView, stubView)
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Mirror qualified as TrieMirror
import Singular.Registry.TxBuilder.BookingFixture qualified as Booking
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , mkInlineDatum
    , mkRequestDatumWith
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , edgeName
    )

spec :: Spec
spec = writeRows >> phaseLogRows >> inputRows

writeRows :: Spec
writeRows = describe "a singular write on injected capabilities (#323)" $ do
    it
        "journals every field of the point its body was built from, \
        \though the chain moved before signing"
        $ withFixture
        $ \fx -> do
            _ <- try @SomeException (write fx)
            built <- readIORef (fxBuiltAt fx)
            point <- maybe (fail "the build never ran") pure built
            fresh <-
                Cage.withView (memoryProvider (fxChain fx)) (pure . Cage.viewPoint)
            fresh `shouldNotBe` point
            prepared <- preparedLines (fxDir fx)
            map journalledPoint prepared
                `shouldBe` [ Just
                                ( Cage.cpNetwork point
                                , Cage.cpEra point
                                , renderPoint point
                                )
                           ]
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
                                            ("", "")
                                        )
                        ctx =
                            (writeContext fx)
                                { wcCommand = "fold"
                                , wcCapabilities =
                                    (wcCapabilities (writeContext fx))
                                        { capReads =
                                            servingView
                                                stubView
                                                    { Cage.viewUTxOsAt = \addr ->
                                                        if addr == requestAddr
                                                            then pure [(request, requestOut)]
                                                            else fail "an inadmissible request reached a later provider read"
                                                    }
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
                    nodesBefore <- BS.readFile (mirrorPathFor (configPath (fxDir fx)))
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
                    BS.readFile (mirrorPathFor (configPath (fxDir fx)))
                        `shouldReturn` nodesBefore
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
    :: (Fixture -> Saved -> Live -> Mirror -> ConwayTx -> IO a) -> IO a
withInputFixture use = withFixture $ \fx -> do
    let cfg = Booking.cfg
        tid@(TokenId name) = Booking.tokenId
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
                    & outputsTxBodyL .~ StrictSeq.fromList [stateOut]
                    & mintTxBodyL
                        .~ MultiAsset (Map.singleton policy (Map.singleton name 1))
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
    let live = Live saved [] (TxIn (txIdTx boot) (TxIx 0), stateOut)
    point <- newStatePoint (fst (liveState live))
    let chosen = TS.TrieSelection (savedIdentity saved) point (Root emptyRoot)
    TrieMirror.createStoredMirror
        (configPath (fxDir fx))
        chosen
        boot
        (const (pure ()))
        `shouldReturn` Right ()
    mirror <- openMirror saved
    requireMirrorSelection saved live mirror
    use fx saved live mirror boot

data Fixture = Fixture
    { fxDir :: FilePath
    , fxChain :: MemoryChain
    , fxWallet :: Wallet
    , fxSent :: IORef [ConwayTx]
    , fxConfirmed :: IORef [String]
    , fxBuiltAt :: IORef (Maybe Cage.ChainPoint)
    , fxUnsigned :: IORef (Maybe ConwayTx)
    }

magic :: Word32
magic = 42

{- | The network and era the chain's views name: neither the magic the
wallet was loaded under nor the era name a journal could write as a
constant, so a journalled point that does not come from the view fails.
-}
viewNetwork :: Word32
viewNetwork = 2_323

viewEra :: Text
viewEra = "era-under-test"

withFixture :: (Fixture -> IO a) -> IO a
withFixture k = withSystemTempDirectory "singular-write" $ \dir -> do
    let keyPath = dir </> "payment.skey"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    w <- loadWallet magic keyPath
    chain <-
        newMemoryChain
            ChainState
                { csNetwork = viewNetwork
                , csEra = viewEra
                , csTip = Nothing
                , csPParams = emptyPParams
                , csUTxO =
                    Map.singleton
                        (outRef 'f')
                        (mkBasicTxOut (walletAddr w) (MaryValue (Coin 50_000_000) mempty))
                , csRegistered = Set.empty
                , csSystemStartMs = 0
                , csSlotLengthMs = 1_000
                }
    mutate chain id
    Fixture (dir </> "registry") chain w
        <$> newIORef []
        <*> newIORef []
        <*> newIORef Nothing
        <*> newIORef Nothing
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
                { capReads = memoryProvider (fxChain fx)
                , capSubmit = signedSubmitter $ Submitter $ \tx -> do
                    modifyIORef' (fxSent fx) (<> [tx])
                    pure (Submitted (txIdTx tx))
                , capConfirm = \_ txid -> modifyIORef' (fxConfirmed fx) (<> [txid])
                }
        , wcTimeout = Just 5
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
        writeIORef (fxBuiltAt fx) (Just (Cage.viewPoint v))
        utxos <- Cage.viewUTxOsAt v (walletAddr (fxWallet fx))
        mutate (fxChain fx) id
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

-- | The network, era and @slot.hash@ a @prepared@ line names, if all three.
journalledPoint :: Aeson.Object -> Maybe (Word32, Text, Text)
journalledPoint o =
    (,,)
        <$> field "journalNetwork" o
        <*> field "journalEra" o
        <*> field "journalChainPoint" o

field :: (Aeson.FromJSON a) => Aeson.Key -> Aeson.Object -> Maybe a
field k = Aeson.parseMaybe (.: k)

renderPoint :: Cage.ChainPoint -> Text
renderPoint p =
    T.pack (show (Cage.unSlotNo (Cage.cpSlot p)))
        <> "."
        <> T.pack (BC.unpack (B16.encode (Cage.cpBlockHash p)))

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

{- | The write of the ordinary CLI with @SINGULAR_LOG@ set or unset. Every
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
                    withCurrentDirectory cwd $ withLogEnv Nothing $ do
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
            -- the control: the variable is what makes the file appear
            logged <- withFixture $ \fx -> do
                let path = takeDirectory (fxDir fx) </> "phase.log"
                withLogEnv (Just path) $ do
                    _ <- writeVia (loggedContext (phaseLogAt path) fx) id fx
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
                withLogEnv (Just path) $
                    writeVia (loggedContext (phaseLogAt path) fx) bounded fx
            built <- readIORef (fxBuiltAt fx)
            builtPoint <- maybe (fail "the build never ran") pure built
            tip <-
                Cage.cpSlot
                    <$> Cage.withView (memoryProvider (fxChain fx)) (pure . Cage.viewPoint)
            -- the build's own view is not the tip the submission met
            Cage.cpSlot builtPoint `shouldNotBe` tip
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
                `shouldBe` [Just (Cage.unSlotNo tip)]
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
                ctx = loggedContext (phaseLogAt path) fx
                caps = wcCapabilities ctx
                broken =
                    ctx
                        { wcCapabilities =
                            caps
                                { capConfirm = \_ _ ->
                                    throwIO (userError "403 for project_id=CRED-5c1d2")
                                }
                        }
            _ <-
                withLogEnv (Just path) (try @SomeException (writeVia broken id fx))
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
                ctx = loggedContext (phaseLogAt path) fx
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
                                { capSubmit = signedSubmitter $ Submitter $ \_ ->
                                    throwIO (userError "401 for project_id=CRED-9e4b7")
                                }
                        }
            _ <- withLogEnv (Just path) $ do
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
            let normal e = e{journalBody = Nothing, journalTime = Nothing}
                run logPath = withFixture $ \fx -> do
                    ((), out, err) <- withLogEnv logPath $ captured $ do
                        _ <-
                            writeVia
                                ( maybe
                                    (writeContext fx)
                                    (\p -> loggedContext (phaseLogAt p) fx)
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
                                (\p -> loggedContext (phaseLogAt p) fx)
                                logPath
                        caps = wcCapabilities ctx0
                        ctx
                            | failing =
                                ctx0
                                    { wcCapabilities =
                                        caps{capConfirm = \_ _ -> throwIO (userError "the wait broke")}
                                    }
                            | otherwise = ctx0
                    r <- withLogEnv logPath (try @SomeException (writeVia ctx id fx))
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
            (signed, ()) <- withLogEnv Nothing (write fx)
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

-- | A write context whose reads go through the phase log, as a command's do.
loggedContext :: PhaseLog -> Fixture -> WriteContext
loggedContext lg fx =
    ctx
        { wcCapabilities = caps{capReads = loggedProvider lg (capReads caps)}
        }
  where
    ctx = writeContext fx
    caps = wcCapabilities ctx

-- | Run with @SINGULAR_LOG@ set to a path or unset, restoring it after.
withLogEnv :: Maybe FilePath -> IO a -> IO a
withLogEnv new act = do
    old <- lookupEnv "SINGULAR_LOG"
    let put = maybe (unsetEnv "SINGULAR_LOG") (setEnv "SINGULAR_LOG")
    bracket_ (put new) (put old) act

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

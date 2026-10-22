{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.Application.OpenDatum.CommandRunSpec
Description : #416 — every command handler run in process, its typed events compared with its receipt
License     : Apache-2.0

Each command the command line can name is run through 'runCommand', the
same dispatch the packaged command runs, over an environment that serves a
chain fixture instead of Koios: the fixture applies every submitted
transaction to its own outputs, and the registry's scripts are accept-all
programs of the arities the builders apply, so the handlers build, sign,
submit and read back as they do on a network. The fixture is not a ledger:
nothing here claims a script or a ledger rule accepts these transactions.

Every receipt-bound fact a typed event carries must equal the receipt's: the
command and its outcome, the key, the edge and the request (in the receipt's
own fields and in every object it lists), each transaction's step and id
and what the journal says it met, the root, the token, the refusal's kind.
One contradicting event is a failure, whatever other events agree.

The commands run are the 'Command' constructors, read from the type, not
listed here; a constructor no run exercises fails the extent row.
-}
module Singular.Application.OpenDatum.CommandRunSpec (spec) where

import Control.Applicative ((<|>))
import Control.Exception
    ( SomeException
    , bracket
    , finally
    , throwIO
    , try
    )
import Control.Monad (forM, unless, when)
import Control.Tracer (Tracer (..))
import Data.Aeson (toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (forM_, toList)
import Data.Function ((&))
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (nub, partition, sort)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe
    ( fromMaybe
    , isJust
    , isNothing
    , listToMaybe
    , mapMaybe
    )
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Word (Word64)
import GHC.Generics
    ( C1
    , Constructor
    , D1
    , Generic (..)
    , conName
    , (:+:)
    )
import Lens.Micro ((%~), (.~), (^.))
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , doesFileExist
    , doesPathExist
    , listDirectory
    , removeFile
    , removePathForcibly
    , renameFile
    )
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO
    ( IOMode (..)
    , hClose
    , hFlush
    , hPrint
    , openFile
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
import System.Posix.Types (Fd (..))
import Test.Hspec

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class
    ( hashFromBytes
    , hashToBytes
    , hashWith
    )
import Cardano.Ledger.Address (Addr (..), decodeAddr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.PParams (getLanguageView)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.Tx
    ( ScriptIntegrity (..)
    , hashScriptIntegrity
    )
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..), TxDats (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , scriptIntegrityHashTxBodyL
    , treasuryDonationTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (datsTxWitsL, rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Language (Language (PlutusV3))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import UntypedPlutusCore qualified as UPLC

import Singular.Application.OpenDatum.Command
    ( OpenDatumCommand (..)
    , parseOpenDatumCommand
    )
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , dataToJson
    , envelopeFromData
    , envelopeToData
    )
import Singular.Application.OpenDatum.LawfulBooking
    ( TerminationFault (..)
    , applicationAddressBytes
    , bookInsertRedeemerOf
    , lawfulApplicationBurn
    , lawfulInsertBooking
    , lawfulInsertBookingAs
    , lawfulTerminationBookingWith
    )
import Singular.Application.OpenDatum.Plan (insertionOf)
import Singular.Application.OpenDatum.Root (runPackagedOpenDatumVia)
import Singular.Application.OpenDatum.Run (runOpenDatum)
import Singular.Application.OpenDatum.Value
    ( closedDatumApplication
    , openDatumApplication
    )
import Singular.CLI.Booking (BookingVerb (..), bookingEdgeName)
import Singular.CLI.Command
    ( EntryArgs (..)
    , EntryMode (..)
    , WriteSettings (..)
    )
import Singular.CLI.Live
    ( Live (..)
    , Saved (..)
    , attachLive
    , requireTrieSelection
    , resolveSaved
    , withTrie
    )
import Singular.CLI.Live qualified as Live
import Singular.CLI.ManagedState (addressPartition, managedDir)
import Singular.CLI.Passphrase (mkPassphrase)
import Singular.CLI.Proof (Leaf (..), leafName)
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , bodiesDir
    , journalPath
    , readJournal
    )
import Singular.CLI.ReceiptBody (boundBody)
import Singular.CLI.Registry
    ( loadRelease
    , loadReleaseCodes
    , pendingPath
    )
import Singular.CLI.Session (Env (..), readsIn, txIdHex)
import Singular.CLI.Trace
import Singular.CLI.Vault
    ( createVaultFile
    , sealVault
    , vaultWorkFactor
    )
import Singular.Registry.Application (Application)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Bundle
    ( Bundle (..)
    , BundleRefusal
    , BundleTransaction (..)
    , TextEnvelope (..)
    , bodyDeadline
    , bodyIdentity
    , checkBundle
    , decodeBundle
    , decodeTransactionEnvelope
    , renderBundleRefusal
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config qualified as Config
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , unverifiedVerifier
    )
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , jumpChainTo
    , jumpChainToHostClock
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (signedTx)
import Singular.Registry.StateToken (ReferenceRole, parseStateToken)
import Singular.Registry.SyntheticLedger
    ( errorProgram
    , unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trace
    ( Evaluation (..)
    , ReadEvent (Evaluated)
    )
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges
    ( adaOnlyOut
    , registryContextFor
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , computeScriptHash
    , extractCageDatum
    , mkInlineDatum
    , policyIdFromPin
    , requestAddrFromCfg
    , requestPolicyOf
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.Internal.Identity (txInToRef)
import Singular.Registry.TxBuilder.Update (updateTokenSelected)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRequest (..)
    , OnChainTerminationRequest (..)
    , applicationTagName
    , edgeInsertActive
    , edgeName
    , edgeUpdateTerminal
    , terminationTrieReadyTagName
    , trieReadyTagName
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )

spec :: Spec
spec =
    handlerRows
        >> setupRecut
        >> readbackRows
        >> bookingRefusalRows
        >> permanentRecognition
        >> settledListSingletonRow
        >> openDatumDescribeCommandRows
        >> externalWriteRows
        >> vaultWriteRows
        >> chunk4Producers

{- | The open datum create receipt carries the working describe line. The
application owns no describe verb, so the line always names the registry
binary. Two registries give two tokens, so a fixed line cannot pass.
Values the test checks against are read from the run itself, never typed.
-}
openDatumDescribeCommandRows :: Spec
openDatumDescribeCommandRows = describe "Open datum create prints the describe command" $ do
    it
        "carries the registry describe line in each open datum create receipt"
        $ withRig
        $ \rig -> do
            firstSeed <- fundSeed rig
            firstRun <-
                run
                    rig
                    "first open datum create"
                    ["open-datum", "create", "--seed", firstSeed]
            outcomeOf (runReceipt firstRun) `shouldBe` Just "success"
            firstToken <- tokenOf firstRun
            firstLine <- case valueAt "describeCommand" (runReceipt firstRun) of
                Just (Aeson.String line) -> pure line
                other ->
                    expectationFailure
                        ("the first open datum create carries no describe line: " <> show other)
                        >> pure ""
            checkPrinted rig firstToken firstLine
            secondSeed <- fundSeed2 rig
            secondRun <-
                run
                    rig
                    "second open datum create"
                    ["open-datum", "create", "--seed", secondSeed]
            outcomeOf (runReceipt secondRun) `shouldBe` Just "success"
            secondToken <- tokenOf secondRun
            secondLine <- case valueAt "describeCommand" (runReceipt secondRun) of
                Just (Aeson.String line) -> pure line
                other ->
                    expectationFailure
                        ( "the second open datum create carries no describe line: "
                            <> show other
                        )
                        >> pure ""
            secondToken `shouldSatisfy` (/= firstToken)
            secondLine `shouldSatisfy` (/= firstLine)
            checkPrinted rig secondToken secondLine
            case parseOpenDatumCommand
                ["open-datum", "describe", "--blueprint", rigBlueprint rig] of
                Left _ -> pure ()
                Right command ->
                    expectationFailure
                        ("open datum names a describe verb: " <> show command)
  where
    allowedFlags =
        [ "--blueprint"
        , "--state-token"
        , "--koios-url"
        , "--network-magic"
        , "--network-time"
        ]
    requiredFlags = ["--blueprint", "--state-token", "--koios-url", "--network-magic"]
    checkPrinted rig token line = do
        let parts = words (T.unpack line)
        take 3 parts `shouldBe` ["singular", "registry", "describe"]
        let flags = [word | word <- parts, take 2 word == "--"]
        all (`elem` allowedFlags) flags `shouldBe` True
        all (`elem` flags) requiredFlags `shouldBe` True
        ("--json" `elem` flags) `shouldBe` False
        ("--wallet-skey" `elem` flags) `shouldBe` False
        ("--wallet-address" `elem` flags) `shouldBe` False
        ("--koios-token-file" `elem` flags) `shouldBe` False
        ("--state-dir" `elem` flags) `shouldBe` False
        ("--receipt" `elem` flags) `shouldBe` False
        T.isInfixOf (T.pack (rigBlueprint rig)) line `shouldBe` True
        T.isInfixOf (T.pack token) line `shouldBe` True
        T.isInfixOf (T.pack (rigKey rig)) line `shouldBe` False

permanentRecognition :: Spec
permanentRecognition = describe "Permanent contract recognition"
    $ it
        "refuses a caller supplied blueprint whose script identities are unknown"
    $ withRig
    $ \rig -> do
        loaded <- loadRelease openDatumApplication (rigBlueprint rig)
        case loaded of
            Left _ -> pure ()
            Right _ ->
                expectationFailure "unknown scripts were recognized as permanent M1"

handlerRows :: Spec
handlerRows = describe
    "every command handler, run in process, against its receipt (#416)"
    $ do
        it
            "runs every command the command line names, and each stream agrees with its receipt"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let ran = nub (sort [name | Run{runName = name} <- runs])
                ran `shouldBe` sort commandNames
                [ (runLabel r, outcomeOf (runReceipt r), found)
                  | r <- runs
                  , let found = disagreements (runKey r) (runReceipt r) (runEvents r)
                  , not (null found)
                  ]
                    `shouldBe` []
        it
            "changes no command's outcome or exit when a sink throws or writes to a \
            \closed handle, and the live sink still sees every run"
            $ do
                plain <- withRig lifecycle
                traced <-
                    withRigVia
                        ( \collect -> do
                            closed <- closedHandleSink
                            fanOut
                                [Tracer (\_ -> throwIO (userError "the sink broke")), closed, collect]
                        )
                        lifecycle
                map summary traced `shouldBe` map summary plain
                [runLabel r | r <- traced, null (runEvents r)] `shouldBe` []
        it
            "places each transaction, from its evaluation to its readback, in one \
            \scope, under the edge its command acts on"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let placements =
                        [ (runLabel r, step, nub paths, started)
                        | r <- runs
                        , let started = not (null [() | Trace _ (What (EdgeStarted _)) <- runEvents r])
                        , step <-
                            nub [s | Trace scope _ <- runEvents r, InTransaction s <- scope]
                        , let paths =
                                [ takeWhile (/= InTransaction step) scope
                                | Trace scope (How h) <- runEvents r
                                , InTransaction step `elem` scope
                                , mechanicOfItsTransaction h
                                ]
                        , not (null paths)
                        ]
                    misplaced =
                        [ (label, step, paths)
                        | (label, step, paths, started) <- placements
                        , length paths /= 1
                            || ( step `elem` edgeSteps
                                    && started
                                    && not (or [True | InEdge _ <- concat paths])
                               )
                        ]
                -- the extent: every step that acts on an edge was placed somewhere
                nub (sort [s | (_, s, _, True) <- placements, s `elem` edgeSteps])
                    `shouldBe` sort edgeSteps
                misplaced `shouldBe` []
        it
            "reads in timed steps, each naming what it read, and a build reads before \
            \it reports what it found"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let fetches r = [f | Trace _ (How (Fetched f)) <- runEvents r]
                    succeeded = [r | r <- runs, outcomeOf (runReceipt r) == Just "success"]
                    unread = [runLabel r | r <- succeeded, null (fetches r)]
                    unnamed =
                        [ (runLabel r, f)
                        | r <- runs
                        , f <- fetches r
                        , null (fetchWhat f) || fetchSource f /= "fixture"
                        ]
                    -- in each build that reports a protocol fact, its read comes first
                    unordered =
                        [ (runLabel r, step)
                        | r <- runs
                        , step <-
                            nub [s | Trace scope _ <- runEvents r, InTransaction s <- scope]
                        , step `elem` ["book", "fold", "update"]
                        , let inStep = dropWhile (not . startsStep step) (runEvents r)
                              beforeFact = takeWhile (not . protocolFact) (drop 1 inStep)
                        , any protocolFact inStep
                        , null [() | Trace _ (How (Fetched _)) <- beforeFact]
                        ]
                    startsStep step (Trace scope _) = InTransaction step `elem` scope
                    protocolFact = \case
                        Trace _ (What (RequestSeen{})) -> True
                        Trace _ (What (EdgeStarted _)) -> True
                        _ -> False
                length succeeded `shouldSatisfy` (> 10)
                (unread, unnamed, unordered) `shouldBe` ([], [], [])
                [ l
                  | r <- runs
                  , Just l <- map renderText (runEvents r)
                  , "how  read " `T.isInfixOf` l
                  ]
                    `shouldSatisfy` (not . null)
        it
            "closes a build read that fails before it decides, ahead of its refusal"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                case [r | r <- runs, runLabel r == "update an absent key"] of
                    [absent] -> do
                        let events = runEvents absent
                            fetches = [f | Trace _ (How (Fetched f)) <- events]
                            buildReads =
                                [ f
                                | f <- fetches
                                , fetchWhat f == ["state", "key outputs"]
                                ]
                            refusals = [k | Trace _ (What (Refused k _)) <- events]
                            posFetch = length (takeWhile (not . isBuildFetch) events)
                            isBuildFetch = \case
                                Trace _ (How (Fetched f)) ->
                                    fetchWhat f == ["state", "key outputs"]
                                _ -> False
                            posRefused = length (takeWhile (not . isRefused) events)
                            isRefused = \case
                                Trace _ (What (Refused{})) -> True
                                _ -> False
                        outcomeOf (runReceipt absent) `shouldBe` Just "client-refusal"
                        refusals `shouldBe` [ClientRefused]
                        length buildReads `shouldBe` 1
                        case buildReads of
                            [f] -> do
                                fetchSource f `shouldBe` "fixture"
                                fetchElapsed f `shouldSatisfy` (>= 0)
                                case fetchEnd f of
                                    FailedWith _ -> pure ()
                                    Done -> expectationFailure "a failed build read ends Done"
                            _ -> expectationFailure "one build read"
                        (posFetch < posRefused) `shouldBe` True
                        disagreements (runKey absent) (runReceipt absent) events `shouldBe` []
                    _ -> expectationFailure "one absent update run"
        it
            "refuses an inspect whose token no registry minted, naming the absence"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                nowhere <- case [ r | r <- runs, runLabel r == "inspect a registry that does not exist"
                                ] of
                    [n] -> pure n
                    found ->
                        fail
                            ("expected one missing-registry inspect, found " <> show (length found))
                emptyActor <- case [ r
                                   | r <- runs
                                   , runLabel r == "inspect from an empty directory with the state token"
                                   ] of
                    [e] -> pure e
                    found ->
                        fail
                            ("expected one empty-directory inspect, found " <> show (length found))
                outcomeOf (runReceipt nowhere) `shouldBe` Just "client-refusal"
                case textAt "reason" (runReceipt nowhere) of
                    Just reason ->
                        reason `shouldSatisfy` T.isPrefixOf "state-token-not-found"
                    Nothing -> expectationFailure "the refusal names no reason"
                disagreements
                    (runKey nowhere)
                    (runReceipt nowhere)
                    (runEvents nowhere)
                    `shouldBe` []
                outcomeOf (runReceipt emptyActor) `shouldBe` Just "success"
                disagreements
                    (runKey emptyActor)
                    (runReceipt emptyActor)
                    (runEvents emptyActor)
                    `shouldBe` []
        it
            "reports a script that fails its local evaluation as refused there, from \
            \the build's own session"
            $ withRigOf failingOpenDatum pure
            $ \rig -> do
                seed <- fundSeed rig
                created <- run rig "create" ["open-datum", "create", "--seed", seed]
                tok <- tokenOf created
                refused <-
                    run
                        rig
                        "insert alice-1"
                        ( [ "open-datum"
                          , "insert"
                          , "--key"
                          , "alice-1"
                          , "--payload"
                          , rigDir rig </> "payload.json"
                          ]
                            <> tokenArgs tok
                        )
                let events = runEvents refused
                ( outcomeOf (runReceipt refused)
                    , [k | Trace _ (What (Refused k _)) <- events]
                    , or [evalFailed e > 0 | Trace _ (How (Read (Evaluated e))) <- events]
                    , disagreements (runKey refused) (runReceipt refused) events
                    )
                    `shouldBe` (Just "client-refusal", [EvaluationRefused], True, [])
        it "fails a stream that contradicts its receipt in any one fact" $
            withRig $ \rig -> do
                runs <- lifecycle rig
                -- the control is only a control over a stream that agrees
                [ runLabel r
                  | r <- runs
                  , not (null (disagreements (runKey r) (runReceipt r) (runEvents r)))
                  ]
                    `shouldBe` []
                let altered =
                        [ (runLabel r, what', disagreements (runKey r) (runReceipt r) events')
                        | r <- runs
                        , (what', events') <- alterations (runReceipt r) (runEvents r)
                        ]
                    kinds = nub [w | (_, w, _) <- altered]
                length altered `shouldSatisfy` (> 50)
                -- every fact the comparison binds is planted somewhere in the lifecycle
                sort kinds `shouldBe` sort plantedFacts
                [(l, w) | (l, w, []) <- altered] `shouldBe` []
        it "agrees with a fold receipt read from its settled list alone" $
            withRig $ \rig -> do
                runs <- lifecycle rig
                let folds = foldSuccesses runs
                [runLabel r | r <- folds] `shouldSatisfy` (not . null)
                -- the post-removal shape: no top-level single-request fields,
                -- the settled list carrying the same facts
                [ (runLabel r, found)
                  | r <- folds
                  , let found = disagreements (runKey r) (readFromTheList r) (runEvents r)
                  , not (null found)
                  ]
                    `shouldBe` []
        it "fails a fold receipt whose settled list contradicts it" $
            withRig $ \rig -> do
                runs <- lifecycle rig
                let folds = foldSuccesses runs
                [runLabel r | r <- folds] `shouldSatisfy` (not . null)
                -- every contradiction binds somewhere in the lifecycle's folds,
                -- planted on the post-removal shape so the earlier top-level
                -- duplicates cannot mask a contradicted settled fact
                nub
                    ( sort
                        [ w
                        | r <- folds
                        , (w, _) <-
                            settledAlterations (readFromTheList r)
                        ]
                    )
                    `shouldBe` settledContradictions
                [ (runLabel r, what')
                  | r <- folds
                  , (what', receipt') <- settledAlterations (readFromTheList r)
                  , null (disagreements (runKey r) receipt' (runEvents r))
                  ]
                    `shouldBe` []

-- ---------------------------------------------------------
-- The commands, from the type
-- ---------------------------------------------------------

class ConNames f where
    conNames :: Proxy f -> [String]

instance (ConNames f) => ConNames (D1 c f) where
    conNames _ = conNames (Proxy :: Proxy f)

instance (ConNames f, ConNames g) => ConNames (f :+: g) where
    conNames _ = conNames (Proxy :: Proxy f) <> conNames (Proxy :: Proxy g)

instance (Constructor c) => ConNames (C1 c f) where
    conNames _ = [conName (undefined :: C1 c f p)]

-- | Every command the command line can name, by constructor; help runs nothing.
commandNames :: [String]
commandNames =
    sort
        [ n
        | n <- conNames (Proxy :: Proxy (Rep OpenDatumCommand))
        , n /= "OpenHelp"
        ]

-- | The constructor a parsed command is.
constructorOf :: OpenDatumCommand -> String
constructorOf = \case
    OpenHelp _ -> "OpenHelp"
    OpenCreate _ _ -> "OpenCreate"
    OpenInsert _ -> "OpenInsert"
    OpenUpdate _ -> "OpenUpdate"
    OpenTerminate _ -> "OpenTerminate"
    OpenFold _ -> "OpenFold"
    OpenInspect _ -> "OpenInspect"

-- ---------------------------------------------------------
-- Tracing setup re-cut: a trace file that cannot be written
-- ---------------------------------------------------------

{- | Two writes, the creates of two registries, through the packaged composition
over the rig's chain, untraced and then under three tracing settings. Each run is
on a fresh rig in the same directory, so its receipts and its registry's
files compare byte for byte with the untraced run's. The only field set
aside is the journal's wall-clock stamp, 'journalStamp', which must be
present and an ISO-8601 time on every line of both runs.

The file sink reports no failure of its own, so the failed appends are shown
by a pair: with a writable file and standard error at the same setting, the
file receives exactly the lines standard error does; with only the file's
path made unwritable, standard error receives as many lines again and the
file does not exist.
-}
setupRecut :: Spec
setupRecut = describe "(#416) tracing setup re-cut"
    $ it
        "keeps a write's receipt, journal, outcome and exit when its trace file \
        \cannot be written, the same run with a writable file receiving every event"
    $ withSystemTempDirectory "trace-recut"
    $ \base -> do
        let at = base </> "rig"
            writable = base </> "trace.jsonl"
            unwritable = base </> "missing" </> "trace.jsonl"
            json = ["--trace", "what", "--trace-format", "json"]
            paired file = json <> ["--trace-to", "file:" <> file, "--trace-to", "stderr"]
        plain <- packagedWrites at []
        control <- packagedWrites at (paired writable)
        faulted <- packagedWrites at (paired unwritable)
        alone <-
            packagedWrites
                at
                ["--trace", "what", "--trace-to", "file:" <> unwritable]
        -- the baseline is a write: each command submitted and journalled
        map (\(n, code, _, _) -> (n, code)) (writtenRuns plain)
            `shouldBe` [("create", ExitSuccess), ("create two", ExitSuccess)]
        let prepared =
                [ ()
                | Just "prepared" <- map (textAt "journalEvent") (writtenJournal plain)
                ]
            submitted =
                [ ()
                | (_, _, out, _) <- writtenRuns plain
                , Just (Aeson.Object r) <- [Aeson.decodeStrict out]
                , Just (Aeson.Array s) <- [KeyMap.lookup "submissions" r]
                , _ <- toList s
                ]
        length prepared `shouldSatisfy` (>= 2)
        length prepared `shouldBe` length submitted
        -- the fault is reached: the writable twin receives every event
        controlFile <- BS.readFile writable
        let lineCount = length . BC.lines
            narrated w = [lineCount err | (_, _, _, err) <- writtenRuns w]
        sum (narrated control) `shouldSatisfy` (> 0)
        all (> 0) (narrated control) `shouldBe` True
        lineCount controlFile `shouldBe` sum (narrated control)
        narrated faulted `shouldBe` narrated control
        doesFileExist unwritable `shouldReturn` False
        doesDirectoryExist (base </> "missing") `shouldReturn` False
        narrated alone `shouldBe` [0, 0]
        -- and changes nothing a write leaves
        forM_
            [ ("writable" :: String, control)
            , ("unwritable", faulted)
            , ("unwritable alone", alone)
            ]
            $ \(name, w) -> do
                (name, [(n, code, out) | (n, code, out, _) <- writtenRuns w])
                    `shouldBe` (name, [(n, code, out) | (n, code, out, _) <- writtenRuns plain])
                (name, writtenFiles w) `shouldBe` (name, writtenFiles plain)
                (name, writtenJournal w) `shouldBe` (name, writtenJournal plain)
                (name, writtenStamps w)
                    `shouldBe` (name, map (const True) (writtenStamps plain))
        writtenStamps plain `shouldBe` map (const True) (writtenStamps plain)

{- | The reference read-back of a create (#437): a provider that cannot
answer it is a provider failure, attributed by the typed failure the
client holds — never a completed read step claiming the output absent —
while a read that established the output missing stays the distinct
not-live refusal it always was.
-}
readbackRows :: Spec
readbackRows =
    describe
        "a create's reference read-back the provider cannot answer (#437)"
        $ do
            let referenceSteps r =
                    [ f
                    | Trace _ (How (Fetched f)) <- runEvents r
                    , fetchWhat f == ["reference scripts"]
                    ]
                reasonOf r = textAt "reason" (runReceipt r)
            it
                "attributes the failed read as the typed provider failure, never a completed absence"
                $ withRig
                $ \rig -> do
                    seed <- fundSeed rig
                    failed <-
                        runAtTxIn
                            (Left (Cage.BackendReadFailure "the exchange died"))
                            rig
                            "create-read-failed"
                            ["open-datum", "create", "--seed", seed]
                    outcomeOf (runReceipt failed) `shouldBe` Just "partial"
                    reasonOf failed
                        `shouldSatisfy` maybe False (T.isInfixOf "BackendReadFailure")
                    reasonOf failed
                        `shouldSatisfy` maybe False (not . T.isInfixOf "is not live")
                    case reverse (referenceSteps failed) of
                        (step : _) -> case fetchEnd step of
                            FailedWith _ -> pure ()
                            Done -> expectationFailure "the failed read-back ends Done"
                        [] ->
                            expectationFailure "the create never read its references back"
            it
                "keeps a read the provider refused — a missing output — a failed read, not an absence"
                $ withRig
                $ \rig -> do
                    seed <- fundSeed rig
                    refused <-
                        runAtTxIn
                            (Left (Cage.MissingOutput (fundOutput 1)))
                            rig
                            "create-read-refused"
                            ["open-datum", "create", "--seed", seed]
                    outcomeOf (runReceipt refused) `shouldBe` Just "partial"
                    reasonOf refused
                        `shouldSatisfy` maybe False (T.isInfixOf "MissingOutput")
                    reasonOf refused
                        `shouldSatisfy` maybe False (not . T.isInfixOf "is not live")
                    case reverse (referenceSteps refused) of
                        (step : _) -> case fetchEnd step of
                            FailedWith _ -> pure ()
                            Done ->
                                expectationFailure
                                    "a refused read ends the step Done"
                        [] ->
                            expectationFailure "the create never read its references back"
            it "keeps a successful empty answer the distinct not-live refusal" $
                withRig $ \rig -> do
                    seed <- fundSeed rig
                    empty <-
                        runAtTxIn
                            (Right (Evidenced [] Nothing))
                            rig
                            "create-read-empty"
                            ["open-datum", "create", "--seed", seed]
                    outcomeOf (runReceipt empty) `shouldBe` Just "partial"
                    reasonOf empty
                        `shouldSatisfy` maybe False (T.isInfixOf "is not live")
                    case reverse (referenceSteps empty) of
                        (step : _) -> case fetchEnd step of
                            Done -> pure ()
                            FailedWith _ ->
                                expectationFailure
                                    "a successful empty read ends the step failed"
                        [] ->
                            expectationFailure "the create never read its references back"

-- ---------------------------------------------------------
-- The early booking refusal
-- ---------------------------------------------------------

{- | S6.1 (#486): every ordinary verb refuses a booking the key's current
entry rules out, in submit and in preview alike, before anything is
signed: nothing is submitted, no request is left behind, no booking fee
is paid, and the reason names the key, labelled client policy. On the
base these bookings succeed (or stop with the old holding reason); each
row below fails there on its own and passes once the verbs check. The
oracles: the Lean table for the decision (found/required leaves), the
producer's own vocabulary for the structured fields
(@bookingEdgeName@/@leafName@), the issue story for the reason's words.
-}
bookingRefusalRows :: Spec
bookingRefusalRows = describe "the early booking refusal (#486)" $ do
    -- One example per verb, per mode, per case: a grouped assertion
    -- would mask the later refusals behind the first failure.
    let refused verb found required reasonFragment target = do
            outcomeOf (runReceipt target) `shouldBe` Just "client-refusal"
            textAt "reason" (runReceipt target)
                `shouldSatisfy` maybe False (T.isInfixOf reasonFragment)
            textAt "reason" (runReceipt target)
                `shouldSatisfy` maybe False (T.isInfixOf "client policy")
            valueAt "edge" (runReceipt target)
                `shouldBe` Just (toJSON (bookingEdgeName verb))
            valueAt "leafFound" (runReceipt target)
                `shouldBe` Just (toJSON (leafName found))
            valueAt "leafRequired" (runReceipt target)
                `shouldBe` Just (toJSON (leafName required))
            valueAt "policy" (runReceipt target)
                `shouldBe` Just (toJSON ("client" :: Text))
            textAt "request" (runReceipt target) `shouldBe` Nothing
            submissionsOf (runReceipt target) `shouldBe` []
        labelled label runs = case [r | r <- runs, runLabel r == label] of
            [found] -> pure found
            _ -> fail ("one run labelled " <> label)
    it "refuses an insert on an active key in submit, with exit 10" $
        withRig $ \rig -> do
            runs <- lifecycle rig
            target <- labelled "insert an active key" runs
            runExit target `shouldBe` ExitFailure 10
            refused
                BookInsert
                Active
                Unknown
                "alice-1 is already registered"
                target
    it "refuses an insert on an active key in preview" $
        withRig $ \rig ->
            refused
                BookInsert
                Active
                Unknown
                "alice-1 is already registered"
                =<< labelled "insert an active key preview"
                =<< lifecycle rig
    it "refuses an insert on an active key before any signing key is read" $
        withRig $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            insert <-
                run
                    rig
                    "insert alice-1"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt insert) `shouldBe` Just "success"
            fold1 <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf insert <> tokenArgs t)
            outcomeOf (runReceipt fold1) `shouldBe` Just "success"
            -- The signing-key file does not exist: any read of it fails,
            -- so the named refusal proves the refusal came first.
            nokey <-
                runWithKey
                    (rigDir rig </> "missing.skey")
                    rig
                    "insert an active key with no signing key"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      ]
                        <> tokenArgs t
                    )
            runExit nokey `shouldBe` ExitFailure 10
            refused
                BookInsert
                Active
                Unknown
                "alice-1 is already registered"
                nokey
    it "refuses an insert on a terminal key in submit" $
        withRig $ \rig ->
            refused
                BookInsert
                Terminal
                Unknown
                "alice-1 is already retired"
                =<< labelled "insert a terminal key"
                =<< lifecycle rig
    it "refuses an insert on a terminal key in preview" $
        withRig $ \rig ->
            refused
                BookInsert
                Terminal
                Unknown
                "alice-1 is already retired"
                =<< labelled "insert a terminal key preview"
                =<< lifecycle rig
    it "refuses a terminate on a terminal key in submit" $
        withRig $ \rig ->
            refused
                BookTerminate
                Terminal
                Active
                "alice-1 is already retired"
                =<< labelled "terminate a terminal key"
                =<< lifecycle rig
    it "refuses a terminate on a terminal key in preview" $
        withRig $ \rig ->
            refused
                BookTerminate
                Terminal
                Active
                "alice-1 is already retired"
                =<< labelled "terminate a terminal key preview"
                =<< lifecycle rig
    it "refuses a terminate on an unknown key in submit" $
        withRig $ \rig ->
            refused
                BookTerminate
                Unknown
                Active
                "nobody is not registered"
                =<< labelled "terminate an unknown key"
                =<< lifecycle rig
    it "refuses a terminate on an unknown key in preview" $
        withRig $ \rig ->
            refused
                BookTerminate
                Unknown
                Active
                "nobody is not registered"
                =<< labelled "terminate an unknown key preview"
                =<< lifecycle rig
    it "refuses an update on an unknown key in submit" $
        withRig $ \rig ->
            refused
                BookUpdate
                Unknown
                Active
                "nobody is not registered"
                =<< labelled "update an absent key"
                =<< lifecycle rig
    it "refuses an update on an unknown key in preview" $
        withRig $ \rig ->
            refused
                BookUpdate
                Unknown
                Active
                "nobody is not registered"
                =<< labelled "update an unknown key preview"
                =<< lifecycle rig
    it "refuses an update on a terminal key in submit" $
        withRig $ \rig ->
            refused
                BookUpdate
                Terminal
                Active
                "alice-1 is already retired"
                =<< labelled "update a terminal key"
                =<< lifecycle rig
    it "refuses an update on a terminal key in preview" $
        withRig $ \rig ->
            refused
                BookUpdate
                Terminal
                Active
                "alice-1 is already retired"
                =<< labelled "update a terminal key preview"
                =<< lifecycle rig
    it "still accepts the bookings the Lean table admits, in submit" $
        withRig $ \rig -> do
            runs <- lifecycle rig
            let succeeds label =
                    labelled label runs
                        >>= (`shouldBe` Just "success") . outcomeOf . runReceipt
            succeeds "insert alice-2"
            succeeds "update alice-1"
            succeeds "terminate alice-1"
    -- Accepted previews pin no over-refusal. They stand outside the
    -- shared lifecycle: a succeeding preview emits no traced fetch, and
    -- the timed-read comparison requires one of every succeeding run.
    it "still accepts the bookings the Lean table admits, in preview" $
        withRig $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            let preview args = run rig "preview" (args <> tokenArgs t)
                walletAddrText = bech32Address (walletAddr (rigWallet rig))
                succeeds args =
                    preview args >>= (`shouldBe` Just "success") . outcomeOf . runReceipt
            insert <-
                run
                    rig
                    "insert alice-1"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt insert) `shouldBe` Just "success"
            fold1 <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf insert <> tokenArgs t)
            outcomeOf (runReceipt fold1) `shouldBe` Just "success"
            succeeds
                [ "open-datum"
                , "insert"
                , "--key"
                , "unused"
                , "--payload"
                , rigDir rig </> "payload.json"
                , "--preview"
                , "--wallet-address"
                , walletAddrText
                ]
            succeeds
                [ "open-datum"
                , "terminate"
                , "--key"
                , "alice-1"
                , "--preview"
                , "--wallet-address"
                , walletAddrText
                ]
            succeeds
                [ "open-datum"
                , "update"
                , "--key"
                , "alice-1"
                , "--payload"
                , rigDir rig </> "payload-2.json"
                , "--preview"
                , "--wallet-address"
                , walletAddrText
                ]

-- | What two packaged writes left: each run, the registry's files and its journal.
data Written = Written
    { writtenRuns :: [(String, ExitCode, BS.ByteString, BS.ByteString)]
    -- ^ Each command: its name, exit, standard output and standard error
    , writtenFiles :: [(FilePath, BS.ByteString)]
    -- ^ Every file of the registry but its journal
    , writtenJournal :: [Aeson.Value]
    -- ^ Every journal line, its wall-clock stamp removed
    , writtenStamps :: [Bool]
    -- ^ Per journal line: its stamp is present and an ISO-8601 time
    }

-- | The journal's wall-clock field, the one field the comparison sets aside.
journalStamp :: Aeson.Key
journalStamp = "journalTime"

-- | Two creates, of two registries, through the packaged composition, on a fresh rig here.
packagedWrites :: FilePath -> [String] -> IO Written
packagedWrites at flags = do
    removePathForcibly at
    createDirectory at
    withRigIn at syntheticBlueprint pure $ \rig -> do
        first <- fundSeed rig
        one <-
            packaged
                rig
                "registry"
                "create"
                ["open-datum", "create", "--seed", first]
        second <- fundSeed2 rig
        two <-
            packaged
                rig
                "registry-2"
                "create two"
                ["open-datum", "create", "--seed", second]
        registries <-
            mapM (registryFiles . (rigDir rig </>)) ["registry", "registry-2"]
        let files = concatMap fst registries
            journal = concatMap snd registries
        pure
            Written
                { writtenRuns = [one, two]
                , writtenFiles = files
                , writtenJournal = map unstamped journal
                , writtenStamps = map stamped journal
                }
  where
    packaged rig registry name args = do
        let errPath = rigDir rig </> (registry <> ".stderr")
        h <- openFile errPath WriteMode
        (code, out, _) <-
            captured
                ( runPackagedOpenDatumVia
                    (\tracer -> (envOf rig){envTracer = tracer})
                    openDatumApplication
                    (pure (Just h))
                    (commandLine rig registry args <> flags)
                    []
                )
        hClose h
        err <- BS.readFile errPath
        pure (name, code, out, err)
    registryFiles registry = do
        names <- sort <$> listDirectoryRecursive registry
        -- The journal lives under the managed identity partition, never
        -- directly at the configured root: locate it instead of assuming it.
        let (journals, others) = partition ((== "journal.jsonl") . takeFileName) names
        journalRel <- case journals of
            [found] -> pure found
            _ ->
                fail
                    ( "expected exactly one managed journal under "
                        <> registry
                        <> ", found "
                        <> show (length journals)
                    )
        files <-
            mapM
                (\p -> (,) (registry </> p) <$> BS.readFile (registry </> p))
                others
        journal <-
            mapM
                (maybe (fail "a journal line is not JSON") pure . Aeson.decodeStrict)
                . BC.lines
                =<< BS.readFile (registry </> journalRel)
        pure (files, journal)
    unstamped = \case
        Aeson.Object o -> Aeson.Object (KeyMap.delete journalStamp o)
        other -> other
    stamped = \case
        Aeson.Object o
            | Just (Aeson.String t) <- KeyMap.lookup journalStamp o ->
                isJust (iso8601ParseM (T.unpack t) :: Maybe UTCTime)
        _ -> False

-- | Every file below a directory, as paths relative to it.
listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
    entries <- listDirectory dir
    concat
        <$> mapM
            ( \e -> do
                isDir <- doesDirectoryExist (dir </> e)
                if isDir
                    then map (e </>) <$> listDirectoryRecursive (dir </> e)
                    else pure [e]
            )
            entries

-- ---------------------------------------------------------
-- The rig
-- ---------------------------------------------------------

data Rig = Rig
    { rigDir :: FilePath
    , rigChain :: RawChain
    , rigWallet :: Wallet
    , rigKey :: FilePath
    , rigBlueprint :: FilePath
    , rigEvents :: IORef [Trace]
    , rigAnswer :: IORef (Maybe Cage.SubmitResult)
    -- ^ When set, what the provider answers the next submission instead of taking it
    , rigTracer :: Tracer IO Trace
    -- ^ What the commands trace into: the collector, or a composition holding it
    }

-- | One command run: its constructor, a label, its exit, its receipt and its events.
data Run = Run
    { runName :: String
    , runLabel :: String
    , runExit :: ExitCode
    , runReceipt :: Aeson.Value
    , runEvents :: [Trace]
    , runKey :: Maybe Text
    -- ^ The key the command line names, base16
    }

-- | The @--request@ of a run's receipt, for the fold that follows it.
requestOf :: Run -> [String]
requestOf r =
    maybe
        []
        (\q -> ["--request", T.unpack q])
        (textAt "request" (runReceipt r))

magic :: Integer
magic = 42

withRig :: (Rig -> IO a) -> IO a
withRig = withRigVia pure

-- | The rig, its commands tracing into a composition built around its collector.
withRigVia
    :: (Tracer IO Trace -> IO (Tracer IO Trace)) -> (Rig -> IO a) -> IO a
withRigVia = withRigOf syntheticBlueprint

-- | The rig over this blueprint.
withRigOf
    :: Aeson.Value
    -> (Tracer IO Trace -> IO (Tracer IO Trace))
    -> (Rig -> IO a)
    -> IO a
withRigOf blueprintJson compose use =
    withSystemTempDirectory "command-run" $ \dir ->
        withRigIn dir blueprintJson compose use

-- | The rig over this blueprint, in this directory.
withRigIn
    :: FilePath
    -> Aeson.Value
    -> (Tracer IO Trace -> IO (Tracer IO Trace))
    -> (Rig -> IO a)
    -> IO a
withRigIn dir blueprintJson compose use = do
    let keyPath = dir </> "payment.skey"
        blueprint = dir </> "plutus.json"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    BL.writeFile blueprint (Aeson.encode blueprintJson)
    BL.writeFile
        (dir </> "payload.json")
        (Aeson.encode (Aeson.object ["int" .= (7 :: Int)]))
    BL.writeFile
        (dir </> "payload-2.json")
        (Aeson.encode (Aeson.object ["int" .= (8 :: Int)]))
    wallet <- loadWallet (fromIntegral magic) keyPath
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = fromIntegral magic
                , csTip = Nothing
                , csPParams = withSyntheticCosts preprodParams
                , csUTxO =
                    Map.fromList
                        [ ( fundOutput n
                          , mkBasicTxOut
                                (walletAddr wallet)
                                (MaryValue (Coin 2_000_000_000) mempty)
                          )
                        | n <- [1 .. 6]
                        ]
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    advanceChain chain id
    jumpChainToHostClock chain
    events <- newIORef []
    answer <- newIORef Nothing
    tracer <- compose (Tracer (\t -> modifyIORef' events (<> [t])))
    use (Rig dir chain wallet keyPath blueprint events answer tracer)

-- | A wallet output at the start of the chain.
fundOutput :: Int -> TxIn
fundOutput n =
    either
        (error . ("fundOutput: " <>))
        id
        (parseOutRef (T.pack (replicate 64 'f' <> "#" <> show n)))

{- | The registry's validators as accept-all programs, each taking the
parameters the builders apply and then the script context.
-}
syntheticBlueprint :: Aeson.Value
syntheticBlueprint = blueprintOf (const unitProgram)

{- | The same validators, the open datum's failing whatever it is given: an
insertion's booking, which mints under it, fails its local evaluation.
-}
failingOpenDatum :: Aeson.Value
failingOpenDatum = blueprintOf $ \title arity ->
    if title == "open_datum.open_datum"
        then errorProgram arity
        else unitProgram arity

-- | The registry's validators, each program made from its title and arity.
blueprintOf :: (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintOf = blueprintWith []

{- | The same, carrying these further validators (title and arity), each
program made as the others are.
-}
blueprintWith
    :: [(Text, Int)] -> (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintWith further program =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= ( [ validator "state.state" 1
                 , validator "request.request" 3
                 , validator "open_datum.open_datum" 2
                 , validator "witness.witness" 3
                 , validator "witness.witness" 3
                 ]
                    <> [validator title arity | (title, arity) <- further]
               )
        , "definitions" .= Aeson.object []
        ]
  where
    validator :: Text -> Int -> Aeson.Value
    validator title arity =
        let code = program title arity
        in  Aeson.object
                [ "title" .= title
                , "redeemer" .= Aeson.object ["schema" .= Aeson.object []]
                , "hash"
                    .= TE.decodeUtf8 (B16.encode (scriptHashBytes (computeScriptHash code)))
                , "compiledCode" .= TE.decodeUtf8 (B16.encode (SBS.fromShort code))
                ]

-- | The environment of a run over the rig: the fixture's capabilities.
envOf :: Rig -> Env
envOf rig =
    Env
        { envTracer = rigTracer rig
        , envSource = "fixture"
        , envLoadRelease = loadReleaseCodes
        , envReads = \_ k -> k (capabilities rig)
        , envWrites = \_ k -> k (capabilities rig)
        }

{- | The environment of a run whose submissions land in the slot the chain
stood at: each body lands (its outputs live, its inputs spent) and the chain's
slot does not move. A comparison of a staged chain with a key-file chain builds
every body of both at the one slot the staged chain is built at (a chained
view keeps the held view's tip), so what follows the slot (the booked time, the
nonce both tags commit to, the validity interval) is the same on both sides.
-}
envPinned :: Rig -> Env
envPinned rig =
    (envOf rig)
        { envWrites = \_ k -> k pinned
        }
  where
    held = capabilities rig
    pinned =
        held
            { capSubmit = \signed -> do
                slot <- freshView rig (fmap Cage.observedSlot . SessionIO.tip)
                answer <- capSubmit held signed
                jumpChainTo (rigChain rig) slot
                pure answer
            }

-- | Reads of the chain fixture, and a submission it applies to its outputs.
capabilities :: Rig -> Capabilities NoWitness IO
capabilities rig =
    Capabilities
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
            in  (network, observeProvider unverifiedVerifier (\_ -> pure ()) provider)
        , capSubmit = \signed ->
            readIORef (rigAnswer rig) >>= \case
                Just answer -> writeIORef (rigAnswer rig) Nothing >> pure answer
                Nothing -> do
                    let tx = signedTx signed
                        txid = txIdTx tx
                        spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
                        made = zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
                    recordTransaction (rigChain rig) tx
                    advanceChain (rigChain rig) $ \facts ->
                        facts
                            { csUTxO =
                                Map.union
                                    (Map.fromList [(TxIn txid (TxIx ix), out) | (ix, out) <- made])
                                    (foldr Map.delete (csUTxO facts) spent)
                            }
                    pure (Cage.SubmitAccepted txid)
        , capConfirm = \_ -> pure ()
        , capFacts = pure []
        , capTrace = pure []
        }

{- | The rig's capabilities with every exact-input read answered by this —
a refused read as a typed failure, or a successful empty answer — every
other read served by the chain as it stands: a provider that cannot
make one read, or one that answers nothing there, not one that is down.
-}
atTxInCapabilities
    :: Either Cage.ReadFailure (Evidenced NoWitness Cage.Outputs)
    -> Rig
    -> Capabilities NoWitness IO
atTxInCapabilities answer rig =
    (capabilities rig)
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
                answering =
                    provider
                        { Cage.acquire =
                            \requested action ->
                                Cage.acquire provider requested (answeringReads action)
                        }
            in  ( network
                , observeProvider unverifiedVerifier (\_ -> pure ()) answering
                )
        }
  where
    answeringReads action session =
        action
            session
                { Cage.outputs = \query -> case query of
                    Cage.AtTxIn _ -> pure answer
                    _ -> Cage.outputs session query
                }

-- ---------------------------------------------------------
-- The lifecycle
-- ---------------------------------------------------------

{- | Run the commands in the order a registry's life takes them, each over the
state the previous left, whatever outcome each reaches.
-}

{- | The state token a create printed, as a person passes it to every
later command of that registry.
-}
tokenOf :: Run -> IO String
tokenOf r = case textAt "stateToken" (runReceipt r) of
    Just t -> pure (T.unpack t)
    Nothing ->
        fail
            ("no state token in " <> runLabel r <> ": " <> show (runReceipt r))

-- | A command line naming the registry by its state token.
tokenArgs :: String -> [String]
tokenArgs t = ["--state-token", t]

lifecycle :: Rig -> IO [Run]
lifecycle rig = do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    -- Every command after a create names its registry by the state token
    -- that create printed: there is no saved registry to attach to.
    t1 <- tokenOf create
    insert <-
        run
            rig
            "insert alice-1"
            ( ["open-datum", "insert", "--key", "alice-1", "--payload", payload]
                <> tokenArgs t1
            )
    fold1 <-
        run
            rig
            "fold alice-1"
            (["open-datum", "fold"] <> requestOf insert <> tokenArgs t1)
    -- S6.1: alice-1 is active now; booking it again is refused (#486).
    insertActive <-
        run
            rig
            "insert an active key"
            ( ["open-datum", "insert", "--key", "alice-1", "--payload", payload]
                <> tokenArgs t1
            )
    insertActivePreview <-
        run
            rig
            "insert an active key preview"
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "alice-1"
              , "--payload"
              , payload
              , "--preview"
              , "--wallet-address"
              , previewAddr
              ]
                <> tokenArgs t1
            )

    inspect <-
        run
            rig
            "inspect alice-1"
            (["open-datum", "inspect", "--key", "alice-1"] <> tokenArgs t1)
    update <-
        run
            rig
            "update alice-1"
            ( ["open-datum", "update", "--key", "alice-1", "--payload", payload2]
                <> tokenArgs t1
            )
    terminate <-
        run
            rig
            "terminate alice-1"
            (["open-datum", "terminate", "--key", "alice-1"] <> tokenArgs t1)
    fold2 <-
        run
            rig
            "fold alice-1 terminal"
            (["open-datum", "fold"] <> requestOf terminate <> tokenArgs t1)
    -- S6.1: alice-1 is terminal now; booking it either way is refused.
    insertTerminal <-
        run
            rig
            "insert a terminal key"
            ( ["open-datum", "insert", "--key", "alice-1", "--payload", payload]
                <> tokenArgs t1
            )
    insertTerminalPreview <-
        run
            rig
            "insert a terminal key preview"
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "alice-1"
              , "--payload"
              , payload
              , "--preview"
              , "--wallet-address"
              , previewAddr
              ]
                <> tokenArgs t1
            )
    terminateTerminal <-
        run
            rig
            "terminate a terminal key"
            (["open-datum", "terminate", "--key", "alice-1"] <> tokenArgs t1)
    terminateTerminalPreview <-
        run
            rig
            "terminate a terminal key preview"
            ( [ "open-datum"
              , "terminate"
              , "--key"
              , "alice-1"
              , "--preview"
              , "--wallet-address"
              , previewAddr
              ]
                <> tokenArgs t1
            )
    updateTerminal <-
        run
            rig
            "update a terminal key"
            ( ["open-datum", "update", "--key", "alice-1", "--payload", payload2]
                <> tokenArgs t1
            )
    updateTerminalPreview <-
        run
            rig
            "update a terminal key preview"
            ( [ "open-datum"
              , "update"
              , "--key"
              , "alice-1"
              , "--payload"
              , payload2
              , "--preview"
              , "--wallet-address"
              , previewAddr
              ]
                <> tokenArgs t1
            )
    insert2 <-
        run
            rig
            "insert alice-2"
            ( ["open-datum", "insert", "--key", "alice-2", "--payload", payload]
                <> tokenArgs t1
            )
    foldInsert2 <-
        run
            rig
            "fold alice-2"
            (["open-datum", "fold"] <> requestOf insert2 <> tokenArgs t1)
    -- a second registry, folded like the first
    seed2 <- fundSeed2 rig
    create2 <-
        runAt
            rig
            "registry-2"
            "create second registry"
            [ "open-datum"
            , "create"
            , "--seed"
            , seed2
            ]
    t2 <- tokenOf create2
    insert3 <-
        runAt
            rig
            "registry-2"
            "insert alice-3"
            ( ["open-datum", "insert", "--key", "alice-3", "--payload", payload]
                <> tokenArgs t2
            )
    foldInsert3 <-
        runAt
            rig
            "registry-2"
            "fold alice-3"
            (["open-datum", "fold"] <> requestOf insert3 <> tokenArgs t2)
    -- refusals, each where it happens
    nothingPending <-
        runAt
            rig
            "registry-2"
            "fold with nothing pending"
            (["open-datum", "fold"] <> tokenArgs t2)
    overAllowance <-
        run
            rig
            "insert over its allowance"
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "alice-4"
              , "--payload"
              , payload
              , "--max-outlay"
              , "1"
              ]
                <> tokenArgs t1
            )
    absent <-
        run
            rig
            "update an absent key"
            ( ["open-datum", "update", "--key", "nobody", "--payload", payload2]
                <> tokenArgs t1
            )
    -- S6.1: nobody was never registered; booking it is refused.
    terminateNobody <-
        run
            rig
            "terminate an unknown key"
            (["open-datum", "terminate", "--key", "nobody"] <> tokenArgs t1)
    terminateNobodyPreview <-
        run
            rig
            "terminate an unknown key preview"
            ( [ "open-datum"
              , "terminate"
              , "--key"
              , "nobody"
              , "--preview"
              , "--wallet-address"
              , previewAddr
              ]
                <> tokenArgs t1
            )
    updateNobodyPreview <-
        run
            rig
            "update an unknown key preview"
            ( [ "open-datum"
              , "update"
              , "--key"
              , "nobody"
              , "--payload"
              , payload2
              , "--preview"
              , "--wallet-address"
              , previewAddr
              ]
                <> tokenArgs t1
            )
    -- refused before any transaction is built
    existing <-
        run
            rig
            "create over an existing registry"
            ["open-datum", "create", "--seed", seed]
    -- A well-formed token no registry minted: this release's state
    -- policy with the name an unused fixture seed derives. The
    -- fixture holds no mint record for it, so its inspect is refused
    -- by name instead of reading another registry.
    missingToken <- absentToken t1
    missing <-
        runAt
            rig
            "no-registry"
            "inspect a registry that does not exist"
            ( ["open-datum", "inspect", "--key", "alice-1"]
                <> tokenArgs missingToken
            )
    emptyDir <-
        -- An empty actor directory with a valid existing token reads that
        -- registry: the token names it, not the directory. This success
        -- does not replace the missing-registry refusal above.
        runAt
            rig
            "empty-actor"
            "inspect from an empty directory with the state token"
            (["open-datum", "inspect", "--key", "alice-1"] <> tokenArgs t1)
    writeIORef
        (rigAnswer rig)
        (Just (Cage.SubmitRefused "the ledger said no"))
    rejected <-
        run
            rig
            "insert the ledger rejects"
            ( ["open-datum", "insert", "--key", "alice-5", "--payload", payload]
                <> tokenArgs t1
            )
    writeIORef
        (rigAnswer rig)
        (Just (Cage.SubmitFailed "connection refused"))
    unanswered <-
        run
            rig
            "insert the provider drops"
            ( ["open-datum", "insert", "--key", "alice-6", "--payload", payload]
                <> tokenArgs t1
            )
    pure
        [ create
        , insert
        , fold1
        , insertActive
        , insertActivePreview
        , inspect
        , update
        , terminate
        , fold2
        , insertTerminal
        , insertTerminalPreview
        , terminateTerminal
        , terminateTerminalPreview
        , updateTerminal
        , updateTerminalPreview
        , insert2
        , foldInsert2
        , create2
        , insert3
        , foldInsert3
        , nothingPending
        , overAllowance
        , absent
        , terminateNobody
        , terminateNobodyPreview
        , updateNobodyPreview
        , existing
        , missing
        , emptyDir
        , rejected
        , unanswered
        ]
  where
    payload = rigDir rig </> "payload.json"
    payload2 = rigDir rig </> "payload-2.json"
    previewAddr = bech32Address (walletAddr (rigWallet rig))

-- | A wallet output the create can consume as its seed.
fundSeed :: Rig -> IO String
fundSeed _ = pure (T.unpack (renderOutRef (fundOutput 1)))

-- | A wallet output still unspent, for the second registry.
fundSeed2 :: Rig -> IO String
fundSeed2 rig = do
    held <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \s ->
            SessionIO.outputsAt s (walletAddr (rigWallet rig))
    case reverse (map fst held) of
        i : _ -> pure (T.unpack (renderOutRef i))
        [] -> fail "the wallet holds nothing for a second registry"

{- | A well-formed token no registry minted: this release's state policy
with the name the unused fixture seed derives. The text keeps the
policy the create printed and swaps in that name.
-}
absentToken :: String -> IO String
absentToken printed = case T.splitOn "." (T.pack printed) of
    [policy, _] ->
        pure
            ( T.unpack
                ( policy
                    <> "."
                    <> TE.decodeUtf8
                        (B16.encode (deriveAssetName (txInToRef (fundOutput 7))))
                )
            )
    _ -> fail ("no policy in state token " <> printed)

-- | One command line, parsed as the packaged command parses it and run in process.
run :: Rig -> String -> [String] -> IO Run
run rig = runAt rig "registry"

-- | The same, against the registry in this directory of the rig.
runAt :: Rig -> FilePath -> String -> [String] -> IO Run
runAt rig = runVia rig (envOf rig)

{- | The same, over an environment of the caller's: the packaged one, or
one whose provider cannot answer a read.
-}
runVia :: Rig -> Env -> FilePath -> String -> [String] -> IO Run
runVia rig env registry label args = do
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . show)
            pure
            (parseOpenDatumCommand (commandLine rig registry args))
    (code, out, _) <-
        captured (runOpenDatum env command)
    receipt <-
        maybe
            (fail ("no receipt for " <> label <> ": " <> show out))
            pure
            (Aeson.decodeStrict out)
    events <- readIORef (rigEvents rig)
    pure
        Run
            { runName = constructorOf command
            , runLabel = label
            , runExit = code
            , runReceipt = receipt
            , runEvents = events
            , runKey =
                listToMaybe
                    [ hexText (TE.encodeUtf8 (T.pack k))
                    | ("--key", k) <- zip args (drop 1 args)
                    ]
            }

{- | A command line through the same dispatch and receipt plumbing, over
a provider that answers every exact-input read with this: a refused
read as a typed failure, or a successful empty answer — the read-back
a create must make of a reference it just published.
-}
runAtTxIn
    :: Either Cage.ReadFailure (Evidenced NoWitness Cage.Outputs)
    -> Rig
    -> String
    -> [String]
    -> IO Run
runAtTxIn answer rig =
    runVia
        rig
        ( (envOf rig)
            { envReads = \_ k -> k (atTxInCapabilities answer rig)
            , envWrites = \_ k -> k (atTxInCapabilities answer rig)
            }
        )
        "registry"

-- | A command line over the rig, as the packaged command is given it.
commandLine :: Rig -> FilePath -> [String] -> [String]
commandLine rig registry args =
    args
        <> [ "--state-dir"
           , rigDir rig </> registry
           , "--blueprint"
           , rigBlueprint rig
           , "--koios-url"
           , "http://fixture.invalid"
           , "--network-magic"
           , show magic
           ]
        <> ["--wallet-skey" | wantsKey]
        <> [rigKey rig | wantsKey]
        <> createValues
  where
    -- A preview holds no signing key: it names the caller by address.
    -- A line that already names one keeps it: the key-ordering control
    -- supplies an absent key file through the same dispatch.
    wantsKey =
        take 2 args /= ["open-datum", "inspect"]
            && "--preview" `notElem` args
            && "--bundle" `notElem` args
            && "--vault" `notElem` args
            && "--wallet-skey" `notElem` args
    -- A create is given the registration cost and the booking width it
    -- requires; a line that already names either keeps its own.
    createValues
        | take 2 args == ["open-datum", "create"]
            && "--registration-cost" `notElem` args
            && "--booking-width" `notElem` args =
            ["--registration-cost", "0", "--booking-width", "60000"]
        | otherwise = []

-- | One command line with this signing-key path instead of the rig's.
runWithKey :: FilePath -> Rig -> String -> [String] -> IO Run
runWithKey keyPath rig label args =
    runAt rig "registry" label (args <> ["--wallet-skey", keyPath])

-- ---------------------------------------------------------
-- The comparison
-- ---------------------------------------------------------

-- | The receipt's outcome.
outcomeOf :: Aeson.Value -> Maybe Text
outcomeOf = textAt "outcome"

textAt :: Aeson.Key -> Aeson.Value -> Maybe Text
textAt k = \case
    Aeson.Object o | Just (Aeson.String t) <- KeyMap.lookup k o -> Just t
    _ -> Nothing

-- | Every object in a value, itself included.
objectsIn :: Aeson.Value -> [Aeson.Object]
objectsIn = \case
    Aeson.Object o -> o : concatMap objectsIn (KeyMap.elems o)
    Aeson.Array xs -> concatMap objectsIn xs
    _ -> []

{- | A request the receipt names: its key, edge and processing deadline, where
the object naming it states them.
-}
data RequestFact = RequestFact
    { factRequest :: Text
    , factKey :: Maybe Text
    , factEdge :: Maybe Text
    , factDeadline :: Maybe Integer
    }

{- | The receipt's request facts: each object naming a request, and the
request a booking left (its output 0).
-}
requestFacts :: Aeson.Value -> [RequestFact]
requestFacts receipt =
    [ RequestFact r (fieldOf "key" o) (fieldOf "edge" o) (deadlineIn o)
    | o <- objectsIn receipt
    , Just r <- [fieldOf "request" o]
    ]
        <> [ RequestFact r Nothing Nothing Nothing
           | o <- objectsIn receipt
           , Just r <- [fieldOf "pendingRequest" o]
           ]
        <> [ RequestFact (b <> "#0") (fieldOf "key" o) Nothing Nothing
           | Aeson.Object o <- [receipt]
           , Just b <- [fieldOf "booking" o]
           ]
  where
    deadlineIn o = case KeyMap.lookup "foldDeadline" o of
        Just d -> integerAt "posixMs" d
        Nothing -> case KeyMap.lookup "deadline" o of
            Just d -> integerAt "posixMs" d
            Nothing -> integerAt "processingEnds" (Aeson.Object o)

-- | The first entry of the receipt's settled list, as an object.
firstSettled :: Aeson.Value -> Maybe Aeson.Object
firstSettled v = case elementsAt "settled" v of
    Just (Aeson.Object o : _) -> Just o
    _ -> Nothing

-- | A settled request's own text fact, from the receipt's settled list.
settledField :: Aeson.Key -> Aeson.Value -> Maybe Text
settledField name v = firstSettled v >>= fieldOf name

-- | A settled request's settlement text fact.
settledSettlement :: Aeson.Key -> Aeson.Value -> Maybe Text
settledSettlement name v = do
    o <- firstSettled v
    case KeyMap.lookup "settlement" o of
        Just (Aeson.Object s) -> fieldOf name s
        _ -> Nothing

fieldOf :: Aeson.Key -> Aeson.Object -> Maybe Text
fieldOf k o = case KeyMap.lookup k o of
    Just (Aeson.String t) -> Just t
    _ -> Nothing

integerAt :: Aeson.Key -> Aeson.Value -> Maybe Integer
integerAt k = \case
    Aeson.Object o
        | Just v <- KeyMap.lookup k o
        , Aeson.Success i <- Aeson.fromJSON v ->
            Just i
    _ -> Nothing

valueAt :: Aeson.Key -> Aeson.Value -> Maybe Aeson.Value
valueAt k = \case
    Aeson.Object o -> KeyMap.lookup k o
    _ -> Nothing

-- | The elements of an array field.
elementsAt :: Aeson.Key -> Aeson.Value -> Maybe [Aeson.Value]
elementsAt k v = case valueAt k v of
    Just (Aeson.Array xs) -> Just (toList xs)
    _ -> Nothing

{- | The runs whose receipt is a successful fold's: the receipt whose earlier
top-level single-request fields the next slice removes.
-}
foldSuccesses :: [Run] -> [Run]
foldSuccesses =
    filter
        ( \r ->
            textAt "command" (runReceipt r) == Just "fold"
                && outcomeOf (runReceipt r) == Just "success"
        )

{- | A fold run's receipt without its earlier top-level single-request
fields: the post-removal shape, the settled list carrying the same facts.
-}
readFromTheList :: Run -> Aeson.Value
readFromTheList r =
    withoutFields earlierSingleRequestFields (runReceipt r)

{- | The earlier top-level single-request fields of a fold receipt, printed
beside the settled list: the next slice removes them, so the events are
compared with the settled list instead.
-}
earlierSingleRequestFields :: [Aeson.Key]
earlierSingleRequestFields =
    [ "request"
    , "key"
    , "edge"
    , "liveOutput"
    , "envelope"
    , "released"
    , "deposit"
    , "datumHash"
    , "datumCbor"
    ]

-- | The receipt without these top-level fields: the post-removal shape.
withoutFields :: [Aeson.Key] -> Aeson.Value -> Aeson.Value
withoutFields names = \case
    Aeson.Object o -> Aeson.Object (foldl (flip KeyMap.delete) o names)
    v -> v

{- | Every way a fold receipt's settled list can stop agreeing with its
events: removed, emptied, or contradicted in each fact the comparison
binds. An alteration whose path the receipt does not carry is absent, so
each delivery branch keeps the settlement field it prints.
-}
settledAlterations :: Aeson.Value -> [(String, Aeson.Value)]
settledAlterations receipt =
    [ ("settled removed", withoutFields ["settled"] receipt)
    , ("settled emptied", setSettled [] receipt)
    ]
        <> mapMaybe
            (\(what', f) -> (what',) <$> overFirstSettled f receipt)
            [ ("settled request", withText "request" flipLeading)
            , ("settled key", withText "key" flipLeading)
            , ("settled edge", withText "edge" (<> "x"))
            , ("settled deadline", overDeadline (withInteger "posixMs" (+ 1)))
            ,
                ( "settled live output"
                , overSettlement (withText "liveOutput" flipLeading)
                )
            ,
                ( "settled terminated request"
                , overSettlement (withText "terminated" flipLeading)
                )
            ]

{- | Every settled-list contradiction 'settledAlterations' plants; both
delivery branches occur among the lifecycle's folds, so the extent is
both settlement fields.
-}
settledContradictions :: [String]
settledContradictions =
    sort
        [ "settled removed"
        , "settled emptied"
        , "settled request"
        , "settled key"
        , "settled edge"
        , "settled deadline"
        , "settled live output"
        , "settled terminated request"
        ]

-- | The receipt with its settled list replaced by these entries.
setSettled :: [Aeson.Value] -> Aeson.Value -> Aeson.Value
setSettled settled = \case
    Aeson.Object o -> Aeson.Object (KeyMap.insert "settled" (Aeson.toJSON settled) o)
    v -> v

{- | The receipt with its first settled entry edited; Nothing when there is
no settled entry or the edit binds nothing.
-}
overFirstSettled
    :: (Aeson.Object -> Maybe Aeson.Object)
    -> Aeson.Value
    -> Maybe Aeson.Value
overFirstSettled f v = do
    o <- firstSettled v
    o' <- f o
    let rest = maybe [] (drop 1) (elementsAt "settled" v)
    pure (setSettled (Aeson.Object o' : rest) v)

-- | Replace a text field of an object; Nothing when it holds no text there.
withText
    :: Aeson.Key -> (Text -> Text) -> Aeson.Object -> Maybe Aeson.Object
withText name f o = case KeyMap.lookup name o of
    Just (Aeson.String t) -> Just (KeyMap.insert name (Aeson.String (f t)) o)
    _ -> Nothing

-- | Replace an integer field of an object; Nothing when it holds no number.
withInteger
    :: Aeson.Key
    -> (Integer -> Integer)
    -> Aeson.Object
    -> Maybe Aeson.Object
withInteger name f o = case KeyMap.lookup name o of
    Just v
        | Aeson.Success n <- Aeson.fromJSON v ->
            Just (KeyMap.insert name (Aeson.toJSON (f n)) o)
    _ -> Nothing

-- | Edit the entry's settlement object, when it carries one.
overSettlement
    :: (Aeson.Object -> Maybe Aeson.Object)
    -> Aeson.Object
    -> Maybe Aeson.Object
overSettlement f o = case KeyMap.lookup "settlement" o of
    Just (Aeson.Object s)
        | Just s' <- f s ->
            Just (KeyMap.insert "settlement" (Aeson.Object s') o)
    _ -> Nothing

-- | Edit the entry's deadline object, when it carries one.
overDeadline
    :: (Aeson.Object -> Maybe Aeson.Object)
    -> Aeson.Object
    -> Maybe Aeson.Object
overDeadline f o = case KeyMap.lookup "deadline" o of
    Just (Aeson.Object d)
        | Just d' <- f d ->
            Just (KeyMap.insert "deadline" (Aeson.Object d') o)
    _ -> Nothing

-- | Flip a text's first character, so a bound fact contradicts its event.
flipLeading :: Text -> Text
flipLeading t =
    if T.take 1 t == "0" then "1" <> T.drop 1 t else "0" <> T.drop 1 t

-- | The receipt's submissions: step, transaction id, case and whether observed.
submissionsOf :: Aeson.Value -> [(Text, Text, Maybe Text, Bool)]
submissionsOf = \case
    Aeson.Object o
        | Just (Aeson.Array xs) <- KeyMap.lookup "submissions" o ->
            [ (s, t, c, observed)
            | Aeson.Object x <- toList xs
            , let c = case KeyMap.lookup "case" x of
                    Just (Aeson.String v) -> Just v
                    _ -> Nothing
                  observed = KeyMap.lookup "observed" x == Just (Aeson.Bool True)
            , Just (Aeson.String s) <- [KeyMap.lookup "step" x]
            , Just (Aeson.String t) <- [KeyMap.lookup "tx" x]
            ]
    _ -> []

{- | The edge actions a command performs, by its receipt's command: create
boots, insert and terminate book the edge their plan books (and fold it when
asked), update updates, reject rejects, fold and reclaim act on the edge
their receipt names. OpenInspect performs none.
-}
inRole :: Maybe Text -> Maybe Text -> EdgeAction -> Bool
inRole command receiptEdge action = case (command, action) of
    (Just "create", Booting) -> True
    (Just "insert", Booking e) -> e == booked edgeInsertActive
    (Just "insert", Folding e) -> e == booked edgeInsertActive
    (Just "terminate", Booking e) -> e == booked edgeUpdateTerminal
    (Just "terminate", Folding e) -> e == booked edgeUpdateTerminal
    (Just "update", Updating) -> True
    (Just "fold", Folding e) -> Just e == receiptEdge || isNothing receiptEdge
    (Just "reject", Rejecting) -> True
    (Just "reclaim", Reclaiming e) -> Just e == receiptEdge || isNothing receiptEdge
    _ -> False
  where
    booked = T.pack . edgeName

-- | Whether a refusal kind can stand under a receipt's outcome.
refusalFits :: RefusalKind -> Maybe Text -> Bool
refusalFits k o = case k of
    LedgerRejected -> o == Just "ledger-refusal"
    TransportFailed -> o `elem` map Just ["partial", "node-unavailable", "timeout"]
    ClientRefused ->
        o
            `elem` map
                Just
                ["client-refusal", "partial", "concurrent-writer", "stale-state"]
    EvaluationRefused -> o `elem` map Just ["client-refusal", "partial"]

{- | Every way the typed events contradict the receipt; empty when every event
that carries a receipt-bound fact agrees with it. The key is the receipt's,
or the one the command line named when the receipt names none (a refusal's
receipt carries no key).
-}
disagreements :: Maybe Text -> Aeson.Value -> [Trace] -> [String]
disagreements invokedKey receipt events =
    concat
        [ ends
        , ["key " <> show k | k <- eventKeys, Just k /= expectedKey]
        , [ "request " <> show r <> " not named by the receipt"
          | r <- eventRequests
          , r `notElem` map factRequest facts
          , not (null facts && outcome /= Just "success")
          ]
        , [ "request " <> show r <> " " <> what' <> " " <> v
          | Trace _ (What (RequestSeen r e k d _)) <- events
          , f <- facts
          , factRequest f == r
          , (what', v, fv) <-
                [ ("key", show (hexText k), show <$> factKey f)
                , ("edge", show e, show <$> factEdge f)
                ]
                    <> [ ("deadline", show d, show . Just <$> factDeadline f)
                       | isJust d
                       ]
          , Just w <- [fv]
          , w /= v
          ]
        , [ "booked " <> show r <> " deadline " <> show d
          | Trace _ (What (Booked r (Just d))) <- events
          , f <- facts
          , factRequest f == r
          , Just d' <- [factDeadline f]
          , d /= d'
          ]
        , [ "edge " <> show a <> " outside the command's role"
          | a <- eventEdges
          , not (inRole command receiptEdge a)
          ]
        , [ "leaf " <> show l
          | Trace _ (What (KeySeen _ l _)) <- events
          , Just l' <- [textAt "leaf" receipt]
          , l /= l'
          ]
        , [ "holding " <> show h
          | Trace _ (What (KeySeen _ _ h)) <- events
          , Just application <- [valueAt "applicationOutput" receipt]
          , h /= textAt "output" application
          ]
        , [ "pending " <> show n
          | Trace _ (What (RegistrySeen _ _ (Just n))) <- events
          , Just ps <- [elementsAt "pendingRequests" receipt]
          , n /= length ps
          ]
        , [ "registry root " <> show r
          | Trace _ (What (RegistrySeen _ r _)) <- events
          , Just expected <- [rootBefore]
          , r /= expected
          ]
        , [ "transaction "
                <> show (s, t)
                <> " not among the receipt's submissions"
          | (s, t, observedOnly) <- eventTxs
          , (s, t) `notElem` [(s', t') | (s', t', _, _) <- subs]
          , not (observedOnly && (s, t) `elem` reused)
          ]
        , [ "reference " <> show (s, t) <> " read back " <> show n <> " times"
          | (s, t) <- reused
          , let n =
                    length
                        [ ()
                        | Trace _ (How (Tx (TxObserved s' t' _))) <- events
                        , (s', t') == (s, t)
                        ]
          , n /= 1
          ]
        , [ "submission " <> show (s, t) <> " has no signing and submission event"
          | (s, t, _, _) <- subs
          , not (any (signed s t) events) || not (any (submitted s t) events)
          ]
        , [ "submission "
                <> show t
                <> " observed "
                <> show o
                <> " against its events"
          | (s, t, _, o) <- subs
          , o /= any (observedEvent s t) events
          ]
        , [ "submission "
                <> show t
                <> " met "
                <> show c
                <> " but its events say "
                <> show v
          | (_, t, c, _) <- subs
          , v <- verdictsOf t
          , not (consistent v c)
          ]
        , [ "root " <> show a
          | Trace _ (What (RootSeen _ a)) <- events
          , Just a /= textAt "root" receipt
          ]
        , [ "token " <> show tok
          | Trace _ (What (Created tok _)) <- events
          , Just tok /= textAt "token" receipt
          ]
        , [ "created state " <> show st
          | Trace _ (What (Created _ st)) <- events
          , Just (T.takeWhile (/= '#') st) /= textAt "boot" receipt
          ]
        , [ "rejected " <> show rs
          | Trace _ (What (Rejected rs)) <- events
          , sort rs /= sort receiptRejected
          ]
        , [ "reclaimed " <> show v
          | Trace _ (What (Reclaimed _ v)) <- events
          , Just v /= (valueAt "returned" receipt >>= integerAt "lovelace")
          ]
        , [ "updated output " <> show o
          | Trace _ (What (Updated _ o)) <- events
          , Just o /= textAt "liveOutput" receipt
          ]
        , [ "folded output " <> show o
          | Trace _ (What (Folded _ _ o)) <- events
          , Just o
                /= ( settledSettlement "liveOutput" receipt
                        <|> settledSettlement "terminated" receipt
                   )
          ]
        , [ "the fold's settled list is not exactly the one pending request"
          | command == Just "fold"
          , Just xs <- [elementsAt "settled" receipt]
          , length xs /= 1
          ]
        , [ "refusal " <> show k <> " under outcome " <> show outcome
          | Trace _ (What (Refused k _)) <- events
          , not (refusalFits k outcome)
          ]
        , [ "refusal events " <> show n <> " under outcome " <> show outcome
          | let n = length [() | Trace _ (What (Refused _ _)) <- events]
          , if refusalOutcome outcome then n /= 1 else n > 1
          ]
        , [ "ledger refusal with no ledger rejection event"
          | outcome == Just "ledger-refusal"
          , null [() | Trace _ (What (Refused LedgerRejected _)) <- events]
          ]
        ]
  where
    outcome = textAt "outcome" receipt
    command = textAt "command" receipt
    -- A fold receipt's key and edge live in its settled list; the earlier
    -- top-level fields are printed beside it until the removal slice.
    expectedKey
        | command == Just "fold" =
            settledField "key" receipt <|> textAt "key" receipt <|> invokedKey
        | otherwise = textAt "key" receipt <|> invokedKey
    receiptEdge
        | command == Just "fold" =
            settledField "edge" receipt <|> textAt "edge" receipt
        | otherwise = textAt "edge" receipt
    facts = requestFacts receipt
    subs = submissionsOf receipt
    -- a reference the command found already published: read back, not submitted
    reused =
        [ ("publish-" <> role, T.takeWhile (/= '#') out)
        | Just rs <- [elementsAt "references" receipt]
        , Aeson.Object o <- rs
        , Just role <- [fieldOf "role" o]
        , Just out <- [fieldOf "output" o]
        , T.takeWhile (/= '#') out `notElem` [t | (_, t, _, _) <- subs]
        ]
    receiptRejected =
        [ r
        | Just xs <- [elementsAt "rejected" receipt]
        , Aeson.Object o <- xs
        , Just r <- [fieldOf "request" o]
        ]
    rootBefore = case [b | Trace _ (What (RootSeen b _)) <- events] of
        b : _ -> Just b
        [] -> textAt "root" receipt
    ends = case [(c, o) | Trace [] (What (CommandEnded c o _)) <- events] of
        [(c, o)]
            | Just c == command
            , Just o == outcome
            , isEnd (lastMaybe events) ->
                []
        found ->
            [ "the stream's end "
                <> show found
                <> " against the receipt's command and outcome"
            ]
    isEnd = \case
        Just (Trace [] (What (CommandEnded{}))) -> True
        _ -> False
    lastMaybe xs = if null xs then Nothing else Just (last xs)
    eventKeys =
        [hexText k | Trace _ (What (KeySeen k _ _)) <- events]
            <> [hexText k | Trace _ (What (Folded _ k _)) <- events]
            <> [hexText k | Trace _ (What (Updated k _)) <- events]
            <> [hexText k | Trace scope _ <- events, InKey k <- scope]
    eventRequests =
        [r | Trace _ (What (RequestSeen r _ _ _ _)) <- events]
            <> [r | Trace _ (What (Booked r _)) <- events]
            <> [r | Trace _ (What (Reclaimed r _)) <- events]
            <> concat [rs | Trace _ (What (Rejected rs)) <- events]
            <> [r | Trace scope _ <- events, InRequest r <- scope]
    eventEdges =
        [a | Trace _ (What (EdgeStarted a)) <- events]
            <> [a | Trace scope _ <- events, InEdge a <- scope]
            <> [Folding e | Trace _ (What (Folded e _ _)) <- events]
    eventTxs =
        [ (s, t, observedOnly)
        | Trace _ (How (Tx e)) <- events
        , let observedOnly = case e of
                TxObserved{} -> True
                _ -> False
        , Just (s, t) <- [txOf e]
        ]
    txOf = \case
        TxBuilt{} -> Nothing
        TxSigned s t _ _ _ -> Just (s, t)
        TxSubmitted{submitStep = s, submitTxId = t} -> Just (s, t)
        TxConfirmed s t _ _ -> Just (s, t)
        TxObserved s t _ -> Just (s, t)
    signed s t = \case
        Trace _ (How (Tx (TxSigned s' t' _ _ _))) -> (s', t') == (s, t)
        _ -> False
    submitted s t = \case
        Trace _ (How (Tx TxSubmitted{submitStep = s', submitTxId = t'})) -> (s', t') == (s, t)
        _ -> False
    observedEvent s t = \case
        Trace _ (How (Tx (TxObserved s' t' _))) -> (s', t') == (s, t)
        _ -> False
    verdictsOf t =
        [ Left v
        | Trace _ (How (Tx TxSubmitted{submitTxId = t', submitVerdict = v})) <-
            events
        , t' == t
        ]
            <> [ Right v | Trace _ (How (Tx (TxConfirmed _ t' _ v))) <- events, t' == t
               ]
    consistent v c = case (v, c) of
        (Left Accepted, Just x) ->
            x
                `elem` ["acknowledged", "timeout", "included", "rolled-back", "excluded"]
        (Left LedgerRefusedIt, Just x) -> x == "rejected"
        (Left WrongNetwork, Just x) -> x == "rejected"
        (Left ProviderFailed, Just x) -> x == "unknown"
        (Left (SubmitThrew _), Just x) -> x == "unknown"
        (Right Confirmed, Just x) -> x `elem` ["included", "rolled-back", "excluded"]
        (Right ConfirmTimedOut, Just x) -> x == "timeout"
        (Right (ConfirmFailed _), Just x) -> x == "timeout"
        (Right (ConfirmThrew _), Just x) -> x == "timeout"
        (_, Nothing) -> False

hexText :: BS.ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

{- | One contradiction planted per fact a stream carries, wherever the
receipt binds that fact: each altered stream must disagree with the
unaltered receipt. Every event is altered in each fact it carries, its
scopes included; an observation is also removed. A refusal is altered only to
kinds its outcome cannot stand under.
-}
alterations :: Aeson.Value -> [Trace] -> [(String, [Trace])]
alterations receipt events =
    [ ( label
      , [if i == n then e' else x | (i, x) <- zip [0 :: Int ..] events]
      )
    | (n, e) <- zip [0 ..] events
    , (label, e') <- alter e <> scoped e
    ]
        <> [ ( "observation removed"
             , [x | (i, x) <- zip [0 :: Int ..] events, i /= n]
             )
           | (n, Trace _ (How (Tx TxObserved{}))) <- zip [0 ..] events
           ]
        <> [ ( "refusal removed"
             , [x | (i, x) <- zip [0 :: Int ..] events, i /= n]
             )
           | refusalOutcome outcome
           , (n, Trace _ (What (Refused{}))) <- zip [0 ..] events
           ]
        <> [ ( "refusal repeated"
             , concat
                [if i == n then [x, x] else [x] | (i, x) <- zip [0 :: Int ..] events]
             )
           | (n, Trace _ (What (Refused{}))) <- zip [0 ..] events
           ]
  where
    outcome = textAt "outcome" receipt
    bound k = isJust (valueAt k receipt)
    deadlineOf r =
        listToMaybe
            [ d
            | f <- requestFacts receipt
            , factRequest f == r
            , Just d <- [factDeadline f]
            ]
    flipText t = if T.take 1 t == "0" then "1" <> T.drop 1 t else "0" <> T.drop 1 t
    flipBytes b = "x" <> b
    otherEdge = \case
        Booking e -> Booking (e <> "x")
        Folding e -> Folding (e <> "x")
        Reclaiming e -> Reclaiming (e <> "x")
        Updating -> Rejecting
        _ -> Updating
    scoped (Trace scope event) =
        [ (label, Trace (outer <> [s'] <> inner) event)
        | (k, s) <- zip [0 :: Int ..] scope
        , let (outer, rest) = splitAt k scope
              inner = drop 1 rest
        , (label, s') <- case s of
            InKey key -> [("scope key", InKey (flipBytes key))]
            InRequest r -> [("scope request", InRequest (flipText r))]
            InEdge a -> [("scope edge", InEdge (otherEdge a))]
            _ -> []
        ]
    alter (Trace scope event) = case event of
        What (CommandEnded c o ms) ->
            [ ("outcome", Trace scope (What (CommandEnded c (o <> "-altered") ms)))
            , ("command", Trace scope (What (CommandEnded (c <> "-altered") o ms)))
            ]
        What (KeySeen k l h) ->
            [("key", Trace scope (What (KeySeen (flipBytes k) l h)))]
                <> [ ("leaf", Trace scope (What (KeySeen k (l <> "x") h)))
                   | bound "leaf"
                   ]
                <> [ ( "holding"
                     , Trace scope (What (KeySeen k l (maybe (Just "x") (const Nothing) h)))
                     )
                   | bound "applicationOutput"
                   ]
        What (RegistrySeen st r p) ->
            [ ("pending", Trace scope (What (RegistrySeen st r ((+ 1) <$> p))))
            | isJust p
            , bound "pendingRequests"
            ]
                <> [ ("registry root", Trace scope (What (RegistrySeen st (flipText r) p)))
                   | bound "root"
                   ]
        What (RequestSeen r e k d s) ->
            [ ("request", Trace scope (What (RequestSeen (flipText r) e k d s)))
            ,
                ( "request key"
                , Trace scope (What (RequestSeen r e (flipBytes k) d s))
                )
            , ("request edge", Trace scope (What (RequestSeen r (e <> "x") k d s)))
            ]
                <> [ ( "request deadline"
                     , Trace scope (What (RequestSeen r e k ((+ 1) <$> d) s))
                     )
                   | isJust d
                   , isJust (deadlineOf r)
                   ]
        What (EdgeStarted a) -> [("edge started", Trace scope (What (EdgeStarted (otherEdge a))))]
        What (Booked r d) ->
            [("booked request", Trace scope (What (Booked (flipText r) d)))]
                <> [ ("booked deadline", Trace scope (What (Booked r ((+ 1) <$> d))))
                   | isJust d
                   , isJust (deadlineOf r)
                   ]
        What (Folded e k o) ->
            [ ("fold edge", Trace scope (What (Folded (e <> "x") k o)))
            , ("fold key", Trace scope (What (Folded e (flipBytes k) o)))
            , ("fold output", Trace scope (What (Folded e k (flipText o))))
            ]
        What (Updated k o) ->
            [ ("update key", Trace scope (What (Updated (flipBytes k) o)))
            , ("update output", Trace scope (What (Updated k (flipText o))))
            ]
        What (Rejected rs) ->
            [ ("rejected request", Trace scope (What (Rejected (map flipText rs))))
            ]
                <> [ ("rejected dropped", Trace scope (What (Rejected (drop 1 rs))))
                   | not (null rs)
                   ]
        What (Reclaimed r v) ->
            [ ("reclaimed request", Trace scope (What (Reclaimed (flipText r) v)))
            , ("reclaimed amount", Trace scope (What (Reclaimed r (v + 1))))
            ]
        What (Created t s) ->
            [ ("token", Trace scope (What (Created (flipText t) s)))
            , ("created state", Trace scope (What (Created t (flipText s))))
            ]
        What (RootSeen b a) -> [("root", Trace scope (What (RootSeen b (flipText a))))]
        What (Refused _ c) ->
            [ ("refusal kind", Trace scope (What (Refused k' c)))
            | k' <- [minBound .. maxBound]
            , not (refusalFits k' outcome)
            ]
        How (Tx (TxSigned s t f ms end)) ->
            [
                ( "signed id"
                , Trace scope (How (Tx (TxSigned s (flipText t) f ms end)))
                )
            ]
        How (Tx x@TxSubmitted{}) ->
            [ ("submitted verdict", Trace scope (How (Tx x{submitVerdict = v})))
            | v <- [Accepted, LedgerRefusedIt, ProviderFailed]
            , v /= submitVerdict x
            ]
        How (Tx (TxConfirmed s t ms v)) ->
            [ ("confirmed verdict", Trace scope (How (Tx (TxConfirmed s t ms v'))))
            | v' <- [Confirmed, ConfirmTimedOut]
            , v' /= v
            ]
        How (Tx (TxObserved s t ms)) ->
            [ ("observed step", Trace scope (How (Tx (TxObserved (s <> "x") t ms))))
            ]
        _ -> []

-- Standard streams
-- ---------------------------------------------------------

captured :: IO a -> IO (a, BS.ByteString, BS.ByteString)
captured act = withSystemTempDirectory "command-run-captured" $ \dir -> do
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

-- | What a run ended with: its label, outcome class and exit status.
summary :: Run -> (String, Maybe Text, ExitCode)
summary r = (runLabel r, outcomeOf (runReceipt r), runExit r)

-- | A sink writing to a handle that is already closed.
closedHandleSink :: IO (Tracer IO Trace)
closedHandleSink = do
    (path, h) <- openTempFile "/tmp" "closed-sink"
    hClose h
    removeFile path
    pure (Tracer (hPrint h))

-- | Every fact 'alterations' plants a contradiction in.
plantedFacts :: [String]
plantedFacts =
    [ "outcome"
    , "command"
    , "key"
    , "leaf"
    , "holding"
    , "pending"
    , "registry root"
    , "request"
    , "request key"
    , "request edge"
    , "request deadline"
    , "edge started"
    , "booked request"
    , "booked deadline"
    , "fold edge"
    , "fold key"
    , "fold output"
    , "update key"
    , "update output"
    , "token"
    , "created state"
    , "root"
    , "refusal kind"
    , "signed id"
    , "submitted verdict"
    , "confirmed verdict"
    , "observed step"
    , "observation removed"
    , "refusal removed"
    , "refusal repeated"
    , "scope key"
    , "scope request"
    , "scope edge"
    ]

-- | The journal steps that act on an edge: boot, book, fold, update.
edgeSteps :: [Text]
edgeSteps = ["boot", "book", "fold", "update"]

{- | A mechanic that belongs to its transaction once its build has decided
where it is placed: an evaluation, the build, the signing, submission,
confirmation and readback. Reads before the decision are not.
-}
mechanicOfItsTransaction :: How -> Bool
mechanicOfItsTransaction = \case
    Read (Evaluated _) -> True
    Tx _ -> True
    _ -> False

-- | Whether a receipt's outcome is a refusal: its stream carries exactly one refusal event.
refusalOutcome :: Maybe Text -> Bool
refusalOutcome = (`elem` map Just ["client-refusal", "ledger-refusal"])

-- A fold receipt's settled list holds exactly the one pending request.
settledListSingletonRow :: Spec
settledListSingletonRow = describe
    "a fold receipt's settled list holds exactly the one pending request"
    $ do
        it "reports a fold that settled two requests where one was pending" $ do
            let twoEntry =
                    Aeson.object
                        [ "command" .= ("fold" :: Text)
                        , "settled"
                            .= [ Aeson.object ["request" .= ("a#0" :: Text)]
                               , Aeson.object ["request" .= ("b#0" :: Text)]
                               ]
                        ]
            disagreements Nothing twoEntry []
                `shouldSatisfy` any (T.isInfixOf "settled list" . T.pack)
        it "reports nothing about the settled list for a fold of one" $ do
            let oneEntry =
                    Aeson.object
                        [ "command" .= ("fold" :: Text)
                        , "settled" .= [Aeson.object ["request" .= ("a#0" :: Text)]]
                        ]
            disagreements Nothing oneEntry []
                `shouldSatisfy` (not . any (T.isInfixOf "settled list" . T.pack))

-- ---------------------------------------------------------
-- The external signer on the writes
-- ---------------------------------------------------------

{- | Each open-datum write that takes the external signer — insert alone or
with the fold, update, terminate alone or with the fold, and fold — is run
with an address and a new bundle file while the key file is hidden, then
by the key file over the same chain: the key-file run is the oracle for
the bundle's bodies and for the receipt's fields. Nothing here claims a
script or a ledger rule accepts these transactions.
-}
externalWriteRows :: Spec
externalWriteRows =
    describe "the external signer on the open-datum writes" $ do
        forM_ shapes $ \shape ->
            describe (shapeName shape) $
                aroundAll (stagingOf shape) (stagedShapeRows shape)
        externalCreateRows
        keyFileNeedsItsKeyRow
        refusalsWriteNoBundleRows
        pendingBundleRows

{- | The rows every staged scenario owes, whichever command it runs: the
bundle, the bodies against the key-file path's, the journal, the receipt and
the narration.
-}
stagedShapeRows :: Shape -> SpecWith Staging
stagedShapeRows shape = do
    it "ends with waiting-for-signatures, status 19, and sends nothing" $
        \st -> do
            ( runExit (stStaged st)
                , outcomeOf (runReceipt (stStaged st))
                , textAt "reason" (runReceipt (stStaged st))
                )
                `shouldBe` ( ExitFailure 19
                           , Just "waiting-for-signatures"
                           , Nothing
                           )
            stWalletAfter st `shouldBe` stWalletBefore st
    it "writes exactly one bundle holding the whole chain in build order" $
        \st -> do
            (_, bundle, bodies) <- bundleOf st
            bundleCommand bundle `shouldBe` shapeCommand shape
            length bodies `shouldBe` shapeBodies shape
            [bundleTxIdentity entry | entry <- toList (bundleTransactions bundle)]
                `shouldBe` map bodyIdentity bodies
            summarySteps (runReceipt (stStaged st))
                `shouldBe` stKeySteps st
            chainedInOrder bodies
                `shouldBe` True
    it
        "builds the bodies the key-file path builds once every earlier body has landed"
        $ \st -> do
            (_, _, bodies) <- bundleOf st
            length (stKeyBodies st) `shouldBe` shapeBodies shape
            map (^. bodyTxL) (canonicalChain (clockChosen shape) bodies)
                `shouldBe` map (^. bodyTxL) (canonicalChain (clockChosen shape) (stKeyBodies st))
    it
        "binds what the body comparison sets aside to the bodies themselves"
        $ \st -> do
            (_, _, bodies) <- bundleOf st
            unboundFields
                (stParams st)
                (stStagedWindow st)
                (clockChosen shape)
                bodies
                `shouldBe` []
            unboundFields
                (stParams st)
                (stKeyWindow st)
                (clockChosen shape)
                (stKeyBodies st)
                `shouldBe` []
    it
        "saves the bundle and each unsigned body beside the journal, one waiting line per transaction"
        $ \st -> do
            (bytes, bundle, bodies) <- bundleOf st
            let waiting = [e | e <- stJournal st, journalEvent e == "waiting-for-signatures"]
                bundleHash = hashOfBytes bytes
            map journalEvent (stJournal st)
                `shouldBe` replicate (length bodies) "waiting-for-signatures"
            map journalTxId waiting `shouldBe` map txIdHex bodies
            forM_ (zip3 waiting (toList (bundleTransactions bundle)) bodies) $
                \(e, entry, _) -> do
                    journalDetail e `shouldBe` Just bundleHash
                    raw <- savedRaw e
                    journalBodyHash e `shouldBe` Just (hashOfBytes raw)
                    B16.encode raw
                        `shouldBe` TE.encodeUtf8 (envelopeCborHex (bundleTxEnvelope entry))
            saved <- case textAt "saved" =<< valueAt "bundle" (runReceipt (stStaged st)) of
                Just p -> pure (T.unpack p)
                Nothing -> fail "no saved bundle path in the receipt"
            BS.readFile saved `shouldReturn` bytes
    it "opens no key file" $
        \st -> do
            hiddenKey st `shouldReturn` True
            runExit (stStaged st) `shouldBe` ExitFailure 19
    it
        "states open-datum's own fields under expected, none at the top level"
        $ \st -> do
            expected <- case valueAt "expected" (runReceipt (stStaged st)) of
                Just v@(Aeson.Object _) -> pure v
                other -> fail ("no expected fields: " <> show other)
            let own =
                    [ k
                    | k <- KeyMap.keys (fieldsOfReceipt (runReceipt (stKeyFile st)))
                    , k `notElem` ["command", "outcome", "reconciled", "submissions"]
                    ]
            own `shouldNotBe` []
            forM_ own $ \k -> do
                valueAt k (runReceipt (stStaged st)) `shouldBe` Nothing
                valueAt k expected `shouldNotBe` Nothing
    unless (null (shapeOwnDone shape)) $
        it "narrates none of open-datum's own done events for what it staged" $
            \st -> do
                ownDone shape (runEvents (stStaged st)) `shouldBe` []
                nub (ownDone shape (runEvents (stKeyFile st)))
                    `shouldMatchList` shapeOwnDone shape
    it "leaves the key-file receipt unchanged" $
        \st -> do
            runExit (stKeyFile st) `shouldBe` ExitSuccess
            outcomeOf (runReceipt (stKeyFile st)) `shouldBe` Just "success"
            valueAt "expected" (runReceipt (stKeyFile st)) `shouldBe` Nothing
            valueAt "bundle" (runReceipt (stKeyFile st)) `shouldBe` Nothing

-- | How the wallet is funded for a shape.
data Funding = PlainFunding | TokenOnlyFunding

-- | One command shape, run as a staged external run and then by the key file.
data Shape = Shape
    { shapeName :: String
    , shapeCommand :: Text
    -- ^ The command's name in its journal and its bundle
    , shapeBodies :: Int
    -- ^ How many transactions its whole chain holds
    , shapeFunding :: Funding
    , shapeOwnDone :: [Done]
    -- ^ The done events its own entry code narrates on the key-file path
    , shapeSetup :: Rig -> String -> IO [String]
    -- ^ Key-file setup over the registry, then the words the line ends with
    , shapeWords :: Rig -> [String]
    }

shapes :: [Shape]
shapes =
    [ Shape "insert" "insert" 1 PlainFunding [DoneBooked] (\_ _ -> pure []) $ \rig ->
        insertWords rig
    , Shape
        "insert from a wallet that needs a funding preparation"
        "insert"
        2
        TokenOnlyFunding
        [DoneBooked]
        (\_ _ -> pure [])
        $ \rig ->
            insertWords rig
    , Shape
        "insert with the fold"
        "insert"
        2
        PlainFunding
        [DoneBooked]
        (\_ _ -> pure [])
        $ \rig ->
            insertWords rig <> ["--fold"]
    , Shape
        "update"
        "update"
        1
        PlainFunding
        [DoneUpdated, DoneRootSeen]
        (\rig t -> [] <$ activeEntry rig t)
        $ \rig ->
            [ "open-datum"
            , "update"
            , "--key"
            , "bob-1"
            , "--payload"
            , payload2Of rig
            ]
    , Shape
        "terminate"
        "terminate"
        1
        PlainFunding
        [DoneBooked]
        (\rig t -> [] <$ activeEntry rig t)
        (const ["open-datum", "terminate", "--key", "bob-1"])
    , Shape
        "terminate with the fold"
        "terminate"
        2
        PlainFunding
        [DoneBooked]
        (\rig t -> [] <$ activeEntry rig t)
        (const ["open-datum", "terminate", "--key", "bob-1", "--fold"])
    , Shape
        "fold"
        "fold"
        1
        PlainFunding
        []
        (\rig t -> requestOf <$> pendingEntry rig t)
        (const ["open-datum", "fold"])
    , Shape
        "fold from a wallet that needs a funding preparation"
        "fold"
        2
        TokenOnlyFunding
        []
        (\rig t -> requestOf <$> pendingEntry rig t)
        (const ["open-datum", "fold"])
    ]

{- | The positions of a shape's chain whose validity closes at a slot the clock
chooses: a termination has no processing window to close at, so its fold closes
a short span after the clock, and two runs seconds apart close it seconds apart.
-}
clockChosen :: Shape -> [Int]
clockChosen shape
    | shapeName shape == "terminate with the fold" = [1]
    | otherwise = []

insertWords :: Rig -> [String]
insertWords rig =
    ["open-datum", "insert", "--key", "bob-1", "--payload", payloadOf rig]

payloadOf, payload2Of :: Rig -> FilePath
payloadOf rig = rigDir rig </> "payload.json"
payload2Of rig = rigDir rig </> "payload-2.json"

-- | Key-file setup: bob-1 booked, its request pending.
pendingEntry :: Rig -> String -> IO Run
pendingEntry rig t = do
    booked <- run rig "setup insert" (insertWords rig <> tokenArgs t)
    outcomeOf (runReceipt booked) `shouldBe` Just "success"
    pure booked

-- | Key-file setup: bob-1 booked and folded, so active.
activeEntry :: Rig -> String -> IO ()
activeEntry rig t = do
    booked <- pendingEntry rig t
    folded <-
        run
            rig
            "setup fold"
            (["open-datum", "fold"] <> requestOf booked <> tokenArgs t)
    outcomeOf (runReceipt folded) `shouldBe` Just "success"

-- | Key-file setup: bob-1 terminal.
terminalEntry :: Rig -> String -> IO ()
terminalEntry rig t = do
    activeEntry rig t
    terminated <-
        run
            rig
            "setup terminate"
            (["open-datum", "terminate", "--key", "bob-1", "--fold"] <> tokenArgs t)
    outcomeOf (runReceipt terminated) `shouldBe` Just "success"

-- | What a staged shape left: both runs, the bundle, the journal, the oracle.
data Staging = Staging
    { stRig :: Rig
    , stToken :: String
    , stStaged :: Run
    , stKeyFile :: Run
    , stBundle :: Either String (BS.ByteString, Bundle, [ConwayTx])
    , stJournal :: [JournalEntry]
    , stKeyBodies :: [ConwayTx]
    , stKeySteps :: [Text]
    , stWalletBefore :: [TxIn]
    , stWalletAfter :: [TxIn]
    , stStagedWindow :: (Integer, Integer)
    -- ^ The wall-clock milliseconds before and after the staged run
    , stKeyWindow :: (Integer, Integer)
    -- ^ The same for the key-file run
    , stParams :: PParams ConwayEra
    -- ^ The chain's protocol parameters, whose cost models the script data hash covers
    }

-- | The directory a staged run of this state root resolves for the rig's wallet.
stagedPartition :: Rig -> FilePath -> String -> FilePath
stagedPartition rig root tokenStr =
    managedDir
        (rigDir rig </> root)
        (fromIntegral magic)
        token
        (addressPartition (walletAddr (rigWallet rig)))
  where
    token = case parseStateToken (T.pack tokenStr) of
        Right t -> t
        Left why -> error ("stagedPartition: " <> T.unpack why)

-- | The external signer's flags for the rig's own wallet.
externalArgs :: Rig -> FilePath -> [String]
externalArgs rig bundlePath =
    [ "--wallet-address"
    , bech32Address (walletAddr (rigWallet rig))
    , "--bundle"
    , bundlePath
    ]

-- | Where the staged run's state root and bundle file live in the rig.
stagedRoot :: FilePath
stagedRoot = "bob-external"

stagedBundlePath :: Rig -> FilePath
stagedBundlePath rig = rigDir rig </> "bob.bundle"

hiddenKeyPath :: Rig -> FilePath
hiddenKeyPath rig = rigKey rig <> ".hidden"

-- | The wallet's unspent outputs, as the chain holds them now.
walletRefs :: Rig -> IO [TxIn]
walletRefs rig =
    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
        map fst <$> SessionIO.outputsAt v (walletAddr (rigWallet rig))

-- | The line run by the staged external run, with the key file hidden during it.
runHidden :: Rig -> String -> [String] -> IO Run
runHidden rig label line = do
    renameFile (rigKey rig) (hiddenKeyPath rig)
    runAt
        rig
        stagedRoot
        label
        (line <> externalArgs rig (stagedBundlePath rig))
        `finally` renameFile (hiddenKeyPath rig) (rigKey rig)

-- | Whether the key file was hidden for the staged run: it is restored after.
hiddenKey :: Staging -> IO Bool
hiddenKey st =
    (&&)
        <$> doesFileExist (rigKey (stRig st))
        <*> (not <$> doesFileExist (hiddenKeyPath (stRig st)))

-- | Run a shape once: staged without a key, then by the key file over the same chain.
stagingOf :: Shape -> (Staging -> IO ()) -> IO ()
stagingOf shape use = withRig $ \rig -> do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    t <- tokenOf create
    extra <- shapeSetup shape rig t
    case shapeFunding shape of
        PlainFunding -> pure ()
        TokenOnlyFunding -> tokenOnlyWallet rig
    let line = shapeWords shape rig <> extra <> tokenArgs t
    walletBefore <- walletRefs rig
    (stagedWindow, staged) <- windowed (runHidden rig "staged" line)
    walletAfter <- walletRefs rig
    (keyWindow, keyFile) <-
        windowed (runVia rig (envPinned rig) "registry" "key file" line)
    params <-
        SessionIO.withLatest
            (rawChainProvider (rigChain rig))
            SessionIO.parameters
    journal <- journalAt (stagedPartition rig stagedRoot t)
    keyJournal <- journalAt (stagedPartition rig "registry" t)
    let prepared =
            [ e
            | e <- keyJournal
            , journalEvent e == "prepared"
            , journalCommand e == shapeCommand shape
            ]
    keyBodies <-
        forM prepared $ \e -> do
            (_, body) <- boundBody keyJournal (journalTxId e)
            either (fail . T.unpack) pure body
    bundle <- readBundle (stagedBundlePath rig)
    use
        Staging
            { stRig = rig
            , stToken = t
            , stStaged = staged
            , stKeyFile = keyFile
            , stBundle = bundle
            , stJournal = journal
            , stKeyBodies = keyBodies
            , stKeySteps = map journalStep prepared
            , stWalletBefore = walletBefore
            , stWalletAfter = walletAfter
            , stStagedWindow = stagedWindow
            , stKeyWindow = keyWindow
            , stParams = params
            }

-- | The journal of a partition, empty when nothing was ever written to it.
journalAt :: FilePath -> IO [JournalEntry]
journalAt dir = do
    present <- doesFileExist (journalPath dir)
    if present then readJournal dir else pure []

-- | A bundle refusal as the text that names it.
renderRefusal :: Either BundleRefusal a -> Either String a
renderRefusal = either (Left . renderBundleRefusal) Right

-- | The bundle at a path, checked, with every body decoded; why not, when it is absent or unsound.
readBundle
    :: FilePath -> IO (Either String (BS.ByteString, Bundle, [ConwayTx]))
readBundle path = do
    present <- doesFileExist path
    if not present
        then pure (Left ("no bundle file at " <> path))
        else do
            bytes <- BS.readFile path
            pure $ do
                bundle <- renderRefusal (decodeBundle bytes)
                renderRefusal (checkBundle bundle)
                bodies <-
                    forM
                        (toList (bundleTransactions bundle))
                        (decodeTransactionEnvelope . bundleTxEnvelope)
                pure (bytes, bundle, bodies)

bundleOf :: Staging -> IO (BS.ByteString, Bundle, [ConwayTx])
bundleOf st =
    either (\why -> expectationFailure why >> fail why) pure (stBundle st)

hashOfBytes :: BS.ByteString -> Text
hashOfBytes bytes = hexText (hashToBytes (hashWith @Blake2b_256 id bytes))

-- | The raw CBOR a waiting line's saved body file holds.
savedRaw :: JournalEntry -> IO BS.ByteString
savedRaw e = do
    path <-
        maybe (fail "the line names no saved body") pure (journalBody e)
    stored <- BS.readFile path
    either
        (fail . ("the saved body is not hex: " <>))
        pure
        (B16.decode (BC.filter (/= '\n') stored))

{- | A chain of bodies as the oracle compares it. Three things follow the
wall clock, directly or through the hash of a body that carries it, and are
set aside: the submission time inside a request datum (the booking reads the
clock); the id of an earlier body of the chain, named by its position instead
(an id is the hash of a body); and the script data hash (it covers the
redeemers, whose indices follow the sorted inputs, hence the ids). A fourth,
the upper end of a validity interval the clock chooses (a termination fold has
no window to close at, so it closes a short span after the clock), is set aside
at the positions the caller names. Nothing else is set aside, the validity
interval included: every body of both chains is built at the one slot, so the
booked time, the nonce both tags commit to and the interval follow the slot
and are compared as they come. 'unboundFields' binds each of these to the body
that carries it, so that setting them aside here hides no defect.
-}
canonicalChain :: [Int] -> [ConwayTx] -> [ConwayTx]
canonicalChain clocked bodies = zipWith canonical [0 :: Int ..] bodies
  where
    earlier = zip (map txIdTx bodies) [0 :: Int ..]
    positioned (TxIn spent ix) = case lookup spent earlier of
        Just k -> TxIn (placeholderId k) ix
        Nothing -> TxIn spent ix
    placeholderId k = case parseOutRef (T.pack (replicate 63 'e' <> show k <> "#0")) of
        Right (TxIn tid _) -> tid
        Left why -> error ("canonicalChain: " <> why)
    closedByClock k
        | k `elem` clocked =
            bodyTxL . vldtTxBodyL %~ \(ValidityInterval lower _) -> ValidityInterval lower SNothing
        | otherwise = id
    canonical k tx =
        tx
            & bodyTxL . inputsTxBodyL %~ Set.map positioned
            & bodyTxL . referenceInputsTxBodyL %~ Set.map positioned
            & bodyTxL . collateralInputsTxBodyL %~ Set.map positioned
            & bodyTxL . scriptIntegrityHashTxBodyL .~ SNothing
            & closedByClock k
            & bodyTxL . outputsTxBodyL %~ fmap unsubmitted
    unsubmitted out = case extractCageDatum out of
        Just (RequestDatum r) ->
            out
                & datumTxOutL
                    .~ mkInlineDatum (toPlcData (RequestDatum r{requestSubmittedAt = 0}))
        _ -> out

-- | The steps a receipt's bundle summary names, in order.
summarySteps :: Aeson.Value -> [Text]
summarySteps receipt = case valueAt "bundle" receipt >>= valueAt "transactions" of
    Just (Aeson.Array txs) -> mapMaybe (textAt "step") (toList txs)
    _ -> []

-- | Every body after the first spends an output an earlier body made.
chainedInOrder :: [ConwayTx] -> Bool
chainedInOrder bodies =
    and
        [ any
            (\(TxIn spent _) -> spent `elem` map txIdTx (take k bodies))
            (Set.toList (body ^. bodyTxL . inputsTxBodyL))
        | (k, body) <- zip [0 ..] bodies
        , k > 0
        ]

fieldsOfReceipt :: Aeson.Value -> Aeson.Object
fieldsOfReceipt = \case
    Aeson.Object o -> o
    _ -> KeyMap.empty

-- | The events open-datum's entry code narrates to say a transaction is done.
data Done = DoneBooked | DoneUpdated | DoneRootSeen
    deriving stock (Eq, Ord, Show)

-- | The done events of this kind-list a trace holds, in order.
ownDone :: Shape -> [Trace] -> [Done]
ownDone shape events =
    [ d
    | Trace _ (What w) <- events
    , Just d <- [doneOf w]
    , d `elem` shapeOwnDone shape
    ]
  where
    doneOf = \case
        Booked{} -> Just DoneBooked
        Updated{} -> Just DoneUpdated
        RootSeen{} -> Just DoneRootSeen
        _ -> Nothing

{- | The wallet's ada-only lovelace held in one output that carries a token, so
no output is ada-only; the published reference outputs stay where they are.
-}
tokenOnlyWallet :: Rig -> IO ()
tokenOnlyWallet rig = do
    held <- adaOnlyHeld rig
    let total = sum [c | (_, o) <- held, let Coin c = o ^. coinTxOutL]
        holder = case hashFromBytes (BS.replicate 28 3) of
            Just h -> ScriptHash h
            Nothing -> error "tokenOnlyWallet: 28 bytes are not a hash"
        asset =
            MultiAsset
                (Map.singleton (PolicyID holder) (Map.singleton (AssetName "") 1))
        made =
            mkBasicTxOut
                (walletAddr (rigWallet rig))
                (MaryValue (Coin total) asset)
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.insert
                    (fundOutput 99)
                    made
                    (foldr (Map.delete . fst) (csUTxO facts) held)
            }

-- | A key-file write with its key file hidden is refused: the control that makes hiding it meaningful.
keyFileNeedsItsKeyRow :: Spec
keyFileNeedsItsKeyRow =
    it
        "a key-file write with the key file hidden is refused, so hiding it shows the external run reads none"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            renameFile (rigKey rig) (hiddenKeyPath rig)
            refused <-
                run rig "key file hidden" (insertWords rig <> tokenArgs t)
                    `finally` renameFile (hiddenKeyPath rig) (rigKey rig)
            runExit refused `shouldNotBe` ExitSuccess
            runExit refused `shouldNotBe` ExitFailure 19

-- | Whether the registry a refusal row creates is open or closed.
data Mode = OpenMode | ClosedMode

-- | The blueprint a mode needs: the closed mode also carries its own validator.
blueprintFor :: Mode -> Aeson.Value
blueprintFor = \case
    OpenMode -> syntheticBlueprint
    ClosedMode ->
        blueprintWith [("open_datum.closed_datum", 2)] $ \title arity ->
            if title == "open_datum.closed_datum"
                then distinctUnitProgram arity
                else unitProgram arity

{- | An accept-all program of this many parameters whose code differs from
'unitProgram', so its script hash does: the closed validator must not share
the open one's hash, or the registry's mode could not tell them apart.
-}
distinctUnitProgram :: Int -> SBS.ShortByteString
distinctUnitProgram parameters =
    PLC.serialiseUPLC $
        UPLC.Program () plcVersion110 $
            iterate (UPLC.LamAbs () (UPLC.DeBruijn 0)) applied !! parameters
  where
    applied =
        UPLC.Apply
            ()
            (UPLC.LamAbs () (UPLC.DeBruijn 0) (mkConstant () ()))
            (mkConstant () (0 :: Integer))

{- | open-datum's own refusals before signing: each line is refused by the
key-file path too, and under the external signer it leaves no bundle file
and no journal line, and the wallet untouched.
-}
refusalsWriteNoBundleRows :: Spec
refusalsWriteNoBundleRows =
    describe "refuses before signing and writes no bundle" $ do
        refusalRow
            "an update on a closed registry"
            ClosedMode
            "is closed"
            activeEntry
            updateWords
        refusalRow
            "an update of a key nobody inserted"
            OpenMode
            "is not registered"
            (\_ _ -> pure ())
            updateWords
        refusalRow
            "a terminate of a key nobody inserted"
            OpenMode
            "is not registered"
            (\_ _ -> pure ())
            terminateWords
        refusalRow
            "an insert of a terminal key"
            OpenMode
            "already retired"
            terminalEntry
            insertWords
        refusalRow
            "an update of a terminal key"
            OpenMode
            "already retired"
            terminalEntry
            updateWords
        refusalRow
            "a terminate of a terminal key"
            OpenMode
            "already retired"
            terminalEntry
            terminateWords
        refusalRow
            "an insert whose outlay is over its ceiling"
            OpenMode
            "passes the approved allowance"
            (\_ _ -> pure ())
            (\rig -> insertWords rig <> ["--max-outlay", "1"])
        refusalRow
            "an update whose outlay is over its ceiling"
            OpenMode
            "passes the approved allowance"
            activeEntry
            (\rig -> updateWords rig <> ["--max-outlay", "1"])
        refusalRow
            "an insert from a wallet that cannot fund it"
            OpenMode
            "has no ada-only output"
            (\rig _ -> emptyWallet rig)
            insertWords
        refusalRow
            "a fold with nothing pending"
            OpenMode
            "nothing is pending"
            (\_ _ -> pure ())
            (const ["open-datum", "fold"])
  where
    updateWords rig =
        [ "open-datum"
        , "update"
        , "--key"
        , "bob-1"
        , "--payload"
        , payload2Of rig
        ]
    terminateWords _ = ["open-datum", "terminate", "--key", "bob-1"]

refusalRow
    :: String
    -> Mode
    -> Text
    -> (Rig -> String -> IO ())
    -> (Rig -> [String])
    -> Spec
refusalRow name mode fragment prepare wordsOf =
    it name $
        withRigOf (blueprintFor mode) pure $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    ( ["open-datum", "create", "--seed", seed]
                        <> ["--closed" | ClosedMode <- [mode]]
                    )
            t <- tokenOf create
            prepare rig t
            walletBefore <- walletRefs rig
            let line = wordsOf rig <> tokenArgs t
            keyFile <- run rig "key file" line
            staged <- runHidden rig "staged" line
            walletAfter <- walletRefs rig
            runExit keyFile `shouldNotBe` ExitSuccess
            textAt "reason" (runReceipt keyFile)
                `shouldSatisfy` maybe False (T.isInfixOf fragment)
            textAt "reason" (runReceipt staged)
                `shouldBe` textAt "reason" (runReceipt keyFile)
            runExit staged `shouldBe` runExit keyFile
            outcomeOf (runReceipt staged)
                `shouldBe` outcomeOf (runReceipt keyFile)
            doesPathExist (stagedBundlePath rig) `shouldReturn` False
            journalAt (stagedPartition rig stagedRoot t) `shouldReturn` []
            walletAfter `shouldBe` walletBefore

{- | The wallet's ada-only outputs removed: it holds nothing to fund a write
with, its published reference outputs apart.
-}
emptyWallet :: Rig -> IO ()
emptyWallet rig = do
    held <- adaOnlyHeld rig
    advanceChain (rigChain rig) $ \facts ->
        facts{csUTxO = foldr (Map.delete . fst) (csUTxO facts) held}

-- | The wallet's ada-only outputs: what a write is funded from.
adaOnlyHeld :: Rig -> IO [(TxIn, TxOut ConwayEra)]
adaOnlyHeld rig =
    filter (adaOnlyOut . snd)
        <$> SessionIO.withLatest
            (rawChainProvider (rigChain rig))
            (\v -> SessionIO.outputsAt v (walletAddr (rigWallet rig)))

-- | The wall-clock milliseconds before and after an action, with what it returned.
windowed :: IO a -> IO ((Integer, Integer), a)
windowed action = do
    before' <- posixMs
    result <- action
    after' <- posixMs
    pure ((before', after'), result)
  where
    posixMs = floor . (* 1000) <$> getPOSIXTime

{- | What binds each field 'canonicalChain' sets aside to the body that
carries it; empty when every one holds. Each check reads the body and the
chain only, never the other side of the comparison:

* the script data hash is the hash of the body's own redeemers, datums and the
  protocol parameters' cost model, or absent exactly when the body has none;
* a request datum's submission time lies within the wall-clock window of the
  run that built the body, read by the test's own clock;
* an input that names an earlier member of the chain names an output that
  member has, and a member earlier than the body that spends it;
* a validity interval the clock closes opens before it closes (it opens at the
  slot the chain stood at) and closes after the run's window opens and no
  later than the longest span the fold tries past its end. The synthetic time keeps one-second slots from
  the epoch, so a slot is a thousand milliseconds.
-}
unboundFields
    :: PParams ConwayEra
    -> (Integer, Integer)
    -> [Int]
    -> [ConwayTx]
    -> [String]
unboundFields pp (opened, closed) clocked bodies = concat (zipWith check [0 :: Int ..] bodies)
  where
    ids = zip (map txIdTx bodies) [0 :: Int ..]
    outputCounts = map (length . (^. bodyTxL . outputsTxBodyL)) bodies
    check k tx =
        integrity k tx
            <> submissions k tx
            <> positions k tx
            <> closing k tx
            <> booked k tx
    integrity k tx =
        let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
            TxDats datums = tx ^. witsTxL . datsTxWitsL
            wanted
                | Map.null declared && Map.null datums = SNothing
                | otherwise =
                    SJust
                        ( hashScriptIntegrity
                            ( ScriptIntegrity
                                (tx ^. witsTxL . rdmrsTxWitsL)
                                (tx ^. witsTxL . datsTxWitsL)
                                (Set.singleton (getLanguageView pp PlutusV3))
                            )
                        )
        in  [ "body "
                <> show k
                <> ": its script data hash is not the hash of its own redeemers, datums and cost model"
            | tx ^. bodyTxL . scriptIntegrityHashTxBodyL /= wanted
            ]
    submissions k tx =
        [ "body "
            <> show k
            <> ": a request datum states the submission time "
            <> show submitted
            <> ", outside the run's window "
            <> show (opened, closed)
        | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
        , Just (RequestDatum r) <- [extractCageDatum out]
        , let submitted = requestSubmittedAt r
        , submitted < opened || submitted > closed
        ]
    closing k tx =
        [ "body "
            <> show k
            <> ": its validity "
            <> show interval
            <> " does not close inside the run's window "
            <> show (opened, closed)
            <> " and the longest span past it"
        | k `elem` clocked
        , let interval = tx ^. bodyTxL . vldtTxBodyL
        , not (closesInside interval)
        ]
    closesInside (ValidityInterval lower upper) = case (lower, upper) of
        (SJust (SlotNo low), SJust (SlotNo high)) ->
            low < high
                && toInteger high * 1000 >= opened
                && toInteger high * 1000 <= closed + 130_000
        _ -> False
    booked k tx =
        [ "body "
            <> show k
            <> ": a registration datum states the booked time "
            <> show (regSubmittedAt r)
            <> ", which is not the start of the upper slot of its own validity"
        | let ValidityInterval _ upper = tx ^. bodyTxL . vldtTxBodyL
        , out <- toList (tx ^. bodyTxL . outputsTxBodyL)
        , Just (RegistrationDatum r) <- [extractCageDatum out]
        , upper /= SJust (SlotNo (fromInteger (regSubmittedAt r `div` 1000)))
        ]
    positions k tx =
        [ "body "
            <> show k
            <> ": spends output "
            <> show ix
            <> " of chain member "
            <> show j
            <> ", which is not an earlier member with that output"
        | spending <-
            Set.toList (tx ^. bodyTxL . inputsTxBodyL)
                <> Set.toList (tx ^. bodyTxL . referenceInputsTxBodyL)
                <> Set.toList (tx ^. bodyTxL . collateralInputsTxBodyL)
        , let TxIn spent (TxIx ix) = spending
        , Just j <- [lookup spent ids]
        , not (j < k && toInteger ix < toInteger (outputCounts !! j))
        ]

-- ---------------------------------------------------------
-- The external signer's create
-- ---------------------------------------------------------

-- | One create scenario: the registry's mode and whether a state carrier is live.
data CreateScenario = CreateScenario
    { csName :: String
    , csMode :: Mode
    , csLiveCarrier :: Bool
    , csSteps :: [Text]
    -- ^ The steps create's whole chain holds in this scenario, in build order
    }

createScenarios :: [CreateScenario]
createScenarios =
    [ CreateScenario
        "create with the state publication"
        OpenMode
        False
        (publishing <> chain)
    , CreateScenario "create over a live state carrier" OpenMode True chain
    , CreateScenario
        "closed create with the state publication"
        ClosedMode
        False
        (publishing <> chain)
    ]
  where
    publishing = ["publish-state"]
    chain =
        [ "boot"
        , "publish-request"
        , "publish-witness-absent"
        , "publish-witness-active"
        , "publish-witness-terminal"
        , "publish-application"
        ]

createWords :: CreateScenario -> [String]
createWords sc =
    ["open-datum", "create"] <> ["--closed" | ClosedMode <- [csMode sc]]

{- | open-datum create with an address and a new bundle file builds create's
whole chain as one bundle, in the order the key-file create builds it, and
exits 19; every rule the other staged writes owe holds for it too.
-}
externalCreateRows :: Spec
externalCreateRows = describe "create" $ do
    forM_ createScenarios $ \sc ->
        describe (csName sc) $
            around (createStagingOf sc) $ do
                stagedShapeRows (createShapeOf sc)
                it
                    "builds create's whole chain in the order the key-file path builds it"
                    $ \st -> summarySteps (runReceipt (stStaged st)) `shouldBe` csSteps sc
                it "names no state token and no deadline in its bundle" $
                    \st -> do
                        (_, bundle, _) <- bundleOf st
                        bundleStateToken bundle `shouldBe` Nothing
                        [bundleTxDeadline e | e <- toList (bundleTransactions bundle)]
                            `shouldSatisfy` all isNothing
                it "records its pending identity before the bundle, and reads it back" $
                    \st -> do
                        let rig = stRig st
                        (_, bundle, bodies) <- bundleOf st
                        doesFileExist
                            (pendingPath (stagedPartition rig stagedRoot (stToken st)))
                            `shouldReturn` True
                        inspected <-
                            runAt
                                rig
                                stagedRoot
                                "inspect of the pending create"
                                ( ["open-datum", "inspect", "--key", "any"]
                                    <> tokenArgs (stToken st)
                                    <> ["--wallet-address", bech32Address (walletAddr (rigWallet rig))]
                                )
                        outcomeOf (runReceipt inspected) `shouldBe` Just "partial"
                        pendingIdentity <- case valueAt "incompleteCreate" (runReceipt inspected) of
                            Just v@(Aeson.Object _) -> pure v
                            other -> fail ("no pending identity read back: " <> show other)
                        valueAt "networkMagic" pendingIdentity
                            `shouldBe` Just (toJSON (bundleNetworkMagic bundle))
                        seedIn <- case textAt "seed" pendingIdentity of
                            Just s -> either fail pure (parseOutRef s)
                            Nothing ->
                                fail ("the pending identity names no seed: " <> show pendingIdentity)
                        case [b | b <- bodies, b ^. bodyTxL . mintTxBodyL /= mempty] of
                            boot : _ ->
                                Set.member seedIn (boot ^. bodyTxL . inputsTxBodyL) `shouldBe` True
                            [] -> expectationFailure "no staged body mints the state token"
    existingBundleCreateRow

createShapeOf :: CreateScenario -> Shape
createShapeOf sc =
    Shape
        (csName sc)
        "create"
        (length (csSteps sc))
        PlainFunding
        []
        (\_ _ -> pure [])
        (const [])

-- | Run a staged create, then the key-file create over the same chain.
createStagingOf :: CreateScenario -> (Staging -> IO ()) -> IO ()
createStagingOf sc use = withRigOf (blueprintFor (csMode sc)) pure $ \rig -> do
    seed <-
        if csLiveCarrier sc
            then do
                first' <-
                    runAt
                        rig
                        "carrier"
                        "key-file create publishing the carrier"
                        (createWords sc <> ["--seed", T.unpack (renderOutRef (fundOutput 1))])
                outcomeOf (runReceipt first') `shouldBe` Just "success"
                (\s -> ["--seed", s]) <$> fundSeed2 rig
            else pure []
    let line = createWords sc <> seed
    walletBefore <- walletRefs rig
    (stagedWindow, staged) <-
        windowed (runHidden rig "staged create" line)
    walletAfter <- walletRefs rig
    (keyWindow, keyFile) <- windowed (run rig "key file create" line)
    t <- case valueAt "expected" (runReceipt staged) >>= textAt "stateToken" of
        Just token -> pure (T.unpack token)
        Nothing -> tokenOf keyFile
    journal <- journalAt (stagedPartition rig stagedRoot t)
    keyJournal <- journalAt (stagedPartition rig "registry" t)
    let prepared =
            [ e
            | e <- keyJournal
            , journalEvent e == "prepared"
            , journalCommand e == "create"
            ]
    keyBodies <-
        forM prepared $ \e -> do
            (_, body) <- boundBody keyJournal (journalTxId e)
            either (fail . T.unpack) pure body
    bundle <- readBundle (stagedBundlePath rig)
    params <-
        SessionIO.withLatest
            (rawChainProvider (rigChain rig))
            SessionIO.parameters
    use
        Staging
            { stRig = rig
            , stToken = t
            , stStaged = staged
            , stKeyFile = keyFile
            , stBundle = bundle
            , stJournal = journal
            , stKeyBodies = keyBodies
            , stKeySteps = map journalStep prepared
            , stWalletBefore = walletBefore
            , stWalletAfter = walletAfter
            , stStagedWindow = stagedWindow
            , stKeyWindow = keyWindow
            , stParams = params
            }

existingBundleCreateRow :: Spec
existingBundleCreateRow =
    it
        "refuses an existing bundle file on create before anything is read, its bytes untouched"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            let bundlePath = rigDir rig </> "taken-create.bundle"
                sentinel = "sentinel bytes"
                refusedOnTheBundle at label = do
                    refused <-
                        runAt
                            rig
                            at
                            label
                            ( ["open-datum", "create", "--seed", seed]
                                <> externalArgs rig bundlePath
                            )
                    runExit refused `shouldBe` ExitFailure 10
                    outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
                    fromMaybe "" (textAt "reason" (runReceipt refused))
                        `shouldSatisfy` T.isInfixOf (T.pack bundlePath)
                    BS.readFile bundlePath `shouldReturn` sentinel
            BS.writeFile bundlePath sentinel
            refusedOnTheBundle
                "bob-external-create-taken"
                "staged create onto an existing bundle file"
            doesDirectoryExist (rigDir rig </> "bob-external-create-taken")
                `shouldReturn` False
            let blueprint = rigBlueprint rig
                hiddenBlueprint = blueprint <> ".hidden"
            renameFile blueprint hiddenBlueprint
            refusedOnTheBundle
                "bob-external-create-taken-blueprint"
                "staged create onto an existing bundle file, the blueprint unreadable"
                `finally` renameFile hiddenBlueprint blueprint

-- ---------------------------------------------------------
-- A pending bundle stops the next write
-- ---------------------------------------------------------

-- | What a staged write left: its run, the bundle it is waiting on and where.
data Pending = Pending
    { pgRig :: Rig
    , pgToken :: String
    , pgBundle :: Bundle
    , pgBodies :: [ConwayTx]
    , pgHash :: Text
    , pgSaved :: Text
    }

{- | A staged write of a registry left one bundle pending: key-file setup
over the registry, then the staged line with the key file hidden.
-}
pendingStaged
    :: (Rig -> String -> IO [String])
    -> (Rig -> [String])
    -> (Pending -> IO ())
    -> IO ()
pendingStaged setup stagedWords use = withRig $ \rig -> do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    t <- tokenOf create
    extra <- setup rig t
    staged <-
        runHidden rig "staged" (stagedWords rig <> extra <> tokenArgs t)
    runExit staged `shouldBe` ExitFailure 19
    (bytes, bundle, bodies) <-
        readBundle (stagedBundlePath rig) >>= either fail pure
    saved <- case textAt "saved" =<< valueAt "bundle" (runReceipt staged) of
        Just p -> pure p
        Nothing -> fail "no saved bundle path in the receipt"
    use
        Pending
            { pgRig = rig
            , pgToken = t
            , pgBundle = bundle
            , pgBodies = bodies
            , pgHash = hashOfBytes bytes
            , pgSaved = saved
            }

-- | A staged update of an active entry leaves one bundle pending.
pendingUpdate :: (Pending -> IO ()) -> IO ()
pendingUpdate = pendingStaged (\rig t -> [] <$ activeEntry rig t) updateLine

-- | A staged insert with the fold leaves one bundle of two members pending.
pendingInsertWithFold :: (Pending -> IO ()) -> IO ()
pendingInsertWithFold =
    pendingStaged
        (\_ _ -> pure [])
        (\rig -> insertWords rig <> ["--fold"])

-- | A staged fold of a pending request leaves one bundle pending; the fold has a deadline.
pendingFold :: (Pending -> IO ()) -> IO ()
pendingFold =
    pendingStaged
        (\rig t -> requestOf <$> pendingEntry rig t)
        (const ["open-datum", "fold"])

-- | An insert of a key no setup booked.
insertOtherWords :: Rig -> [String]
insertOtherWords rig =
    ["open-datum", "insert", "--key", "bob-2", "--payload", payloadOf rig]

updateLine :: Rig -> [String]
updateLine rig =
    [ "open-datum"
    , "update"
    , "--key"
    , "bob-1"
    , "--payload"
    , payload2Of rig
    ]

-- | Whether the next write names the key file or the external signer.
data NextSigner = ByKeyFile | ByExternal FilePath

signerLabel :: NextSigner -> String
signerLabel = \case
    ByKeyFile -> "by the key file"
    ByExternal _ -> "by the external signer"

pendingBundleRows :: Spec
pendingBundleRows = describe "a pending bundle stops the next write" $ do
    describe "after a staged update" $
        around pendingUpdate $
            forM_ nextWrites $ \(verb, wordsOf) ->
                forM_ [ByKeyFile, ByExternal "next.bundle"] $ \signer ->
                    it (verb <> " " <> signerLabel signer) $ \p -> do
                        let rig = pgRig p
                            stateDir = stagedPartition rig stagedRoot (pgToken p)
                            nextBundle = case signer of
                                ByExternal name -> Just (rigDir rig </> (verb <> "-" <> name))
                                ByKeyFile -> Nothing
                            signerArgs = maybe [] (externalArgs rig) nextBundle
                        journalBefore <- journalAt stateDir
                        walletBefore <- walletRefs rig
                        next <-
                            runAt
                                rig
                                stagedRoot
                                ("next " <> verb)
                                (wordsOf rig <> tokenArgs (pgToken p) <> signerArgs)
                        walletAfter <- walletRefs rig
                        journalAfter <- journalAt stateDir
                        ( runExit next
                            , outcomeOf (runReceipt next)
                            , textAt "hash" =<< valueAt "pendingBundle" (runReceipt next)
                            , textAt "saved" =<< valueAt "pendingBundle" (runReceipt next)
                            )
                            `shouldBe` ( ExitFailure 19
                                       , Just "waiting-for-signatures"
                                       , Just (pgHash p)
                                       , Just (pgSaved p)
                                       )
                        awaitedIn (runReceipt next)
                            `shouldBe` [ (txIdHex body, bodyDeadline body)
                                       | body <- pgBodies p
                                       ]
                        maybe
                            (pure ())
                            (\path -> doesPathExist path `shouldReturn` False)
                            nextBundle
                        stoppedLeavesNothingOfItsOwn journalBefore journalAfter
                        walletAfter `shouldBe` walletBefore
    describe
        "after a staged insert with the fold, its booking found on chain"
        $ around pendingInsertWithFold
        $ forM_ [ByKeyFile, ByExternal "partial.bundle"]
        $ \signer ->
            it ("the next insert " <> signerLabel signer) $ \p -> do
                let rig = pgRig p
                    stateDir = stagedPartition rig stagedRoot (pgToken p)
                    nextBundle = case signer of
                        ByExternal name -> Just (rigDir rig </> name)
                        ByKeyFile -> Nothing
                (booking, fold) <- case pgBodies p of
                    [b, f] -> pure (b, f)
                    other ->
                        fail
                            ( "the staged insert with the fold holds "
                                <> show (length other)
                                <> " bodies"
                            )
                landBodies rig [booking]
                journalBefore <- journalAt stateDir
                walletBefore <- walletRefs rig
                next <-
                    runAt
                        rig
                        stagedRoot
                        "next insert, the booking landed"
                        ( insertOtherWords rig
                            <> tokenArgs (pgToken p)
                            <> maybe [] (externalArgs rig) nextBundle
                        )
                walletAfter <- walletRefs rig
                journalAfter <- journalAt stateDir
                ( runExit next
                    , outcomeOf (runReceipt next)
                    , textAt "hash" =<< valueAt "pendingBundle" (runReceipt next)
                    )
                    `shouldBe` (ExitFailure 19, Just "waiting-for-signatures", Just (pgHash p))
                awaitedIn (runReceipt next)
                    `shouldBe` [(txIdHex fold, bodyDeadline fold)]
                map journalKey' (drop (length journalBefore) journalAfter)
                    `shouldBe` [("landed", txIdHex booking)]
                stoppedLeavesNothingOfItsOwn journalBefore journalAfter
                -- the check can fail: an appended line of the write's own is refused
                stoppedLeavesNothingOfItsOwn
                    journalBefore
                    [ e
                        { journalEvent =
                            if journalEvent e == "landed" then "prepared" else journalEvent e
                        }
                    | e <- journalAfter
                    ]
                    `shouldThrow` anyException
                maybe
                    (pure ())
                    (\path -> doesPathExist path `shouldReturn` False)
                    nextBundle
                walletAfter `shouldBe` walletBefore
    describe "after a staged create" $
        around pendingCreate $
            forM_ [ByKeyFile, ByExternal "second.bundle"] $ \signer ->
                it ("a second create " <> signerLabel signer) $ \p -> do
                    let rig = pgRig p
                        stateDir = stagedPartition rig stagedRoot (pgToken p)
                        nextBundle = case signer of
                            ByExternal name -> Just (rigDir rig </> name)
                            ByKeyFile -> Nothing
                    journalBefore <- journalAt stateDir
                    walletBefore <- walletRefs rig
                    next <-
                        runAt
                            rig
                            stagedRoot
                            "second create"
                            (["open-datum", "create"] <> maybe [] (externalArgs rig) nextBundle)
                    walletAfter <- walletRefs rig
                    journalAfter <- journalAt stateDir
                    ( runExit next
                        , outcomeOf (runReceipt next)
                        , textAt "hash" =<< valueAt "pendingBundle" (runReceipt next)
                        )
                        `shouldBe` (ExitFailure 19, Just "waiting-for-signatures", Just (pgHash p))
                    maybe
                        (pure ())
                        (\path -> doesPathExist path `shouldReturn` False)
                        nextBundle
                    stoppedLeavesNothingOfItsOwn journalBefore journalAfter
                    walletAfter `shouldBe` walletBefore
    it
        "a landed bundle never blocks, and the next write reports it as landed"
        $ pendingUpdate
        $ \p -> do
            let rig = pgRig p
            landBodies rig (pgBodies p)
            next <-
                runAt
                    rig
                    stagedRoot
                    "write after the bundle landed"
                    (insertOtherWords rig <> tokenArgs (pgToken p))
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            bundleStatesOf (runReceipt next)
                `shouldBe` [(pgHash p, "landed")]
    it "a dead bundle never blocks, and the next write reports it as dead" $
        pendingFold $ \p -> do
            let rig = pgRig p
            deadline <- case mapMaybe bodyDeadline (pgBodies p) of
                d : _ -> pure d
                [] -> fail "the staged fold carries no deadline"
            jumpChainTo (rigChain rig) (SlotNo (deadline + 1))
            next <-
                runAt
                    rig
                    stagedRoot
                    "write after the bundle died"
                    (insertOtherWords rig <> tokenArgs (pgToken p))
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            bundleStatesOf (runReceipt next)
                `shouldBe` [(pgHash p, "dead")]
  where
    nextWrites =
        [
            ( "insert"
            , \rig ->
                ["open-datum", "insert", "--key", "bob-2", "--payload", payloadOf rig]
            )
        , ("update", updateLine)
        , ("terminate", const ["open-datum", "terminate", "--key", "bob-1"])
        , ("fold", const ["open-datum", "fold"])
        ]

-- | A staged create leaves one bundle pending, its pending identity recorded.
pendingCreate :: (Pending -> IO ()) -> IO ()
pendingCreate use = withRig $ \rig -> do
    staged <- runHidden rig "staged create" ["open-datum", "create"]
    runExit staged `shouldBe` ExitFailure 19
    t <- case valueAt "expected" (runReceipt staged) >>= textAt "stateToken" of
        Just token -> pure (T.unpack token)
        Nothing -> fail "the staged create names no state token"
    (bytes, bundle, bodies) <-
        readBundle (stagedBundlePath rig) >>= either fail pure
    saved <- case textAt "saved" =<< valueAt "bundle" (runReceipt staged) of
        Just p -> pure p
        Nothing -> fail "no saved bundle path in the receipt"
    use
        Pending
            { pgRig = rig
            , pgToken = t
            , pgBundle = bundle
            , pgBodies = bodies
            , pgHash = hashOfBytes bytes
            , pgSaved = saved
            }

-- | The transactions applied to the chain, as a submission would, in order.
landBodies :: Rig -> [ConwayTx] -> IO ()
landBodies rig bodies =
    forM_ bodies $ \tx -> do
        let txid = txIdTx tx
            spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
            made = zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
        recordTransaction (rigChain rig) tx
        advanceChain (rigChain rig) $ \facts ->
            facts
                { csUTxO =
                    Map.union
                        (Map.fromList [(TxIn txid (TxIx ix), out) | (ix, out) <- made])
                        (foldr Map.delete (csUTxO facts) spent)
                }

-- | The members a stop names as awaited: identity and deadline, in order.
awaitedIn :: Aeson.Value -> [(Text, Maybe Word64)]
awaitedIn receipt = case valueAt "pendingBundle" receipt >>= valueAt "awaited" of
    Just (Aeson.Array members) ->
        [ (identity, deadline)
        | m <- toList members
        , let deadline = case valueAt "deadline" m of
                Just (Aeson.Number n) -> Just (floor n)
                _ -> Nothing
        , Just identity <- [textAt "identity" m]
        ]
    _ -> []

-- | Each bundle a receipt's reconciliation reports: its hash and state.
bundleStatesOf :: Aeson.Value -> [(Text, Text)]
bundleStatesOf receipt = case valueAt "reconciled" receipt >>= valueAt "bundles" of
    Just (Aeson.Array bundles) ->
        [ (h, s)
        | b <- toList bundles
        , Just h <- [textAt "hash" b]
        , Just s <- [textAt "state" b]
        ]
    _ -> []

{- | A stopped write leaves nothing of its own in the journal: the lines it
found stay as they were, and the only lines appended are the earlier bundle's
reconciliation (a member found on chain is recorded landed, a bundle that
died, dead). No prepared, waiting or submission line is its own.
-}
stoppedLeavesNothingOfItsOwn
    :: [JournalEntry] -> [JournalEntry] -> Expectation
stoppedLeavesNothingOfItsOwn found appended = do
    map journalKey' (take (length found) appended)
        `shouldBe` map journalKey' found
    filter
        ((`notElem` ["landed", "dead"]) . fst)
        (map journalKey' (drop (length found) appended))
        `shouldBe` []

-- | A journal line as the stop must leave it: its event and the transaction it names.
journalKey' :: JournalEntry -> (Text, Text)
journalKey' e = (journalEvent e, journalTxId e)

-- ---------------------------------------------------------
-- The vault signer (#642 slice 3)
-- ---------------------------------------------------------

{- | The vault mode on the five open-datum writes: with the vault and its
passphrase descriptor, a write builds the bundle the external mode writes for
the vault's address, signs every member from the vault, sends them in order
through the submit core and journals the outcome by the journal phase's
rules. The vault is the rig wallet's own key, sealed under a passphrase the
run reads from a descriptor, and the key file is hidden throughout.
-}
vaultWriteRows :: Spec
vaultWriteRows = describe "the vault signer on the open-datum writes" $ do
    forM_ shapes $ \shape ->
        describe (shapeName shape) $
            aroundAll (vaultShapeStaging shape) (vaultShapeRows shape)
    describe "create" $
        forM_ createScenarios $ \sc ->
            describe (csName sc) $
                aroundAll (vaultCreateStaging sc) $ do
                    vaultShapeRows (createShapeOf sc)
                    it "leaves a registry the token reads back" $ \vs -> do
                        t <- case valueAt "stateToken" (runReceipt (vsSigned vs)) of
                            Just (Aeson.String s) -> pure (T.unpack s)
                            other -> fail ("no state token stated as fact: " <> show other)
                        inspected <-
                            runAt
                                (vsRig vs)
                                vaultRoot
                                "inspect of the vault-made registry"
                                (["open-datum", "inspect", "--key", "any"] <> tokenArgs t)
                        outcomeOf (runReceipt inspected) `shouldBe` Just "success"
    vaultRefusedMemberRow
    vaultUncertainRow
    vaultRefusalsRow

-- | The passphrase the rows' vaults are sealed with.
vaultPassphrase :: String
vaultPassphrase = "a passphrase only the rig's vault knows"

-- | The state root the vault runs use, apart from the external run's.
vaultRoot :: FilePath
vaultRoot = "bob-vault"

-- | The rig wallet's key sealed into a vault of this name, under the rig.
rigVault :: Rig -> String -> IO FilePath
rigVault rig name = do
    passphrase <-
        either (fail . show) pure (mkPassphrase (BC.pack vaultPassphrase))
    sealed <-
        sealVault vaultWorkFactor passphrase (walletSignKey (rigWallet rig))
            >>= either (fail . show) pure
    let path = rigDir rig </> (name <> ".vault")
    createVaultFile path sealed >>= either (fail . show) pure
    pure path

{- | A descriptor that yields this passphrase once, as a script hands it
over; the reader closes it.
-}
passphraseDescriptor :: Rig -> String -> String -> IO Int
passphraseDescriptor rig name spelling = do
    let path = rigDir rig </> (name <> ".passphrase")
    BC.writeFile path (BC.pack (spelling <> "\n"))
    Fd n <- openFd path ReadOnly defaultFileFlags
    pure (fromIntegral n)

-- | The vault signer's flags.
vaultArgs :: FilePath -> Int -> [String]
vaultArgs vault fd = ["--vault", vault, "--passphrase-fd", show fd]

-- | Every spelling of the vault's secrets: the passphrase and the key bytes.
vaultSecrets :: Rig -> [BS.ByteString]
vaultSecrets rig =
    [ BC.pack vaultPassphrase
    , raw
    , B16.encode raw
    ]
  where
    raw = rawSerialiseSignKeyDSIGN (walletSignKey (rigWallet rig))

-- | No secret of the vault in the receipt, the journal or the trace of a run.
assertNoVaultSecret :: Rig -> FilePath -> Run -> IO ()
assertNoVaultSecret rig dir r = do
    journalled <- BS.readFile (journalPath dir)
    let printed = BL.toStrict (Aeson.encode (runReceipt r))
        traced = BC.pack (show (runEvents r))
    forM_ (vaultSecrets rig) $ \secret -> do
        printed `shouldNotSatisfy` BS.isInfixOf secret
        journalled `shouldNotSatisfy` BS.isInfixOf secret
        traced `shouldNotSatisfy` BS.isInfixOf secret

-- | The events a journal holds for one transaction, in order.
memberEvents :: [JournalEntry] -> ConwayTx -> [Text]
memberEvents entries body =
    [journalEvent e | e <- entries, journalTxId e == txIdHex body]

-- | The wallet's key file is hidden while the action runs, and restored after.
withKeyHidden :: Rig -> IO a -> IO a
withKeyHidden rig act = do
    renameFile (rigKey rig) (hiddenKeyPath rig)
    act `finally` renameFile (hiddenKeyPath rig) (rigKey rig)

-- | One vault scenario: the same line run staged externally and then from the vault.
data VaultStaging = VaultStaging
    { vsRig :: Rig
    , vsToken :: String
    , vsStaged :: Run
    -- ^ The external run: exit 19, its bundle file written
    , vsExternal :: Either String (BS.ByteString, Bundle, [ConwayTx])
    -- ^ The external run's bundle
    , vsSigned :: Run
    -- ^ The vault run over the same chain state, the key file hidden
    , vsJournal :: [JournalEntry]
    -- ^ The vault run's journal
    , vsStagedWindow :: (Integer, Integer)
    -- ^ The wall-clock milliseconds before and after the external run
    , vsSignedWindow :: (Integer, Integer)
    -- ^ The same for the vault run
    , vsParams :: PParams ConwayEra
    -- ^ The chain's protocol parameters, whose cost models the script data hash covers
    }

-- | Run a shape staged externally, then from the vault, over the same chain.
vaultShapeStaging :: Shape -> (VaultStaging -> IO ()) -> IO ()
vaultShapeStaging shape use = withRig $ \rig -> do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    t <- tokenOf create
    extra <- shapeSetup shape rig t
    case shapeFunding shape of
        PlainFunding -> pure ()
        TokenOnlyFunding -> tokenOnlyWallet rig
    vaultStagingOver
        rig
        t
        (shapeWords shape rig <> extra <> tokenArgs t)
        use

-- | Run a create staged externally, then from the vault, over the same chain.
vaultCreateStaging
    :: CreateScenario -> (VaultStaging -> IO ()) -> IO ()
vaultCreateStaging sc use = withRigOf (blueprintFor (csMode sc)) pure $ \rig -> do
    seed <-
        if csLiveCarrier sc
            then do
                first' <-
                    runAt
                        rig
                        "carrier"
                        "key-file create publishing the carrier"
                        (createWords sc <> ["--seed", T.unpack (renderOutRef (fundOutput 1))])
                outcomeOf (runReceipt first') `shouldBe` Just "success"
                (\s -> ["--seed", s]) <$> fundSeed2 rig
            else pure []
    let line = createWords sc <> seed
    (stagedWindow, staged) <-
        windowed (runHidden rig "staged create" line)
    t <- case valueAt "expected" (runReceipt staged) >>= textAt "stateToken" of
        Just token -> pure (T.unpack token)
        Nothing -> fail "the staged create names no state token"
    vault <- rigVault rig "bob"
    fd <- passphraseDescriptor rig "bob" vaultPassphrase
    (signedWindow, signed) <-
        windowed $
            withKeyHidden rig $
                runAt rig vaultRoot "vault create" (line <> vaultArgs vault fd)
    external <- readBundle (stagedBundlePath rig)
    journal <- journalAt (stagedPartition rig vaultRoot t)
    params <-
        SessionIO.withLatest
            (rawChainProvider (rigChain rig))
            SessionIO.parameters
    use
        VaultStaging
            { vsRig = rig
            , vsToken = t
            , vsStaged = staged
            , vsExternal = external
            , vsSigned = signed
            , vsJournal = journal
            , vsStagedWindow = stagedWindow
            , vsSignedWindow = signedWindow
            , vsParams = params
            }

vaultStagingOver
    :: Rig -> String -> [String] -> (VaultStaging -> IO ()) -> IO ()
vaultStagingOver rig t line use = do
    (stagedWindow, staged) <- windowed (runHidden rig "staged" line)
    vault <- rigVault rig "bob"
    fd <- passphraseDescriptor rig "bob" vaultPassphrase
    (signedWindow, signed) <-
        windowed $
            withKeyHidden rig $
                runVia
                    rig
                    (envPinned rig)
                    vaultRoot
                    "vault"
                    (line <> vaultArgs vault fd)
    external <- readBundle (stagedBundlePath rig)
    journal <- journalAt (stagedPartition rig vaultRoot t)
    params <-
        SessionIO.withLatest
            (rawChainProvider (rigChain rig))
            SessionIO.parameters
    use
        VaultStaging
            { vsRig = rig
            , vsToken = t
            , vsStaged = staged
            , vsExternal = external
            , vsSigned = signed
            , vsJournal = journal
            , vsStagedWindow = stagedWindow
            , vsSignedWindow = signedWindow
            , vsParams = params
            }

-- | The rows every vault scenario owes, whichever command it runs.
vaultShapeRows :: Shape -> SpecWith VaultStaging
vaultShapeRows shape = do
    it
        "ends in success and sends the bundle, where the same line staged ends at 19"
        $ \vs -> do
            runExit (vsStaged vs) `shouldBe` ExitFailure 19
            ( runExit (vsSigned vs)
                , outcomeOf (runReceipt (vsSigned vs))
                , textAt "reason" (runReceipt (vsSigned vs))
                )
                `shouldBe` (ExitSuccess, Just "success", Nothing)
    it
        "builds the bodies the external mode writes for the vault's address, the clock-bound fields set aside and bound to their own bodies"
        $ \vs -> do
            (_, _, external) <- either fail pure (vsExternal vs)
            (_, _, signed) <- vaultBundleOf vs
            length signed `shouldBe` shapeBodies shape
            map (^. bodyTxL) (canonicalChain (clockChosen shape) signed)
                `shouldBe` map (^. bodyTxL) (canonicalChain (clockChosen shape) external)
            unboundFields
                (vsParams vs)
                (vsSignedWindow vs)
                (clockChosen shape)
                signed
                `shouldBe` []
            unboundFields
                (vsParams vs)
                (vsStagedWindow vs)
                (clockChosen shape)
                external
                `shouldBe` []
    unless (shapeBooks shape)
        $ it
            "builds exactly the bundle bytes the external mode writes when no body carries the clock"
        $ \vs -> do
            (bytes, _, _) <- either fail pure (vsExternal vs)
            (signedBytes, _, _) <- vaultBundleOf vs
            signedBytes `shouldBe` bytes
    it
        "sends every member in order and journals each landed after its waiting line"
        $ \vs -> do
            (_, _, bodies) <- vaultBundleOf vs
            sent <- case valueAt "submissions" (runReceipt (vsSigned vs)) of
                Just (Aeson.Array xs) -> pure (toList xs)
                other -> fail ("no submissions: " <> show other)
            map (textAt "identity") sent `shouldBe` map (Just . txIdHex) bodies
            map (textAt "how") sent `shouldBe` [Just "sent" | _ <- bodies]
            map (memberEvents (vsJournal vs)) bodies
                `shouldBe` [["waiting-for-signatures", "landed"] | _ <- bodies]
    it "states open-datum's own fields as fact, none under expected" $
        \vs -> do
            expected <- case valueAt "expected" (runReceipt (vsStaged vs)) of
                Just (Aeson.Object o) -> pure o
                other -> fail ("no expected fields on the staged run: " <> show other)
            KeyMap.keys expected `shouldNotBe` []
            valueAt "expected" (runReceipt (vsSigned vs)) `shouldBe` Nothing
            forM_ (KeyMap.keys expected) $ \k ->
                valueAt k (runReceipt (vsSigned vs)) `shouldNotBe` Nothing
    unless (null (shapeOwnDone shape)) $
        it "narrates open-datum's own done events once the bundle has landed" $
            \vs -> do
                ownDone shape (runEvents (vsStaged vs)) `shouldBe` []
                nub (ownDone shape (runEvents (vsSigned vs)))
                    `shouldMatchList` shapeOwnDone shape
    it "opens no key file and carries no secret of the vault anywhere" $
        \vs -> do
            doesFileExist (rigKey (vsRig vs)) `shouldReturn` True
            assertNoVaultSecret
                (vsRig vs)
                (stagedPartition (vsRig vs) vaultRoot (vsToken vs))
                (vsSigned vs)

-- | The bundle the vault run saved beside its journal, read as the receipt names it.
vaultBundleOf
    :: VaultStaging -> IO (BS.ByteString, Bundle, [ConwayTx])
vaultBundleOf vs = do
    h <-
        maybe
            (fail "no bundle hash in the vault receipt")
            pure
            (valueAt "bundle" (runReceipt (vsSigned vs)) >>= textAt "hash")
    found <-
        readBundle
            ( bodiesDir (stagedPartition (vsRig vs) vaultRoot (vsToken vs))
                </> ("bundle-" <> T.unpack h <> ".bundle")
            )
    either fail pure found

-- | Whether a shape's chain holds a booking, whose request datum reads the clock.
shapeBooks :: Shape -> Bool
shapeBooks shape = shapeCommand shape `notElem` ["update", "fold"]

-- | A registry with the insert line over it, ready for a vault run.
vaultInsertRig :: Rig -> IO String
vaultInsertRig rig = do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    tokenOf create

{- | The command's own fields as the external mode's staged receipt of this
line states them under @expected@, read from a run of the line, never typed.
-}
stagedExpectedKeys :: Rig -> String -> [String] -> IO [Aeson.Key]
stagedExpectedKeys rig label line = do
    staged <- runHidden rig label line
    runExit staged `shouldBe` ExitFailure 19
    case valueAt "expected" (runReceipt staged) of
        Just (Aeson.Object o) | not (KeyMap.null o) -> pure (KeyMap.keys o)
        other ->
            fail
                ("the staged reference states no fields under expected: " <> show other)

{- | What a vault run whose bundle has not landed states of the command: its
own fields under @expected@, exactly the set the external mode's staged
receipt of the same line carries, each present and not null, and none of
them at the top level.
-}
assertNotLandedStatesOnlyExpected :: [Aeson.Key] -> Run -> Expectation
assertNotLandedStatesOnlyExpected reference r = do
    reference `shouldNotBe` []
    expected <- case valueAt "expected" (runReceipt r) of
        Just (Aeson.Object o) -> pure o
        other ->
            fail
                ( "expected is not an object of the command's own fields: "
                    <> show other
                )
    sort (KeyMap.keys expected) `shouldBe` sort reference
    forM_ (KeyMap.toList expected) $ \(k, v) ->
        (k, v == Aeson.Null) `shouldBe` (k, False)
    forM_ reference $ \k ->
        (k, valueAt k (runReceipt r)) `shouldBe` (k, Nothing)

vaultRefusedMemberRow :: Spec
vaultRefusedMemberRow =
    it
        "a node refusal of a member journals the bundle dead and ends as a ledger refusal naming the members that went through"
        $ withRig
        $ \rig -> do
            t <- vaultInsertRig rig
            vault <- rigVault rig "bob"
            fd <- passphraseDescriptor rig "bob" vaultPassphrase
            ownFields <-
                stagedExpectedKeys
                    rig
                    "reference staged insert with the fold"
                    (insertWords rig <> ["--fold"] <> tokenArgs t)
            writeIORef
                (rigAnswer rig)
                (Just (Cage.SubmitRefused "the booking's inputs are gone"))
            signed <-
                withKeyHidden rig $
                    runAt
                        rig
                        vaultRoot
                        "vault insert refused by the node"
                        (insertWords rig <> ["--fold"] <> tokenArgs t <> vaultArgs vault fd)
            runExit signed `shouldBe` ExitFailure 11
            outcomeOf (runReceipt signed) `shouldBe` Just "ledger-refusal"
            fromMaybe "" (textAt "reason" (runReceipt signed))
                `shouldSatisfy` T.isInfixOf "the booking's inputs are gone"
            identitiesIn "wentThrough" (runReceipt signed) `shouldBe` Just []
            assertNotLandedStatesOnlyExpected ownFields signed
            entries <- journalAt (stagedPartition rig vaultRoot t)
            [ journalEvent e
              | e <- entries
              , journalEvent e `elem` ["landed", "dead"]
              ]
                `shouldBe` ["dead", "dead"]
            -- the refused member names the node's answer; the others die with it
            case [journalDetail e | e <- entries, journalEvent e == "dead"] of
                refused : others -> do
                    refused
                        `shouldSatisfy` maybe False (T.isPrefixOf "refused by the node")
                    others `shouldSatisfy` notElem Nothing
                [] -> expectationFailure "no member was journalled dead"
            assertNoVaultSecret rig (stagedPartition rig vaultRoot t) signed

-- | The identities in a receipt's list field.
identitiesIn :: Aeson.Key -> Aeson.Value -> Maybe [Text]
identitiesIn k v = case valueAt k v of
    Just (Aeson.Array xs) -> Just [x | Aeson.String x <- toList xs]
    _ -> Nothing

vaultUncertainRow :: Spec
vaultUncertainRow =
    it
        "an uncertain answer ends the vault run partial with its fields under expected, and the next open-datum write stops on the bundle at 19"
        $ withRig
        $ \rig -> do
            t <- vaultInsertRig rig
            vault <- rigVault rig "bob"
            fd <- passphraseDescriptor rig "bob" vaultPassphrase
            ownFields <-
                stagedExpectedKeys
                    rig
                    "reference staged insert"
                    (insertWords rig <> tokenArgs t)
            writeIORef
                (rigAnswer rig)
                (Just (Cage.SubmitFailed "the node did not answer"))
            signed <-
                withKeyHidden rig $
                    runAt
                        rig
                        vaultRoot
                        "vault insert whose answer was lost"
                        (insertWords rig <> tokenArgs t <> vaultArgs vault fd)
            runExit signed `shouldBe` ExitFailure 15
            outcomeOf (runReceipt signed) `shouldBe` Just "partial"
            assertNotLandedStatesOnlyExpected ownFields signed
            next <-
                runAt
                    rig
                    vaultRoot
                    "the next write of the same wallet"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-2"
                      , "--payload"
                      , payload2Of rig
                      ]
                        <> tokenArgs t
                    )
            runExit next `shouldBe` ExitFailure 19
            outcomeOf (runReceipt next) `shouldBe` Just "waiting-for-signatures"
            assertNoVaultSecret rig (stagedPartition rig vaultRoot t) signed

vaultRefusalsRow :: Spec
vaultRefusalsRow =
    it
        "a wrong passphrase or an unreadable vault is refused alike, naming the vault, before the blueprint, the chain or the state directory is touched"
        $ withRig
        $ \rig -> do
            t <- vaultInsertRig rig
            vault <- rigVault rig "bob"
            let absent = rigDir rig </> "absent.vault"
                blind =
                    (envOf rig)
                        { envReads = \_ _ -> fail "read"
                        , envWrites = \_ _ -> fail "read"
                        , envLoadRelease = \_ _ -> pure (Left "the blueprint cannot be loaded")
                        }
            wrong <- passphraseDescriptor rig "wrong" "not the passphrase"
            fd <- passphraseDescriptor rig "missing" vaultPassphrase
            forM_
                [ ("wrong passphrase", vault, wrong)
                , ("unreadable vault", absent, fd)
                ]
                $ \(label, named, descriptor) -> do
                    r <-
                        runVia
                            rig
                            blind
                            "never-made"
                            ("vault " <> label)
                            (insertWords rig <> tokenArgs t <> vaultArgs named descriptor)
                    runExit r `shouldBe` ExitFailure 10
                    outcomeOf (runReceipt r) `shouldBe` Just "client-refusal"
                    fromMaybe "" (textAt "reason" (runReceipt r))
                        `shouldSatisfy` T.isInfixOf (T.pack named)
                    fromMaybe "" (textAt "reason" (runReceipt r))
                        `shouldNotSatisfy` T.isInfixOf "blueprint"
            doesPathExist (rigDir rig </> "never-made") `shouldReturn` False

-- ---------------------------------------------------------
-- chunk4 producers
-- ---------------------------------------------------------

{- | The producers as the frozen law needs them (checkpoint four): an insert
books the tagged registration request the application's mint certifies, a
terminate spends the key's custody through the application's own spend arm,
the fold finds both by the request policy, and the retained compiled programs
accept what the producers book. Every expectation is read from the booking, the
chain or the registry's own configuration, never typed; every setup that is not
the producer under test is built apart from the producers
('Singular.Application.OpenDatum.LawfulBooking') and says so.
-}
chunk4Producers :: Spec
chunk4Producers = describe "chunk4 producers" $ do
    registrationBookingRows
    registrationPreviewRows
    registrationDiscoveryRows
    refusedFoldNarrationRows
    queryChoiceRows
    receiptRows
    terminationBookingRows
    carrierRows
    applicationMintRows
    terminationSpendRows
    retainedProgramRows

-- | What kind of cage datum an output carries, for a failure that names it.
datumKind :: CageDatum -> String
datumKind = \case
    RequestDatum _ -> "a legacy request datum"
    StateDatum _ -> "a state datum"
    AbsentCustody _ -> "an absent-custody datum"
    RegistrationDatum _ -> "a registration request datum"
    TerminationDatum _ -> "a termination request datum"

failTest :: String -> IO a
failTest why = expectationFailure why >> fail why

-- | The outputs of a body that carry a cage datum, with the datum.
cageOutputs :: ConwayTx -> [(TxOut ConwayEra, CageDatum)]
cageOutputs tx =
    [ (out, datum)
    | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
    , Just datum <- [extractCageDatum out]
    ]

-- | The transactions a command prepared on the key-file path, in order.
preparedBodies :: Rig -> String -> Text -> IO [ConwayTx]
preparedBodies rig t command = do
    journal <- journalAt (stagedPartition rig "registry" t)
    forM
        [ e
        | e <- journal
        , journalEvent e == "prepared"
        , journalCommand e == command
        ]
        $ \e -> do
            (_, body) <- boundBody journal (journalTxId e)
            either (fail . T.unpack) pure body

-- | The first transaction a command prepared.
preparedFirst :: Rig -> String -> Text -> IO ConwayTx
preparedFirst rig t command =
    preparedBodies rig t command >>= \case
        body : _ -> pure body
        [] ->
            failTest ("the " <> T.unpack command <> " prepared no transaction")

-- | The payment key hash of the rig's wallet: the controller of what it books.
walletKeyHash :: Rig -> ByteString
walletKeyHash = addrKeyHashBytes . walletAddr . rigWallet

-- | The refund address bytes of a registration request.
refundOf :: OnChainRegistrationRequest -> ByteString
refundOf r = case regRefundAddress r of
    BuiltinByteString bytes -> bytes

-- | The mint of a body, policy by policy.
mintOf :: ConwayTx -> Map.Map PolicyID (Map.Map AssetName Integer)
mintOf tx = let MultiAsset m = tx ^. bodyTxL . mintTxBodyL in m

-- | The redeemer a body gives to the minting of this policy.
mintRedeemerOf :: ConwayTx -> PolicyID -> Maybe PLC.Data
mintRedeemerOf tx policy =
    listToMaybe
        [ d
        | (ConwayMinting (AsIx i), (Data d, _)) <- Map.toList redeemers
        , listToMaybe (drop (fromIntegral i) policies) == Just policy
        ]
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    policies = Map.keys (mintOf tx)

-- | The redeemer a body gives to the spending of this input.
spendRedeemerOf :: ConwayTx -> TxIn -> Maybe PLC.Data
spendRedeemerOf tx ref =
    listToMaybe
        [ d
        | (ConwaySpending (AsIx i), (Data d, _)) <- Map.toList redeemers
        , listToMaybe (drop (fromIntegral i) inputs) == Just ref
        ]
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    inputs = toList (tx ^. bodyTxL . inputsTxBodyL)

-- | The policy of a script address: the request policy is the request validator.
policyOfAddress :: TxOut ConwayEra -> Maybe PolicyID
policyOfAddress out = case out ^. addrTxOutL of
    Addr _ (ScriptHashObj h) _ -> Just (PolicyID h)
    _ -> Nothing

-- | The policy whose script hash the application's destination address carries.
policyOfDestination :: ByteString -> Maybe PolicyID
policyOfDestination bytes
    | BS.length bytes == 29 =
        PolicyID . ScriptHash <$> hashFromBytes (BS.drop 1 bytes)
    | otherwise = Nothing

-- | The signers a body requires, as key hash bytes.
signersOf :: ConwayTx -> Set.Set ByteString
signersOf tx =
    Set.map
        (\(KeyHash h) -> hashToBytes h)
        (tx ^. bodyTxL . reqSignerHashesTxBodyL)

-- | A booked registration, decoded from the transaction that books it.
data Registration = Registration
    { rgOut :: TxOut ConwayEra
    , rgRequest :: OnChainRegistrationRequest
    , rgEnvelope :: Envelope
    }

registrationOf :: ConwayTx -> IO Registration
registrationOf tx = case cageOutputs tx of
    [(out, RegistrationDatum r)] -> do
        envelope <- case regDatum r of
            Just d ->
                either
                    (failTest . ("the request's datum is no envelope: " <>))
                    pure
                    (envelopeFromData d)
            Nothing -> failTest "the registration request carries no datum"
        pure (Registration out r envelope)
    found ->
        failTest
            ( "expected one registration request output in the booking, found "
                <> show (map (datumKind . snd) found)
            )

-- | A registry, an insert of bob-1 by the key file and the booking it prepared.
withBookedInsert
    :: [String] -> (Rig -> String -> Run -> ConwayTx -> IO a) -> IO a
withBookedInsert extra use = withRig $ \rig -> do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    t <- tokenOf create
    booked <- run rig "insert" (insertWords rig <> extra <> tokenArgs t)
    outcomeOf (runReceipt booked) `shouldBe` Just "success"
    body <- preparedFirst rig t "insert"
    use rig t booked body

registrationBookingRows :: Spec
registrationBookingRows =
    describe "an insert books a tagged registration request" $ do
        it
            "puts one registration request on chain, carrying the complete envelope"
            $ withBookedInsert ["--deposit", "3000000"]
            $ \rig _ _ body -> do
                rg <- registrationOf body
                let r = rgRequest rg
                    control = envControl (rgEnvelope rg)
                regKey r `shouldBe` ctlKey control
                ctlKey control `shouldBe` TE.encodeUtf8 "bob-1"
                refundOf r `shouldBe` ctlController control
                ctlController control `shouldBe` walletKeyHash rig
                ctlDeposit control `shouldBe` 3_000_000
        it
            "makes the envelope's deposit the request's carrier, with cost and tip beside it"
            $ withBookedInsert ["--deposit", "3000000"]
            $ \_ _ _ body -> do
                rg <- registrationOf body
                let r = rgRequest rg
                regCarrierAda r `shouldBe` ctlDeposit (envControl (rgEnvelope rg))
                rgOut rg ^. coinTxOutL
                    `shouldBe` Coin (regRegistrationCost r + regDeclaredTip r + regCarrierAda r)
        it "names the application's own script address as the destination" $
            withBookedInsert [] $ \_ _ _ body -> do
                rg <- registrationOf body
                let destination = regDestination (rgRequest rg)
                BS.length destination `shouldBe` 29
                BS.take 1 destination `shouldBe` BS.pack [0x70]
                applicationPolicy <- case policyOfDestination destination of
                    Just p -> pure p
                    Nothing -> failTest "the destination is no script address"
                Map.member applicationPolicy (mintOf body) `shouldBe` True
        it
            "mints the request's trie-ready tag and the application tag it commits to, one each, and nothing else"
            $ withBookedInsert []
            $ \_ _ _ body -> do
                rg <- registrationOf body
                let r = rgRequest rg
                    control = envControl (rgEnvelope rg)
                requestPolicy <-
                    maybe
                        (failTest "the request output is not at a script")
                        pure
                        (policyOfAddress (rgOut rg))
                applicationPolicy <-
                    maybe
                        (failTest "the destination is no script address")
                        pure
                        (policyOfDestination (regDestination r))
                mintOf body
                    `shouldBe` Map.fromList
                        [
                            ( requestPolicy
                            , Map.singleton (AssetName (SBS.toShort (trieReadyTagName r))) 1
                            )
                        ,
                            ( applicationPolicy
                            , Map.singleton
                                ( AssetName
                                    ( SBS.toShort
                                        ( applicationTagName
                                            (ctlKey control)
                                            (regRefundAddress r)
                                            (regDestination r)
                                            (regNonce r)
                                        )
                                    )
                                )
                                1
                            )
                        ]
        it
            "gives the application mint the registration redeemer and the request mint the empty one"
            $ withBookedInsert []
            $ \_ _ _ body -> do
                rg <- registrationOf body
                let r = rgRequest rg
                    control = envControl (rgEnvelope rg)
                requestPolicy <-
                    maybe
                        (failTest "the request output is not at a script")
                        pure
                        (policyOfAddress (rgOut rg))
                applicationPolicy <-
                    maybe
                        (failTest "the destination is no script address")
                        pure
                        (policyOfDestination (regDestination r))
                mintRedeemerOf body applicationPolicy
                    `shouldBe` Just
                        ( bookInsertRedeemerOf
                            (ctlKey control)
                            (ctlController control)
                            (regDestination r)
                            (rgEnvelope rg)
                        )
                mintRedeemerOf body requestPolicy `shouldBe` Just (PLC.Constr 0 [])
        it "requires the controller's signature and no other" $
            withBookedInsert [] $ \rig _ _ body ->
                signersOf body `shouldBe` Set.singleton (walletKeyHash rig)
        it "bounds the booking above, and books the start of that upper slot" $
            withBookedInsert [] $ \rig _ _ body -> do
                rg <- registrationOf body
                case body ^. bodyTxL . vldtTxBodyL of
                    ValidityInterval _ (SJust upper) -> do
                        upperMs <-
                            SessionIO.withLatest
                                (rawChainProvider (rigChain rig))
                                (`SessionIO.slotStart` upper)
                        regSubmittedAt (rgRequest rg) `shouldBe` upperMs
                    other ->
                        failTest ("the booking has no upper validity bound: " <> show other)

-- | A preview and a write of the same insert, each report read back.
registrationPreviewRows :: Spec
registrationPreviewRows =
    describe "the preview reports the booking the write submits"
        $ it
            "states the same inputs, references, purposes and fee as the transaction the insert prepares"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            previewed <-
                run
                    rig
                    "preview"
                    ( insertWords rig
                        <> [ "--preview"
                           , "--wallet-address"
                           , bech32Address (walletAddr (rigWallet rig))
                           ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "success"
            written <- run rig "insert" (insertWords rig <> tokenArgs t)
            outcomeOf (runReceipt written) `shouldBe` Just "success"
            body <- preparedFirst rig t "insert"
            bookingReport <- case valueAt "booking" (runReceipt previewed) of
                Just b -> pure b
                Nothing -> failTest "the preview reports no booking"
            let inputsOf = map txInText . toList
                Redeemers redeemers = body ^. witsTxL . rdmrsTxWitsL
            textsAt "inputs" bookingReport
                `shouldBe` Just (inputsOf (body ^. bodyTxL . inputsTxBodyL))
            textsAt "referenceInputs" bookingReport
                `shouldBe` Just (inputsOf (body ^. bodyTxL . referenceInputsTxBodyL))
            purposesOf bookingReport
                `shouldBe` Just (map (show . fst) (Map.toList redeemers))
            integerAt "fee" bookingReport
                `shouldBe` Just (let Coin f = body ^. bodyTxL . feeTxBodyL in f)
            -- and the preview's booking is that of a registration: two mints
            let minting = length (filter isMinting (fromMaybe [] (purposesOf bookingReport)))
            unless (minting == 2) $
                failTest
                    ( "the preview reports "
                        <> show minting
                        <> " minting purpose(s); a registration mints under the request policy and under the application policy"
                    )
  where
    isMinting = T.isInfixOf "Minting" . T.pack
    txInText i = T.unpack (renderOutRef i)
    textsAt key v = case v of
        Aeson.Object o -> case KeyMap.lookup key o of
            Just (Aeson.Array a) -> Just [T.unpack s | Aeson.String s <- toList a]
            _ -> Nothing
        _ -> Nothing
    purposesOf v = case v of
        Aeson.Object o -> case KeyMap.lookup "purposes" o of
            Just (Aeson.Array a) ->
                Just
                    [ T.unpack p
                    | Aeson.Object e <- toList a
                    , Just (Aeson.String p) <- [KeyMap.lookup "purpose" e]
                    ]
            _ -> Nothing
        _ -> Nothing

-- ---------------------------------------------------------
-- Setup apart from every producer
-- ---------------------------------------------------------

-- | A registry resolved the way a command resolves it, for a control that books by hand.
data Lawful = Lawful
    { lwSaved :: Saved
    , lwLive :: Live
    , lwEntry :: EntryArgs
    , lwPayer :: Addr
    }

-- | Every role a registry's references can play.
allRoles :: Set.Set ReferenceRole
allRoles = Set.fromList [minBound .. maxBound]

withLawful
    :: Rig
    -> String
    -> String
    -> (Cage.Session NoWitness IO -> Lawful -> IO a)
    -> IO a
withLawful = withLawfulApp openDatumApplication

-- | The same, for a closed registry, whose application value is the closed wrapper.
withLawfulClosed
    :: Rig
    -> String
    -> String
    -> (Cage.Session NoWitness IO -> Lawful -> IO a)
    -> IO a
withLawfulClosed = withLawfulApp closedDatumApplication

-- | A registry resolved the way a command resolves it, under this application value.
withLawfulApp
    :: Application
    -> Rig
    -> String
    -> String
    -> (Cage.Session NoWitness IO -> Lawful -> IO a)
    -> IO a
withLawfulApp app rig t key use = do
    let line =
            ["open-datum", "insert", "--key", key, "--payload", payloadOf rig]
                <> tokenArgs t
    cmd <-
        either
            (failTest . show)
            pure
            (parseOpenDatumCommand (commandLine rig "registry" line))
    ea <- case cmd of
        OpenInsert a -> pure a
        _ -> failTest "the line is no insert"
    ws <- case entryMode ea of
        Submit w -> pure w
        _ -> failTest "the line is no submission"
    let env = envOf rig
    release <-
        envLoadRelease env app (entryBlueprint ea)
            >>= either failTest pure
    envReads env (writeProvider ws) $ \caps ->
        SessionIO.withLatest (readsIn (envSource env) (envTracer env) caps) $ \v -> do
            saved <-
                resolveSaved
                    app
                    ""
                    release
                    (entryAccess ea)
                    allRoles
                    Nothing
                    v
            live <- attachLive v saved
            use v (Lawful saved live ea (walletAddr (rigWallet rig)))

-- | A view of the chain as it stands, with no command around it.
freshView :: Rig -> (Cage.Session NoWitness IO -> IO a) -> IO a
freshView rig = SessionIO.withLatest (rawChainProvider (rigChain rig))

-- | A transaction the chain applies: recorded, its outputs live, its inputs spent.
landTx :: Rig -> ConwayTx -> IO ()
landTx rig tx = do
    let txid = txIdTx tx
        spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
        made = zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
    recordTransaction (rigChain rig) tx
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.union
                    (Map.fromList [(TxIn txid (TxIx ix), out) | (ix, out) <- made])
                    (foldr Map.delete (csUTxO facts) spent)
            }

-- | The first output of a body that holds this asset.
outputHolding
    :: PolicyID -> ByteString -> ConwayTx -> Maybe (TxIn, TxOut ConwayEra)
outputHolding policy name tx =
    listToMaybe
        [ (TxIn (txIdTx tx) (TxIx ix), out)
        | (ix, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
        , let MaryValue _ (MultiAsset m) = out ^. valueTxOutL
        , Just assets <- [Map.lookup policy m]
        , Map.member (AssetName (SBS.toShort name)) assets
        ]

{- | A registration of this key booked by hand, apart from every producer, and
landed: the transaction and the request it made. The nonce is the caller's.
-}
plantRegistration
    :: Rig -> String -> String -> Integer -> IO (ConwayTx, TxIn)
plantRegistration = plantRegistrationVia withLawful

-- | The same, resolving the registry through the given application value.
plantRegistrationVia
    :: ( forall a
          . Rig
         -> String
         -> String
         -> (Cage.Session NoWitness IO -> Lawful -> IO a)
         -> IO a
       )
    -> Rig
    -> String
    -> String
    -> Integer
    -> IO (ConwayTx, TxIn)
plantRegistrationVia lawfully rig t key nonce = lawfully rig t key $ \v lw -> do
    tip <- SessionIO.tip v
    let saved = lwSaved lw
        payer = lwPayer lw
        slot = Cage.observedSlot tip
        envelope = insertionOf saved (lwEntry lw) (addrKeyHashBytes payer) (PLC.I 7)
    tx <-
        lawfulInsertBooking
            (savedCfg saved)
            v
            (savedToken saved)
            (fst (liveState (lwLive lw)))
            (Live.applied saved)
            envelope
            (Coin 1_000_000)
            nonce
            (slot, slot + 10)
            payer
    landTx rig tx
    jumpChainTo (rigChain rig) (slot + 40)
    pure (tx, TxIn (txIdTx tx) (TxIx 0))

{- | A key that is active, made apart from every producer: the hand-booked
registration, landed, folded by the library's own fold and landed. The custody
output the fold made, with its policy of singular tags.
-}
activeKeyApart
    :: Rig -> String -> String -> IO (TxIn, TxOut ConwayEra)
activeKeyApart rig t key = do
    (_, request) <- plantRegistration rig t key 11
    withLawful rig t key $ \_ lw -> do
        let saved = lwSaved lw
            cfg = savedCfg saved
        freshView rig $ \v -> do
            live <- attachLive v saved
            sel <- requireTrieSelection saved live
            ctx <- registryContextFor cfg (savedCodes saved) v (liveRefs live)
            folded <-
                withTrie sel $ \snapshot ->
                    updateTokenSelected
                        cfg
                        v
                        snapshot
                        (savedToken saved)
                        (lwPayer lw)
                        ctx
                        (request NE.:| [])
            landTx rig folded
            case outputHolding
                (policyIdFromPin (Config.cfgActivePolicy cfg))
                (TE.encodeUtf8 (T.pack key))
                folded of
                Just custody -> pure custody
                Nothing -> failTest "the fold made no output holding the key's singular tag"

-- | The leaf the inspect of a key reports.
leafOf :: Rig -> String -> String -> IO (Maybe Aeson.Value)
leafOf rig t key = do
    inspected <-
        run
            rig
            "inspect"
            (["open-datum", "inspect", "--key", key] <> tokenArgs t)
    pure (valueAt "leaf" (runReceipt inspected))

-- ---------------------------------------------------------
-- The fold finds a booked registration by the request policy
-- ---------------------------------------------------------

-- ---------------------------------------------------------
-- The queries a command makes
-- ---------------------------------------------------------

{- | The rig's capabilities with every output query recorded, and a refusal
for the queries a caller names, as a typed failure the provider cannot answer.
Every other read is served by the chain as it stands.
-}
recordingCapabilities
    :: IORef [Cage.OutputQuery]
    -> (Cage.OutputQuery -> Maybe Cage.ReadFailure)
    -> Rig
    -> Capabilities NoWitness IO
recordingCapabilities seen refuse rig =
    (capabilities rig)
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
                recording =
                    provider
                        { Cage.acquire =
                            \requested action ->
                                Cage.acquire provider requested (recordingReads action)
                        }
            in  ( network
                , observeProvider unverifiedVerifier (\_ -> pure ()) recording
                )
        }
  where
    recordingReads action session =
        action
            session
                { Cage.outputs = \query -> do
                    modifyIORef' seen (<> [query])
                    case refuse query of
                        Just failure -> pure (Left failure)
                        Nothing -> Cage.outputs session query
                }

-- | Whether a query, or any query it composes, reads this address.
readsAddress :: Addr -> Cage.OutputQuery -> Bool
readsAddress addr = \case
    Cage.AtAddress a -> a == addr
    Cage.AnyOf qs -> any (readsAddress addr) qs
    Cage.AllOf qs -> any (readsAddress addr) qs
    _ -> False

-- | Whether a query, or any query it composes, lists this policy's holders.
listsPolicy :: PolicyID -> Cage.OutputQuery -> Bool
listsPolicy policy = \case
    Cage.HoldingPolicy p -> p == policy
    Cage.AnyOf qs -> any (listsPolicy policy) qs
    Cage.AllOf qs -> any (listsPolicy policy) qs
    _ -> False

queryChoiceRows :: Spec
queryChoiceRows =
    describe
        "the pending requests are found by the request policy's listing, and by nothing else"
        $ do
            forM_ [("named", True), ("unnamed", False)] $ \(kind, named) ->
                it
                    ( "folds a booked registration, "
                        <> kind
                        <> ", when the request address cannot be scanned"
                    )
                    $ withRig
                    $ \rig -> do
                        seed <- fundSeed rig
                        create <- run rig "create" ["open-datum", "create", "--seed", seed]
                        t <- tokenOf create
                        (_, request) <- plantRegistration rig t "bob-1" 11
                        (policy, address) <- requestRoutes rig t
                        seen <- newIORef []
                        let caps =
                                recordingCapabilities
                                    seen
                                    ( \q ->
                                        if readsAddress address q
                                            then
                                                Just (Cage.BackendReadFailure "the request address cannot be scanned")
                                            else Nothing
                                    )
                                    rig
                            selection =
                                if named then ["--request", T.unpack (renderOutRef request)] else []
                        folded <-
                            runVia
                                rig
                                ( (envOf rig)
                                    { envReads = \_ k -> k caps
                                    , envWrites = \_ k -> k caps
                                    }
                                )
                                "registry"
                                "fold with no address scan"
                                (["open-datum", "fold"] <> selection <> tokenArgs t)
                        outcomeOf (runReceipt folded) `shouldBe` Just "success"
                        queries <- readIORef seen
                        any (listsPolicy policy) queries `shouldBe` True
                        any (readsAddress address) queries `shouldBe` False
            it
                "refuses a fold whose policy listing fails, and never scans the request address instead"
                $ withRig
                $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    t <- tokenOf create
                    _ <- plantRegistration rig t "bob-1" 11
                    (policy, address) <- requestRoutes rig t
                    seen <- newIORef []
                    let caps =
                            recordingCapabilities
                                seen
                                ( \q ->
                                    if listsPolicy policy q
                                        then
                                            Just (Cage.BackendReadFailure "the listing by policy is incomplete")
                                        else Nothing
                                )
                                rig
                    folded <-
                        runVia
                            rig
                            ( (envOf rig)
                                { envReads = \_ k -> k caps
                                , envWrites = \_ k -> k caps
                                }
                            )
                            "registry"
                            "fold with a failing listing"
                            (["open-datum", "fold"] <> tokenArgs t)
                    outcomeOf (runReceipt folded) `shouldNotBe` Just "success"
                    queries <- readIORef seen
                    any (listsPolicy policy) queries `shouldBe` True
                    any (readsAddress address) queries `shouldBe` False
                    -- the registration stays pending: a fold that can read finds it
                    again <- run rig "fold" (["open-datum", "fold"] <> tokenArgs t)
                    outcomeOf (runReceipt again) `shouldBe` Just "success"
            it
                "lists the pending requests of an inspect without scanning the request address"
                $ withRig
                $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    t <- tokenOf create
                    (_, request) <- plantRegistration rig t "bob-1" 11
                    (policy, address) <- requestRoutes rig t
                    seen <- newIORef []
                    let caps =
                            recordingCapabilities
                                seen
                                ( \q ->
                                    if readsAddress address q
                                        then
                                            Just (Cage.BackendReadFailure "the request address cannot be scanned")
                                        else Nothing
                                )
                                rig
                    inspected <-
                        runVia
                            rig
                            ( (envOf rig)
                                { envReads = \_ k -> k caps
                                , envWrites = \_ k -> k caps
                                }
                            )
                            "registry"
                            "inspect with no address scan"
                            (["open-datum", "inspect", "--key", "bob-1"] <> tokenArgs t)
                    outcomeOf (runReceipt inspected) `shouldBe` Just "success"
                    T.isInfixOf
                        (renderOutRef request)
                        (T.pack (show (valueAt "pendingRequests" (runReceipt inspected))))
                        `shouldBe` True
                    queries <- readIORef seen
                    any (listsPolicy policy) queries `shouldBe` True
                    any (readsAddress address) queries `shouldBe` False

-- | The request policy and the request address of the registry a rig created.
requestRoutes :: Rig -> String -> IO (PolicyID, Addr)
requestRoutes rig t = withLawful rig t "bob-1" $ \_ lw -> do
    let saved = lwSaved lw
        cfg = savedCfg saved
    pure
        ( requestPolicyOf cfg (savedToken saved)
        , requestAddrFromCfg cfg (savedToken saved) Testnet
        )

registrationDiscoveryRows :: Spec
registrationDiscoveryRows =
    describe "the fold finds a booked registration by the request policy" $ do
        it
            "settles a registration booked apart from every producer, selected by its request"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" ["open-datum", "create", "--seed", seed]
                t <- tokenOf create
                (_, request) <- plantRegistration rig t "bob-1" 11
                folded <-
                    run
                        rig
                        "fold"
                        ( ["open-datum", "fold", "--request", T.unpack (renderOutRef request)]
                            <> tokenArgs t
                        )
                outcomeOf (runReceipt folded) `shouldBe` Just "success"
                leafOf rig t "bob-1" `shouldReturn` Just (toJSON (leafName Active))
        it "settles it with no request named, as the only pending request" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" ["open-datum", "create", "--seed", seed]
                t <- tokenOf create
                _ <- plantRegistration rig t "bob-1" 11
                folded <- run rig "fold" (["open-datum", "fold"] <> tokenArgs t)
                outcomeOf (runReceipt folded) `shouldBe` Just "success"
                leafOf rig t "bob-1" `shouldReturn` Just (toJSON (leafName Active))
        it
            "leaves an output with no tag of the request policy unfolded, whatever datum it carries"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" ["open-datum", "create", "--seed", seed]
                t <- tokenOf create
                (booking, _) <- plantRegistration rig t "bob-1" 11
                registered <- registrationOf booking
                -- the same request address, no tag of the request policy on the output
                let untagged =
                        mkBasicTxOut
                            (rgOut registered ^. addrTxOutL)
                            (MaryValue (Coin 20_000_000) mempty)
                squatter <- landSquatter rig untagged
                folded <-
                    run
                        rig
                        "fold the squatter"
                        ( ["open-datum", "fold", "--request", T.unpack (renderOutRef squatter)]
                            <> tokenArgs t
                        )
                outcomeOf (runReceipt folded) `shouldNotBe` Just "success"
                leafOf rig t "bob-1" `shouldReturn` Just (toJSON (leafName Unknown))

-- ---------------------------------------------------------
-- A fold names the booked request it refuses
-- ---------------------------------------------------------

{- | A registration booked apart from every producer over the slots a caller
names, landed: the transaction and the request it made. The start of the upper
slot is the booked time.
-}
plantRegistrationBetween
    :: Rig -> String -> String -> Integer -> (SlotNo, SlotNo) -> IO TxIn
plantRegistrationBetween rig t key nonce window = withLawful rig t key $ \v lw -> do
    let saved = lwSaved lw
        payer = lwPayer lw
        envelope = insertionOf saved (lwEntry lw) (addrKeyHashBytes payer) (PLC.I 7)
    tx <-
        lawfulInsertBooking
            (savedCfg saved)
            v
            (savedToken saved)
            (fst (liveState (lwLive lw)))
            (Live.applied saved)
            envelope
            (Coin 1_000_000)
            nonce
            window
            payer
    landTx rig tx
    pure (TxIn (txIdTx tx) (TxIx 0))

{- | The fold of this request is refused, and the narration names the request,
its key and its kind before it says so, as the receipt names the request.
-}
refusedFoldNamesTheRequest :: Rig -> String -> String -> TxIn -> IO ()
refusedFoldNamesTheRequest rig t key request = do
    folded <-
        run
            rig
            "fold"
            ( ["open-datum", "fold", "--request", T.unpack (renderOutRef request)]
                <> tokenArgs t
            )
    outcomeOf (runReceipt folded) `shouldBe` Just "client-refusal"
    textAt "pendingRequest" (runReceipt folded)
        `shouldBe` Just (renderOutRef request)
    [ (r, e, k)
      | Trace _ (What (RequestSeen r e k _ _)) <- runEvents folded
      ]
        `shouldBe` [
                       ( renderOutRef request
                       , T.pack (edgeName edgeInsertActive)
                       , TE.encodeUtf8 (T.pack key)
                       )
                   ]
    [k | Trace _ (What (Refused k _)) <- runEvents folded]
        `shouldBe` [ClientRefused]
    [() | Trace scope _ <- runEvents folded, InEdge (Folding _) <- scope]
        `shouldBe` []

refusedFoldNarrationRows :: Spec
refusedFoldNarrationRows =
    describe
        "a fold names the booked request, its key and its kind before it refuses it"
        $ do
            it
                "a registration whose key an earlier request of the batch already names"
                $ withRig
                $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    t <- tokenOf create
                    SlotNo now <- freshView rig (fmap Cage.observedSlot . SessionIO.tip)
                    first <-
                        plantRegistrationBetween
                            rig
                            t
                            "key-two"
                            21
                            (SlotNo now, SlotNo (now + 10))
                    second <-
                        plantRegistrationBetween
                            rig
                            t
                            "key-two"
                            22
                            (SlotNo now, SlotNo (now + 10))
                    -- the request later in ledger input order is the one excluded
                    refusedFoldNamesTheRequest rig t "key-two" (max first second)
            it "a registration whose processing window has closed" $
                withRig $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    t <- tokenOf create
                    -- booked in the first minute of the chain's history
                    late <-
                        plantRegistrationBetween rig t "key-five" 23 (SlotNo 1, SlotNo 11)
                    refusedFoldNamesTheRequest rig t "key-five" late

-- | An output put on the chain by a transaction nobody here built.
landSquatter :: Rig -> TxOut ConwayEra -> IO TxIn
landSquatter rig out = do
    ref <-
        either (failTest . ("squatter: " <>)) pure $
            parseOutRef (T.pack (replicate 64 '5' <> "#0"))
    advanceChain (rigChain rig) $ \facts ->
        facts{csUTxO = Map.insert ref out (csUTxO facts)}
    pure ref

-- ---------------------------------------------------------
-- A terminate spends the key's custody
-- ---------------------------------------------------------

-- | A registry holding bob-1 as an active key, made apart from every producer, and the terminate prepared over it.
withBookedTermination
    :: [String]
    -> (Rig -> String -> (TxIn, TxOut ConwayEra) -> ConwayTx -> IO a)
    -> IO a
withBookedTermination extra use = withRig $ \rig -> do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    t <- tokenOf create
    custody <- activeKeyApart rig t "bob-1"
    leafOf rig t "bob-1" `shouldReturn` Just (toJSON (leafName Active))
    booked <-
        run
            rig
            "terminate"
            (["open-datum", "terminate", "--key", "bob-1"] <> extra <> tokenArgs t)
    outcomeOf (runReceipt booked) `shouldBe` Just "success"
    body <- preparedFirst rig t "terminate"
    use rig t custody body

-- | The non-ada assets of an output.
assetsOf
    :: TxOut ConwayEra -> Map.Map PolicyID (Map.Map AssetName Integer)
assetsOf out = let MaryValue _ (MultiAsset m) = out ^. valueTxOutL in m

lovelaceOf :: TxOut ConwayEra -> Integer
lovelaceOf out = let Coin c = out ^. coinTxOutL in c

terminationBookingRows :: Spec
terminationBookingRows =
    describe "a terminate books the spend of the key's custody" $ do
        it
            "spends the custody output through the application's own termination arm"
            $ withBookedTermination []
            $ \_ _ (ref, _) body -> do
                Set.member ref (body ^. bodyTxL . inputsTxBodyL) `shouldBe` True
                case spendRedeemerOf body ref of
                    Just (PLC.Constr 2 [PLC.I added]) -> added `shouldSatisfy` (>= 0)
                    other ->
                        failTest
                            ("the custody spend carries no termination redeemer: " <> show other)
        it
            "books one termination request that holds the whole custody value and what is added"
            $ withBookedTermination []
            $ \_ _ (ref, custody) body -> do
                added <- case spendRedeemerOf body ref of
                    Just (PLC.Constr 2 [PLC.I n]) -> pure n
                    other ->
                        failTest
                            ("the custody spend carries no termination redeemer: " <> show other)
                (out, request) <- case cageOutputs body of
                    [(o, TerminationDatum r)] -> pure (o, r)
                    found ->
                        failTest
                            ( "expected one termination request output in the booking, found "
                                <> show (map (datumKind . snd) found)
                            )
                termKey request `shouldBe` TE.encodeUtf8 "bob-1"
                termDestination request `shouldBe` mempty
                lovelaceOf out `shouldBe` lovelaceOf custody + added
                let held = assetsOf custody
                    requested = assetsOf out
                [ (policy, name, quantity)
                  | (policy, names) <- Map.toList held
                  , (name, quantity) <- Map.toList names
                  , (Map.lookup policy requested >>= Map.lookup name) /= Just quantity
                  ]
                    `shouldBe` []
        it
            "mints the request's trie-ready tag and nothing else, with no approval under the application policy"
            $ withBookedTermination []
            $ \_ _ _ body -> do
                (out, request) <- case cageOutputs body of
                    [(o, TerminationDatum r)] -> pure (o, r)
                    found ->
                        failTest
                            ( "expected one termination request output in the booking, found "
                                <> show (map (datumKind . snd) found)
                            )
                requestPolicy <-
                    maybe
                        (failTest "the request output is not at a script")
                        pure
                        (policyOfAddress out)
                mintOf body
                    `shouldBe` Map.singleton
                        requestPolicy
                        ( Map.singleton
                            (AssetName (SBS.toShort (terminationTrieReadyTagName request)))
                            1
                        )
        it "pays none of the custody to the controller or to anyone else" $
            withBookedTermination [] $ \_ _ (_, custody) body -> do
                let tagged = Map.keysSet (assetsOf custody)
                    outputs = toList (body ^. bodyTxL . outputsTxBodyL)
                    holdersOfCustody =
                        [ o
                        | o <- outputs
                        , not (Map.null (Map.restrictKeys (assetsOf o) tagged))
                        ]
                unless (length holdersOfCustody == 1) $
                    failTest
                        ( "the custody's tokens are held by "
                            <> show (length holdersOfCustody)
                            <> " output(s) of the booking; the termination request output alone must hold them"
                        )
        it "requires the controller's signature and no other" $
            withBookedTermination [] $ \rig _ _ body ->
                signersOf body `shouldBe` Set.singleton (walletKeyHash rig)
        it "with the fold, ends with the key terminal" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" ["open-datum", "create", "--seed", seed]
                t <- tokenOf create
                _ <- activeKeyApart rig t "bob-1"
                done <-
                    run
                        rig
                        "terminate with the fold"
                        (["open-datum", "terminate", "--key", "bob-1", "--fold"] <> tokenArgs t)
                outcomeOf (runReceipt done) `shouldBe` Just "success"
                leafOf rig t "bob-1" `shouldReturn` Just (toJSON (leafName Terminal))
        it
            "is previewed as the booking the write prepares: one spend and one mint"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" ["open-datum", "create", "--seed", seed]
                t <- tokenOf create
                _ <- activeKeyApart rig t "bob-1"
                previewed <-
                    run
                        rig
                        "preview"
                        ( ["open-datum", "terminate", "--key", "bob-1"]
                            <> [ "--preview"
                               , "--wallet-address"
                               , bech32Address (walletAddr (rigWallet rig))
                               ]
                            <> tokenArgs t
                        )
                outcomeOf (runReceipt previewed) `shouldBe` Just "success"
                written <-
                    run
                        rig
                        "terminate"
                        (["open-datum", "terminate", "--key", "bob-1"] <> tokenArgs t)
                outcomeOf (runReceipt written) `shouldBe` Just "success"
                body <- preparedFirst rig t "terminate"
                let Redeemers redeemers = body ^. witsTxL . rdmrsTxWitsL
                    purposes = map (show . fst) (Map.toList redeemers)
                    reported = case valueAt "booking" (runReceipt previewed) of
                        Just (Aeson.Object o) -> case KeyMap.lookup "purposes" o of
                            Just (Aeson.Array a) ->
                                [ T.unpack p
                                | Aeson.Object e <- toList a
                                , Just (Aeson.String p) <- [KeyMap.lookup "purpose" e]
                                ]
                            _ -> []
                        _ -> []
                reported `shouldBe` purposes
                let count word = length (filter (T.isInfixOf word . T.pack) reported)
                unless (count "Spending" == 1 && count "Minting" == 1) $
                    failTest
                        ( "the preview reports "
                            <> show (count "Spending")
                            <> " spending and "
                            <> show (count "Minting")
                            <> " minting purpose(s); a termination is one custody spend and one mint"
                        )

-- ---------------------------------------------------------
-- The carrier of a custody the fold will make
-- ---------------------------------------------------------

{- | The least lovelace the ledger lets the custody output of this envelope
hold: the output the fold makes at the application's address, holding the
key's singular tag under the envelope as its inline datum.
-}
custodyMinimum :: Rig -> Lawful -> Envelope -> IO Integer
custodyMinimum rig lw envelope = do
    let saved = lwSaved lw
        cfg = savedCfg saved
        control = envControl envelope
        singular =
            MultiAsset
                ( Map.singleton
                    (policyIdFromPin (Config.cfgActivePolicy cfg))
                    (Map.singleton (AssetName (SBS.toShort (ctlKey control))) 1)
                )
    address <-
        decodeAddr
            (applicationAddressBytes (Config.network cfg) (Live.applied saved))
    pp <- freshView rig SessionIO.parameters
    let out =
            mkBasicTxOut address (MaryValue (Coin (ctlDeposit control)) singular)
                & datumTxOutL .~ mkInlineDatum (envelopeToData envelope)
        Coin least = getMinCoinTxOut pp out
    pure least

-- | A payload of this many sixty-four byte pieces, written beside the rig's others.
writeBigPayload :: Rig -> Int -> IO FilePath
writeBigPayload rig pieces = do
    let path = rigDir rig </> "payload-big.json"
    BL.writeFile
        path
        ( Aeson.encode
            ( dataToJson
                ( PLC.List
                    [PLC.B (BS.replicate 64 (fromIntegral n)) | n <- [1 .. pieces]]
                )
            )
        )
    pure path

carrierRows :: Spec
carrierRows =
    describe "the carrier of a custody must meet the ledger's minimum" $ do
        it
            "refuses, or states the limit of, an insert whose custody output could not meet the minimum"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" ["open-datum", "create", "--seed", seed]
                t <- tokenOf create
                big <- writeBigPayload rig 40
                -- the fixture is only a test of the rule when the deposit named is below the minimum the ledger asks
                least <- withLawful rig t "bob-1" $ \_ lw ->
                    custodyMinimum
                        rig
                        lw
                        ( insertionOf
                            (lwSaved lw)
                            (lwEntry lw)
                            (walletKeyHash rig)
                            ( PLC.List
                                [PLC.B (BS.replicate 64 (fromIntegral n)) | n <- [1 .. 40 :: Int]]
                            )
                        )
                least `shouldSatisfy` (> 5_000_000)
                attempted <-
                    run
                        rig
                        "insert a payload too large for the deposit named"
                        ( [ "open-datum"
                          , "insert"
                          , "--key"
                          , "bob-1"
                          , "--payload"
                          , big
                          , "--deposit"
                          , "5000000"
                          ]
                            <> tokenArgs t
                        )
                let named =
                        T.pack (show least) `T.isInfixOf` T.pack (show (runReceipt attempted))
                    outcome = outcomeOf (runReceipt attempted)
                -- booked at all, the carrier is the deposit named: never topped up
                when (outcome == Just "success") $ do
                    body <- preparedFirst rig t "insert"
                    rg <- registrationOf body
                    regCarrierAda (rgRequest rg) `shouldBe` 5_000_000
                unless named $
                    failTest
                        ( "the insert ended "
                            <> show outcome
                            <> " and its receipt does not name the "
                            <> show least
                            <> " lovelace the ledger asks of its custody output"
                        )
        it
            "books the same payload once the deposit meets the minimum, the deposit being the carrier"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" ["open-datum", "create", "--seed", seed]
                t <- tokenOf create
                big <- writeBigPayload rig 40
                booked <-
                    run
                        rig
                        "insert with a deposit that meets the minimum"
                        ( [ "open-datum"
                          , "insert"
                          , "--key"
                          , "bob-1"
                          , "--payload"
                          , big
                          , "--deposit"
                          , "30000000"
                          ]
                            <> tokenArgs t
                        )
                outcomeOf (runReceipt booked) `shouldBe` Just "success"
                body <- preparedFirst rig t "insert"
                rg <- registrationOf body
                let r = rgRequest rg
                    control = envControl (rgEnvelope rg)
                ctlDeposit control `shouldBe` 30_000_000
                regCarrierAda r `shouldBe` ctlDeposit control
                least <- withLawful rig t "bob-1" $ \_ lw -> custodyMinimum rig lw (rgEnvelope rg)
                ctlDeposit control `shouldSatisfy` (>= least)

-- ---------------------------------------------------------
-- The application mint, evaluated as compiled
-- ---------------------------------------------------------

-- | The registry's compiled validators as the release retains them.
retainedBlueprint :: IO Aeson.Value
retainedBlueprint = do
    raw <-
        BL.readFile
            "test/fixtures/blueprint/open-datum-deployment-blueprint.json"
    either fail pure (Aeson.eitherDecode raw)

-- | The rig over the retained programs.
withRetainedRig :: (Rig -> IO a) -> IO a
withRetainedRig use = retainedBlueprint >>= \blueprint -> withRigOf blueprint pure use

-- | A registry created over the retained programs.
withRetainedRegistry :: (Rig -> String -> IO a) -> IO a
withRetainedRegistry use = withRetainedRig $ \rig -> do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    outcomeOf (runReceipt create) `shouldBe` Just "success"
    t <- tokenOf create
    use rig t

-- | A closed registry created over the retained programs.
withRetainedClosedRegistry :: (Rig -> String -> IO a) -> IO a
withRetainedClosedRegistry use = withRetainedRig $ \rig -> do
    seed <- fundSeed rig
    create <-
        run rig "create" ["open-datum", "create", "--seed", seed, "--closed"]
    outcomeOf (runReceipt create) `shouldBe` Just "success"
    t <- tokenOf create
    use rig t

-- | What building a transaction under the retained programs ended in.
evaluatedAs :: IO ConwayTx -> IO (Either String ())
evaluatedAs build = do
    r <- try build
    pure $ case r of
        Left (e :: SomeException) -> Left (take 400 (show e))
        Right _ -> Right ()

applicationMintRows :: Spec
applicationMintRows = do
    mintRowsUnder
        "the application mint (open_datum), evaluated as compiled"
        withRetainedRegistry
        withLawful
    mintRowsUnder
        "the application mint (closed_datum, the closed wrapper), evaluated as compiled"
        withRetainedClosedRegistry
        withLawfulClosed

{- | The compiled mint rows over one kind of registry: the wrapper the registry
pins is the program evaluated, and every row reads what it expects from the
registry it created.
-}
mintRowsUnder
    :: String
    -> (forall a. (Rig -> String -> IO a) -> IO a)
    -> ( forall b
          . Rig
         -> String
         -> String
         -> (Cage.Session NoWitness IO -> Lawful -> IO b)
         -> IO b
       )
    -> Spec
mintRowsUnder title withRegistry withLawfulHere =
    describe title $ do
        it
            "accepts the registration booked as the law books it (the positive control)"
            $ withRegistry
            $ \rig t ->
                withLawfulHere rig t "bob-1" $ \v lw -> do
                    tip <- SessionIO.tip v
                    let saved = lwSaved lw
                        slot = Cage.observedSlot tip
                        envelope = insertionOf saved (lwEntry lw) (walletKeyHash rig) (PLC.I 7)
                    booked <-
                        evaluatedAs $
                            lawfulInsertBooking
                                (savedCfg saved)
                                v
                                (savedToken saved)
                                (fst (liveState (lwLive lw)))
                                (Live.applied saved)
                                envelope
                                (Coin 1_000_000)
                                11
                                (slot, slot + 10)
                                (lwPayer lw)
                    booked `shouldBe` Right ()
        it "refuses a mint under a redeemer that is not one of its own" $
            withRegistry $ \rig t ->
                withLawfulHere rig t "bob-1" $ \v lw -> do
                    tip <- SessionIO.tip v
                    let saved = lwSaved lw
                        slot = Cage.observedSlot tip
                        envelope = insertionOf saved (lwEntry lw) (walletKeyHash rig) (PLC.I 7)
                    refused <-
                        evaluatedAs $
                            lawfulInsertBookingAs
                                (Just (PLC.Constr 0 []))
                                (savedCfg saved)
                                v
                                (savedToken saved)
                                (fst (liveState (lwLive lw)))
                                (Live.applied saved)
                                envelope
                                (Coin 1_000_000)
                                11
                                (slot, slot + 10)
                                (lwPayer lw)
                    case refused of
                        Left why | "ConwayMinting" `T.isInfixOf` T.pack why -> pure ()
                        other ->
                            failTest
                                ( "expected the application mint to refuse the registration under a redeemer that is not its own, got "
                                    <> show other
                                )
        it
            "accepts a pure burn of an application tag under a redeemer of its own"
            $ burnUnder
                ( PLC.Constr
                    1
                    [ PLC.B (BS.replicate 32 1)
                    , PLC.B (BS.replicate 28 2)
                    , PLC.Constr 0 [PLC.B (BS.replicate 32 3), PLC.I 0]
                    ]
                )
                `shouldReturn` Right ()
        it
            "accepts a pure burn of an application tag under the fold's fixed redeemer, whatever its bytes"
            $ burnUnder (PLC.Constr 0 []) `shouldReturn` Right ()
  where
    burnUnder redeemer = withRegistry $ \rig t ->
        withLawfulHere rig t "bob-1" $ \_ lw -> do
            let saved = lwSaved lw
                cfg = savedCfg saved
                tagName = BS.replicate 32 0x7a
                holder =
                    mkBasicTxOut
                        (lwPayer lw)
                        ( MaryValue
                            (Coin 3_000_000)
                            ( MultiAsset
                                ( Map.singleton
                                    (policyIdFromPin (Config.cfgApplicationPolicy cfg))
                                    (Map.singleton (AssetName (SBS.toShort tagName)) 1)
                                )
                            )
                        )
            ref <-
                either
                    (failTest . ("holder: " <>))
                    pure
                    (parseOutRef (T.pack (replicate 64 '7' <> "#0")))
            advanceChain (rigChain rig) $ \facts -> facts{csUTxO = Map.insert ref holder (csUTxO facts)}
            freshView rig $ \v ->
                evaluatedAs $
                    lawfulApplicationBurn
                        cfg
                        v
                        (Live.applied saved)
                        redeemer
                        (ref, holder)
                        tagName
                        (lwPayer lw)

-- ---------------------------------------------------------
-- The producers' bookings, under the retained programs
-- ---------------------------------------------------------

retainedProgramRows :: Spec
retainedProgramRows =
    describe
        "the retained compiled programs accept what the producers book and the fold settles"
        $ do
            it
                "settles, by the library's fold, a registration the application's mint accepted"
                $ withRetainedRegistry
                $ \rig t -> do
                    (_, request) <- plantRegistration rig t "bob-1" 11
                    withLawful rig t "bob-1" $ \_ lw -> do
                        let saved = lwSaved lw
                            cfg = savedCfg saved
                        folded <-
                            freshView rig $ \v -> do
                                live <- attachLive v saved
                                sel <- requireTrieSelection saved live
                                ctx <- registryContextFor cfg (savedCodes saved) v (liveRefs live)
                                evaluatedAs $
                                    withTrie sel $ \snapshot ->
                                        updateTokenSelected
                                            cfg
                                            v
                                            snapshot
                                            (savedToken saved)
                                            (lwPayer lw)
                                            ctx
                                            (request NE.:| [])
                        folded `shouldBe` Right ()
            it
                "settles, by the library's fold, a registration the closed wrapper's mint accepted"
                $ withRetainedClosedRegistry
                $ \rig t -> do
                    (_, request) <- plantRegistrationVia withLawfulClosed rig t "bob-1" 11
                    withLawfulClosed rig t "bob-1" $ \_ lw -> do
                        let saved = lwSaved lw
                            cfg = savedCfg saved
                        folded <-
                            freshView rig $ \v -> do
                                live <- attachLive v saved
                                sel <- requireTrieSelection saved live
                                ctx <- registryContextFor cfg (savedCodes saved) v (liveRefs live)
                                evaluatedAs $
                                    withTrie sel $ \snapshot ->
                                        updateTokenSelected
                                            cfg
                                            v
                                            snapshot
                                            (savedToken saved)
                                            (lwPayer lw)
                                            ctx
                                            (request NE.:| [])
                        folded `shouldBe` Right ()
            it
                "books an insert and settles it in the same command, the key ending active"
                $ withRetainedRegistry
                $ \rig t -> do
                    done <-
                        run
                            rig
                            "insert with the fold"
                            (insertWords rig <> ["--fold"] <> tokenArgs t)
                    outcomeOf (runReceipt done) `shouldBe` Just "success"
                    leafOf rig t "bob-1" `shouldReturn` Just (toJSON (leafName Active))

-- ---------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------

-- | Every integer a receipt states under a key whose name holds this word, wherever it sits.
numbersNamed :: Text -> Aeson.Value -> [Integer]
numbersNamed word = go
  where
    go = \case
        Aeson.Object o ->
            concat
                [ [ n
                  | T.isInfixOf word (T.toLower (Key.toText k))
                  , Aeson.Success n <- [Aeson.fromJSON v]
                  ]
                    <> go v
                | (k, v) <- KeyMap.toList o
                ]
        Aeson.Array a -> concatMap go a
        _ -> []

-- | The one output of a booking that carries a cage datum, whatever the datum.
requestOutputOf :: ConwayTx -> IO (TxOut ConwayEra)
requestOutputOf tx = case cageOutputs tx of
    [(out, _)] -> pure out
    found ->
        failTest
            ( "expected one request output in the booking, found "
                <> show (length found)
            )

receiptRows :: Spec
receiptRows =
    describe
        "receipts report the transfer a booking makes and the donation a fold makes"
        $ do
            it
                "the insert receipt states the lovelace the booking transfers into the request"
                $ withBookedInsert []
                $ \_ _ booked body -> do
                    out <- requestOutputOf body
                    let stated = numbersNamed "transfer" (runReceipt booked)
                    unless (not (null stated) && all (== lovelaceOf out) stated) $
                        failTest
                            ( "the insert receipt states a transfer of "
                                <> show stated
                                <> ", the request output holds "
                                <> show (lovelaceOf out)
                            )
            it
                "the terminate receipt states that the booking transfers the whole custody value"
                $ withRig
                $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    t <- tokenOf create
                    _ <- activeKeyApart rig t "bob-1"
                    booked <-
                        run
                            rig
                            "terminate"
                            (["open-datum", "terminate", "--key", "bob-1"] <> tokenArgs t)
                    outcomeOf (runReceipt booked) `shouldBe` Just "success"
                    body <- preparedFirst rig t "terminate"
                    out <- requestOutputOf body
                    let stated = numbersNamed "transfer" (runReceipt booked)
                    unless (not (null stated) && all (== lovelaceOf out) stated) $
                        failTest
                            ( "the terminate receipt states a transfer of "
                                <> show stated
                                <> ", the request output holds "
                                <> show (lovelaceOf out)
                            )
            it "the fold receipt states the donation the fold's body makes" $
                withRig $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    t <- tokenOf create
                    _ <- plantRegistration rig t "bob-1" 11
                    folded <- run rig "fold" (["open-datum", "fold"] <> tokenArgs t)
                    outcomeOf (runReceipt folded) `shouldBe` Just "success"
                    body <- preparedFirst rig t "fold"
                    let Coin donated = body ^. bodyTxL . treasuryDonationTxBodyL
                        stated = numbersNamed "donation" (runReceipt folded)
                    unless (not (null stated) && all (== donated) stated) $
                        failTest
                            ( "the fold receipt states a donation of "
                                <> show stated
                                <> ", the fold's body donates "
                                <> show donated
                            )
            it "inspect lists a booked registration among the pending requests" $
                withRig $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    t <- tokenOf create
                    (_, request) <- plantRegistration rig t "bob-1" 11
                    inspected <-
                        run
                            rig
                            "inspect"
                            (["open-datum", "inspect", "--key", "bob-1"] <> tokenArgs t)
                    let listed = valueAt "pendingRequests" (runReceipt inspected)
                    T.isInfixOf (renderOutRef request) (T.pack (show listed))
                        `shouldBe` True

-- ---------------------------------------------------------
-- The application's termination spend, evaluated as compiled
-- ---------------------------------------------------------

terminationSpendRows :: Spec
terminationSpendRows =
    describe "the application's termination spend, evaluated as compiled" $ do
        it
            "accepts the termination booked as the law books it (the positive control)"
            $ terminationUnder Intact `shouldReturn` Right ()
        it "refuses it when the controller does not sign" $
            terminationUnder WithoutSigner >>= refusedByTheSpend
        it
            "refuses it when the request holds less than the custody and what is added"
            $ terminationUnder ShortRequest >>= refusedByTheSpend
  where
    refusedByTheSpend = \case
        Left why | "ConwaySpending" `T.isInfixOf` T.pack why -> pure ()
        other ->
            failTest
                ( "expected the application's spend to refuse the termination, got "
                    <> show other
                )
    terminationUnder fault = withRetainedRegistry $ \rig t ->
        withLawful rig t "bob-1" $ \_ lw -> do
            let saved = lwSaved lw
                cfg = savedCfg saved
                envelope = insertionOf saved (lwEntry lw) (walletKeyHash rig) (PLC.I 7)
                control = envControl envelope
                singular =
                    MultiAsset
                        ( Map.singleton
                            (policyIdFromPin (Config.cfgActivePolicy cfg))
                            (Map.singleton (AssetName (SBS.toShort (ctlKey control))) 1)
                        )
            address <-
                decodeAddr
                    (applicationAddressBytes (Config.network cfg) (Live.applied saved))
            let custody =
                    mkBasicTxOut address (MaryValue (Coin 4_000_000) singular)
                        & datumTxOutL .~ mkInlineDatum (envelopeToData envelope)
            ref <-
                either
                    (failTest . ("custody: " <>))
                    pure
                    (parseOutRef (T.pack (replicate 64 '8' <> "#0")))
            advanceChain (rigChain rig) $ \facts -> facts{csUTxO = Map.insert ref custody (csUTxO facts)}
            freshView rig $ \v ->
                evaluatedAs $
                    lawfulTerminationBookingWith
                        fault
                        cfg
                        v
                        (savedToken saved)
                        (fst (liveState (lwLive lw)))
                        (Live.applied saved)
                        (ref, custody)
                        (ctlKey control)
                        (ctlController control)
                        (Coin 1_000_000)
                        11
                        (lwPayer lw)

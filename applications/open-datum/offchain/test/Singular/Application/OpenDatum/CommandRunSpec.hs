{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
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
module Singular.Application.OpenDatum.CommandRunSpec
    ( spec
    , Rig (..)
    , Run (..)
    , capabilities
    , envOf
    , fundOutput
    , magic
    , outcomeOf
    , runAt
    , runVia
    , runWithKey
    , submissionsOf
    , textAt
    , withRigOf
    ) where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , genKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class
    ( hashFromBytes
    , hashToBytes
    , hashWith
    )
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Alonzo.PParams (getLanguageView)
import Cardano.Ledger.Alonzo.Tx
    ( ScriptIntegrity (..)
    , hashScriptIntegrity
    )
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..), TxDats (..))
import Cardano.Ledger.Api.Tx
    ( addrTxWitsL
    , bodyTxL
    , txIdTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (datsTxWitsL, rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Core (PParams, extractHash)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys
    ( VKey (..)
    , WitVKey (..)
    , asWitness
    , verifySignedDSIGN
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Language (Language (PlutusV3))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Applicative ((<|>))
import Control.Exception (bracket, finally, throwIO)
import Control.Monad (forM, unless, when)
import Control.Tracer (Tracer (..))
import Data.Aeson (toJSON, (.=))
import Data.Aeson qualified as Aeson
    ( Key
    , Object
    , Result (Success)
    , ToJSON (toJSON)
    , Value (..)
    , decodeStrict
    , eitherDecode
    , eitherDecodeStrict'
    , encode
    , fromJSON
    , object
    )
import Data.Aeson.Key qualified as AesonKey (toText)
import Data.Aeson.KeyMap qualified as KeyMap
    ( delete
    , elems
    , empty
    , insert
    , keys
    , lookup
    , null
    , toList
    )
import Data.ByteString qualified as BS
    ( ByteString
    , empty
    , isInfixOf
    , readFile
    , replicate
    , writeFile
    )
import Data.ByteString.Base16 qualified as B16 (decode, encode)
import Data.ByteString.Char8 qualified as BC
    ( filter
    , lines
    , pack
    , replicate
    , unpack
    , writeFile
    )
import Data.ByteString.Lazy qualified as BL
    ( ByteString
    , toStrict
    , writeFile
    )
import Data.ByteString.Short qualified as SBS
    ( ShortByteString
    , fromShort
    , toShort
    )
import Data.Either (fromLeft)
import Data.Foldable (forM_, toList)
import Data.Function ((&))
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, nub, partition, sort)
import Data.Map.Strict qualified as Map
    ( Map
    , delete
    , fromList
    , insert
    , isSubmapOfBy
    , member
    , null
    , singleton
    , toList
    , union
    , unionWith
    )
import Data.Maybe
    ( fromMaybe
    , isJust
    , isNothing
    , listToMaybe
    , mapMaybe
    )
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
    ( delete
    , empty
    , insert
    , map
    , member
    , singleton
    , toList
    )
import Data.Text (Text)
import Data.Text qualified as T
    ( drop
    , isInfixOf
    , isPrefixOf
    , isSuffixOf
    , pack
    , splitOn
    , take
    , takeWhile
    , toLower
    , unpack
    )
import Data.Text.Encoding qualified as TE
    ( decodeUtf8
    , encodeUtf8
    )
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
import PlutusCore.Data qualified as PD (Data (I))
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 qualified as PLC (serialiseUPLC)
import Singular.Application.OpenDatum.Command
    ( OpenDatumCommand (..)
    , parseOpenDatumCommand
    , renderCLIError
    )
import Singular.Application.OpenDatum.Envelope
    ( Envelope (..)
    , dataFromJson
    , envelopeFromData
    )
import Singular.Application.OpenDatum.Root
    ( runOpenDatumSingular
    , runPackagedOpenDatumVia
    )
import Singular.Application.OpenDatum.Run (runOpenDatum)
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.CLI.Booking (BookingVerb (..), bookingEdgeName)
import Singular.CLI.Finish (finish)
import Singular.CLI.Inspect (runInspect)
import Singular.CLI.ManagedState (addressPartition, managedDir)
import Singular.CLI.Passphrase
    ( PassphraseSource (..)
    , mkPassphrase
    )
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
import Singular.CLI.Session (Env (..), txIdHex)
import Singular.CLI.Sign (signBundle)
import Singular.CLI.Submit (submitBundle)
import Singular.CLI.Trace
    ( ConfirmVerdict
        ( ConfirmFailed
        , ConfirmThrew
        , ConfirmTimedOut
        , Confirmed
        )
    , EdgeAction
        ( Booking
        , Booting
        , Folding
        , Reclaiming
        , Rejecting
        , Updating
        )
    , Ended (Done, FailedWith)
    , Event (How, What)
    , Fetch (fetchElapsed, fetchEnd, fetchSource, fetchWhat)
    , How (Fetched, Read, Tx)
    , RefusalKind (..)
    , Scope (InEdge, InKey, InRequest, InTransaction)
    , SubmitVerdict
        ( Accepted
        , LedgerRefusedIt
        , ProviderFailed
        , SubmitThrew
        , WrongNetwork
        )
    , Trace (Trace)
    , TxEvent
        ( TxBuilt
        , TxConfirmed
        , TxObserved
        , TxSigned
        , TxSubmitted
        , submitStep
        , submitTxId
        , submitVerdict
        )
    , What
        ( Booked
        , CommandEnded
        , Created
        , EdgeStarted
        , Folded
        , KeySeen
        , Reclaimed
        , Refused
        , RegistrySeen
        , Rejected
        , RequestSeen
        , RootSeen
        , Updated
        )
    , fanOut
    , renderText
    )
import Singular.CLI.Vault
    ( createVaultFile
    , sealVault
    , vaultWorkFactor
    )
import Singular.Registry.AddressOracle
    ( addressOf
    , bodyOfToken
    , fingerprintOf
    , holdsOf
    )
import Singular.Registry.Application
    ( Application (..)
    , DecodedHolding (..)
    , Decoder (..)
    , HoldingRules (..)
    , datumFromJson
    , neutralApplication
    )
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
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , unverifiedVerifier
    )
import Singular.Registry.Ledger (Addr, Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
    ( LedgerProvider (acquire)
    , OutputQuery (AtAddress, AtTxIn, HoldingAsset)
    , Outputs
    , ReadFailure (BackendReadFailure, MissingOutput)
    , Session (outputs)
    , SubmitResult (SubmitAccepted, SubmitFailed, SubmitRefused)
    )
import Singular.Registry.PlainJson
    ( PayloadSchema (..)
    , payloadFromJson
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , jumpChainTo
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
    ( ceilingSlot
    , outputsAt
    , parameters
    , withLatest
    )
import Singular.Registry.Signing (detachedWitness, signedTx)
import Singular.Registry.StateToken (parseStateToken)
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
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , extractCageDatum
    , mkInlineDatum
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.Internal.Identity (txInToRef)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , edgeInsertActive
    , edgeName
    , edgeUpdateTerminal
    , stateActivePolicyBytes
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )
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
import System.Posix.Files (setFileMode)
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
    ( Expectation
    , Spec
    , SpecWith
    , anyException
    , around
    , aroundAll
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldMatchList
    , shouldNotBe
    , shouldNotContain
    , shouldNotSatisfy
    , shouldReturn
    , shouldSatisfy
    , shouldThrow
    )
import UntypedPlutusCore qualified as UPLC
    ( DeBruijn (DeBruijn)
    , Program (Program)
    , Term (Apply, LamAbs)
    )

spec :: Spec
spec =
    handlerRows
        >> setupRecut
        >> readbackRows
        >> bookingRefusalRows
        >> permanentRecognition
        >> settledListSingletonRow
        >> externalWriteRows
        >> vaultWriteRows
        >> saveStateTokenRows
        >> payloadSchemaRunRows
        >> printedPayloadRows
        >> registryAddressRows
        >> witnessReachRows
        >> witnessKeptRows

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
    OpenStateCreate _ _ -> "OpenStateCreate"
    OpenStateFold _ -> "OpenStateFold"
    OpenHoldingUpdate{} -> "OpenHoldingUpdate"
    OpenHoldingTerminate{} -> "OpenHoldingTerminate"
    OpenRegistrationBook _ -> "OpenRegistrationBook"
    OpenRegistrationReclaim _ -> "OpenRegistrationReclaim"
    OpenRegistrationCleanup _ -> "OpenRegistrationCleanup"

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
    , rigSubmitted :: IORef [ConwayTx]
    -- ^ Every transaction the provider took, as it was submitted, in order
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
        (Aeson.encode (7 :: Int))
    BL.writeFile
        (dir </> "payload-2.json")
        (Aeson.encode (8 :: Int))
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
    events <- newIORef []
    answer <- newIORef Nothing
    submitted <- newIORef []
    tracer <- compose (Tracer (\t -> modifyIORef' events (<> [t])))
    use
        (Rig dir chain wallet keyPath blueprint events answer submitted tracer)

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
                 , validator "singular_state.singular_state.spend" 2
                 , validator "open_datum_requests.open_datum_requests.spend" 1
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
                    modifyIORef' (rigSubmitted rig) (<> [tx])
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
    -- The new line: a registry of open datum on the proved design, a booking
    -- folded, a booking reclaimed inside its window, a booking cleaned up after it.
    registrationRuns <- registrationLifecycle rig
    pure $
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
            <> registrationRuns
  where
    payload = rigDir rig </> "payload.json"
    payload2 = rigDir rig </> "payload-2.json"
    previewAddr = bech32Address (walletAddr (rigWallet rig))

{- | The commands of the proved design, each run once on a registry of its own:
the creation, a booking folded, a booking reclaimed inside its window and a
booking cleaned up after it. The validators of the rig accept everything, so
these runs read what the commands build, send and print; the rows over the
compiled validators are the registration command spec's.
-}
registrationLifecycle :: Rig -> IO [Run]
registrationLifecycle rig = do
    created <- runAt rig "proved" "state create" ["state", "create"]
    token <- tokenOf created
    booked <- runAt rig "proved" "registration book" (book token "fold")
    folded <-
        runAt
            rig
            "proved"
            "state fold"
            (["state", "fold", "--state-token", token] <> pendingOf booked)
    foldedTx <- last <$> readIORef (rigSubmitted rig)
    let holding = renderOutRef (TxIn (txIdTx foldedTx) (TxIx 1))
    updated <-
        runAt
            rig
            "proved"
            "holding update"
            [ "holding"
            , "update"
            , "--state-token"
            , token
            , "--holding"
            , T.unpack holding
            , "--payload"
            , rigDir rig </> "payload.json"
            ]
    nextHolding <-
        maybe
            (fail "the update prints no holding")
            pure
            (textAt "holding" (runReceipt updated))
    terminated <-
        runAt
            rig
            "proved"
            "holding terminate"
            [ "holding"
            , "terminate"
            , "--state-token"
            , token
            , "--holding"
            , T.unpack nextHolding
            ]
    terminationFold <-
        runAt
            rig
            "proved"
            "termination fold"
            (["state", "fold", "--state-token", token] <> pendingOf terminated)
    toReclaim <-
        runAt
            rig
            "proved"
            "registration book to reclaim"
            (book token "reclaim")
    reachMs (milliseconds "processDeadline" toReclaim)
    reclaimed <-
        runAt
            rig
            "proved"
            "registration reclaim"
            ( ["registration", "reclaim", "--state-token", token]
                <> pendingOf toReclaim
            )
    toClean <-
        runAt
            rig
            "proved"
            "registration book to clean up"
            (book token "cleanup")
    reachMs (milliseconds "reclaimEnd" toClean)
    cleaned <-
        runAt
            rig
            "proved"
            "registration cleanup"
            ( ["registration", "cleanup", "--state-token", token]
                <> pendingOf toClean
            )
    pure
        [ created
        , booked
        , folded
        , updated
        , terminated
        , terminationFold
        , toReclaim
        , reclaimed
        , toClean
        , cleaned
        ]
  where
    book token key =
        [ "registration"
        , "book"
        , "--state-token"
        , token
        , "--key"
        , key
        , "--payload"
        , rigDir rig </> "payload.json"
        ]
    pendingOf r =
        maybe
            []
            (\p -> ["--pending", T.unpack p])
            (textAt "pending" (runReceipt r))
    milliseconds field r = case valueAt field (runReceipt r) of
        Just (Aeson.Number n) -> truncate n :: Integer
        _ -> 0
    reachMs ms = do
        slot <-
            SessionIO.withLatest
                (rawChainProvider (rigChain rig))
                (`SessionIO.ceilingSlot` ms)
        jumpChainTo (rigChain rig) (SlotNo (unSlotNo slot + 1))

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
                ( "settled released output"
                , overSettlement (withText "released" flipLeading)
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
        , "settled released output"
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
                        <|> settledSettlement "released" receipt
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
        externalCompletionRows
        witnessCheckRow

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
            map (^. bodyTxL) (canonicalChain bodies)
                `shouldBe` map (^. bodyTxL) (canonicalChain (stKeyBodies st))
    it
        "binds what the body comparison sets aside to the bodies themselves"
        $ \st -> do
            (_, _, bodies) <- bundleOf st
            unboundFields (stParams st) (stStagedWindow st) bodies
                `shouldBe` []
            unboundFields (stParams st) (stKeyWindow st) (stKeyBodies st)
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
    when (needsPreparation shape)
        $ it
            "the key-file path submits that chain, each transaction witnessed by the one wallet alone, and leaves the published references as they were"
        $ \st -> do
            map txIdTx (stKeySubmitted st) `shouldBe` map txIdTx (stKeyBodies st)
            forM_ (stKeySubmitted st) (expectSignedOnlyBy (rigWallet (stRig st)))
            Map.null (stRefsBefore st) `shouldBe` False
            stRefsAfter st `shouldBe` stRefsBefore st
    when (needsPreparation shape)
        $ it
            "begins with a preparation whose made output the command spends and collateralises from alone, one wallet signing for the whole bundle, the key-file path building the same chain"
        $ \st -> do
            (_, bundle, bodies) <- bundleOf st
            expectPreparedBundle (stRig st) bundle bodies
            expectPreparedChain (stKeyBodies st)
    when (needsPreparation shape)
        $ it
            "the preparation checks refuse a command that collateralises elsewhere, one that leaves the made output unspent, a lone preparation and another signer"
        $ \st -> do
            (_, bundle, bodies) <- bundleOf st
            case bodies of
                [prep, final] -> do
                    let made = TxIn (txIdTx prep) (TxIx 0)
                        elsewhere = TxIn (txIdTx prep) (TxIx 1)
                    expectPreparedChain
                        [ prep
                        , final & bodyTxL . collateralInputsTxBodyL .~ Set.singleton elsewhere
                        ]
                        `shouldThrow` anyException
                    expectPreparedChain
                        [ prep
                        , final & bodyTxL . inputsTxBodyL %~ Set.delete made
                        ]
                        `shouldThrow` anyException
                    expectPreparedChain [prep] `shouldThrow` anyException
                    expectPreparedBundle
                        (stRig st)
                        bundle{bundleSigners = pure "addr_test1other"}
                        bodies
                        `shouldThrow` anyException
                _ ->
                    expectationFailure
                        "the staged chain is not a preparation and its command"

{- | The witness check can fail: a real submitted transaction passes it, and
the same transaction without its witness, under a foreign key's witness, with
a foreign witness beside its own, or under a valid signature over another
body, does not.
-}
witnessCheckRow :: Spec
witnessCheckRow =
    it
        "the witness check refuses a transaction with no witness, a foreign one, an extra one and a signature over another body"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            inserted <- run rig "insert" (insertWords rig <> tokenArgs t)
            outcomeOf (runReceipt inserted) `shouldBe` Just "success"
            taken <- readIORef (rigSubmitted rig)
            case reverse taken of
                tx : other : _ -> do
                    let wallet = rigWallet rig
                        stranger =
                            genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 9))
                                :: SignKeyDSIGN Ed25519DSIGN
                        own = tx ^. witsTxL . addrTxWitsL
                        with ws = tx & witsTxL . addrTxWitsL .~ ws
                    expectSignedOnlyBy wallet tx
                    expectSignedOnlyBy wallet (with Set.empty)
                        `shouldThrow` anyException
                    expectSignedOnlyBy
                        wallet
                        (with (Set.singleton (detachedWitness stranger tx)))
                        `shouldThrow` anyException
                    expectSignedOnlyBy
                        wallet
                        (with (Set.insert (detachedWitness stranger tx) own))
                        `shouldThrow` anyException
                    expectSignedOnlyBy
                        wallet
                        (with (Set.singleton (detachedWitness (walletSignKey wallet) other)))
                        `shouldThrow` anyException
                _ -> expectationFailure "the registry made fewer than two transactions"

{- | What an externally signed bundle that needs a preparation leaves: the
bundle staged without a key, signed OUTSIDE the command by the vault
(@singular wallet sign@'s own function), submitted (@singular submit@'s own
function), and then reconciled by the next write of the same wallet.
-}
data Completion = Completion
    { cpRig :: Rig
    , cpBundle :: (BS.ByteString, Bundle, [ConwayTx])
    , cpStaged :: Run
    , cpSign :: (ExitCode, [FilePath])
    -- ^ the signing's exit and the witness files it printed
    , cpSubmit :: (ExitCode, Maybe Aeson.Value)
    -- ^ the submission's exit and the receipt it printed
    , cpTaken :: [ConwayTx]
    -- ^ the transactions the provider took during the submission
    , cpWalletAfter :: [TxIn]
    , cpTokensBefore :: Map.Map PolicyID (Map.Map AssetName Integer)
    , cpTokensAfter :: Map.Map PolicyID (Map.Map AssetName Integer)
    , cpRefsBefore :: Map.Map TxIn (TxOut ConwayEra)
    , cpRefsAfter :: Map.Map TxIn (TxOut ConwayEra)
    , cpNext :: Run
    -- ^ the next write of the same wallet and state root
    , cpJournal :: [JournalEntry]
    -- ^ the journal after that write
    }

externalCompletionOf :: Shape -> (Completion -> IO ()) -> IO ()
externalCompletionOf shape use = withRig $ \rig -> do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    t <- tokenOf create
    extra <- shapeSetup shape rig t
    tokenOnlyWallet rig
    let line = shapeWords shape rig <> extra <> tokenArgs t
        witnessDir = rigDir rig </> "witnesses"
    tokensBefore <- walletTokens rig
    refsBefore <- referenceCensus rig
    staged <- runHidden rig "staged" line
    bundle <- readBundle (stagedBundlePath rig) >>= either fail pure
    vault <- rigVault rig "bob"
    fd <- passphraseDescriptor rig "bob" vaultPassphrase
    (signExit, signOut, _) <-
        captured
            ( signBundle
                (stagedBundlePath rig)
                vault
                (PassphraseDescriptor fd)
                (Just witnessDir)
            )
    submittedBefore <- countSubmitted rig
    (submitExit, submitOut, _) <-
        captured
            ( submitBundle
                (envOf rig)
                neutralApplication
                fixtureSettings
                (Just (rigBlueprint rig))
                (stagedBundlePath rig)
                [witnessDir]
                Nothing
            )
    taken <- submittedSince rig submittedBefore
    walletAfter <- walletRefs rig
    tokensAfter <- walletTokens rig
    refsAfter <- referenceCensus rig
    next <-
        runAt
            rig
            stagedRoot
            "next write"
            (insertOtherWords rig <> tokenArgs t)
    journal <- journalAt (stagedPartition rig stagedRoot t)
    use
        Completion
            { cpRig = rig
            , cpBundle = bundle
            , cpStaged = staged
            , cpSign = (signExit, lines (BC.unpack signOut))
            , cpSubmit = (submitExit, Aeson.decodeStrict submitOut)
            , cpTaken = taken
            , cpWalletAfter = walletAfter
            , cpTokensBefore = tokensBefore
            , cpTokensAfter = tokensAfter
            , cpRefsBefore = refsBefore
            , cpRefsAfter = refsAfter
            , cpNext = next
            , cpJournal = journal
            }

{- | A booking or an update that needs a preparation, staged without a key,
is signed elsewhere and submitted: both members go through in order under the
one signature, the made output is spent by the command, the tokens and the
published references are as they were, and the next write reconciles the
bundle: each member journalled landed after its waiting line, nothing left
waiting.
-}
externalCompletionRows :: Spec
externalCompletionRows =
    describe
        "an externally signed bundle that needs a preparation is signed elsewhere, submitted, and completes"
        $ forM_ [s | s <- shapes, needsPreparation s, shapeCommand s /= "fold"]
        $ \shape ->
            describe (shapeName shape) $
                aroundAll (externalCompletionOf shape) $ do
                    it
                        "waits at 19 without a key, then the saved bundle is signed by the vault and submitted: both members sent, in order, each carrying the one wallet's witness alone"
                        $ \c -> do
                            let (_, bundle, bodies) = cpBundle c
                            runExit (cpStaged c) `shouldBe` ExitFailure 19
                            length bodies `shouldBe` 2
                            fst (cpSign c) `shouldBe` ExitSuccess
                            length (snd (cpSign c)) `shouldBe` length bodies
                            fst (cpSubmit c) `shouldBe` ExitSuccess
                            receipt <-
                                maybe
                                    (fail "the submission printed no receipt")
                                    pure
                                    (snd (cpSubmit c))
                            outcomeOf receipt `shouldBe` Just "success"
                            let entries = fromMaybe [] (elementsAt "submissions" receipt)
                            map (textAt "identity") entries
                                `shouldBe` map (Just . txIdHex) bodies
                            map (textAt "how") entries `shouldBe` [Just "sent", Just "sent"]
                            forM_ entries $ \e ->
                                (valueAt "chainPoint" e `shouldNotBe` Nothing)
                                    >> (valueAt "chainPoint" e `shouldNotBe` Just Aeson.Null)
                            map txIdTx (cpTaken c) `shouldBe` map txIdTx bodies
                            forM_ (cpTaken c) (expectSignedOnlyBy (rigWallet (cpRig c)))
                            toList (bundleSigners bundle)
                                `shouldBe` [T.pack (bech32Address (walletAddr (rigWallet (cpRig c))))]
                    it
                        "leaves the made output spent by the command, the tokens exact and the published references as they were"
                        $ \c -> do
                            let (_, _, bodies) = cpBundle c
                            case bodies of
                                [prep, final] -> do
                                    let made = TxIn (txIdTx prep) (TxIx 0)
                                    expectPreparedChain bodies
                                    cpWalletAfter c `shouldNotContain` [made]
                                    toList (final ^. bodyTxL . inputsTxBodyL) `shouldContain` [made]
                                _ ->
                                    expectationFailure "the bundle is not a preparation and its command"
                            Map.null (cpTokensBefore c) `shouldBe` False
                            cpTokensAfter c `shouldBe` cpTokensBefore c
                            Map.null (cpRefsBefore c) `shouldBe` False
                            cpRefsAfter c `shouldBe` cpRefsBefore c
                    it
                        "is reconciled by the next write: each member journalled waiting then landed, in order, and nothing left waiting"
                        $ \c -> do
                            let (bytes, _, bodies) = cpBundle c
                            outcomeOf (runReceipt (cpNext c)) `shouldBe` Just "success"
                            bundleStatesOf (runReceipt (cpNext c))
                                `shouldBe` [(hashOfBytes bytes, "landed")]
                            map (memberEvents (cpJournal c)) bodies
                                `shouldBe` [["waiting-for-signatures", "landed"] | _ <- bodies]

-- | How the wallet is funded for a shape.
data Funding = PlainFunding | TokenOnlyFunding

-- | Whether the shape's wallet needs a funding preparation first.
needsPreparation :: Shape -> Bool
needsPreparation shape = case shapeFunding shape of
    PlainFunding -> False
    TokenOnlyFunding -> True

{- | A chain that begins with a preparation: its first body's first output is
the made output and is ada only; the last body spends it and collateralises
from it alone (a ledger refuses collateral that carries tokens); and the
chain holds exactly the preparation and the command.
-}
expectPreparedChain :: [ConwayTx] -> Expectation
expectPreparedChain bodies = case bodies of
    [prep, final] -> do
        let made = TxIn (txIdTx prep) (TxIx 0)
        case toList (prep ^. bodyTxL . outputsTxBodyL) of
            o : _ -> adaOnlyOut o `shouldBe` True
            [] -> expectationFailure "the preparation made no output"
        toList (final ^. bodyTxL . inputsTxBodyL) `shouldContain` [made]
        toList (final ^. bodyTxL . collateralInputsTxBodyL) `shouldBe` [made]
    _ ->
        expectationFailure
            ( "a preparation and its command are two bodies, not "
                <> show (length bodies)
            )

{- | The same for a bundle, which a single wallet signs whole: the preparation
and the command are signed by the same signer, the rig wallet.
-}
expectPreparedBundle :: Rig -> Bundle -> [ConwayTx] -> Expectation
expectPreparedBundle rig bundle bodies = do
    expectPreparedChain bodies
    toList (bundleSigners bundle)
        `shouldBe` [T.pack (bech32Address (walletAddr (rigWallet rig)))]

-- | How many transactions the provider has taken so far.
countSubmitted :: Rig -> IO Int
countSubmitted rig = length <$> readIORef (rigSubmitted rig)

-- | The transactions the provider took after the first @n@, in order.
submittedSince :: Rig -> Int -> IO [ConwayTx]
submittedSince rig n = drop n <$> readIORef (rigSubmitted rig)

{- | A transaction the provider took carries exactly one verification-key
witness, the wallet's, valid over the transaction's own body: nothing
missing, nothing foreign, nothing signed over another body. The provider of
the rig accepts any transaction, so the witnesses are read off what it was
given.
-}
expectSignedOnlyBy :: Wallet -> ConwayTx -> Expectation
expectSignedOnlyBy wallet tx =
    case Set.toList (tx ^. witsTxL . addrTxWitsL) of
        [WitVKey key signature] -> do
            key
                `shouldBe` asWitness (VKey (deriveVerKeyDSIGN (walletSignKey wallet)))
            let TxId bodyHash = txIdTx tx
            verifySignedDSIGN key (extractHash bodyHash) signature `shouldBe` True
        witnesses ->
            expectationFailure
                ( "a submitted transaction carries "
                    <> show (length witnesses)
                    <> " verification-key witnesses, wanted exactly the wallet's"
                )

{- | The published reference outputs at the rig wallet's address, by input,
with their whole value: the outputs no command may spend.
-}
referenceCensus :: Rig -> IO (Map.Map TxIn (TxOut ConwayEra))
referenceCensus rig =
    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
        outs <- SessionIO.outputsAt v (walletAddr (rigWallet rig))
        pure
            ( Map.fromList
                [u | u@(_, o) <- outs, o ^. referenceScriptTxOutL /= SNothing]
            )

-- | The settings the fixture's own provider ignores.
fixtureSettings :: ProviderSettings
fixtureSettings =
    ProviderSettings
        "http://fixture.invalid"
        (fromIntegral magic)
        Nothing
        Nothing

-- | The non-ada assets the rig wallet holds, summed over its outputs.
walletTokens
    :: Rig -> IO (Map.Map PolicyID (Map.Map AssetName Integer))
walletTokens rig =
    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
        outs <- SessionIO.outputsAt v (walletAddr (rigWallet rig))
        pure
            ( foldr
                ( \(_, o) acc -> case o ^. valueTxOutL of
                    MaryValue _ (MultiAsset m) ->
                        Map.unionWith (Map.unionWith (+)) m acc
                )
                mempty
                outs
            )

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
        "update from a wallet that needs a funding preparation"
        "update"
        2
        TokenOnlyFunding
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
        "terminate from a wallet that needs a funding preparation"
        "terminate"
        2
        TokenOnlyFunding
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
    , stKeySubmitted :: [ConwayTx]
    -- ^ The transactions the key-file run submitted, as the provider took them
    , stRefsBefore :: Map.Map TxIn (TxOut ConwayEra)
    -- ^ The wallet's published reference outputs before either run
    , stRefsAfter :: Map.Map TxIn (TxOut ConwayEra)
    -- ^ The same once the key-file run has landed
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
    refsBefore <- referenceCensus rig
    (stagedWindow, staged) <- windowed (runHidden rig "staged" line)
    walletAfter <- walletRefs rig
    submittedBefore <- countSubmitted rig
    (keyWindow, keyFile) <- windowed (run rig "key file" line)
    keySubmitted <- submittedSince rig submittedBefore
    refsAfter <- referenceCensus rig
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
            , stKeySubmitted = keySubmitted
            , stRefsBefore = refsBefore
            , stRefsAfter = refsAfter
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
redeemers, whose indices follow the sorted inputs, hence the ids). Nothing
else is set aside, the validity interval included: the first body of a
chain is built at the same tip on both sides, and the later ones are compared
as they come. 'unboundFields' binds each of the three to the body that
carries it, so that setting them aside here hides no defect.
-}
canonicalChain :: [ConwayTx] -> [ConwayTx]
canonicalChain bodies = zipWith canonical [0 :: Int ..] bodies
  where
    earlier = zip (map txIdTx bodies) [0 :: Int ..]
    positioned (TxIn spent ix) = case lookup spent earlier of
        Just k -> TxIn (placeholderId k) ix
        Nothing -> TxIn spent ix
    placeholderId k = case parseOutRef (T.pack (replicate 63 'e' <> show k <> "#0")) of
        Right (TxIn tid _) -> tid
        Left why -> error ("canonicalChain: " <> why)
    canonical _ tx =
        tx
            & bodyTxL . inputsTxBodyL %~ Set.map positioned
            & bodyTxL . referenceInputsTxBodyL %~ Set.map positioned
            & bodyTxL . collateralInputsTxBodyL %~ Set.map positioned
            & bodyTxL . scriptIntegrityHashTxBodyL .~ SNothing
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
  member has, and a member earlier than the body that spends it.
-}
unboundFields
    :: PParams ConwayEra -> (Integer, Integer) -> [ConwayTx] -> [String]
unboundFields pp (opened, closed) bodies = concat (zipWith check [0 :: Int ..] bodies)
  where
    ids = zip (map txIdTx bodies) [0 :: Int ..]
    outputCounts = map (length . (^. bodyTxL . outputsTxBodyL)) bodies
    check k tx = integrity k tx <> submissions k tx <> positions k tx
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
        , "publish-witness-active"
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
    refsBefore <- referenceCensus rig
    (stagedWindow, staged) <-
        windowed (runHidden rig "staged create" line)
    walletAfter <- walletRefs rig
    submittedBefore <- countSubmitted rig
    (keyWindow, keyFile) <- windowed (run rig "key file create" line)
    keySubmitted <- submittedSince rig submittedBefore
    refsAfter <- referenceCensus rig
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
            , stKeySubmitted = keySubmitted
            , stRefsBefore = refsBefore
            , stRefsAfter = refsAfter
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
    , vsTokensBefore :: Map.Map PolicyID (Map.Map AssetName Integer)
    -- ^ The tokens the wallet held before either run
    , vsTokensAfter :: Map.Map PolicyID (Map.Map AssetName Integer)
    -- ^ The tokens it holds once the vault run has landed
    , vsSubmitted :: [ConwayTx]
    -- ^ The transactions the vault run submitted, as the provider took them
    , vsRefsBefore :: Map.Map TxIn (TxOut ConwayEra)
    -- ^ The wallet's published reference outputs before either run
    , vsRefsAfter :: Map.Map TxIn (TxOut ConwayEra)
    -- ^ The same once the vault run has landed
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
    tokensBefore <- walletTokens rig
    refsBefore <- referenceCensus rig
    submittedBefore <- countSubmitted rig
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
    tokensAfter <- walletTokens rig
    refsAfter <- referenceCensus rig
    submitted <- submittedSince rig submittedBefore
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
            , vsTokensBefore = tokensBefore
            , vsTokensAfter = tokensAfter
            , vsSubmitted = submitted
            , vsRefsBefore = refsBefore
            , vsRefsAfter = refsAfter
            }

vaultStagingOver
    :: Rig -> String -> [String] -> (VaultStaging -> IO ()) -> IO ()
vaultStagingOver rig t line use = do
    tokensBefore <- walletTokens rig
    refsBefore <- referenceCensus rig
    (stagedWindow, staged) <- windowed (runHidden rig "staged" line)
    submittedBefore <- countSubmitted rig
    vault <- rigVault rig "bob"
    fd <- passphraseDescriptor rig "bob" vaultPassphrase
    (signedWindow, signed) <-
        windowed $
            withKeyHidden rig $
                runAt rig vaultRoot "vault" (line <> vaultArgs vault fd)
    tokensAfter <- walletTokens rig
    refsAfter <- referenceCensus rig
    submitted <- submittedSince rig submittedBefore
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
            , vsTokensBefore = tokensBefore
            , vsTokensAfter = tokensAfter
            , vsSubmitted = submitted
            , vsRefsBefore = refsBefore
            , vsRefsAfter = refsAfter
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
            map (^. bodyTxL) (canonicalChain signed)
                `shouldBe` map (^. bodyTxL) (canonicalChain external)
            unboundFields (vsParams vs) (vsSignedWindow vs) signed `shouldBe` []
            unboundFields (vsParams vs) (vsStagedWindow vs) external `shouldBe` []
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
    when (needsPreparation shape)
        $ it
            "signs the preparation and the command from the one vault: the command spends the made output and collateralises from it alone, and the wallet keeps its tokens"
        $ \vs -> do
            (_, bundle, bodies) <- vaultBundleOf vs
            expectPreparedBundle (vsRig vs) bundle bodies
            Map.null (vsTokensBefore vs) `shouldBe` False
            -- a booking and an update move none of them; a fold also
            -- receives the approval of the request it settles
            if shapeCommand shape == "fold"
                then
                    Map.isSubmapOfBy
                        (Map.isSubmapOfBy (<=))
                        (vsTokensBefore vs)
                        (vsTokensAfter vs)
                        `shouldBe` True
                else vsTokensAfter vs `shouldBe` vsTokensBefore vs
    when (needsPreparation shape)
        $ it
            "the vault run submits the bundle's transactions in order, each witnessed by the one wallet alone, and leaves the published references as they were"
        $ \vs -> do
            (_, _, bodies) <- vaultBundleOf vs
            map txIdTx (vsSubmitted vs) `shouldBe` map txIdTx bodies
            forM_ (vsSubmitted vs) (expectSignedOnlyBy (rigWallet (vsRig vs)))
            Map.null (vsRefsBefore vs) `shouldBe` False
            vsRefsAfter vs `shouldBe` vsRefsBefore vs
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
-- --save-state-token: the registry's name kept by create
-- ---------------------------------------------------------

{- | A create can keep the new registry's name in the settings file, so the
commands after it name no registry on their line. The name is whatever the
create's own receipt prints, read from the run and never typed; a create that
does not succeed leaves the file as it was.
-}
saveStateTokenRows :: Spec
saveStateTokenRows = describe
    "Open datum create keeps the registry's name in the settings file"
    $ do
        it "writes the receipt's state token and keeps the other keys" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                BC.writeFile
                    file
                    "{\"network-magic\": 42, \"state-token\": \"stale.token\"}"
                (code, receipt, err) <-
                    savingRun
                        rig
                        ["open-datum", "create", "--seed", seed, saveSwitch, "--config", file]
                (code, outcomeOf receipt, textAt "reason" receipt)
                    `shouldBe` (ExitSuccess, Just "success", Nothing)
                token <-
                    maybe (fail "no state token") pure (textAt "stateToken" receipt)
                written <- BS.readFile file
                Aeson.decodeStrict written
                    `shouldBe` Just
                        ( Aeson.object
                            [ "network-magic" .= (42 :: Int)
                            , "state-token" .= token
                            ]
                        )
                BC.unpack err `shouldSatisfy` isInfixOf file
        it "leaves the file as it was when the create does not succeed" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                    untouched = "{\"state-token\": \"stale.token\"}"
                BC.writeFile file untouched
                refused <-
                    runAtTxIn
                        (Left (Cage.BackendReadFailure "the exchange died"))
                        rig
                        "create-read-failed"
                        ["open-datum", "create", "--seed", seed, saveSwitch, "--config", file]
                outcomeOf (runReceipt refused) `shouldBe` Just "partial"
                runExit refused `shouldSatisfy` (/= ExitSuccess)
                BS.readFile file `shouldReturn` untouched
        it
            "says on standard error that a write failed after the registry exists, and keeps the exit status"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                let dir = rigDir rig </> "settings-home"
                    file = dir </> "settings.json"
                    untouched = "{\"trace\": \"what\"}"
                createDirectory dir
                BC.writeFile file untouched
                setFileMode dir 0o555
                (code, receipt, err) <-
                    savingRun
                        rig
                        ["open-datum", "create", "--seed", seed, saveSwitch, "--config", file]
                        `finally` setFileMode dir 0o755
                code `shouldBe` ExitSuccess
                outcomeOf receipt `shouldBe` Just "success"
                let said = T.toLower (TE.decodeUtf8 err)
                said `shouldSatisfy` T.isInfixOf (T.pack file)
                said `shouldSatisfy` T.isInfixOf "permission denied"
                said `shouldSatisfy` T.isInfixOf "receipt"
                BS.readFile file `shouldReturn` untouched
                listDirectory dir `shouldReturn` ["settings.json"]
        it
            "refuses a read-only settings file at the root, before opening anything"
            $ withSystemTempDirectory "save-root"
            $ \dir -> do
                let file = dir </> "settings.json"
                BC.writeFile file "{\"trace\": \"what\"}"
                setFileMode file 0o444
                (code, out, err) <-
                    captured
                        ( runOpenDatumSingular
                            openDatumApplication
                            (Just stderr)
                            []
                            [ "open-datum"
                            , "create"
                            , "--blueprint"
                            , dir </> "plutus.json"
                            , "--koios-url"
                            , "http://127.0.0.1:9"
                            , "--network-magic"
                            , "42"
                            , "--vault"
                            , dir </> "absent.vault"
                            , "--state-dir"
                            , dir </> "state"
                            , "--config"
                            , file
                            , saveSwitch
                            ]
                        )
                code `shouldBe` ExitFailure 2
                out `shouldBe` ""
                let said = TE.decodeUtf8 err
                said `shouldSatisfy` T.isInfixOf (T.pack saveSwitch)
                said `shouldSatisfy` T.isInfixOf (T.pack file)
                said `shouldSatisfy` T.isInfixOf "read-only"
                said `shouldSatisfy` (not . T.isInfixOf "absent.vault")
                doesPathExist (dir </> "state") `shouldReturn` False

saveSwitch :: String
saveSwitch = "--save-state-token"

{- | One command line as the packaged command parses it and the dispatch runs
it, with the standard error it wrote.
-}
savingRun
    :: Rig -> [String] -> IO (ExitCode, Aeson.Value, BS.ByteString)
savingRun rig args = do
    command <-
        either
            (fail . renderCLIError)
            pure
            (parseOpenDatumCommand (commandLine rig "registry" args))
    (code, out, err) <- captured (runOpenDatum (envOf rig) command)
    receipt <-
        maybe
            (fail ("no receipt: " <> show out))
            pure
            (Aeson.decodeStrict out)
    pure (code, receipt, err)

-- ---------------------------------------------------------
-- A payload written as plain JSON (#719)
-- ---------------------------------------------------------

{- | Every command that takes @--payload@ reads the file in the schema it is
given: plain JSON by default, the detailed Plutus data schema when the
setting says so. What a key holds is read back from inspect's envelope, the
exact data, never from the print this ticket changes later. Each expected
datum is the one the detailed-schema reader of the previous release gives
for the detailed document the spec works out by hand. A refusal names the
file and the flag, nothing is submitted, and it comes before the node is
read: the environment of those rows cannot read a node at all.
-}
payloadSchemaRunRows :: Spec
payloadSchemaRunRows = describe "a payload written as plain JSON (#719)" $ do
    describe "what insert and update store" $
        forM_ storedRows $ \(label, file, setting, detailed) -> do
            it ("insert stores " <> label) $ withRegistry $ \rig token -> do
                path <- payloadFile rig "stored.json" file
                booked <-
                    run
                        rig
                        "insert"
                        ( ["open-datum", "insert", "--key", "k1", "--payload", path]
                            <> setting
                            <> tokenArgs token
                        )
                outcomeOf (runReceipt booked) `shouldBe` Just "success"
                _ <-
                    run
                        rig
                        "fold"
                        (["open-datum", "fold"] <> requestOf booked <> tokenArgs token)
                heldPayload rig token "k1"
                    `shouldReturn` Just (detailedDatum detailed)
            it ("update replaces the payload with " <> label) $ withRegistry $ \rig token -> do
                first <- payloadFile rig "first.json" "0"
                booked <-
                    run
                        rig
                        "insert"
                        ( ["open-datum", "insert", "--key", "k1", "--payload", first]
                            <> tokenArgs token
                        )
                outcomeOf (runReceipt booked) `shouldBe` Just "success"
                _ <-
                    run
                        rig
                        "fold"
                        (["open-datum", "fold"] <> requestOf booked <> tokenArgs token)
                heldPayload rig token "k1" `shouldReturn` Just (PD.I 0)
                path <- payloadFile rig "stored.json" file
                updated <-
                    run
                        rig
                        "update"
                        ( ["open-datum", "update", "--key", "k1", "--payload", path]
                            <> setting
                            <> tokenArgs token
                        )
                outcomeOf (runReceipt updated) `shouldBe` Just "success"
                heldPayload rig token "k1"
                    `shouldReturn` Just (detailedDatum detailed)
    describe "the previews build what the commands submit" $ do
        it
            "an insert preview of a plain file carries the envelope of the detailed document"
            $ withRegistry
            $ \rig token -> do
                plain <- payloadFile rig "plain.json" "{\"answer\": 42}"
                detailed <- payloadFile rig "detailed.json" answerDetailed
                a <- previewInsert rig token plain []
                b <- previewInsert rig token detailed ["--payload-schema", "detailed"]
                outcomeOf (runReceipt a) `shouldBe` Just "success"
                previewedPayload a `shouldBe` Just (detailedDatum answerDetailed)
                previewedPayload b `shouldBe` previewedPayload a
        it
            "an update preview of a plain file builds what the detailed document builds"
            $ withRegistry
            $ \rig token -> do
                first <- payloadFile rig "first.json" "0"
                booked <-
                    run
                        rig
                        "insert"
                        ( ["open-datum", "insert", "--key", "k1", "--payload", first]
                            <> tokenArgs token
                        )
                _ <-
                    run
                        rig
                        "fold"
                        (["open-datum", "fold"] <> requestOf booked <> tokenArgs token)
                plain <- payloadFile rig "plain.json" "{\"answer\": 42}"
                detailed <- payloadFile rig "detailed.json" answerDetailed
                a <- previewUpdate rig token plain []
                b <- previewUpdate rig token detailed ["--payload-schema", "detailed"]
                outcomeOf (runReceipt a) `shouldBe` Just "success"
                valueAt "update" (runReceipt a) `shouldSatisfy` (/= Nothing)
                valueAt "update" (runReceipt b)
                    `shouldBe` valueAt "update" (runReceipt a)
    describe "what is refused, and where" $
        forM_ refusalRows $ \(label, file, setting, sentence) ->
            forM_ refusedBy $ \(verb, attempt) ->
                it (label <> " is refused by " <> verb <> " before the node is read") $
                    withRig $ \rig -> do
                        path <- payloadFile rig "refused.json" file
                        outcome <- attempt rig path setting
                        outcome `shouldBe` Just ("client-refusal", sentence path)
  where
    storedRows =
        [
            ( "a plain object with no setting"
            , "{\"answer\": 42}"
            , []
            , answerDetailed
            )
        ,
            ( "a plain object with the setting plain"
            , "{\"answer\": 42}"
            , ["--payload-schema", "plain"]
            , answerDetailed
            )
        ,
            ( "the same object in the detailed schema with the setting detailed"
            , answerDetailed
            , ["--payload-schema", "detailed"]
            , answerDetailed
            )
        , ("a plain integer", "7", [], "{\"int\":7}")
        ,
            ( "the detailed integer"
            , "{\"int\":7}"
            , ["--payload-schema", "detailed"]
            , "{\"int\":7}"
            )
        , ("a plain text", "\"alice\"", [], "{\"bytes\":\"616c696365\"}")
        ,
            ( "a plain list of a number and a boolean"
            , "[1, true]"
            , []
            , "{\"list\":[{\"int\":1},{\"constructor\":1,\"fields\":[]}]}"
            )
        ,
            ( "a constructor of the detailed schema with the setting detailed"
            , "{\"constructor\":2,\"fields\":[{\"int\":5}]}"
            , ["--payload-schema", "detailed"]
            , "{\"constructor\":2,\"fields\":[{\"int\":5}]}"
            )
        ]
    answerDetailed =
        "{\"map\":[{\"k\":{\"bytes\":\"616e73776572\"},\"v\":{\"int\":42}}]}"
    -- the file text, the setting, and the sentence the refusal must be
    refusalRows =
        [
            ( "a detailed document without the setting"
            , "{\"constructor\":0,\"fields\":[{\"int\":42}]}"
            , []
            , \path ->
                path <> ": --payload cannot be stored as plain JSON: " <> instruction
            )
        ,
            ( "a plain object under the setting detailed"
            , "{\"answer\": 42}"
            , ["--payload-schema", "detailed"]
            , \path ->
                path
                    <> ": --payload is not Plutus data: "
                    <> fromLeft "" (datumFromJson (decodeDoc "{\"answer\": 42}"))
            )
        ,
            ( "a number with a fraction"
            , "{\"price\": 1.5}"
            , []
            , ( <>
                    ": --payload cannot be stored as plain JSON: the number 1.5 at $.price has a fraction; only whole numbers are stored"
              )
            )
        ,
            ( "null"
            , "{\"gone\": null}"
            , []
            , ( <>
                    ": --payload cannot be stored as plain JSON: null at $.gone has no Plutus data counterpart"
              )
            )
        ,
            ( "a file that is not JSON"
            , "{\"a\": }"
            , []
            , \path -> path <> ": " <> notJsonReason "{\"a\": }"
            )
        ]
    instruction = case payloadFromJson PlainSchema (decodeDoc "{\"int\":1}") of
        Left why -> T.unpack why
        Right _ -> "stored as plain"
    decodeDoc :: BL.ByteString -> Aeson.Value
    decodeDoc = either (error . ("not JSON: " <>)) id . Aeson.eitherDecode
    notJsonReason :: BL.ByteString -> String
    notJsonReason text =
        fromLeft
            "it is JSON"
            ( Aeson.eitherDecodeStrict' (BL.toStrict text)
                :: Either String Aeson.Value
            )
    -- every command that takes a payload, as a refusal outcome the environment cannot disturb
    refusedBy =
        [
            ( "insert"
            , \rig path setting ->
                viaCommand
                    rig
                    ["open-datum", "insert", "--key", "k9", "--payload", path]
                    setting
            )
        ,
            ( "update"
            , \rig path setting ->
                viaCommand
                    rig
                    ["open-datum", "update", "--key", "k9", "--payload", path]
                    setting
            )
        ,
            ( "insert --preview"
            , \rig path setting ->
                viaCommand
                    rig
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "k9"
                      , "--payload"
                      , path
                      , "--preview"
                      ]
                        <> ["--wallet-address", bech32Address (walletAddr (rigWallet rig))]
                    )
                    setting
            )
        ,
            ( "update --preview"
            , \rig path setting ->
                viaCommand
                    rig
                    ( [ "open-datum"
                      , "update"
                      , "--key"
                      , "k9"
                      , "--payload"
                      , path
                      , "--preview"
                      ]
                        <> ["--wallet-address", bech32Address (walletAddr (rigWallet rig))]
                    )
                    setting
            )
        ]

-- | A rig with a registry created, and the state-token argument of its commands.
withRegistry :: (Rig -> String -> IO a) -> IO a
withRegistry use = withRig $ \rig -> do
    seed <- fundSeed rig
    created <- run rig "create" ["open-datum", "create", "--seed", seed]
    token <- tokenOf created
    use rig token

-- | A payload file in the rig's directory.
payloadFile :: Rig -> FilePath -> BL.ByteString -> IO FilePath
payloadFile rig name text = do
    let path = rigDir rig </> name
    BL.writeFile path text
    pure path

-- | The data of a detailed-schema document, by the reader of the previous release.
detailedDatum :: BL.ByteString -> PD.Data
detailedDatum text = case Aeson.eitherDecode text of
    Left why -> error ("not JSON: " <> why)
    Right v -> either (error . ("not detailed: " <>)) id (datumFromJson v)

-- | The payload data of an envelope printed as detailed-schema JSON.
payloadOfEnvelope :: Aeson.Value -> Maybe PD.Data
payloadOfEnvelope json =
    either (const Nothing) Just (dataFromJson json)
        >>= either (const Nothing) (Just . envPayload) . envelopeFromData

-- | The payload the registry holds for a key, from inspect's envelope.
heldPayload :: Rig -> String -> String -> IO (Maybe PD.Data)
heldPayload rig token key = do
    inspected <-
        run
            rig
            ("inspect " <> key)
            (["open-datum", "inspect", "--key", key] <> tokenArgs token)
    pure $
        valueAt "applicationOutput" (runReceipt inspected)
            >>= valueAt "envelope"
            >>= payloadOfEnvelope

-- | The payload an insert preview's envelope carries.
previewedPayload :: Run -> Maybe PD.Data
previewedPayload r = valueAt "envelope" (runReceipt r) >>= payloadOfEnvelope

previewInsert :: Rig -> String -> FilePath -> [String] -> IO Run
previewInsert rig token path setting =
    run
        rig
        "insert preview"
        ( [ "open-datum"
          , "insert"
          , "--key"
          , "k2"
          , "--payload"
          , path
          , "--preview"
          ]
            <> ["--wallet-address", bech32Address (walletAddr (rigWallet rig))]
            <> setting
            <> tokenArgs token
        )

previewUpdate :: Rig -> String -> FilePath -> [String] -> IO Run
previewUpdate rig token path setting =
    run
        rig
        "update preview"
        ( [ "open-datum"
          , "update"
          , "--key"
          , "k1"
          , "--payload"
          , path
          , "--preview"
          ]
            <> ["--wallet-address", bech32Address (walletAddr (rigWallet rig))]
            <> setting
            <> tokenArgs token
        )

-- | An environment that cannot read a node: a refusal that comes first is the only thing it shows.
blindEnv :: Rig -> Env
blindEnv rig =
    (envOf rig)
        { envReads = \_ _ -> fail "the node was read"
        , envWrites = \_ _ -> fail "the node was read"
        , envLoadRelease = \_ _ -> pure (Left "the blueprint was read")
        }

{- | A command line run where the node cannot be read: its outcome class and
reason when it ends in a refusal, and nothing submitted.
-}
viaCommand :: Rig -> [String] -> [String] -> IO (Maybe (Text, String))
viaCommand rig command setting = do
    let token = phantomToken
    submittedBefore <- countSubmitted rig
    r <-
        runVia
            rig
            (blindEnv rig)
            "registry"
            "payload refusal"
            (command <> setting <> tokenArgs token)
    submittedAfter <- countSubmitted rig
    submittedAfter `shouldBe` submittedBefore
    pure
        ( (,)
            <$> outcomeOf (runReceipt r)
            <*> fmap T.unpack (textAt "reason" (runReceipt r))
        )

-- | A well-formed state token no registry minted; the blind environment never looks it up.
phantomToken :: String
phantomToken = replicate 56 '0' <> "." <> replicate 64 '0'

-- ---------------------------------------------------------
-- The payload that inspect and the update receipt print (#719)
-- ---------------------------------------------------------

{- | Inspect and the update receipt print a key's payload as plain JSON when
the stored data has a plain reading, else in the detailed schema, and always
beside the name of the schema. The form a payload was written in is not
kept: the detailed integer and the plain integer print alike. The envelope
is printed as before and holds the exact data.
-}
printedPayloadRows :: Spec
printedPayloadRows = describe "the printed payload (#719)" $
    forM_ printedRows $ \(label, file, setting, detailed, expected, schema) -> do
        it ("inspect prints " <> label) $ withRegistry $ \rig token -> do
            path <- payloadFile rig "stored.json" file
            booked <-
                run
                    rig
                    "insert"
                    ( ["open-datum", "insert", "--key", "k1", "--payload", path]
                        <> setting
                        <> tokenArgs token
                    )
            _ <-
                run
                    rig
                    "fold"
                    (["open-datum", "fold"] <> requestOf booked <> tokenArgs token)
            inspected <-
                run
                    rig
                    "inspect"
                    (["open-datum", "inspect", "--key", "k1"] <> tokenArgs token)
            let output = valueAt "applicationOutput" (runReceipt inspected)
            (output >>= valueAt "payload", output >>= valueAt "payloadSchema")
                `shouldBe` (Just expected, Just (Aeson.String schema))
            (output >>= valueAt "envelope" >>= payloadOfEnvelope)
                `shouldBe` Just (detailedDatum detailed)
        it ("the update receipt prints " <> label) $ withRegistry $ \rig token -> do
            first <- payloadFile rig "first.json" "0"
            booked <-
                run
                    rig
                    "insert"
                    ( ["open-datum", "insert", "--key", "k1", "--payload", first]
                        <> tokenArgs token
                    )
            outcomeOf (runReceipt booked) `shouldBe` Just "success"
            _ <-
                run
                    rig
                    "fold"
                    (["open-datum", "fold"] <> requestOf booked <> tokenArgs token)
            path <- payloadFile rig "stored.json" file
            updated <-
                run
                    rig
                    "update"
                    ( ["open-datum", "update", "--key", "k1", "--payload", path]
                        <> setting
                        <> tokenArgs token
                    )
            outcomeOf (runReceipt updated) `shouldBe` Just "success"
            ( valueAt "payload" (runReceipt updated)
                , valueAt "payloadSchema" (runReceipt updated)
                )
                `shouldBe` (Just expected, Just (Aeson.String schema))
  where
    jsonOf :: BL.ByteString -> Aeson.Value
    jsonOf = either (error . ("not JSON: " <>)) id . Aeson.eitherDecode
    -- label, the file, the setting, the detailed document of the same data,
    -- the JSON that must be printed, and the schema it is printed in
    printedRows =
        [
            ( "a plain object as plain JSON"
            , "{\"answer\": 42}"
            , []
            , "{\"map\":[{\"k\":{\"bytes\":\"616e73776572\"},\"v\":{\"int\":42}}]}"
            , jsonOf "{\"answer\": 42}"
            , "plain"
            )
        ,
            ( "the detailed form of the same object as the same plain JSON"
            , "{\"map\":[{\"k\":{\"bytes\":\"616e73776572\"},\"v\":{\"int\":42}}]}"
            , ["--payload-schema", "detailed"]
            , "{\"map\":[{\"k\":{\"bytes\":\"616e73776572\"},\"v\":{\"int\":42}}]}"
            , jsonOf "{\"answer\": 42}"
            , "plain"
            )
        ,
            ( "a plain integer as plain JSON"
            , "7"
            , []
            , "{\"int\":7}"
            , Aeson.Number 7
            , "plain"
            )
        ,
            ( "the detailed integer as the plain integer"
            , "{\"int\":7}"
            , ["--payload-schema", "detailed"]
            , "{\"int\":7}"
            , Aeson.Number 7
            , "plain"
            )
        ,
            ( "a plain text as plain JSON"
            , "\"alice\""
            , []
            , "{\"bytes\":\"616c696365\"}"
            , Aeson.String "alice"
            , "plain"
            )
        ,
            ( "a plain list as plain JSON"
            , "[1, true]"
            , []
            , "{\"list\":[{\"int\":1},{\"constructor\":1,\"fields\":[]}]}"
            , jsonOf "[1, true]"
            , "plain"
            )
        ,
            ( "bytes that are not text in the detailed schema"
            , "{\"bytes\":\"ff\"}"
            , ["--payload-schema", "detailed"]
            , "{\"bytes\":\"ff\"}"
            , jsonOf "{\"bytes\":\"ff\"}"
            , "detailed"
            )
        ,
            ( "a constructor that is not a boolean in the detailed schema"
            , "{\"constructor\":2,\"fields\":[{\"int\":5}]}"
            , ["--payload-schema", "detailed"]
            , "{\"constructor\":2,\"fields\":[{\"int\":5}]}"
            , jsonOf "{\"constructor\":2,\"fields\":[{\"int\":5}]}"
            , "detailed"
            )
        ]

-- ---------------------------------------------------------
-- A registry has an address (#728)
-- ---------------------------------------------------------

{- | The receipts and the refusals of a registry that has an address, run
through the dispatch the packaged command runs. The address and the
fingerprint a receipt gives are judged by 'Singular.Registry.AddressOracle', which
reads the word with the @bech32@ package and hashes with @crypton@ directly,
never by the code that wrote them.
-}
registryAddressRows :: Spec
registryAddressRows =
    describe "a registry has an address" $ do
        it
            "the create receipt carries the address and the fingerprint beside the state token, and says them once on standard error"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                (code, receipt, err) <-
                    savingRun rig ["open-datum", "create", "--seed", seed]
                code `shouldBe` ExitSuccess
                token <-
                    maybe (fail "no state token") pure (textAt "stateToken" receipt)
                shouldNameRegistry
                    (T.unpack token)
                    (textAt "registry" receipt)
                    (textAt "fingerprint" receipt)
                address <-
                    maybe
                        (fail "no address")
                        (pure . T.unpack)
                        (textAt "registry" receipt)
                let told = filter (isInfixOf address) (lines (BC.unpack err))
                length told `shouldBe` 1
                told `shouldSatisfy` all (isInfixOf (T.unpack token))
        it "the inspect receipt names the registry it read" $ withRig $ \rig -> do
            (token, _) <- madeRegistry rig
            inspected <-
                runAt
                    rig
                    "empty-actor"
                    "inspect by the state token"
                    (["open-datum", "inspect", "--key", "alice-1"] <> tokenArgs token)
            outcomeOf (runReceipt inspected) `shouldBe` Just "success"
            shouldNameRegistry
                token
                (textAt "registry" (runReceipt inspected))
                (textAt "fingerprint" (runReceipt inspected))
            textAt "stateToken" (runReceipt inspected)
                `shouldBe` Just (T.pack token)
        it
            "inspect reads a registry given by its address alone, as it reads it by its state token"
            $ withRig
            $ \rig -> do
                (token, address) <- madeRegistry rig
                byToken <-
                    runAt
                        rig
                        "empty-actor"
                        "inspect by the state token"
                        (["open-datum", "inspect", "--key", "alice-1"] <> tokenArgs token)
                command <-
                    either
                        (fail . renderCLIError)
                        pure
                        ( parseOpenDatumCommand
                            ( withoutMagic
                                ( commandLine
                                    rig
                                    "empty-actor"
                                    ( ["open-datum", "inspect", "--key", "alice-1"]
                                        <> ["--registry", address]
                                    )
                                )
                            )
                        )
                (code, out, _) <- captured (runOpenDatum (envOf rig) command)
                byAddress <-
                    maybe
                        (fail ("no receipt: " <> show out))
                        pure
                        (Aeson.decodeStrict out)
                outcomeOf (runReceipt byToken) `shouldBe` Just "success"
                code `shouldBe` runExit byToken
                outcomeOf byAddress `shouldBe` outcomeOf (runReceipt byToken)
                forM_ ["root", "leaf", "stateToken"] $ \key ->
                    valueAt key byAddress `shouldBe` valueAt key (runReceipt byToken)
        describe "a registry made by other contracts" $ do
            let commands =
                    [ ("inspect", ["open-datum", "inspect", "--key", "alice-1"])
                    , ("fold", ["open-datum", "fold"])
                    ]
                -- a provider that is read at all fails, and counts the reads: a
                -- refusal that came after one would leave the count above zero
                blind rig = do
                    readsMade <- newIORef (0 :: Int)
                    pure
                        ( (envOf rig)
                            { envReads = \_ _ -> modifyIORef' readsMade (+ 1) >> fail "read"
                            , envWrites = \_ _ -> modifyIORef' readsMade (+ 1) >> fail "read"
                            }
                        , readsMade
                        )
                refusedBy rig name args = do
                    (env, readsMade) <- blind rig
                    refused <- runVia rig env "registry" ("foreign " <> name) args
                    readIORef readsMade `shouldReturn` 0
                    pure refused
            forM_ commands $ \(name, line) ->
                it
                    ( "refuses "
                        <> name
                        <> " naming the releases of the contracts and where to get the newest, before any chain read"
                    )
                    $ withRig
                    $ \rig ->
                        forM_ releasedContracts $ \(policy, tags) -> do
                            refused <-
                                refusedBy
                                    rig
                                    name
                                    (line <> tokenArgs (policy <> "." <> replicate 64 '1'))
                            let reason = T.unpack (fromMaybe "" (textAt "reason" (runReceipt refused)))
                                url tag = "https://github.com/lambdasistemi/singular/releases/tag/" <> tag
                            reason `shouldSatisfy` isInfixOf "state-token-foreign-release"
                            outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
                            runExit refused `shouldBe` ExitFailure 10
                            forM_ tags $ \tag -> reason `shouldSatisfy` isInfixOf tag
                            reason `shouldSatisfy` isInfixOf (url (last tags))
                            forM_ (init tags) $ \tag ->
                                reason `shouldNotSatisfy` isInfixOf (url tag)
            it "refuses a registry of no known release by saying so" $ withRig $ \rig -> do
                refused <-
                    refusedBy
                        rig
                        "inspect"
                        ( ["open-datum", "inspect", "--key", "alice-1"]
                            <> tokenArgs (replicate 56 '1' <> "." <> replicate 64 '1')
                        )
                let reason = T.unpack (fromMaybe "" (textAt "reason" (runReceipt refused)))
                reason `shouldSatisfy` isInfixOf "state-token-foreign-release"
                reason `shouldSatisfy` isInfixOf "no known release"
                runExit refused `shouldBe` ExitFailure 10

{- | The address and the fingerprint a receipt gave for a state token on the
development network, which has the prefix @singular_devnet@: the word decodes
to that prefix and to the 60 bytes of the token, and the fingerprint is the
CIP-14 hash of those bytes.
-}
shouldNameRegistry
    :: String -> Maybe Text -> Maybe Text -> Expectation
shouldNameRegistry token address fingerprint = do
    body <-
        maybe
            (expectationFailure ("not 60 bytes of hex: " <> token) >> pure BS.empty)
            pure
            (bodyOfToken token)
    fmap (holdsOf . T.unpack) address
        `shouldBe` Just (Just ("singular_devnet", body))
    fmap T.unpack fingerprint `shouldBe` fingerprintOf body

-- ---------------------------------------------------------
-- The key reached by its witness token (issue 728, second pull request)
-- ---------------------------------------------------------

{- | @inspect --key@ finds a key's output by the key's witness token: the
registry's active witness policy with the key's bytes
as the asset name, asked of the provider as the holders of that asset. It
does not list every output at the application address, and the leaf is
still proved against the state root as it was. The facts these rows compare
with are read from the chain fixture (the output the receipt names, the
pins in the state datum), never from the code that derives the asset.
-}
witnessReachRows :: Spec
witnessReachRows = describe "the key reached by its witness token" $ do
    forM_ ["alice-1", "k", replicate 32 'z'] $ \key ->
        it
            ( "an active key of "
                <> show (length key)
                <> " bytes is found by its witness and the application address is not listed"
            )
            $ withRegistry
            $ \rig token -> do
                activeKey rig token key
                (queries, inspected) <- inspectRecording rig token key
                let receipt = runReceipt inspected
                    bytes = BC.pack key
                outcomeOf receipt `shouldBe` Just "success"
                valueAt "leaf" receipt `shouldBe` Just (Aeson.String "active")
                output <- heldOutput receipt
                (policy, address) <- holdingOf rig output bytes
                queries
                    `shouldContain` [Cage.HoldingAsset (policy, AssetName (SBS.toShort bytes))]
                queries `shouldNotContain` [Cage.AtAddress address]
    it
        "the receipt names the witness looked up and the output that holds it"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            (_, inspected) <- inspectRecording rig token "alice-1"
            let receipt = runReceipt inspected
            output <- heldOutput receipt
            (policy, _) <- holdingOf rig output "alice-1"
            let witness = valueAt "witness" receipt
            (witness >>= valueAt "active")
                `shouldBe` Just
                    ( Aeson.object
                        [ "policy" .= hexText (policyBytes policy)
                        , "assetName" .= hexText "alice-1"
                        , "holders" .= [output]
                        ]
                    )
    it
        "a terminated key is reached by its witness and nothing holds the token"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            terminated <-
                run
                    rig
                    "terminate"
                    (["open-datum", "terminate", "--key", "alice-1"] <> tokenArgs token)
            outcomeOf (runReceipt terminated) `shouldBe` Just "success"
            folded <-
                run
                    rig
                    "fold terminal"
                    (["open-datum", "fold"] <> requestOf terminated <> tokenArgs token)
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            (queries, inspected) <- inspectRecording rig token "alice-1"
            let receipt = runReceipt inspected
            outcomeOf receipt `shouldBe` Just "success"
            valueAt "leaf" receipt `shouldBe` Just (Aeson.String "terminal")
            active <- statePins rig token
            let name = AssetName (SBS.toShort "alice-1")
                asset policy = Cage.HoldingAsset (PolicyID (policyOf policy), name)
            queries `shouldContain` [asset active]
            let witness = valueAt "witness" receipt
            (witness >>= valueAt "active" >>= valueAt "holders")
                `shouldBe` Just (Aeson.toJSON ([] :: [Text]))
            (witness >>= valueAt "active" >>= textAt "policy")
                `shouldBe` Just (hexText active)
    it
        "a key never registered is answered as it was: no witness field, the same fields, the same exit"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            (_, inspected) <- inspectRecording rig token "nobody"
            let receipt = runReceipt inspected
            runExit inspected `shouldBe` ExitSuccess
            outcomeOf receipt `shouldBe` Just "success"
            valueAt "witness" receipt `shouldBe` Nothing
            topLevelKeys receipt `shouldBe` neverRegisteredFields
    it
        "a provider that cannot answer the witness query makes inspect refuse naming the provider"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            let key = "alice-1" :: BS.ByteString
                refusing =
                    (capabilities rig)
                        { capReads =
                            let (network, provider) = rawChainProvider (rigChain rig)
                                failing =
                                    provider
                                        { Cage.acquire = \requested action ->
                                            Cage.acquire provider requested $ \session ->
                                                action
                                                    session
                                                        { Cage.outputs = \query -> case query of
                                                            Cage.HoldingAsset (_, AssetName name)
                                                                | SBS.fromShort name == key ->
                                                                    pure (Left (Cage.BackendReadFailure "refused"))
                                                            _ -> Cage.outputs session query
                                                        }
                                        }
                            in  ( network
                                , observeProvider unverifiedVerifier (\_ -> pure ()) failing
                                )
                        }
            inspected <-
                runVia
                    rig
                    ( (envOf rig)
                        { envReads = \_ k -> k refusing
                        , envWrites = \_ k -> k refusing
                        }
                    )
                    "empty-actor"
                    "inspect with the witness read refused"
                    (["open-datum", "inspect", "--key", "alice-1"] <> tokenArgs token)
            outcomeOf (runReceipt inspected) `shouldBe` Just "node-unavailable"
            runExit inspected `shouldNotBe` ExitSuccess
            -- the registry was resolved and its pin compared before the read
            -- failed, so the refusal says so as every refusal after it does
            valueAt "applicationPin" (runReceipt inspected)
                `shouldBe` Just (Aeson.String "compared")

-- | A key booked and folded, so that it is active.
activeKey :: Rig -> String -> String -> IO ()
activeKey rig token key = do
    path <- payloadFile rig "witness-payload.json" "0"
    booked <-
        run
            rig
            "insert"
            ( ["open-datum", "insert", "--key", key, "--payload", path]
                <> tokenArgs token
            )
    outcomeOf (runReceipt booked) `shouldBe` Just "success"
    folded <-
        run
            rig
            "fold"
            (["open-datum", "fold"] <> requestOf booked <> tokenArgs token)
    outcomeOf (runReceipt folded) `shouldBe` Just "success"

{- | An inspect of a key from an empty directory, with every output query the
provider answered for it, in order.
-}
inspectRecording
    :: Rig -> String -> String -> IO ([Cage.OutputQuery], Run)
inspectRecording rig token key = do
    seen <- newIORef []
    let recording = recordingCapabilities seen rig
    inspected <-
        runVia
            rig
            ( (envOf rig)
                { envReads = \_ k -> k recording
                , envWrites = \_ k -> k recording
                }
            )
            "empty-actor"
            ("inspect " <> key)
            (["open-datum", "inspect", "--key", key] <> tokenArgs token)
    queries <- readIORef seen
    pure (queries, inspected)

-- | The output a receipt says holds the key.
heldOutput :: Aeson.Value -> IO Text
heldOutput receipt =
    maybe
        (fail ("the receipt names no output for the key: " <> show receipt))
        pure
        (valueAt "applicationOutput" receipt >>= textAt "output")

{- | The policy that names the key in an output, and the output's address,
read from the chain fixture.
-}
holdingOf :: Rig -> Text -> BS.ByteString -> IO (PolicyID, Addr)
holdingOf rig output key = do
    ref <- either fail pure (parseOutRef output)
    answer <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            Cage.outputs v (Cage.AtTxIn ref)
    held <- either (fail . show) (pure . value) answer
    case held of
        [(_, out)] ->
            let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
            in  case [ policy
                     | (policy, names) <- Map.toList assets
                     , Map.member (AssetName (SBS.toShort key)) names
                     ] of
                    [policy] -> pure (policy, out ^. addrTxOutL)
                    other ->
                        fail
                            ( "the output holds the key's token under "
                                <> show (length other)
                                <> " policies"
                            )
        _ -> fail "the output the receipt names is not live"

{- | The active and the terminal policies the registry's state datum pins,
read from the chain fixture.
-}
statePins :: Rig -> String -> IO BS.ByteString
statePins rig token = do
    asset <-
        either (fail . T.unpack) pure (parseStateToken (T.pack token))
    answer <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            Cage.outputs v (Cage.HoldingAsset asset)
    held <- either (fail . show) (pure . value) answer
    case [ st | (_, out) <- held, Just (StateDatum st) <- [extractCageDatum out]
         ] of
        st : _ -> pure (stateActivePolicyBytes st)
        [] -> fail "the state output carries no state datum"

policyBytes :: PolicyID -> BS.ByteString
policyBytes (PolicyID hash) = scriptHashBytes hash

policyOf :: BS.ByteString -> ScriptHash
policyOf bytes = case hashFromBytes bytes of
    Just hash -> ScriptHash hash
    Nothing -> error "policyOf: not a 28-byte hash"

-- | The names of the fields a receipt prints at its top level, in order.
topLevelKeys :: Aeson.Value -> [Text]
topLevelKeys = \case
    Aeson.Object fields -> sort (map AesonKey.toText (KeyMap.keys fields))
    _ -> []

{- | The top-level fields of the receipt of an inspect of a key the registry
never recorded, as the base build (main with the pin gate of issue 730) printed them.
-}
neverRegisteredFields :: [Text]
neverRegisteredFields =
    [ "applicationOutput"
    , "applicationPin"
    , "command"
    , "fingerprint"
    , "freshness"
    , "key"
    , "keyText"
    , "leaf"
    , "mechanism"
    , "observedTip"
    , "outcome"
    , "pendingRequests"
    , "processTime"
    , "reconciliation"
    , "registry"
    , "retractTime"
    , "root"
    , "sessionEvidence"
    , "stateToken"
    ]

{- | What stays as it was when a key is reached by its witness token: the
address alone names the registry, a key never registered gets the receipt the
base build printed, every refusal of the proof comes before the witness is
read and the proven leaf still has to agree with the holdings, and the
neutral program still prints every output at the application's address.
-}
witnessKeptRows :: Spec
witnessKeptRows = describe "what the witness read leaves as it was" $ do
    it
        "an active key is reached from the address alone, with no state token and no network magic"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            address <- addressOfToken token
            (queries, inspected, line) <- inspectByAddress rig address "alice-1"
            line `shouldSatisfy` notElem "--state-token"
            line `shouldSatisfy` notElem "--network-magic"
            let receipt = runReceipt inspected
            outcomeOf receipt `shouldBe` Just "success"
            valueAt "leaf" receipt `shouldBe` Just (Aeson.String "active")
            textAt "registry" receipt `shouldBe` Just (T.pack address)
            output <- heldOutput receipt
            (policy, _) <- holdingOf rig output "alice-1"
            queries
                `shouldContain` [Cage.HoldingAsset (policy, AssetName (SBS.toShort "alice-1"))]
            (valueAt "witness" receipt >>= valueAt "active" >>= valueAt "holders")
                `shouldBe` Just (Aeson.toJSON [output])
    it
        "a terminated key is reached from the address alone, the witness empty"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            terminateKey rig token "alice-1"
            address <- addressOfToken token
            (_, inspected, _) <- inspectByAddress rig address "alice-1"
            let receipt = runReceipt inspected
            outcomeOf receipt `shouldBe` Just "success"
            valueAt "leaf" receipt `shouldBe` Just (Aeson.String "terminal")
            (valueAt "witness" receipt >>= valueAt "active" >>= valueAt "holders")
                `shouldBe` Just (Aeson.toJSON ([] :: [Text]))
    it
        "a key never registered gets the receipt the base build printed, value for value"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            (_, inspected) <- inspectRecording rig token "nobody"
            runExit inspected `shouldBe` ExitSuccess
            withoutSessionId (runReceipt inspected)
                `shouldBe` baseReceiptOfNobody
    it
        "a root that does not chain is refused as stale before the witness is read"
        $ withRegistry
        $ \rig token -> do
            activeKey rig token "alice-1"
            tamperRoot rig token
            (queries, inspected) <- inspectRecording rig token "alice-1"
            outcomeOf (runReceipt inspected) `shouldBe` Just "stale-state"
            runExit inspected `shouldBe` ExitFailure 14
            policy <- witnessPins rig token
            queries
                `shouldNotContain` [Cage.HoldingAsset (policy, AssetName (SBS.toShort "alice-1"))]
    describe "a leaf the holdings do not agree with is refused" $ do
        it "an active leaf with no holding" $
            withRegistry $ \rig token -> do
                activeKey rig token "alice-1"
                output <- inspectedOutput rig token "alice-1"
                ref <- either fail pure (parseOutRef output)
                advanceChain (rigChain rig) $ \facts ->
                    facts{csUTxO = Map.delete ref (csUTxO facts)}
                refusedWith rig token "active with 0 holding(s)"
        it "an active leaf with two holdings" $
            withRegistry $ \rig token -> do
                activeKey rig token "alice-1"
                output <- inspectedOutput rig token "alice-1"
                copyOutput rig output
                refusedWith rig token "active with 2 holding(s)"
        it "a terminal leaf with an active holding" $
            withRegistry $ \rig token -> do
                activeKey rig token "alice-1"
                output <- inspectedOutput rig token "alice-1"
                held <- chainOutput rig output
                terminateKey rig token "alice-1"
                plantOutput rig held
                refusedWith rig token "terminal with 1 holding(s)"
    describe "the declaration of an application's holding rule" $ do
        it "the open datum's rule requires the token, and says so" $
            fmap hrRequiresToken (appHolding openDatumApplication)
                `shouldBe` Just True
        it
            "a rule that needs no token is judged over every output at the address: a tokenless duplicate of the holding is a second holding"
            $ withRegistry
            $ \rig token -> do
                (address, duplicated) <- plantedTokenless rig token
                duplicated `shouldBe` True
                (queries, code, receipt) <-
                    inspectWith tokenlessApplication rig token "alice-1"
                queries `shouldContain` [Cage.AtAddress address]
                code `shouldBe` ExitFailure 18
                outcomeOf receipt `shouldBe` Just "proof-inconsistent"
                textAt "refusal" receipt
                    `shouldSatisfy` maybe False (T.isSuffixOf "active with 2 holding(s)")
        it
            "a rule that requires the token neither asks for nor counts the tokenless duplicate"
            $ withRegistry
            $ \rig token -> do
                (address, _) <- plantedTokenless rig token
                (queries, code, receipt) <-
                    inspectWith openDatumApplication rig token "alice-1"
                queries `shouldNotContain` [Cage.AtAddress address]
                code `shouldBe` ExitSuccess
                outcomeOf receipt `shouldBe` Just "success"
                valueAt "leaf" receipt `shouldBe` Just (Aeson.String "active")

-- | The address of a state token on the rig's network.
addressOfToken :: String -> IO String
addressOfToken token =
    maybe
        (fail ("no address for " <> token))
        pure
        (addressOf (fromIntegral magic) token)

{- | An inspect of a key by the registry's address alone: the line carries
no state token and no network magic. It returns the output queries answered,
the run and the words of the line.
-}
inspectByAddress
    :: Rig -> String -> String -> IO ([Cage.OutputQuery], Run, [String])
inspectByAddress rig address key = do
    seen <- newIORef []
    let line =
            withoutMagic
                ( commandLine
                    rig
                    "empty-actor"
                    ["open-datum", "inspect", "--key", key, "--registry", address]
                )
        recording = recordingCapabilities seen rig
        env =
            (envOf rig)
                { envReads = \_ k -> k recording
                , envWrites = \_ k -> k recording
                }
    writeIORef (rigEvents rig) []
    command <-
        either (fail . renderCLIError) pure (parseOpenDatumCommand line)
    (code, out, _) <- captured (runOpenDatum env command)
    receipt <-
        maybe
            (fail ("no receipt: " <> show out))
            pure
            (Aeson.decodeStrict out)
    events <- readIORef (rigEvents rig)
    queries <- readIORef seen
    pure
        ( queries
        , Run
            { runName = constructorOf command
            , runLabel = "inspect by the address"
            , runExit = code
            , runReceipt = receipt
            , runEvents = events
            , runKey = Nothing
            }
        , line
        )

-- | The rig's capabilities, every output query it answers also noted.
recordingCapabilities
    :: IORef [Cage.OutputQuery] -> Rig -> Capabilities NoWitness IO
recordingCapabilities seen rig =
    (capabilities rig)
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
                noting =
                    provider
                        { Cage.acquire = \requested action ->
                            Cage.acquire provider requested $ \session ->
                                action
                                    session
                                        { Cage.outputs = \query ->
                                            modifyIORef' seen (<> [query])
                                                >> Cage.outputs session query
                                        }
                        }
            in  ( network
                , observeProvider unverifiedVerifier (\_ -> pure ()) noting
                )
        }

-- | A key booked, folded and then terminated and folded again.
terminateKey :: Rig -> String -> String -> IO ()
terminateKey rig token key = do
    terminated <-
        run
            rig
            "terminate"
            (["open-datum", "terminate", "--key", key] <> tokenArgs token)
    outcomeOf (runReceipt terminated) `shouldBe` Just "success"
    folded <-
        run
            rig
            "fold terminal"
            (["open-datum", "fold"] <> requestOf terminated <> tokenArgs token)
    outcomeOf (runReceipt folded) `shouldBe` Just "success"

-- | The output the receipt of an inspect names for an active key.
inspectedOutput :: Rig -> String -> String -> IO Text
inspectedOutput rig token key = do
    inspected <-
        run
            rig
            ("inspect " <> key)
            (["open-datum", "inspect", "--key", key] <> tokenArgs token)
    heldOutput (runReceipt inspected)

-- | A live output of the chain fixture, by its reference.
chainOutput :: Rig -> Text -> IO (TxOut ConwayEra)
chainOutput rig output = do
    ref <- either fail pure (parseOutRef output)
    answer <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            Cage.outputs v (Cage.AtTxIn ref)
    held <- either (fail . show) (pure . value) answer
    case held of
        [(_, out)] -> pure out
        _ -> fail "the output is not live"

-- | Put an output on the chain fixture under a reference nothing else has.
plantOutput :: Rig -> TxOut ConwayEra -> IO ()
plantOutput rig out = do
    ref <-
        either fail pure $
            parseOutRef (T.pack (replicate 64 'c' <> "#7"))
    advanceChain (rigChain rig) $ \facts ->
        facts{csUTxO = Map.insert ref out (csUTxO facts)}

-- | A second output like a live one, so that the key has two holdings.
copyOutput :: Rig -> Text -> IO ()
copyOutput rig output = chainOutput rig output >>= plantOutput rig

{- | Change the root in the state datum of the registry, so that the
registry's public history no longer chains to it.
-}
tamperRoot :: Rig -> String -> IO ()
tamperRoot rig token = do
    asset <-
        either (fail . T.unpack) pure (parseStateToken (T.pack token))
    answer <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            Cage.outputs v (Cage.HoldingAsset asset)
    held <- either (fail . show) (pure . value) answer
    case [ (ref, out, st)
         | (ref, out) <- held
         , Just (StateDatum st) <- [extractCageDatum out]
         ] of
        (ref, out, st) : _ -> do
            let wrong = st{stateRoot = OnChainRoot (BS.replicate 32 0xab)}
                changed = out & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum wrong))
            advanceChain (rigChain rig) $ \facts ->
                facts{csUTxO = Map.insert ref changed (csUTxO facts)}
        [] -> fail "the state output carries no state datum"

{- | The active witness policy of the registry, read
from the state datum (for the queries a refusal must not have made).
-}
witnessPins :: Rig -> String -> IO PolicyID
witnessPins rig token = do
    active <- statePins rig token
    pure (PolicyID (policyOf active))

-- | An inspect that is refused because the leaf and the holdings disagree.
refusedWith :: Rig -> String -> Text -> IO ()
refusedWith rig token expected = do
    inspected <-
        run
            rig
            "inspect"
            (["open-datum", "inspect", "--key", "alice-1"] <> tokenArgs token)
    outcomeOf (runReceipt inspected) `shouldBe` Just "proof-inconsistent"
    runExit inspected `shouldBe` ExitFailure 18
    textAt "refusal" (runReceipt inspected)
        `shouldSatisfy` maybe False (T.isSuffixOf expected)

-- | The words of the neutral program's inspect of a key, from an empty directory.
neutralLine :: Rig -> String -> String -> [String]
neutralLine rig token key =
    ["open-datum", "inspect", "--key", key]
        <> tokenArgs token
        <> [ "--state-dir"
           , rigDir rig </> "empty-actor"
           , "--blueprint"
           , rigBlueprint rig
           , "--koios-url"
           , "http://fixture.invalid"
           , "--network-magic"
           , show magic
           ]

{- | An inspect of a key by an application value over the open-datum registry,
with every output query the provider answered for it, its exit and its receipt.
-}
inspectWith
    :: Application
    -> Rig
    -> String
    -> String
    -> IO ([Cage.OutputQuery], ExitCode, Aeson.Value)
inspectWith app rig token key = do
    seen <- newIORef []
    let recording = recordingCapabilities seen rig
        env =
            (envOf rig)
                { envReads = \_ k -> k recording
                , envWrites = \_ k -> k recording
                }
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . show)
            pure
            (parseOpenDatumCommand (neutralLine rig token key))
    (code, out, _) <- captured $ case command of
        OpenInspect args -> finish (envTracer env) "inspect" Nothing (runInspect app env args)
        _ -> fail "the retained open-datum inspect fixture did not parse"
    receipt <-
        maybe
            (fail ("no receipt: " <> show out))
            pure
            (Aeson.decodeStrict out)
    queries <- readIORef seen
    pure (queries, code, receipt)

{- | An application whose holding rule is the stub's in shape: an output at the
application address whose datum reads as a holding of the key is one, whether
or not it holds the key's token. It says so, as the stub does.
-}
tokenlessApplication :: Application
tokenlessApplication =
    openDatumApplication
        { appHolding = loosened <$> appHolding openDatumApplication
        }
  where
    loosened rules =
        rules
            { hrRequiresToken = False
            , hrFindHoldings = \_ _ key outs ->
                [ (u, found)
                | u@(_, o) <- outs
                , Just (Decoder decode) <- [appDecoder openDatumApplication]
                , Right found <- [decode o]
                , dhKey found == key
                ]
            }

{- | A registry with the key alice-1 active and, beside its holding, a copy of
the holding that holds no token. It returns the application address and
whether the plant is a second output there.
-}
plantedTokenless :: Rig -> String -> IO (Addr, Bool)
plantedTokenless rig token = do
    activeKey rig token "alice-1"
    output <- inspectedOutput rig token "alice-1"
    held <- chainOutput rig output
    (_, address) <- holdingOf rig output "alice-1"
    let MaryValue coin _ = held ^. valueTxOutL
    plantOutput rig (held & valueTxOutL .~ MaryValue coin mempty)
    atAddress <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v address
    pure (address, length atAddress == 2)

-- | A receipt without the identifier of the session that read it, which counts runs.
withoutSessionId :: Aeson.Value -> Aeson.Value
withoutSessionId = \case
    Aeson.Object fields ->
        Aeson.Object
            ( maybe
                fields
                ( \evidence -> KeyMap.insert "sessionEvidence" (dropSession evidence) fields
                )
                (KeyMap.lookup "sessionEvidence" fields)
            )
    other -> other
  where
    dropSession = \case
        Aeson.Object evidence -> Aeson.Object (KeyMap.delete "session" evidence)
        other -> other

{- | The receipt the base build (main with the pin gate of issue 730) printed for
an inspect of a key never registered, in a registry whose only key is @alice-1@,
active: every value, the leaf included, except the identifier of the reading
session.
-}
baseReceiptOfNobody :: Aeson.Value
baseReceiptOfNobody =
    Aeson.object
        [
            ( "applicationOutput"
            , Aeson.object
                [ ("absent", s "no live output holds key 0x6e6f626f6479")
                , ("holdings", Aeson.Array mempty)
                ]
            )
        , ("applicationPin", s "compared")
        , ("command", s "inspect")
        , ("fingerprint", s "asset1frauxgeawqdk3r7jj7e9xxkwug8x5z0qjt9j8a")
        , ("freshness", s "Latest reads in this process; no snapshot binding")
        , ("key", s "6e6f626f6479")
        , ("keyText", s "nobody")
        , ("leaf", s "unknown")
        , ("mechanism", s "Koios raw facts through the shared HTTP transport")
        ,
            ( "observedTip"
            , s
                "8.0000000000000000000000000000000000000000000000000000000000000008"
            )
        , ("outcome", s "success")
        , ("pendingRequests", Aeson.Array mempty)
        , ("processTime", Aeson.Number 600_000)
        ,
            ( "reconciliation"
            , s "stateless public read: no wallet journal checked"
            )
        ,
            ( "registry"
            , s
                "singular_devnet1rphr974gpgngzqujlknd2kw8a4rjrfjuu8yafme7rjrmg8a70pkyk0mj9tpt7p0hf38dn2t2twqhznvz9qdpe7xmfxdpk9xneg9p59"
            )
        , ("retractTime", Aeson.Number 300_000)
        ,
            ( "root"
            , s "58397587c712dcf8e99043ab07b63dfe38fe3628000a1b09e4805f647570b76b"
            )
        ,
            ( "sessionEvidence"
            , Aeson.object
                [ ("binding", Aeson.object [("kind", s "Unbound")])
                , ("facts", Aeson.Array mempty)
                , ("networkMagic", Aeson.Number 42)
                , ("rawSources", Aeson.Array mempty)
                ]
            )
        ,
            ( "stateToken"
            , s
                "186e32faa80a26810392fda6d559c7ed4721a65ce1c9d4ef3e1c87b4.1fbe786c4b3f722ac2bf05f74c4ed9a96a5b81714d82281a1cf8db499a1b14d3"
            )
        ]
  where
    s :: Text -> Aeson.Value
    s = Aeson.String

-- | The state token a registry the rig made has, and its address on the rig's network.
madeRegistry :: Rig -> IO (String, String)
madeRegistry rig = do
    seed <- fundSeed rig
    made <- run rig "create" ["open-datum", "create", "--seed", seed]
    token <- tokenOf made
    address <-
        maybe
            (fail ("no address for " <> token))
            pure
            (addressOf (fromIntegral magic) token)
    pure (token, address)

-- | A command line without its network magic.
withoutMagic :: [String] -> [String]
withoutMagic = \case
    "--network-magic" : _ : rest -> withoutMagic rest
    word : rest -> word : withoutMagic rest
    [] -> []

{- | The state-contract hash of each published release's blueprint, read from
the blueprint's own @state.state@ validator with @jq@, with the releases that
carry it, oldest first: the same facts as the registry command suite.
-}
releasedContracts :: [(String, [String])]
releasedContracts =
    [
        ( "8ac9562f5fb6be9b9b913ae2ad2cc1d9e038f7f7039256f1ac9f7a62"
        , ["v0.4.1", "v0.5.0", "v0.6.0", "v0.6.1"]
        )
    ,
        ( "7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c"
        , ["v0.8.0", "v0.9.0"]
        )
    ,
        ( "68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5"
        ,
            [ "v0.10.0"
            , "v0.10.1"
            , "v0.11.0"
            , "v0.12.0"
            , "v0.13.0"
            , "v0.13.1"
            , "v0.14.0"
            , "v0.15.0"
            ]
        )
    ]

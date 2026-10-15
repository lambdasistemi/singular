{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.CommandRunSpec
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
module Singular.CLI.CommandRunSpec (spec) where

import Control.Applicative ((<|>))
import Control.Concurrent
    ( myThreadId
    , newEmptyMVar
    , putMVar
    , readMVar
    , threadDelay
    , throwTo
    , tryPutMVar
    )
import Control.Concurrent.Async
    ( asyncThreadId
    , cancel
    , waitCatch
    , withAsync
    )
import Control.Exception
    ( AsyncException (..)
    , ErrorCall (..)
    , bracket
    , finally
    , fromException
    , throwIO
    , try
    , uninterruptibleMask_
    )
import Control.Monad (void, when)
import Control.Tracer (Tracer (..))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (forM_, toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, nub, partition, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing, listToMaybe)
import Data.Ord (Down (..))
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import GHC.Generics
    ( C1
    , Constructor
    , D1
    , Generic (..)
    , conName
    , (:+:)
    )
import Lens.Micro ((&), (.~), (^.))
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , doesFileExist
    , listDirectory
    , removePathForcibly
    )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO
    ( IOMode (..)
    , hClose
    , hFlush
    , openFile
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
import System.Timeout (timeout)
import Test.Hspec

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
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
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Word (Word64)

import PlutusCore.Data qualified as PLC
import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( CLIError (..)
    , Command (..)
    , FoldArgs (..)
    , parseCommand
    , renderCLIError
    )
import Singular.CLI.Finish (finish)
import Singular.CLI.Fold (runFoldBounded)
import Singular.CLI.Receipt (FoldTransition (..), JournalEntry (..))
import Singular.CLI.ReceiptBody (boundBody)
import Singular.CLI.Registry
    ( economics
    , loadRelease
    , loadReleaseCodes
    , registryConfigFor
    )
import Singular.CLI.Root (runPackagedVia)
import Singular.CLI.Session (Env (..), txIdHex)
import Singular.CLI.Trace
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , DecodedHolding (..)
    , HoldingRules (..)
    , datumCbor
    , datumHash
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (RegistryEconomics (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , unverifiedVerifier
    )
import Singular.Registry.FoldSelection (foldCapacity)
import Singular.Registry.Ledger (Coin (..), ConwayEra, TokenId (..))
import Singular.Registry.LedgerProvider qualified as Cage
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
import Singular.Registry.Signing (signedTx)
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trace (ReadEvent (Evaluated))
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , approvalDestination
    , approvalName
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , currentPosixMs
    , extractCageDatum
    , extractOwnerBytes
    , findStateUtxo
    , mkInlineDatum
    , mkRequestDatumWith
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.Internal.Identity (txInToRef)
import Singular.Registry.TxBuilder.Request (requestEdgeImpl)
import Singular.Registry.TxBuilder.Update (RegistryContext (..))
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , edgeInsertActive
    , edgeName
    , edgeUpdateTerminal
    , stateAppPolicyBytes
    )
import Singular.Registry.WaitTypes (WaitFailure (..), WaitStage (..))
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec =
    handlerRows
        >> setupRecut
        >> readbackRows
        >> permanentRecognition
        >> applicationPolicyRows
        >> confirmationLifetime
        >> journalTransitionsRow
        >> foldOverSeveralRequestsRow
        >> settledListSingletonRow
        >> createDescribeCommandRows
        >> prepareFundingRows

{- | The create receipt carries the working describe line, built from the
arguments the create ran with. Two registries give two tokens, so a fixed
line cannot pass. Values the test checks against are read from the run
itself, never typed. The printed line, run as printed through the same
fixture, exits successfully with the page.
-}
createDescribeCommandRows :: Spec
createDescribeCommandRows = describe "Create prints the describe command" $ do
    it "carries the working describe line in each create receipt" $ withRig $ \rig -> do
        writeFile
            (takeDirectory (rigBlueprint rig) </> "version.txt")
            "0.10.1\n"
        firstSeed <- fundSeed rig
        previewedRun <-
            run
                rig
                "preview with time directory"
                ( [ "registry"
                  , "create"
                  , "--preview"
                  , "--seed"
                  , firstSeed
                  , "--network-time"
                  , rigDir rig
                  ]
                    <> policyArgs
                )
        outcomeOf (runReceipt previewedRun) `shouldBe` Just "success"
        previewedToken <- tokenOf previewedRun
        previewedLine <- case valueAt "describeCommand" (runReceipt previewedRun) of
            Just (Aeson.String line) -> pure line
            other ->
                expectationFailure
                    ("the preview carries no describe line: " <> show other)
                    >> pure ""
        checkPrinted rig previewedToken previewedLine True (Just (rigDir rig))
        firstRun <-
            run
                rig
                "first create"
                (["registry", "create", "--seed", firstSeed] <> policyArgs)
        outcomeOf (runReceipt firstRun) `shouldBe` Just "success"
        firstToken <- tokenOf firstRun
        firstToken `shouldBe` previewedToken
        firstLine <- case valueAt "describeCommand" (runReceipt firstRun) of
            Just (Aeson.String line) -> pure line
            other ->
                expectationFailure
                    ("the first create carries no describe line: " <> show other)
                    >> pure ""
        checkPrinted rig firstToken firstLine False Nothing
        secondSeed <- fundSeed2 rig
        secondRun <-
            run
                rig
                "second create"
                (["registry", "create", "--seed", secondSeed] <> policyArgs)
        outcomeOf (runReceipt secondRun) `shouldBe` Just "success"
        secondToken <- tokenOf secondRun
        secondLine <- case valueAt "describeCommand" (runReceipt secondRun) of
            Just (Aeson.String line) -> pure line
            other ->
                expectationFailure
                    ("the second create carries no describe line: " <> show other)
                    >> pure ""
        secondToken `shouldSatisfy` (/= firstToken)
        secondLine `shouldSatisfy` (/= firstLine)
        checkPrinted rig secondToken secondLine False Nothing
        runPrinted rig previewedToken previewedLine
        runPrinted rig firstToken firstLine
        runPrinted rig secondToken secondLine
  where
    allowedFlags =
        [ "--blueprint"
        , "--state-token"
        , "--koios-url"
        , "--network-magic"
        , "--network-time"
        ]
    requiredFlags = ["--blueprint", "--state-token", "--koios-url", "--network-magic"]
    checkPrinted rig token line withTime timeDir = do
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
        T.isInfixOf (T.pack (rigDir rig </> "registry")) line `shouldBe` False
        case (withTime, timeDir) of
            (True, Just dir) -> do
                ("--network-time" `elem` flags) `shouldBe` True
                T.isInfixOf (T.pack dir) line `shouldBe` True
            _ -> ("--network-time" `elem` flags) `shouldBe` False
    runPrinted rig token line = do
        let parts = words (T.unpack line)
        commandWords <- case parts of
            ("singular" : rest) -> pure rest
            _ ->
                expectationFailure
                    ( "the printed line does not start with the binary name: "
                        <> T.unpack line
                    )
                    >> pure []
        command <- either (fail . show) pure (parseCommand commandWords)
        (code, out, _) <-
            captured (runCommand neutralApplication (envOf rig) command)
        code `shouldBe` ExitSuccess
        let page = TE.decodeUtf8 out
        T.isInfixOf "command: describe" page `shouldBe` True
        T.isInfixOf (T.pack token) page `shouldBe` True

confirmationLifetime :: Spec
confirmationLifetime = describe "CLI confirmation lifetime" $ do
    -- Observation needs a second harness thread so cancellation occurs only
    -- after command entry. withAsync joins it; the fake's finally releases
    -- its barrier even when an assertion fails. This is the preserved RED.
    it
        "releases confirmation when the submitted command's parent is cancelled"
        $ withRig
        $ \rig -> do
            started <- newEmptyMVar
            released <- newEmptyMVar
            hold <- newEmptyMVar
            let confirm _ =
                    (myThreadId >>= putMVar started >> readMVar hold)
                        `finally` putMVar released ()
                env =
                    (envOf rig)
                        { envWrites = \_ _ action ->
                            action (capabilities rig){capConfirm = confirm}
                        }
            seed <- fundSeed rig
            withAsync
                ( runVia
                    rig
                    env
                    "registry"
                    "cancel-create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
                )
                $ \parent -> do
                    worker <- timeout 10_000_000 (readMVar started)
                    case worker of
                        Nothing -> expectationFailure "confirmation was never allocated"
                        Just tid ->
                            ( do
                                timeout 3_000_000 (cancel parent) `shouldReturn` Just ()
                                timeout 1_000_000 (readMVar released) `shouldReturn` Just ()
                            )
                                `finally` (throwTo tid ThreadKilled >> readMVar released)

    it "confirms each signed transaction on the command's calling thread" $
        withRig $ \rig -> do
            caller <- myThreadId
            confirmed <- newIORef []
            let confirm tx = do
                    myThreadId `shouldReturn` caller
                    modifyIORef' confirmed (<> [txIdHex tx])
            withConfirmationEnv rig confirm $ \env submitted -> do
                result <- confirmationCreate rig env []
                outcomeOf (runReceipt result) `shouldBe` Just "success"
                runExit result `shouldBe` ExitSuccess
                identities <- submitted
                identities `shouldSatisfy` (not . null)
                nub identities `shouldBe` identities
                readIORef confirmed `shouldReturn` identities
                confirmationJournal rig "confirmed" `shouldReturn` map Just identities

    it "journals accepted bytes once when the confirmation provider fails" $
        withRig $ \rig ->
            withConfirmationEnv
                rig
                (const (throwIO (ErrorCall "confirmation provider failed")))
                $ \env submitted -> do
                    result <- confirmationCreate rig env []
                    outcomeOf (runReceipt result) `shouldBe` Just "partial"
                    assertUnconfirmed rig submitted

    it "keeps the synchronous fallback receipt before submission" $
        withRig $ \rig ->
            withConfirmationEnv rig (const (pure ())) $ \env submitted -> do
                let failing =
                        env
                            { envLoadRelease = \_ _ ->
                                throwIO (ErrorCall "release loading failed")
                            }
                result <- confirmationCreate rig failing []
                outcomeOf (runReceipt result) `shouldBe` Just "client-refusal"
                runExit result `shouldBe` ExitFailure 10
                textAt "reason" (runReceipt result)
                    `shouldBe` Just "release loading failed"
                submitted `shouldReturn` []
                confirmationJournal rig "submitted" `shouldReturn` []

    it "interrupts an entered confirmation at a positive command deadline" $
        withRig $ \rig -> do
            entered <- newIORef False
            released <- newIORef False
            let confirm _ =
                    (writeIORef entered True >> threadDelay 10_000_000)
                        `finally` writeIORef released True
            withConfirmationEnv rig confirm $ \env submitted -> do
                result <- confirmationCreate rig env ["--confirm-timeout", "1"]
                outcomeOf (runReceipt result) `shouldBe` Just "timeout"
                readIORef entered `shouldReturn` True
                readIORef released `shouldReturn` True
                assertUnconfirmed rig submitted

    it "preserves caller cancellation and the unresolved signed identity" $
        withRig $ \rig -> do
            entered <- newEmptyMVar
            released <- newEmptyMVar
            hold <- newEmptyMVar
            let confirm _ =
                    (putMVar entered () >> readMVar hold)
                        `finally` putMVar released ()
            withConfirmationEnv rig confirm $ \env submitted ->
                -- The harness must observe entry before interrupting the
                -- command. It owns and joins this one observation thread.
                withAsync (confirmationCreate rig env []) $ \command -> do
                    timeout 10_000_000 (readMVar entered) `shouldReturn` Just ()
                    throwTo (asyncThreadId command) ThreadKilled
                    waitCatch command >>= \case
                        Left failure -> fromException failure `shouldBe` Just ThreadKilled
                        Right _ -> expectationFailure "caller cancellation became a command verdict"
                    timeout 1_000_000 (readMVar released) `shouldReturn` Just ()
                    assertUnconfirmed rig submitted

    it "preserves an entered confirmation's infrastructure wait failure" $
        withRig $ \rig -> do
            entered <- newIORef Nothing
            let confirm tx = do
                    let failure =
                            WaitFailure
                                SessionConfirmationWait
                                (txIdTx tx)
                                1.25
                                1
                                (Just 12_345)
                    writeIORef entered (Just failure)
                    throwIO failure
                identity failure =
                    ( waitStage failure
                    , waitTxId failure
                    , waitElapsed failure
                    , waitBound failure
                    , waitClosedAt failure
                    )
            withConfirmationEnv rig confirm $ \env submitted -> do
                result <- try (confirmationCreate rig env [])
                case result of
                    Left failure -> do
                        expected <- readIORef entered
                        Just (identity failure) `shouldBe` fmap identity expected
                    Right _ ->
                        expectationFailure
                            "infrastructure wait failure became a command verdict"
                assertUnconfirmed rig submitted

    it
        "does not return while an uninterruptible confirmation is held, then joins it"
        $ withRig
        $ \rig -> do
            entered <- newEmptyMVar
            released <- newEmptyMVar
            hold <- newEmptyMVar
            let confirm _ =
                    uninterruptibleMask_ (myThreadId >>= putMVar entered >> readMVar hold)
                        `finally` putMVar released ()
            withConfirmationEnv rig confirm $ \env submitted ->
                -- A second harness thread is necessary to observe nonreturn
                -- and release the deliberate obstruction. Its finally opens
                -- the gate and joins the command, including on assertion failure.
                withAsync (confirmationCreate rig env ["--confirm-timeout", "1"]) $ \command ->
                    ( do
                        timeout 10_000_000 (readMVar entered)
                            `shouldReturn` Just (asyncThreadId command)
                        observed <- timeout 1_500_000 (waitCatch command)
                        isNothing observed `shouldBe` True
                    )
                        `finally` do
                            void (tryPutMVar hold ())
                            joined <- timeout 5_000_000 (waitCatch command)
                            case joined of
                                Just (Right result) -> do
                                    outcomeOf (runReceipt result) `shouldBe` Just "timeout"
                                    assertUnconfirmed rig submitted
                                _ ->
                                    expectationFailure
                                        "released command did not join with its deadline outcome"
                            timeout 1_000_000 (readMVar released) `shouldReturn` Just ()

withConfirmationEnv
    :: Rig -> (ConwayTx -> IO ()) -> (Env -> IO [Text] -> IO a) -> IO a
withConfirmationEnv rig confirm use = do
    submitted <- newIORef []
    let original = capabilities rig
        caps =
            original
                { capConfirm = confirm
                , capSubmit = \signed -> do
                    modifyIORef' submitted (<> [txIdHex (signedTx signed)])
                    capSubmit original signed
                }
        env = (envOf rig){envWrites = \_ _ action -> action caps}
    use env (readIORef submitted)

confirmationCreate :: Rig -> Env -> [String] -> IO Run
confirmationCreate rig env flags = do
    seed <- fundSeed rig
    runVia
        rig
        env
        "registry"
        "confirmation-create"
        (["registry", "create", "--seed", seed] <> policyArgs <> flags)

confirmationJournal :: Rig -> Text -> IO [Maybe Text]
confirmationJournal rig event = do
    files <- listDirectoryRecursive (rigDir rig)
    rows <-
        concat
            <$> mapM
                readRows
                [ rigDir rig </> path
                | path <- files
                , takeFileName path == "journal.jsonl"
                ]
    pure
        [ textAt "journalTxId" row
        | row <- rows
        , textAt "journalEvent" row == Just event
        ]
  where
    readRows file =
        mapM
            ( maybe (fail "invalid confirmation journal JSON") pure
                . Aeson.decodeStrict
            )
            . BC.lines
            =<< BS.readFile file

assertUnconfirmed :: Rig -> IO [Text] -> IO ()
assertUnconfirmed rig submitted = do
    identities <- submitted
    length identities `shouldBe` 1
    confirmationJournal rig "submitted" `shouldReturn` map Just identities
    confirmationJournal rig "unconfirmed"
        `shouldReturn` map Just identities
    confirmationJournal rig "confirmed" `shouldReturn` []
    confirmationJournal rig "rejected" `shouldReturn` []

permanentRecognition :: Spec
permanentRecognition = describe "Permanent contract recognition"
    $ it
        "refuses a caller supplied blueprint whose script identities are unknown"
    $ withRig
    $ \rig -> do
        loaded <- loadRelease neutralApplication (rigBlueprint rig)
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

{- | The constructors that print no receipt: help runs nothing, and
the wallet verbs print one address line and keep no state (the
vault spec: standard output is the address alone), so the receipt
harness below names none of them.
-}
commandsWithoutReceipt :: [String]
commandsWithoutReceipt = ["Help", "WalletCreate", "WalletAddress"]

-- | Every receipted command the command line can name, by constructor.
commandNames :: [String]
commandNames =
    sort
        [ n
        | n <- conNames (Proxy :: Proxy (Rep Command))
        , n `notElem` commandsWithoutReceipt
        ]

-- | The constructor a parsed command is.
constructorOf :: Command -> String
constructorOf = \case
    Help -> "Help"
    Create _ _ -> "Create"
    Describe _ -> "Describe"
    Fold _ -> "Fold"
    Reject _ -> "Reject"
    Reclaim _ -> "Reclaim"
    Inspect _ -> "Inspect"
    WalletCreate _ -> "WalletCreate"
    WalletAddress _ -> "WalletAddress"

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
                            (["registry", "create", "--seed", seed] <> policyArgs)
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
                            (["registry", "create", "--seed", seed] <> policyArgs)
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
                            (["registry", "create", "--seed", seed] <> policyArgs)
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
                (["registry", "create", "--seed", first] <> policyArgs)
        second <- fundSeed2 rig
        two <-
            packaged
                rig
                "registry-2"
                "create two"
                (["registry", "create", "--seed", second] <> policyArgs)
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
                ( runPackagedVia
                    (\tracer -> (envOf rig){envTracer = tracer})
                    neutralApplication
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

-- | The registry's validators, each program made from its title and arity.
blueprintOf :: (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintOf program =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= [ validator "state.state" 1
               , validator "request.request" 3
               , validator "script-app.script-app" 2
               , validator "witness.witness" 3
               , validator "witness.witness" 3
               ]
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
        , envWrites = \_ _ k -> k (capabilities rig)
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

-- ---------------------------------------------------------
-- A wallet whose ada sits beside approvals (#491 remainder, PR 1)
-- ---------------------------------------------------------

{- | The rehearsal wallet, reached in process: create from a funded wallet,
then planted bookings, then a reshape that mirrors the shape the devnet
legs reach by real commands and assert at run time there (no ada-only
output, one token-carrying output holding approvals beside the ada,
published reference scripts untouched). The token output rewrites the
largest remaining ada-only wallet output with the same lovelace plus the
approvals the production certification derives for the planted keys, the
lovelace read at run time, never typed; every other ada-only wallet output is deleted. Outputs at other
addresses (requests, state, refunds) are untouched. Returns the count of
distinct approval names the token output holds.
-}
reshapeRehearsalWallet
    :: Rig -> Map.Map PolicyID (Map.Map AssetName Integer) -> IO Int
reshapeRehearsalWallet rig approvals = do
    when (Map.null approvals) $
        fail "reshapeRehearsalWallet: no certified approvals to hold"
    wallet <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v (walletAddr (rigWallet rig))
    case sortOn (Down . adaOf . snd) [u | u@(_, o) <- wallet, adaOnlyOut o] of
        [] ->
            fail
                "reshapeRehearsalWallet: the wallet holds no ada-only output to reshape"
        ((heldIn, heldOut) : rest) -> do
            let Coin lovelace = heldOut ^. coinTxOutL
                made =
                    heldOut
                        & valueTxOutL .~ MaryValue (Coin lovelace) (MultiAsset approvals)
            advanceChain (rigChain rig) $ \facts ->
                facts
                    { csUTxO =
                        Map.insert
                            heldIn
                            made
                            (foldr (Map.delete . fst) (csUTxO facts) rest)
                    }
            pure (length [n | (_, ns) <- Map.toList approvals, n <- Map.keys ns])
  where
    adaOf out = let Coin c = out ^. coinTxOutL in c

{- | Certify the planted requests as real bookings do, then report the
certified assets: for each planted request output, read its datum and bytes
at run time and derive the expected commitment exactly as the fold's own
selection does — @approvalName@ over the request's edge, key and owner with
@approvalDestination@ over the request's destination — under the registry's
application pin read at run time. Planted requests carry no destination
datum, which the neutral fold refuses as unreadable, so each datum is
rewritten first with the wallet address and a stand-in carried datum
(lovelace, edge, key, owner, deposit and submission time untouched); the
commitment is derived from the rewritten datum, exactly what the fold
reads. The rewritten request outputs carry what a certified booking locks,
so the fold's selection passes them for the production reason; the union is
what the rehearsal wallet holds beside its ada, as the devnet legs show a
reject's change doing. Nothing is typed except the key labels the plants
already use.
-}
certifyPlanted
    :: Rig
    -> String
    -> String
    -> RegistryEconomics
    -> [TxIn]
    -> IO (Map.Map PolicyID (Map.Map AssetName Integer))
certifyPlanted rig tokenStr seedStr econ reqIns = do
    seedIn <-
        either
            (fail . ("certifyPlanted seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel econ (txInToRef seedIn)
        pinned = policyIdFromPin (cfgApplicationPolicy cfg)
        walletAt = walletAddr (rigWallet rig)
        walletBytes = serialiseAddr walletAt
        reqAddr = requestAddrFromCfg cfg tid Testnet
    atReq <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v reqAddr
    let found = [(i, o) | (i, o) <- atReq, i `elem` reqIns]
    when (length found /= length reqIns) $
        fail "certifyPlanted: a planted request output is missing"
    certRows <- mapM (certifyOne pinned walletBytes) found
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                foldr (\(i, _, o) m -> Map.insert i o m) (csUTxO facts) certRows
            }
    pure
        ( Map.unionsWith
            (Map.unionWith (+))
            [a | (_, a, _) <- certRows]
        )
  where
    certifyOne pinned walletBytes (i, o) = case extractCageDatum o of
        Just (RequestDatum req) -> do
            let req' = req{requestDestination = (walletBytes, Just (PLC.Constr 0 []))}
                expected =
                    approvalName
                        (requestEdge req')
                        (requestKey req')
                        (extractOwnerBytes o)
                        (approvalDestination (requestDestination req'))
                asset =
                    Map.singleton
                        pinned
                        (Map.singleton (AssetName (SBS.toShort expected)) 1)
                Coin lovelace = o ^. coinTxOutL
                made =
                    o
                        & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req'))
                        & valueTxOutL .~ MaryValue (Coin lovelace) (MultiAsset asset)
            pure (i, asset, made)
        _ ->
            fail
                "certifyPlanted: a planted request output carries no request datum"

-- | Every output of the rig wallet, read at run time.
readWallet :: Rig -> IO [(TxIn, TxOut ConwayEra)]
readWallet rig =
    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
        SessionIO.outputsAt v (walletAddr (rigWallet rig))

-- | How many wallet outputs carry a reference script.
countRefs :: [(TxIn, TxOut ConwayEra)] -> Int
countRefs outs =
    length [() | (_, o) <- outs, o ^. referenceScriptTxOutL /= SNothing]

{- | The command completes. Split from the receipt field so the seam's
wiring shows green before the receipt carries the preparation.
-}
expectCompleted :: String -> Run -> Expectation
expectCompleted command r = case runExit r of
    ExitSuccess -> pure ()
    _ ->
        expectationFailure
            ( command
                <> " from the rehearsal wallet: expected completion; exit="
                <> show (runExit r)
                <> " reason="
                <> show (receiptReason r)
            )

{- | The receipt carries a @preparation@ field naming a transaction, its
made output, what the output holds and the fee, the output bound to the
transaction. Lands with the receipt change.
-}
expectPreparationField :: String -> Run -> Expectation
expectPreparationField command r = case preparationObject (runReceipt r) of
    Nothing ->
        expectationFailure
            ( command
                <> " receipt carries no preparation field; exit="
                <> show (runExit r)
            )
    Just o -> do
        case (KeyMap.lookup "transaction" o, KeyMap.lookup "output" o) of
            (Just (Aeson.String t), Just (Aeson.String u))
                | T.length t == 64
                , t `T.isPrefixOf` u ->
                    pure ()
            _ ->
                expectationFailure
                    (command <> " preparation output is not bound to its transaction")
        case (KeyMap.lookup "lovelace" o, KeyMap.lookup "fee" o) of
            (Just (Aeson.Number _), Just (Aeson.Number _)) -> pure ()
            _ ->
                expectationFailure
                    (command <> " preparation names no lovelace and fee")

preparationObject :: Aeson.Value -> Maybe (KeyMap.KeyMap Aeson.Value)
preparationObject = \case
    Aeson.Object top -> case KeyMap.lookup "preparation" top of
        Just (Aeson.Object o) -> Just o
        _ -> Nothing
    _ -> Nothing

hasPreparation :: Aeson.Value -> Bool
hasPreparation = \case
    Aeson.Object o -> KeyMap.member "preparation" o
    _ -> False

{- | The receipt carries no @preparation@ field: refused before anything
was submitted, or completed with no preparation made.
-}
expectNoPreparation :: String -> Run -> Expectation
expectNoPreparation command r =
    when
        (hasPreparation (runReceipt r))
        ( expectationFailure
            ( command
                <> " receipt carries a preparation field; exit="
                <> show (runExit r)
            )
        )

-- | The receipt submits no transaction: a refusal journalled nothing.
expectNoSubmissions :: String -> Run -> Expectation
expectNoSubmissions command r = case elementsAt "submissions" (runReceipt r) of
    Nothing -> pure ()
    Just [] -> pure ()
    Just _ ->
        expectationFailure
            (command <> " submitted a transaction; exit=" <> show (runExit r))

{- | Shrink the rehearsal wallet's token-carrying output to the given
lovelace, keeping its assets: shapes a short wallet whose spendable ada
cannot cover preparation plus command.
-}
shortenWallet :: Rig -> Integer -> IO ()
shortenWallet rig lovelace = do
    wallet <- readWallet rig
    case [ u
         | u@(_, o) <- wallet
         , not (adaOnlyOut o)
         , o ^. referenceScriptTxOutL == SNothing
         ] of
        [] -> fail "shortenWallet: no token-carrying output to shrink"
        ((i, o) : _) ->
            let MaryValue _ m = o ^. valueTxOutL
            in  advanceChain (rigChain rig) $ \facts ->
                    facts
                        { csUTxO =
                            Map.insert
                                i
                                (o & valueTxOutL .~ MaryValue (Coin lovelace) m)
                                (csUTxO facts)
                        }

prepareFundingRows :: Spec
prepareFundingRows = describe
    "a fold, a reject and a reclaim prepare a funding output (#491)"
    $ do
        it
            "a fold from a wallet with no ada-only output completes with prepared funding"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyA = TE.encodeUtf8 "carol-a"
                    keyB = TE.encodeUtf8 "carol-b"
                (reqA, _) <- plantRequest rig t1 seed economics keyA
                (reqB, _) <- plantRequest rig t1 seed economics keyB
                refsBefore <- countRefs <$> readWallet rig
                assets <- certifyPlanted rig t1 seed economics [reqA, reqB]
                names <- reshapeRehearsalWallet rig assets
                wallet <- readWallet rig
                [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                names `shouldBe` 2
                countRefs wallet `shouldBe` refsBefore
                folded <-
                    run
                        rig
                        "fold from the rehearsal wallet"
                        (["registry", "fold"] <> tokenArgs t1)
                expectCompleted "fold" folded
                expectPreparationField "fold" folded
        it
            "a reject from a wallet with no ada-only output completes with prepared funding"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <-
                    run
                        rig
                        "create"
                        ( ["registry", "create", "--process-time", "1", "--retract-time", "1"]
                            <> policyArgs
                        )
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let shortEcon =
                        RegistryEconomics
                            { reProcessTime = 1
                            , reRetractTime = 1
                            , reTip = Coin 1_000_000
                            }
                    keyA = TE.encodeUtf8 "carol-a"
                    keyB = TE.encodeUtf8 "carol-b"
                (reqA, subA) <- plantRequest rig t1 seed shortEcon keyA
                (reqB, subB) <- plantRequest rig t1 seed shortEcon keyB
                refsBefore <- countRefs <$> readWallet rig
                assets <- certifyPlanted rig t1 seed shortEcon [reqA, reqB]
                names <- reshapeRehearsalWallet rig assets
                wallet <- readWallet rig
                [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                names `shouldBe` 2
                countRefs wallet `shouldBe` refsBefore
                jumpToAfter
                    rig
                    (max subA subB + reProcessTime shortEcon + reRetractTime shortEcon)
                    2
                rejected <-
                    run
                        rig
                        "reject from the rehearsal wallet"
                        (["registry", "reject"] <> tokenArgs t1)
                expectCompleted "reject" rejected
                expectPreparationField "reject" rejected
        it
            "a reclaim from a wallet with no ada-only output completes with prepared funding"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyR = TE.encodeUtf8 "carol-r"
                (reqR, subR) <- plantRequest rig t1 seed economics keyR
                refsBefore <- countRefs <$> readWallet rig
                assets <- certifyPlanted rig t1 seed economics [reqR]
                names <- reshapeRehearsalWallet rig assets
                wallet <- readWallet rig
                [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                names `shouldBe` 1
                countRefs wallet `shouldBe` refsBefore
                jumpToAfter rig (subR + reProcessTime economics) 0
                reclaimed <-
                    run
                        rig
                        "reclaim from the rehearsal wallet"
                        ( ["registry", "reclaim", "--request", T.unpack (renderOutRef reqR)]
                            <> tokenArgs t1
                        )
                expectCompleted "reclaim" reclaimed
                expectPreparationField "reclaim" reclaimed
        it
            "a short wallet is refused before signing, naming the shortfall"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyR = TE.encodeUtf8 "carol-r"
                (reqR, _) <- plantRequest rig t1 seed economics keyR
                assets <- certifyPlanted rig t1 seed economics [reqR]
                _ <- reshapeRehearsalWallet rig assets
                shortenWallet rig 500_000
                wallet <- readWallet rig
                [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                refused <-
                    run
                        rig
                        "fold from a short wallet"
                        (["registry", "fold"] <> tokenArgs t1)
                runExit refused `shouldBe` ExitFailure 10
                case T.isInfixOf "preparation-unfunded" <$> receiptReason refused of
                    Just True -> pure ()
                    _ ->
                        expectationFailure
                            ("no preparation-unfunded refusal: " <> show (receiptReason refused))
                case T.isInfixOf "nothing was submitted" <$> receiptReason refused of
                    Just True -> pure ()
                    _ ->
                        expectationFailure
                            ( "refusal does not end nothing submitted: "
                                <> show (receiptReason refused)
                            )
                expectNoPreparation "fold" refused
                expectNoSubmissions "fold" refused
        it
            "a short wallet is refused for a reject before signing"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <-
                    run
                        rig
                        "create"
                        ( ["registry", "create", "--process-time", "1", "--retract-time", "1"]
                            <> policyArgs
                        )
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let shortEcon =
                        RegistryEconomics
                            { reProcessTime = 1
                            , reRetractTime = 1
                            , reTip = Coin 1_000_000
                            }
                    keyA = TE.encodeUtf8 "carol-a"
                (reqA, subA) <- plantRequest rig t1 seed shortEcon keyA
                assets <- certifyPlanted rig t1 seed shortEcon [reqA]
                _ <- reshapeRehearsalWallet rig assets
                shortenWallet rig 500_000
                jumpToAfter
                    rig
                    (subA + reProcessTime shortEcon + reRetractTime shortEcon)
                    2
                refused <-
                    run
                        rig
                        "reject from a short wallet"
                        (["registry", "reject"] <> tokenArgs t1)
                runExit refused `shouldBe` ExitFailure 10
                case T.isInfixOf "preparation-unfunded" <$> receiptReason refused of
                    Just True -> pure ()
                    _ ->
                        expectationFailure
                            ("no preparation-unfunded refusal: " <> show (receiptReason refused))
                expectNoPreparation "reject" refused
                expectNoSubmissions "reject" refused
        it
            "an allowance below command plus preparation refuses before signing"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyR = TE.encodeUtf8 "carol-r"
                (reqR, _) <- plantRequest rig t1 seed economics keyR
                assets <- certifyPlanted rig t1 seed economics [reqR]
                _ <- reshapeRehearsalWallet rig assets
                refused <-
                    run
                        rig
                        "fold past a tiny allowance"
                        (["registry", "fold", "--max-outlay", "1"] <> tokenArgs t1)
                runExit refused `shouldBe` ExitFailure 10
                case T.isInfixOf "passes the approved allowance" <$> receiptReason refused of
                    Just True -> pure ()
                    _ ->
                        expectationFailure
                            ("no allowance refusal: " <> show (receiptReason refused))
                case T.isInfixOf "nothing was submitted" <$> receiptReason refused of
                    Just True -> pure ()
                    _ ->
                        expectationFailure
                            ( "refusal does not end nothing submitted: "
                                <> show (receiptReason refused)
                            )
                expectNoPreparation "fold" refused
                expectNoSubmissions "fold" refused
        it
            "a funded wallet folds with no preparation from its largest output"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyN = TE.encodeUtf8 "carol-n"
                (reqN, _) <- plantRequest rig t1 seed economics keyN
                _ <- certifyPlanted rig t1 seed economics [reqN]
                walletBefore <- readWallet rig
                largest <- case sortOn
                    (Down . snd)
                    [ (i, c)
                    | (i, o) <- walletBefore
                    , adaOnlyOut o
                    , let Coin c = o ^. coinTxOutL
                    ] of
                    (i, _) : _ -> pure i
                    [] -> fail "no-needless leg: no ada-only output to fund from"
                completed <-
                    run
                        rig
                        "fold from a funded wallet"
                        (["registry", "fold"] <> tokenArgs t1)
                expectCompleted "fold" completed
                (foldTxId, submitted, submittedTx) <-
                    commandSubmission rig "registry" completed "fold" "fold"
                submitted `shouldBe` [foldTxId]
                let spent = Set.toList (submittedTx ^. bodyTxL . inputsTxBodyL)
                    coll = Set.toList (submittedTx ^. bodyTxL . collateralInputsTxBodyL)
                spent `shouldContain` [largest]
                coll `shouldBe` [largest]
                expectNoPreparation "fold" completed
        it
            "an explicit token-carrying choice is refused with today's text"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyR = TE.encodeUtf8 "carol-r"
                (reqR, _) <- plantRequest rig t1 seed economics keyR
                assets <- certifyPlanted rig t1 seed economics [reqR]
                _ <- reshapeRehearsalWallet rig assets
                wallet <- readWallet rig
                tokenIn <- case [ i
                                | (i, o) <- wallet
                                , not (adaOnlyOut o)
                                , o ^. referenceScriptTxOutL == SNothing
                                ] of
                    [i] -> pure i
                    _ -> fail "explicit leg: no single token output to name"
                refused <-
                    run
                        rig
                        "fold with a token funding choice"
                        ( ["registry", "fold", "--fund-input", T.unpack (renderOutRef tokenIn)]
                            <> tokenArgs t1
                        )
                runExit refused `shouldBe` ExitFailure 10
                case T.isInfixOf "cannot fund the fold" <$> receiptReason refused of
                    Just True -> pure ()
                    _ ->
                        expectationFailure
                            ("no cannot-fund refusal: " <> show (receiptReason refused))
                expectNoPreparation "fold" refused
                expectNoSubmissions "fold" refused
        it
            "a named ada-only output is used with no preparation"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyN = TE.encodeUtf8 "carol-n"
                (reqN, _) <- plantRequest rig t1 seed economics keyN
                _ <- certifyPlanted rig t1 seed economics [reqN]
                walletBefore <- readWallet rig
                -- Two eligible ada-only outputs of different sizes, both
                -- shaped from the rig: split the largest ada-only output
                -- into a smaller and a larger part (a third and two
                -- thirds of what the rig holds, never typed). The smaller
                -- names the explicit choice; a seam that ignores the flag
                -- spends the natural largest instead and fails every
                -- assertion below.
                (bigIn, bigCoin) <- case sortOn
                    (Down . snd)
                    [ (i, c)
                    | (i, o) <- walletBefore
                    , adaOnlyOut o
                    , let Coin c = o ^. coinTxOutL
                    ] of
                    (i, c) : _ -> pure (i, c)
                    [] -> fail "explicit leg: no ada-only output to split"
                bigOut <- case [o | (i, o) <- walletBefore, i == bigIn] of
                    [o] -> pure o
                    _ -> fail "explicit leg: split output vanished"
                let smallCoin = bigCoin `div` 3
                    largeCoin = bigCoin - smallCoin
                when (smallCoin <= 0 || largeCoin <= smallCoin) $
                    fail "explicit leg: cannot split an eligible pair"
                smallIn <-
                    either fail pure (parseOutRef (T.pack (replicate 64 'd' <> "#1")))
                largeIn <-
                    either fail pure (parseOutRef (T.pack (replicate 64 'd' <> "#2")))
                when
                    ( smallIn `elem` map fst walletBefore
                        || largeIn `elem` map fst walletBefore
                    )
                    $ fail "explicit leg: fresh refs collide"
                let mkSmall = bigOut & valueTxOutL .~ MaryValue (Coin smallCoin) mempty
                    mkLarge = bigOut & valueTxOutL .~ MaryValue (Coin largeCoin) mempty
                advanceChain (rigChain rig) $ \facts ->
                    facts
                        { csUTxO =
                            Map.insert
                                smallIn
                                mkSmall
                                (Map.insert largeIn mkLarge (Map.delete bigIn (csUTxO facts)))
                        }
                completed <-
                    run
                        rig
                        "fold with a named funding output"
                        ( ["registry", "fold", "--fund-input", T.unpack (renderOutRef smallIn)]
                            <> tokenArgs t1
                        )
                expectCompleted "fold" completed
                (foldTxId, submitted, submittedTx) <-
                    commandSubmission rig "registry" completed "fold" "fold"
                submitted `shouldBe` [foldTxId]
                let spent = Set.toList (submittedTx ^. bodyTxL . inputsTxBodyL)
                    coll = Set.toList (submittedTx ^. bodyTxL . collateralInputsTxBodyL)
                spent `shouldContain` [smallIn]
                coll `shouldBe` [smallIn]
                spent `shouldNotContain` [largeIn]
                coll `shouldNotContain` [largeIn]
                expectNoPreparation "fold" completed
        it
            "a failure that is not about funding prepares nothing"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                let keyA = TE.encodeUtf8 "carol-a"
                    keyB = TE.encodeUtf8 "carol-b"
                (reqA, _) <- plantRequest rig t1 seed economics keyA
                (reqB, _) <- plantRequest rig t1 seed economics keyB
                assets <- certifyPlanted rig t1 seed economics [reqA, reqB]
                _ <- reshapeRehearsalWallet rig assets
                advanceChain (rigChain rig) $ \facts ->
                    facts{csUTxO = foldr Map.delete (csUTxO facts) [reqA, reqB]}
                refused <-
                    run
                        rig
                        "fold with nothing pending"
                        (["registry", "fold"] <> tokenArgs t1)
                runExit refused `shouldSatisfy` (/= ExitSuccess)
                expectNoPreparation "fold" refused
                expectNoSubmissions "fold" refused

lifecycle :: Rig -> IO [Run]
lifecycle rig = do
    seed <- fundSeed rig
    create <-
        run
            rig
            "create"
            (["registry", "create", "--seed", seed] <> policyArgs)
    -- Every command after a create names its registry by the state token
    -- that create printed: there is no saved registry to attach to.
    t1 <- tokenOf create
    -- A generic insertion request, no envelope: reclaim and reject act on
    -- the request output alone, so no datum payload is needed.
    (req2, sub2) <-
        plantRequest rig t1 seed economics (TE.encodeUtf8 "alice-2")
    -- The chain moves past the processing deadline: the retract window opens.
    jumpToAfter rig (sub2 + reProcessTime economics) 0
    reclaim <-
        run
            rig
            "reclaim alice-2"
            ( ["registry", "reclaim", "--request", T.unpack (renderOutRef req2)]
                <> tokenArgs t1
            )
    -- A second registry whose windows close at once: its request can only be rejected.
    seed2 <- fundSeed2 rig
    create2 <-
        runAt
            rig
            "registry-2"
            "create short windows"
            ( [ "registry"
              , "create"
              , "--seed"
              , seed2
              , "--process-time"
              , "1"
              , "--retract-time"
              , "1"
              ]
                <> policyArgs
            )
    t2 <- tokenOf create2
    let shortEcon =
            RegistryEconomics
                { reProcessTime = 1
                , reRetractTime = 1
                , reTip = Coin 1_000_000
                }
    (_, sub3) <-
        plantRequest rig t2 seed2 shortEcon (TE.encodeUtf8 "alice-3")
    jumpToAfter
        rig
        (sub3 + reProcessTime shortEcon + reRetractTime shortEcon)
        2
    reject <-
        runAt
            rig
            "registry-2"
            "reject"
            (["registry", "reject"] <> tokenArgs t2)
    -- A fold with nothing pending: the refusal exercises Fold.
    nothingPending <-
        runAt
            rig
            "registry-2"
            "fold with nothing pending"
            (["registry", "fold"] <> tokenArgs t2)
    -- An inspect from an empty directory reads the registry by its token.
    emptyDir <-
        runAt
            rig
            "empty-actor"
            "inspect from an empty directory with the state token"
            (["registry", "inspect", "--key", "alice-1"] <> tokenArgs t1)
    -- A stateless page read by token alone, as JSON for its receipt. The
    -- label is the fixture release's own claim; links are computed, never
    -- fetched.
    writeFile
        (takeDirectory (rigBlueprint rig) </> "version.txt")
        "0.10.1\n"
    page <-
        runAt
            rig
            "registry"
            "describe by state token"
            (["registry", "describe", "--json"] <> tokenArgs t1)
    pure
        [create, reclaim, create2, reject, nothingPending, emptyDir, page]

-- | The state token's name as a 'TokenId'.
parseTokenId :: String -> IO TokenId
parseTokenId tokenStr = case T.splitOn "." (T.pack tokenStr) of
    [_, nameHex] -> case B16.decode (TE.encodeUtf8 nameHex) of
        Right bytes
            | BS.length bytes == 32 ->
                pure (TokenId (AssetName (SBS.toShort bytes)))
        Right bytes ->
            fail
                ("parseTokenId: name is " <> show (BS.length bytes) <> " bytes, not 32")
        Left _ -> fail "parseTokenId: name is not hex"
    _ -> fail ("parseTokenId: no policy.name in " <> tokenStr)

{- | Plant a generic insertion request for reclaim and reject: the edge alone,
no envelope and no payload file. The request output is submitted through the
fixture exactly as 'capabilities' submits, and its submission time is read
from its own datum.
-}
plantRequest
    :: Rig
    -> String
    -> String
    -> RegistryEconomics
    -> BS.ByteString
    -> IO (TxIn, Integer)
plantRequest rig tokenStr seedStr econ key = do
    seedIn <-
        either
            (fail . ("plantRequest seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    let seedRef = txInToRef seedIn
    tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel econ seedRef
        reqAddr = requestAddrFromCfg cfg tid Testnet
        wallet = walletAddr (rigWallet rig)
    unsigned <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            requestEdgeImpl cfg v (Coin 1_000_000) tid key edgeInsertActive wallet
    let txid = txIdTx unsigned
        spent = Set.toList (unsigned ^. bodyTxL . inputsTxBodyL)
        made = zip [0 ..] (toList (unsigned ^. bodyTxL . outputsTxBodyL))
        atReq =
            [ (TxIn txid (TxIx ix), out)
            | (ix, out) <- made
            , out ^. addrTxOutL == reqAddr
            ]
    (reqIn, reqOut) <- case atReq of
        [one] -> pure one
        _ ->
            fail
                ( "plantRequest: expected one request output at "
                    <> show reqAddr
                    <> ", found "
                    <> show (length atReq)
                )
    submitted <- case extractCageDatum reqOut of
        Just (RequestDatum r) -> pure (requestSubmittedAt r)
        _ -> fail "plantRequest: request output carries no request datum"
    recordTransaction (rigChain rig) unsigned
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.union
                    (Map.fromList [(TxIn txid (TxIx ix), out) | (ix, out) <- made])
                    (foldr Map.delete (csUTxO facts) spent)
            }
    pure (reqIn, submitted)

-- | Move the chain tip past this millisecond instant, by this many slots more.
jumpToAfter :: Rig -> Integer -> Word64 -> IO ()
jumpToAfter rig ms more =
    jumpChainTo
        (rigChain rig)
        (SlotNo (fromInteger (ms `div` 1000) + more + 1))

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
runVia rig env = runViaApp rig env neutralApplication

{- | The same, composing the caller's application value: the neutral value
for the switched creates (the policy comes through the parser), another
value for the refusal rows.
-}
runViaApp
    :: Rig -> Env -> Application -> FilePath -> String -> [String] -> IO Run
runViaApp rig env app registry label args = do
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . show)
            pure
            (parseCommand (commandLine rig registry args))
    (code, out, _) <-
        captured
            (runCommand app env command)
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
            , envWrites = \_ _ k -> k (atTxInCapabilities answer rig)
            }
        )
        "registry"

-- | A command line over the rig, as the packaged command is given it.
commandLine :: Rig -> FilePath -> [String] -> [String]
commandLine rig registry args =
    args
        <> (if wantsDir then ["--state-dir", rigDir rig </> registry] else [])
        <> [ "--blueprint"
           , rigBlueprint rig
           , "--koios-url"
           , "http://fixture.invalid"
           , "--network-magic"
           , show magic
           ]
        <> ["--wallet-skey" | wantsKey]
        <> [rigKey rig | wantsKey]
  where
    -- Describe reads the page from the chain alone: no state directory
    -- and no signing key reach its parser.
    wantsDir = take 2 args /= ["registry", "describe"]
    wantsKey =
        take 2 args /= ["registry", "inspect"]
            && take 2 args /= ["registry", "describe"]

-- ---------------------------------------------------------
-- --application-policy (#528)
-- ---------------------------------------------------------

{- | The policy the switched creates pin, through the parser: 28 0x07
bytes as hex, computed here at run time and never typed.
-}
policyArgs :: [String]
policyArgs = ["--application-policy", T.unpack (hexText (BS.replicate 28 7))]

-- | The refusal reason a receipt names.
receiptReason :: Run -> Maybe Text
receiptReason r = textAt "reason" (runReceipt r)

{- | A script-pinned value, standing in for the application's value the
registry-cli never names: the pin comes from the script.
-}
scriptPinned :: Application
scriptPinned =
    Application
        { appName = Just "script-app"
        , appExecutable = Just "script-app"
        , appPin = PinByScript "script-app.script-app"
        , appDecoder = Nothing
        , appHolding = Nothing
        }

{- | Run a create pinning these policy bytes through the flag, and check
the receipt's pins, the published references and the state datum on the
chain.
-}
pinsPolicy :: Rig -> FilePath -> String -> BS.ByteString -> IO ()
pinsPolicy rig registry seed policyBytes = do
    let policyHex = T.unpack (hexText policyBytes)
    r <-
        runViaApp
            rig
            (envOf rig)
            neutralApplication
            registry
            ("create pins " <> policyHex)
            [ "registry"
            , "create"
            , "--seed"
            , seed
            , "--application-policy"
            , policyHex
            ]
    outcomeOf (runReceipt r) `shouldBe` Just "success"
    -- the receipt's pins name the hash
    case valueAt "pins" (runReceipt r) >>= valueAt "pinApplication" of
        Just (Aeson.String t) -> t `shouldBe` hexText policyBytes
        _ -> expectationFailure ("no pinApplication in " <> runLabel r)
    -- no reference output for the application is published
    case elementsAt "references" (runReceipt r) of
        Just refs ->
            sort [t | Aeson.Object o <- refs, Just t <- [fieldOf "role" o]]
                `shouldBe` [ "request"
                           , "state"
                           , "witness-absent"
                           , "witness-active"
                           , "witness-terminal"
                           ]
        Nothing -> expectationFailure ("no references in " <> runLabel r)
    -- the state datum on the chain pins the hash
    seedIn <-
        either (fail . ("policy seed: " <>)) pure (parseOutRef (T.pack seed))
    rel <-
        loadReleaseCodes neutralApplication (rigBlueprint rig)
            >>= either fail pure
    let (cfg, _) =
            registryConfigFor
                (hashPinnedApplication (SBS.toShort policyBytes))
                rel
                economics
                (txInToRef seedIn)
    tid <- parseTokenId =<< tokenOf r
    stateUtxos <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v (cageAddrFromCfg cfg Testnet)
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum st) -> stateAppPolicyBytes st `shouldBe` policyBytes
            _ -> expectationFailure ("no state datum in " <> runLabel r)
        Nothing -> expectationFailure ("no state output in " <> runLabel r)

applicationPolicyRows :: Spec
applicationPolicyRows =
    describe "registry create --application-policy (#528)" $
        do
            it
                "pins the given hash in the state datum and publishes no application reference"
                $ withRig
                $ \rig -> do
                    first <- fundSeed rig
                    pinsPolicy rig "policy-a" first (BS.replicate 28 7)
                    second <- fundSeed2 rig
                    pinsPolicy rig "policy-b" second (BS.replicate 28 9)
            it
                "refuses a create without the flag on the neutral value before anything is built or signed"
                $ withRig
                $ \rig -> do
                    seed <- fundSeed rig
                    r <-
                        runViaApp
                            rig
                            (envOf rig)
                            neutralApplication
                            "registry"
                            "create without policy"
                            ["registry", "create", "--seed", seed]
                    outcomeOf (runReceipt r) `shouldBe` Just "client-refusal"
                    receiptReason r
                        `shouldSatisfy` maybe False (T.isInfixOf "--application-policy")
                    receiptReason r
                        `shouldSatisfy` maybe False (not . T.isInfixOf "applyPin")
                    valueAt "transactions" (runReceipt r) `shouldBe` Nothing
                    [() | Trace _ (How (Tx _)) <- runEvents r] `shouldBe` []
            it "does not accept the flag for a script-pinned value" $
                withRig $
                    \rig -> do
                        seed <- fundSeed rig
                        r <-
                            runViaApp
                                rig
                                (envOf rig)
                                scriptPinned
                                "registry"
                                "create with policy on a script pin"
                                (["registry", "create", "--seed", seed] <> policyArgs)
                        outcomeOf (runReceipt r) `shouldBe` Just "client-refusal"
                        receiptReason r
                            `shouldSatisfy` maybe False (T.isInfixOf "--application-policy")
                        receiptReason r
                            `shouldSatisfy` maybe False (T.isInfixOf "not accepted")
                        valueAt "transactions" (runReceipt r) `shouldBe` Nothing
                        [() | Trace _ (How (Tx _)) <- runEvents r] `shouldBe` []
            it "refuses a non-hex hash with a named message" $
                case parseCommand
                    [ "registry"
                    , "create"
                    , "--seed"
                    , replicate 64 'f' <> "#1"
                    , "--blueprint"
                    , "plutus.json"
                    , "--koios-url"
                    , "http://fixture.invalid"
                    , "--network-magic"
                    , "42"
                    , "--wallet-skey"
                    , "payment.skey"
                    , "--application-policy"
                    , "not hex at all"
                    ] of
                    Left err ->
                        renderCLIError err
                            `shouldSatisfy` \said ->
                                T.isInfixOf "--application-policy" (T.pack said)
                                    && T.isInfixOf "56" (T.pack said)
                    Right command ->
                        expectationFailure ("a non-hex hash parsed: " <> show command)
            it "refuses a hash of the wrong length with a named message" $
                case parseCommand
                    [ "registry"
                    , "create"
                    , "--seed"
                    , replicate 64 'f' <> "#1"
                    , "--blueprint"
                    , "plutus.json"
                    , "--koios-url"
                    , "http://fixture.invalid"
                    , "--network-magic"
                    , "42"
                    , "--wallet-skey"
                    , "payment.skey"
                    , "--application-policy"
                    , "abcd"
                    ] of
                    Left err ->
                        renderCLIError err
                            `shouldSatisfy` \said ->
                                T.isInfixOf "--application-policy" (T.pack said)
                                    && T.isInfixOf "56" (T.pack said)
                    Right command ->
                        expectationFailure ("a short hash parsed: " <> show command)
            it "refuses the flag on commands that do not create"
                $ forM_
                    [ ["registry", "fold"]
                    , ["registry", "reject"]
                    , ["registry", "reclaim"]
                    , ["registry", "inspect"]
                    ]
                $ \words' ->
                    case parseCommand (words' <> policyArgs) of
                        Left (BadValue "--application-policy" why)
                            | "create" `isInfixOf` why -> pure ()
                        other ->
                            expectationFailure
                                ("the policy flag survived off create: " <> show other)

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

fieldOf :: Aeson.Key -> Aeson.Object -> Maybe Text
fieldOf k o = case KeyMap.lookup k o of
    Just (Aeson.String t) -> Just t
    _ -> Nothing

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
their receipt names. Inspect performs none.
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
    , "rejected request"
    , "rejected dropped"
    , "reclaimed request"
    , "reclaimed amount"
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

-- | The journal steps that act on an edge: boot, reclaim, reject.
edgeSteps :: [Text]
edgeSteps = ["boot", "reclaim", "reject"]

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

-- ---------------------------------------------------------
-- The fold's journal line lists its one transition
-- ---------------------------------------------------------

{- | A fold of one writes its list of one: after a fold command the
prepared line's list has one entry equal to the scalars.
-}
journalTransitionsRow :: Spec
journalTransitionsRow = describe "a fold's journal line lists its transition" $ do
    it "writes one transition equal to the scalars" $ withRig $ \rig -> do
        seed <- fundSeed rig
        create <-
            run
                rig
                "create"
                (["registry", "create", "--seed", seed] <> policyArgs)
        outcomeOf (runReceipt create) `shouldBe` Just "success"
        t1 <- tokenOf create
        reqIn <- plantFoldableRequest rig t1 seed
        folded <-
            run rig "fold journal" (["registry", "fold"] <> tokenArgs t1)
        outcomeOf (runReceipt folded) `shouldBe` Just "success"
        entries <- foldPreparedEntries rig "registry"
        case entries of
            [entry] -> do
                case journalTransitions entry of
                    Just [transition] -> do
                        transitionRequest transition `shouldBe` renderOutRef reqIn
                        Just (transitionKey transition) `shouldBe` journalKey entry
                        Just (transitionEdge transition) `shouldBe` journalEdge entry
                        Just (transitionExpect transition) `shouldBe` journalExpect entry
                        Just (transitionRootBefore transition)
                            `shouldBe` journalRootBefore entry
                        Just (transitionRootAfter transition)
                            `shouldBe` journalRootAfter entry
                    other ->
                        expectationFailure ("expected one transition, found: " <> show other)
            other ->
                expectationFailure
                    ("expected one prepared fold line, found: " <> show (length other))

{- | Plant one insertion request a neutral fold settles: its destination
carries a datum at the wallet address, and its output carries the
approval asset the selection expects, so the seven checks pass.
-}
plantFoldableRequest :: Rig -> String -> String -> IO TxIn
plantFoldableRequest rig tokenStr seedStr = do
    seedIn <-
        either
            (fail . ("plantFoldableRequest seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel economics (txInToRef seedIn)
        reqAddr = requestAddrFromCfg cfg tid Testnet
        walletAt = walletAddr (rigWallet rig)
        keyBytes = "fold-journal-key" :: BS.ByteString
        edge = edgeInsertActive
    now <- currentPosixMs
    let destBytes = serialiseAddr walletAt
        carried = PLC.Constr 0 [PLC.B "journal"]
        dest = (destBytes, Just carried)
        ownerBytes = addrKeyHashBytes walletAt
        expectedName = approvalName edge keyBytes ownerBytes (approvalDestination dest)
        pinned = cfgApplicationPolicy cfg
        approvalAsset =
            MultiAsset
                ( Map.singleton
                    (policyIdFromPin pinned)
                    (Map.singleton (AssetName (SBS.toShort expectedName)) 1)
                )
        deposit = 4_000_000 :: Integer
        tip = 1_000_000 :: Integer
        bond = deposit + tip
        datum = mkRequestDatumWith tid walletAt keyBytes edge deposit now dest
        reqOut =
            mkBasicTxOut reqAddr (MaryValue (Coin bond) approvalAsset)
                & datumTxOutL .~ mkInlineDatum datum
        reqIn =
            either
                (error . ("plantFoldableRequest outref: " <>))
                id
                (parseOutRef (T.pack (replicate 64 'e' <> "#0")))
    advanceChain (rigChain rig) $ \facts -> facts{csUTxO = Map.insert reqIn reqOut (csUTxO facts)}
    pure reqIn

-- | Every journal entry under a registry directory.
journalEntries :: Rig -> FilePath -> IO [JournalEntry]
journalEntries rig registry = do
    names <- listDirectoryRecursive (rigDir rig </> registry)
    let journals = [p | p <- names, takeFileName p == "journal.jsonl"]
    journalRel <- case journals of
        [found] -> pure found
        _ ->
            fail
                ( "expected exactly one journal under "
                    <> registry
                    <> ", found "
                    <> show (length journals)
                )
    raw <- BS.readFile (rigDir rig </> registry </> journalRel)
    mapM
        (maybe (fail "a journal line is not JSON") pure . Aeson.decodeStrict)
        (BC.lines raw)

-- | Every prepared fold line in a registry's journal.
foldPreparedEntries :: Rig -> FilePath -> IO [JournalEntry]
foldPreparedEntries rig registry =
    filter (\e -> journalStep e == "fold" && journalEvent e == "prepared")
        <$> journalEntries rig registry

{- | One command run's sole submission: its receipt transaction id, every
submitted id in its journal step, and the submitted transaction read
from its saved, hash-bound body. A needless preparation shows here as
a second submission with another funding input.
-}
commandSubmission
    :: Rig -> FilePath -> Run -> Text -> Text -> IO (Text, [Text], ConwayTx)
commandSubmission rig registry r step key = do
    journal <- journalEntries rig registry
    txid <-
        maybe
            (fail ("no " <> T.unpack key <> " in receipt"))
            pure
            (textAt (Key.fromText key) (runReceipt r))
    let submitted =
            nub
                [ journalTxId e
                | e <- journal
                , journalStep e == step
                , journalEvent e == "submitted"
                ]
    (_, body) <- boundBody journal txid
    tx <- either (fail . T.unpack) pure body
    pure (txid, submitted, tx)

-- ---------------------------------------------------------
-- The fold over several requests (bound seam, #518 pull request 3a)
-- ---------------------------------------------------------

{- | Plant one insertion request a bounded fold settles, with explicit key,
carried datum bytes, fake reference character (ledger order) and submission
time override (0 uses the clock): its destination carries the datum at the
wallet address, and its output carries the approval asset the selection
expects, so the seven checks pass under the neutral value.
-}
plantFoldableRequestAt
    :: Rig
    -> String
    -> String
    -> BS.ByteString
    -> BS.ByteString
    -> Char
    -> Integer
    -> IO TxIn
plantFoldableRequestAt rig tokenStr seedStr keyBytes carriedBytes fakeChar submittedOverride = do
    seedIn <-
        either
            (fail . ("plantFoldableRequestAt seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel economics (txInToRef seedIn)
        reqAddr = requestAddrFromCfg cfg tid Testnet
        walletAt = walletAddr (rigWallet rig)
        edge = edgeInsertActive
    now0 <- currentPosixMs
    let now = if submittedOverride == 0 then now0 else submittedOverride
        destBytes = serialiseAddr walletAt
        carried = PLC.Constr 0 [PLC.B carriedBytes]
        dest = (destBytes, Just carried)
        ownerBytes = addrKeyHashBytes walletAt
        expectedName = approvalName edge keyBytes ownerBytes (approvalDestination dest)
        pinned = cfgApplicationPolicy cfg
        approvalAsset =
            MultiAsset
                ( Map.singleton
                    (policyIdFromPin pinned)
                    (Map.singleton (AssetName (SBS.toShort expectedName)) 1)
                )
        deposit = 4_000_000 :: Integer
        tip = 1_000_000 :: Integer
        bond = deposit + tip
        datum = mkRequestDatumWith tid walletAt keyBytes edge deposit now dest
        reqOut =
            mkBasicTxOut reqAddr (MaryValue (Coin bond) approvalAsset)
                & datumTxOutL .~ mkInlineDatum datum
        reqIn =
            either
                (error . ("plantFoldableRequestAt outref: " <>))
                id
                (parseOutRef (T.pack (replicate 64 fakeChar <> "#0")))
    advanceChain (rigChain rig) $ \facts -> facts{csUTxO = Map.insert reqIn reqOut (csUTxO facts)}
    pure reqIn

{- | One fold at an explicit capacity bound, through the same dispatch and
receipt plumbing as 'run': parses the fold command line for its addresses
and funding, then finishes through 'runFoldBounded' instead of production.
-}
runFoldAtBoundApp :: Rig -> Int -> Application -> String -> IO Run
runFoldAtBoundApp rig bound app tokenStr = do
    writeIORef (rigEvents rig) []
    let args = ["registry", "fold"] <> tokenArgs tokenStr
    command <-
        either
            (fail . show)
            pure
            (parseCommand (commandLine rig "registry" args))
    case command of
        Fold fargs -> do
            (code, out, _) <-
                captured
                    ( finish
                        (envTracer (envOf rig))
                        "fold"
                        (foldReceipt fargs)
                        (runFoldBounded bound app (envOf rig) fargs)
                    )
            receipt <-
                maybe
                    ( fail
                        ("no receipt for fold-at-bound " <> show bound <> ": " <> show out)
                    )
                    pure
                    (Aeson.decodeStrict out)
            events <- readIORef (rigEvents rig)
            pure
                Run
                    { runName = "Fold"
                    , runLabel = "fold at bound " <> show bound
                    , runExit = code
                    , runReceipt = receipt
                    , runEvents = events
                    , runKey = Nothing
                    }
        _ -> fail "runFoldAtBoundApp: not a fold command"

runFoldAtBound :: Rig -> Int -> String -> IO Run
runFoldAtBound rig bound = runFoldAtBoundApp rig bound neutralApplication

-- | Every settled entry of the receipt, in order.
settledEntries :: Aeson.Value -> [Aeson.Object]
settledEntries v = case elementsAt "settled" v of
    Just xs -> [o | Aeson.Object o <- xs]
    _ -> []

-- | The request references of the settled list, in order.
settledRequestRefs :: Aeson.Value -> [Text]
settledRequestRefs v =
    [t | o <- settledEntries v, Just t <- [fieldOf "request" o]]

-- | A settlement's live output, when it carries one.
settledLiveOutput :: Aeson.Value -> Maybe Text
settledLiveOutput s = case s of
    Aeson.Object o -> fieldOf "liveOutput" o
    _ -> Nothing

-- | The journal's observed fold lines.
foldObservedEntries :: Rig -> FilePath -> IO [JournalEntry]
foldObservedEntries rig registry = do
    names <- listDirectoryRecursive (rigDir rig </> registry)
    let journals = [p | p <- names, takeFileName p == "journal.jsonl"]
    journalRel <- case journals of
        [found] -> pure found
        _ -> fail ("expected exactly one journal under " <> registry)
    raw <- BS.readFile (rigDir rig </> registry </> journalRel)
    entries <-
        mapM
            (maybe (fail "a journal line is not JSON") pure . Aeson.decodeStrict)
            (BC.lines raw)
    pure
        [ e
        | e <- entries
        , journalStep e == "fold"
        , journalEvent e == "observed"
        ]

{- | The fold settles every selected request in one transaction: rows at
bound 3 (and 2) over settleable pending insertions. RED with the bound
seam stubbed (one folds): each row asserting two settles fails by assertion.
-}

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
                `shouldSatisfy` any ("settled list" `isInfixOf`)
        it "reports nothing about the settled list for a fold of one" $ do
            let oneEntry =
                    Aeson.object
                        [ "command" .= ("fold" :: Text)
                        , "settled" .= [Aeson.object ["request" .= ("a#0" :: Text)]]
                        ]
            disagreements Nothing oneEntry []
                `shouldSatisfy` (not . any ("settled list" `isInfixOf`))

foldOverSeveralRequestsRow :: Spec
foldOverSeveralRequestsRow = describe "the fold settles every selected request in one transaction" $ do
    it
        "two insertions of different keys settle in ledger order at bound 3"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t1 <- tokenOf create
            reqE <-
                plantFoldableRequestAt rig t1 seed "fold-many-a" "many-a" 'e' 0
            reqF <-
                plantFoldableRequestAt rig t1 seed "fold-many-b" "many-b" 'f' 0
            folded <- runFoldAtBound rig 3 t1
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            settledRequestRefs (runReceipt folded)
                `shouldBe` [renderOutRef reqE, renderOutRef reqF]
            length (settledEntries (runReceipt folded)) `shouldBe` 2
            entries <- foldPreparedEntries rig "registry"
            case entries of
                [entry] -> case journalTransitions entry of
                    Just [first, second] -> do
                        transitionRequest first `shouldBe` renderOutRef reqE
                        transitionRequest second `shouldBe` renderOutRef reqF
                        transitionRootAfter first `shouldBe` transitionRootBefore second
                        transitionRootAfter first `shouldNotBe` transitionRootAfter second
                        Just (transitionKey first) `shouldBe` journalKey entry
                        Just (transitionRootBefore first) `shouldBe` journalRootBefore entry
                        Just (transitionRootAfter second) `shouldBe` journalRootAfter entry
                    other ->
                        expectationFailure
                            ("expected two chained transitions, found: " <> show other)
                other ->
                    expectationFailure
                        ("expected one prepared fold line, found: " <> show (length other))
            observed <- foldObservedEntries rig "registry"
            length observed `shouldBe` 1
    it
        "three pending at bound 2 settles two and excludes the third capacity"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t1 <- tokenOf create
            reqE <- plantFoldableRequestAt rig t1 seed "fold-cap-a" "cap-a" 'd' 0
            reqF <- plantFoldableRequestAt rig t1 seed "fold-cap-b" "cap-b" 'e' 0
            _reqG <- plantFoldableRequestAt rig t1 seed "fold-cap-c" "cap-c" 'f' 0
            folded <- runFoldAtBound rig 2 t1
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            settledRequestRefs (runReceipt folded)
                `shouldBe` [renderOutRef reqE, renderOutRef reqF]
            case elementsAt "excluded" (runReceipt folded) of
                Just [Aeson.Object o] -> fieldOf "reason" o `shouldBe` Just "capacity"
                other ->
                    expectationFailure
                        ("expected one capacity exclusion, found: " <> show other)
    it "the earlier deadline of the second request bounds the fold" $ withRig $ \rig -> do
        seed <- fundSeed rig
        create <-
            run
                rig
                "create"
                (["registry", "create", "--seed", seed] <> policyArgs)
        outcomeOf (runReceipt create) `shouldBe` Just "success"
        t1 <- tokenOf create
        now0 <- currentPosixMs
        _reqE <-
            plantFoldableRequestAt rig t1 seed "fold-dl-a" "dl-a" 'e' now0
        _reqF <-
            plantFoldableRequestAt
                rig
                t1
                seed
                "fold-dl-b"
                "dl-b"
                'f'
                (now0 - 300_000)
        folded <- runFoldAtBound rig 3 t1
        outcomeOf (runReceipt folded) `shouldBe` Just "success"
        length (settledEntries (runReceipt folded)) `shouldBe` 2
        let deadlines =
                [ d
                | o <- settledEntries (runReceipt folded)
                , Just d <-
                    [integerAt "posixMs" =<< valueAt "deadline" (Aeson.Object o)]
                ]
        case deadlines of
            [first, second] -> (second < first) `shouldBe` True
            other ->
                expectationFailure
                    ("expected two entry deadlines, found: " <> show other)
        case ( valueAt "foldDeadline" (runReceipt folded) >>= integerAt "posixMs"
             , deadlines
             ) of
            (Just top, _ : second : _) -> top `shouldBe` second
            other ->
                expectationFailure
                    ( "expected the top deadline to follow the second entry, found: "
                        <> show other
                    )
        case ( integerAt "hostClockMs" (runReceipt folded)
             , integerAt "remainingMs" (runReceipt folded)
             , deadlines
             ) of
            (Just clock, Just remaining, _ : second : _) ->
                (remaining + clock) `shouldBe` second
            other ->
                expectationFailure
                    ( "expected the window to follow the second entry, found: "
                        <> show other
                    )
    it
        "two insertions of the same datum to the same destination are both found distinct"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t1 <- tokenOf create
            reqE <-
                plantFoldableRequestAt rig t1 seed "fold-same-a" "same-datum" 'e' 0
            reqF <-
                plantFoldableRequestAt rig t1 seed "fold-same-b" "same-datum" 'f' 0
            folded <- runFoldAtBound rig 3 t1
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            settledRequestRefs (runReceipt folded)
                `shouldBe` [renderOutRef reqE, renderOutRef reqF]
            let liveOuts =
                    [ t
                    | o <- settledEntries (runReceipt folded)
                    , Just s <- [valueAt "settlement" (Aeson.Object o)]
                    , Just t <- [settledLiveOutput s]
                    ]
            length liveOuts `shouldBe` 2
            case liveOuts of
                [firstOut, secondOut] -> (firstOut == secondOut) `shouldBe` False
                _ ->
                    expectationFailure
                        ("expected two distinct live outputs, found: " <> show liveOuts)
    it
        "two insertions and one termination settle with the termination release at bound 3"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t1 <- tokenOf create
            _priorReq <-
                plantFoldableRequestAt rig t1 seed "fold-term-key" "term-prior" 'd' 0
            priorFold <- runFoldAtBound rig 1 t1
            outcomeOf (runReceipt priorFold) `shouldBe` Just "success"
            plantActiveTokenFor rig t1 seed "fold-term-key"
            reqA <- plantFoldableRequestAt rig t1 seed "fold-mix-a" "mix-a" 'e' 0
            reqB <- plantFoldableRequestAt rig t1 seed "fold-mix-b" "mix-b" 'f' 0
            reqC <- plantFoldableTerminationAt rig t1 seed "fold-term-key" 'c'
            folded <- runFoldAtBoundApp rig 3 (testAppExpecting 1) t1
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            length (settledEntries (runReceipt folded)) `shouldBe` 3
            let byRequest =
                    [ (r, o)
                    | o <- settledEntries (runReceipt folded)
                    , Just r <- [fieldOf "request" o]
                    ]
                termObjs = [o | (r, o) <- byRequest, r == renderOutRef reqC]
            length termObjs `shouldBe` 1
            case termObjs of
                [o] -> case valueAt "settlement" (Aeson.Object o) of
                    Just (Aeson.Object s) -> do
                        fieldOf "released" s `shouldSatisfy` isJust
                        case KeyMap.lookup "deposit" s of
                            Just (Aeson.Number _) -> pure ()
                            other ->
                                expectationFailure
                                    ( "expected a deposit in the termination settlement, found: "
                                        <> show other
                                    )
                    other ->
                        expectationFailure
                            ( "expected a settlement object for the termination, found: "
                                <> show other
                            )
                _ -> expectationFailure "expected exactly one termination entry"
            settledRequestRefs (runReceipt folded)
                `shouldSatisfy` ( \refs -> renderOutRef reqA `elem` refs && renderOutRef reqB `elem` refs
                                )
    it
        "an insertion first and a termination second settle with the termination payout at the production bound"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t1 <- tokenOf create
            _priorReq <-
                plantFoldableRequestAt
                    rig
                    t1
                    seed
                    "fold-term-last-key"
                    "term-last-prior"
                    'c'
                    0
            priorFold <- runFoldAtBound rig 1 t1
            outcomeOf (runReceipt priorFold) `shouldBe` Just "success"
            plantActiveTokenFor rig t1 seed "fold-term-last-key"
            reqA <-
                plantFoldableRequestAt rig t1 seed "fold-last-a" "last-a" 'd' 0
            reqB <-
                plantFoldableRequestAt rig t1 seed "fold-last-b" "last-b" 'e' 0
            reqC <-
                plantFoldableTerminationAt rig t1 seed "fold-term-last-key" 'f'
            folded <- runFoldAtBoundApp rig foldCapacity (testAppExpecting 1) t1
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            -- the termination settles last: it is not first in ledger order.
            settledRequestRefs (runReceipt folded)
                `shouldBe` [renderOutRef reqA, renderOutRef reqB, renderOutRef reqC]
            let byRequest =
                    [ (r, o)
                    | o <- settledEntries (runReceipt folded)
                    , Just r <- [fieldOf "request" o]
                    ]
                termObjs = [o | (r, o) <- byRequest, r == renderOutRef reqC]
            length termObjs `shouldBe` 1
            case termObjs of
                [o] -> do
                    fieldOf "edge" o `shouldBe` Just "updateTerminal"
                    case valueAt "settlement" (Aeson.Object o) of
                        Just (Aeson.Object s) -> do
                            fieldOf "released" s
                                `shouldBe` Just (T.pack (replicate 64 'b' <> "#0"))
                            integerAt "deposit" (Aeson.Object s) `shouldBe` Just 4_000_000
                        other ->
                            expectationFailure
                                ( "expected a settlement object for the termination, found: "
                                    <> show other
                                )
                _ -> expectationFailure "expected exactly one termination entry"
            case valueAt "capacity" (runReceipt folded) of
                Just (Aeson.Object c) -> do
                    integerAt "bound" (Aeson.Object c) `shouldBe` Just 9
                    fieldOf "provenance" c
                        `shouldBe` Just
                            "an estimate, not a measurement: about nine requests fit in a fold under preprod's execution budget of 14 million memory units, bound by trie-proof verification"
                other ->
                    expectationFailure
                        ( "expected a capacity object in the fold receipt, found: "
                            <> show other
                        )

{- | Plant one termination request for a key known active: edge updateTerminal
with the approval asset the selection expects, at a fresh fake reference.
-}
plantFoldableTerminationAt
    :: Rig -> String -> String -> BS.ByteString -> Char -> IO TxIn
plantFoldableTerminationAt rig tokenStr seedStr keyBytes fakeChar = do
    seedIn <-
        either
            (fail . ("plantFoldableTerminationAt seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel economics (txInToRef seedIn)
        reqAddr = requestAddrFromCfg cfg tid Testnet
        walletAt = walletAddr (rigWallet rig)
        edge = edgeUpdateTerminal
    now <- currentPosixMs
    let destBytes = serialiseAddr walletAt
        carried = PLC.Constr 0 [PLC.B "term"]
        dest = (destBytes, Just carried)
        ownerBytes = addrKeyHashBytes walletAt
        expectedName = approvalName edge keyBytes ownerBytes (approvalDestination dest)
        pinned = cfgApplicationPolicy cfg
        approvalAsset =
            MultiAsset
                ( Map.singleton
                    (policyIdFromPin pinned)
                    (Map.singleton (AssetName (SBS.toShort expectedName)) 1)
                )
        deposit = 4_000_000 :: Integer
        tip = 1_000_000 :: Integer
        bond = deposit + tip
        datum = mkRequestDatumWith tid walletAt keyBytes edge deposit now dest
        reqOut =
            mkBasicTxOut reqAddr (MaryValue (Coin bond) approvalAsset)
                & datumTxOutL .~ mkInlineDatum datum
        reqIn =
            either
                (error . ("plantFoldableTerminationAt outref: " <>))
                id
                (parseOutRef (T.pack (replicate 64 fakeChar <> "#0")))
    advanceChain (rigChain rig) $ \facts -> facts{csUTxO = Map.insert reqIn reqOut (csUTxO facts)}
    pure reqIn

{- | Plant one output at the application address carrying the key's active
token, so the selection's live-facts see a present token for a termination.
-}
plantActiveTokenFor
    :: Rig -> String -> String -> BS.ByteString -> IO ()
plantActiveTokenFor rig tokenStr seedStr keyBytes = do
    seedIn <-
        either
            (fail . ("plantActiveTokenFor seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    _tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel economics (txInToRef seedIn)
        active = cfgActivePolicy cfg
        appAddr = case hashFromBytes (SBS.fromShort (cfgApplicationPolicy cfg)) of
            Just h -> Addr Testnet (ScriptHashObj (ScriptHash h)) StakeRefNull
            Nothing -> error "plantActiveTokenFor: pinned policy is not 28 bytes"
        activeAsset =
            MultiAsset
                ( Map.singleton
                    (policyIdFromPin active)
                    (Map.singleton (AssetName (SBS.toShort keyBytes)) 1)
                )
        out = mkBasicTxOut appAddr (MaryValue (Coin 2_000_000) activeAsset)
        plantedIn =
            either
                (error . ("plantActiveTokenFor outref: " <>))
                id
                (parseOutRef (T.pack (replicate 64 'b' <> "#0")))
    advanceChain (rigChain rig) $ \facts -> facts{csUTxO = Map.insert plantedIn out (csUTxO facts)}

{- | A test value with holding rules for the release row: carried datums read
as one constant, live holdings are canned per key with that constant, and
the context entry checks it receives every release (exactly the expected
count) before adding the holdings to the builder inventory. It names no
shipped application.
-}
testAppExpecting :: Int -> Application
testAppExpecting expected =
    neutralApplication
        { appName = Just "fold-many-test"
        , appExecutable = Just "fold-many-test"
        , appHolding = Just rules
        }
  where
    constantDatum = PLC.Constr 0 [PLC.B "fold-many-constant"]
    canned key =
        DecodedHolding
            { dhDatumData = constantDatum
            , dhDatumCbor = datumCbor constantDatum
            , dhDatumHash = datumHash constantDatum
            , dhKey = key
            , dhDeposit = 4_000_000
            , dhController = BS.replicate 28 9
            , dhPayload = PLC.I 0
            , dhDatumJson = Aeson.object ["constant" .= (1 :: Int)]
            , dhPayloadJson = Aeson.object ["constant" .= (0 :: Int)]
            }
    rules =
        HoldingRules
            { hrCheckCarried = const (Right constantDatum)
            , hrFindHoldings = \_ _ _ _ -> []
            , hrLiveOutputFor = \cfg _ key outs ->
                let active = cfgActivePolicy cfg
                    carries (_, o) = case o ^. valueTxOutL of
                        MaryValue _ (MultiAsset m) -> case Map.lookup (policyIdFromPin active) m of
                            Just names -> Map.member (AssetName (SBS.toShort key)) names
                            Nothing -> False
                    found = [u | u@(_, _) <- outs, carries u]
                    fakeIn =
                        either
                            (error "testApp live output")
                            id
                            (parseOutRef (T.pack (replicate 64 'a' <> "#0")))
                    dummyHash = case hashFromBytes (BS.replicate 28 8) of
                        Just h -> h
                        Nothing -> error "testApp hash"
                    dummyAddr = Addr Testnet (ScriptHashObj (ScriptHash dummyHash)) StakeRefNull
                    activeAsset =
                        MultiAsset
                            ( Map.singleton
                                (policyIdFromPin active)
                                (Map.singleton (AssetName (SBS.toShort key)) 1)
                            )
                    fakeOut = mkBasicTxOut dummyAddr (MaryValue (Coin 2_000_000) activeAsset)
                in  case found of
                        (u : _) -> Right (u, canned key)
                        [] -> Right ((fakeIn, fakeOut), canned key)
            , hrReleaseOf = \_ _ -> Left "unused"
            , hrWithApplication = \_ _ live ctx ->
                if length live == expected
                    then Right ctx{rcHolderUtxos = rcHolderUtxos ctx <> live}
                    else
                        Left
                            ( T.pack
                                ( "testApp expected "
                                    <> show expected
                                    <> " holdings, got "
                                    <> show (length live)
                                )
                            )
            }

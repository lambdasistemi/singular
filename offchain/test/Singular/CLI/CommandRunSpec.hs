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
import Control.Monad (forM, forM_, unless, void, when)
import Control.Tracer (Tracer (..))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Either (isRight)
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, isPrefixOf, nub, partition, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe
    ( fromMaybe
    , isJust
    , isNothing
    , listToMaybe
    , mapMaybe
    )
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
    , createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    , doesPathExist
    , getCurrentDirectory
    , listDirectory
    , removePathForcibly
    , renameDirectory
    , renameFile
    , setCurrentDirectory
    )
import System.Exit (ExitCode (..))
import System.FilePath
    ( makeRelative
    , takeDirectory
    , takeFileName
    , (</>)
    )
import System.IO
    ( IOMode (..)
    , hClose
    , hFlush
    , openFile
    , stderr
    , stdout
    )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Env.ByteString qualified as PosixEnv
import System.Posix.Files
    ( fileMode
    , getFileStatus
    , nullFileMode
    , ownerReadMode
    , ownerWriteMode
    , setFileMode
    , unionFileModes
    )
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
import System.Timeout (timeout)
import Test.Hspec

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class
    ( hashFromBytes
    , hashToBytes
    , hashWith
    )
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
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
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Balance (BalanceResult (..), balanceTx)
import Cardano.Tx.Ledger (ConwayTx)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Word (Word64)

import PlutusCore.Data qualified as PLC
import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( CLIError (..)
    , Command (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WalletArgs (..)
    , WriteSettings (..)
    , parseCommand
    , parseCommandWithEnvironment
    , parseInvocationFrom
    , renderCLIError
    , singularVersion
    )
import Singular.CLI.Finish (finish)
import Singular.CLI.FlagGroup (Signer (..))
import Singular.CLI.Fold (runFoldBounded)
import Singular.CLI.Help (singularProgram)
import Singular.CLI.ManagedState (addressPartition, managedDir)
import Singular.CLI.Options (Raw (..))
import Singular.CLI.Outlay
    ( Outlay (..)
    , bookingOutlay
    , outlayTotal
    , spendableHeld
    , updateOutlay
    )
import Singular.CLI.Passphrase
    ( mkPassphrase
    , passphraseVariable
    , publicNetworks
    )
import Singular.CLI.Prepare
    ( PrepareRefusal (..)
    , allowanceRefusal
    , measureRequirement
    , preparationFields
    , prepareFunding
    , previewFunding
    )
import Singular.CLI.Receipt
    ( FoldTransition (..)
    , JournalEntry (..)
    , OutcomeClass (..)
    , bodiesDir
    , journalPath
    , outcomeName
    , readJournal
    )
import Singular.CLI.ReceiptBody (boundBody)
import Singular.CLI.Registry
    ( economics
    , hexT
    , loadRelease
    , loadReleaseCodes
    , pendingPath
    , registryConfigFor
    )
import Singular.CLI.Root (runPackagedVia, runSingular)
import Singular.CLI.Session
    ( CommandFailure (..)
    , Env (..)
    , WriteContext (..)
    , confirmedTx
    , expecting
    , failWithFields
    , submitBuilt
    , txIdHex
    , withSession
    )
import Singular.CLI.SettingsFile (keepStateToken)
import Singular.CLI.Sign (renderSignRefusal, witnessPlan)
import Singular.CLI.Sources (loadSources)
import Singular.CLI.SubmitSpec (selfPaymentFiles)
import Singular.CLI.Trace
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
    , ApplicationPin (..)
    , DecodedHolding (..)
    , HoldingRules (..)
    , datumCbor
    , datumHash
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Bundle
    ( Bundle (..)
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
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (RegistryEconomics (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , unverifiedVerifier
    )
import Singular.Registry.FoldSelection (foldCapacity)
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , PParams
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.Lifecycle (protocolFeeReserve)
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
import Singular.Registry.Signing (SignedTx, signTx, signedTx)
import Singular.Registry.StateToken (parseStateToken)
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trace (ReadEvent (Evaluated))
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges (adaOnlyOut, selectFunding)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , addrKeyHashBytes
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
import Singular.Registry.TxBuilder.Internal.Identity
    ( addrWitnessKeyHash
    , txInToRef
    )
import Singular.Registry.TxBuilder.Prepare
    ( Preparation (..)
    , planPreparation
    , spendableOuts
    )
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
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    , parseSignKey
    , walletFromSignKey
    )

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
        >> inclusionPointRows
        >> createDescribeCommandRows
        >> prepareFundingRows
        >> previewFundingRows
        >> externalSignerRows
        >> externalCreateRows
        >> journalPhaseRows
        >> vaultSignerRows
        >> stagedNarrationRows
        >> vaultBookkeepingRows
        >> vaultUnreadJournalRows
        >> saveStateTokenRows
        >> registryAddressRows

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
    it "keeps the Koios token file in the printed describe line" $ withRig $ \rig -> do
        seed <- fundSeed rig
        let tokenFile = rigDir rig <> "/koios.token"
        writeFile tokenFile "token\n"
        previewed <-
            run
                rig
                "preview with a token file"
                ( [ "registry"
                  , "create"
                  , "--preview"
                  , "--seed"
                  , seed
                  , "--koios-token-file"
                  , tokenFile
                  ]
                    <> policyArgs
                )
        outcomeOf (runReceipt previewed) `shouldBe` Just "success"
        case valueAt "describeCommand" (runReceipt previewed) of
            Just (Aeson.String line) ->
                line
                    `shouldSatisfy` T.isInfixOf (T.pack ("--koios-token-file " <> tokenFile))
            other ->
                expectationFailure ("no describe line: " <> show other)
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
        jsonCommand <-
            either (fail . show) pure (parseCommand (commandWords <> ["--json"]))
        (code, out, _) <-
            captured (runCommand neutralApplication (envOf rig) command)
        code `shouldBe` ExitSuccess
        (jsonCode, jsonOut, _) <-
            captured (runCommand neutralApplication (envOf rig) jsonCommand)
        jsonCode `shouldBe` ExitSuccess
        -- the default page is the page --json prints, and a JSON parser reads it
        out `shouldBe` jsonOut
        page <-
            either
                fail
                pure
                (Aeson.eitherDecodeStrict out :: Either String Aeson.Value)
        case page of
            Aeson.Object o -> do
                KeyMap.lookup "command" o `shouldBe` Just (Aeson.String "describe")
                T.isInfixOf (T.pack token) (TE.decodeUtf8 out) `shouldBe` True
            _ -> expectationFailure "the page is no JSON object"

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
                        { envWrites = \_ action ->
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
        env = (envOf rig){envWrites = \_ action -> action caps}
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
harness below names none of them. Submit prints a receipt and runs
in the lifecycle like every registry command.
-}
commandsWithoutReceipt :: [String]
commandsWithoutReceipt = ["Help", "WalletCreate", "WalletAddress", "WalletSign"]

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
    Help _ -> "Help"
    Create _ _ -> "Create"
    Describe _ -> "Describe"
    RegistryAddress _ -> "RegistryAddress"
    Fold _ -> "Fold"
    Reject _ -> "Reject"
    Reclaim _ -> "Reclaim"
    Inspect _ -> "Inspect"
    WalletCreate _ -> "WalletCreate"
    WalletAddress _ -> "WalletAddress"
    WalletSign _ -> "WalletSign"
    SubmitBundle _ -> "SubmitBundle"

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

{- | Every file under a directory with its bytes, each path recorded
relative to the FIXED root given: a relocation, a rename, a deletion and
an append all change the snapshot. A refusal that submits nothing must
leave the whole state directory byte-identical, journal, saved bodies
and all.
-}
snapshotDir :: FilePath -> IO [(FilePath, BS.ByteString)]
snapshotDir root = walk root
  where
    walk dir = do
        names <- sort <$> listDirectory dir
        fmap concat (mapM one names)
      where
        one n = do
            let p = dir </> n
            isDir <- doesDirectoryExist p
            if isDir
                then walk p
                else do
                    bytes <- BS.readFile p
                    pure [(makeRelative root p, bytes)]

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

previewFundingRows :: Spec
previewFundingRows = describe
    "previewFunding plans without submitting (#491 PR2)"
    $ do
        it "a funded wallet previews with no preparation and submits nothing" $ withRig $ \rig -> do
            _ <- fundSeed rig
            create <- run rig "create" (["registry", "create"] <> policyArgs)
            runExit create `shouldBe` ExitSuccess
            walletBefore <- readWallet rig
            let payer = walletAddr (rigWallet rig)
            dummy <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                pp <- SessionIO.parameters v
                dummyTxFromWallet pp payer walletBefore
            chainBefore <- readWallet rig
            result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (\_ -> pure dummy)
                    v
            case result of
                Right (shown, Nothing, tx) -> do
                    tx `shouldBe` dummy
                    shown `shouldSatisfy` (not . null)
                other ->
                    expectationFailure
                        ("funded preview planned unexpectedly: " <> show (voidPrep other))
            chainAfter <- readWallet rig
            chainAfter `shouldBe` chainBefore
        it "a token-only wallet previews one preparation and submits nothing" $ withRig $ \rig -> do
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
            wallet <- readWallet rig
            [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
            let payer = walletAddr (rigWallet rig)
            dummy <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                pp <- SessionIO.parameters v
                dummyTxFromWallet pp payer wallet
            chainBefore <- readWallet rig
            result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case result of
                Right (shown, Just prep, tx) -> do
                    tx `shouldBe` dummy
                    shown `shouldBe` [prepFunding prep]
                    prepFundingCoin prep `shouldSatisfy` (> 0)
                    prepFee prep `shouldSatisfy` (> 0)
                    case preparationFields (Just prep) of
                        [(_, Aeson.Object o)] -> do
                            KeyMap.member "transaction" o `shouldBe` True
                            KeyMap.member "output" o `shouldBe` True
                            KeyMap.member "lovelace" o `shouldBe` True
                            KeyMap.member "fee" o `shouldBe` True
                        _ -> expectationFailure "preview preparation has another shape"
                other ->
                    expectationFailure
                        ("token-only preview planned unexpectedly: " <> show (voidPrep other))
            chainAfter <- readWallet rig
            chainAfter `shouldBe` chainBefore
        it "preview figures equal the actual preparation on the same wallet" $ withRig $ \rig -> do
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
            wallet <- readWallet rig
            [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
            let payer = walletAddr (rigWallet rig)
            eventsBefore <- readIORef (rigEvents rig)
            chainBefore <- readWallet rig
            previewed <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (buildFromView payer)
                    v
            (prepPreview, overTxPreview) <- case previewed of
                Right (_, Just prep, tx) -> pure (prep, tx)
                other -> fail ("preview did not plan: " <> show (voidPrep other))
            eventsAfterPreview <- readIORef (rigEvents rig)
            length eventsAfterPreview `shouldBe` length eventsBefore
            chainAfterPreview <- readWallet rig
            chainAfterPreview `shouldBe` chainBefore
            ppPreview <-
                SessionIO.withLatest
                    (rawChainProvider (rigChain rig))
                    SessionIO.parameters
            let requirement = measureRequirement ppPreview payer overTxPreview
            prepFundingCoin prepPreview `shouldSatisfy` (>= requirement)
            prepFee prepPreview `shouldSatisfy` (> 0)
            (prepFee prepPreview < prepFundingCoin prepPreview) `shouldBe` True
            let wc =
                    WriteContext
                        { wcDir = rigDir rig
                        , wcCommand = "preview-test"
                        , wcWallet = Just (rigWallet rig)
                        , wcCaller = walletAddr (rigWallet rig)
                        , wcCapabilities = capabilities rig
                        , wcTimeout = Nothing
                        , wcTracer = rigTracer rig
                        , wcSource = "fixture"
                        , wcStaged = Nothing
                        }
            actual <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                prepareFunding
                    wc
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (buildFromView payer)
                    v
            (prepReal, _) <- case actual of
                Right (_, Just prep, tx) -> pure (prep, tx)
                other -> fail ("real did not prepare: " <> show (voidPrep other))
            txIdTx (prepTx prepPreview) `shouldBe` txIdTx (prepTx prepReal)
            prepFundingCoin prepPreview `shouldBe` prepFundingCoin prepReal
            prepFee prepPreview `shouldBe` prepFee prepReal
            eventsAfterReal <- readIORef (rigEvents rig)
            length eventsAfterReal `shouldSatisfy` (> length eventsBefore)
            chainAfterReal <- readWallet rig
            chainAfterReal `shouldNotBe` chainBefore
        it "an explicit smaller ada-only choice is used with no preparation" $ withRig $ \rig -> do
            _ <- fundSeed rig
            create <- run rig "create" (["registry", "create"] <> policyArgs)
            runExit create `shouldBe` ExitSuccess
            walletBefore <- readWallet rig
            let payer = walletAddr (rigWallet rig)
            (bigIn, bigCoin) <- case sortOn
                (Down . snd)
                [ (i, c)
                | (i, o) <- walletBefore
                , adaOnlyOut o
                , let Coin c = o ^. coinTxOutL
                ] of
                (i, c) : _ -> pure (i, c)
                [] -> fail "explicit preview leg: no ada-only output to split"
            bigOut <- case [o | (i, o) <- walletBefore, i == bigIn] of
                [o] -> pure o
                _ -> fail "explicit preview leg: split output vanished"
            let smallCoin = bigCoin `div` 3
                largeCoin = bigCoin - smallCoin
            when (smallCoin <= 0 || largeCoin <= smallCoin) $
                fail "explicit preview leg: cannot split an eligible pair"
            smallIn <-
                either fail pure (parseOutRef (T.pack (replicate 64 'd' <> "#1")))
            largeIn <-
                either fail pure (parseOutRef (T.pack (replicate 64 'd' <> "#2")))
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
            eventsBefore <- readIORef (rigEvents rig)
            chainBefore <- readWallet rig
            result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    (Just smallIn)
                    Nothing
                    updateOutlay
                    (buildFromView payer)
                    v
            case result of
                Right (shown, Nothing, tx) -> do
                    shown `shouldBe` [smallIn]
                    shown `shouldNotContain` [largeIn]
                    let spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
                    spent `shouldContain` [smallIn]
                    spent `shouldNotContain` [largeIn]
                other ->
                    expectationFailure
                        ("named preview planned unexpectedly: " <> show (voidPrep other))
            chainAfter <- readWallet rig
            chainAfter `shouldBe` chainBefore
            eventsAfter <- readIORef (rigEvents rig)
            eventsAfter `shouldBe` eventsBefore
        it
            "a short wallet is refused before signing with nothing submitted"
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
                let payer = walletAddr (rigWallet rig)
                dummy <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                    pp <- SessionIO.parameters v
                    full <- SessionIO.outputsAt v payer
                    dummyTxFromWallet pp payer full
                shortenWallet rig 500_000
                wallet <- readWallet rig
                [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                chainBefore <- readWallet rig
                result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding
                        "fold"
                        payer
                        Nothing
                        Nothing
                        updateOutlay
                        (buildFundingAware dummy payer)
                        v
                case result of
                    Left (PreparationShortfall text _) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                    other ->
                        expectationFailure
                            ("short preview planned unexpectedly: " <> show (voidPrep other))
                chainAfter <- readWallet rig
                chainAfter `shouldBe` chainBefore
        it "an allowance below command plus preparation refuses naming both" $ withRig $ \rig -> do
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
            wallet <- readWallet rig
            let payer = walletAddr (rigWallet rig)
            (dummy, outlay, fee) <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                pp <- SessionIO.parameters v
                tx <- dummyTxFromWallet pp payer wallet
                let outlay = updateOutlay tx
                    requirement = measureRequirement pp payer tx
                prepFee <- case planPreparation pp payer requirement wallet of
                    Left err ->
                        fail ("allowance leg: cannot plan covering preparation: " <> show err)
                    Right prep -> pure (prepFee prep)
                pure (tx, outlay, prepFee)
            let limit = outlayTotal outlay + fee
            tiny <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just 1)
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case tiny of
                Left (AllowanceExceeded text _) ->
                    text `shouldSatisfy` isInfixOf "passes the approved allowance"
                other ->
                    expectationFailure
                        ("tiny allowance planned unexpectedly: " <> show (voidPrep other))
            exact <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just limit)
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case exact of
                Right (_, Just _, _) -> pure ()
                other ->
                    expectationFailure
                        ("exact allowance refused unexpectedly: " <> show (voidPrep other))
            below <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just (limit - 1))
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case below of
                Left (AllowanceExceeded _ _) -> pure ()
                other ->
                    expectationFailure
                        ("one-below allowance passed unexpectedly: " <> show (voidPrep other))
            alone <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just (outlayTotal outlay))
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case alone of
                Left (AllowanceExceeded _ _) -> pure ()
                other ->
                    expectationFailure
                        ( "command-alone allowance passed unexpectedly: "
                            <> show (voidPrep other)
                        )
            chainAfter <- readWallet rig
            chainAfter `shouldBe` wallet
        it
            "whole-outlay interval refuses before signing with nothing submitted"
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
                names <- reshapeRehearsalWallet rig assets
                names `shouldBe` 2
                wallet0 <- readWallet rig
                [o | (_, o) <- wallet0, adaOnlyOut o] `shouldBe` []
                let payer = walletAddr (rigWallet rig)
                pp <-
                    SessionIO.withLatest
                        (rawChainProvider (rigChain rig))
                        SessionIO.parameters
                let measure = bookingOutlay pp []
                    Coin reserveInt = protocolFeeReserve pp []
                    build = buildBookingLike payer
                large <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                (oLarge, pLarge) <- case large of
                    Right (_, Just prep, overTx) ->
                        pure (outlayTotal (measure overTx), prepFee prep)
                    other ->
                        fail
                            ( "whole-outlay interval: large wallet did not prepare: "
                                <> show (voidPrep other)
                            )
                let hBelow = oLarge + pLarge - 100_000
                shortenWallet rig hBelow
                walletBelow <- readWallet rig
                [o | (_, o) <- walletBelow, adaOnlyOut o] `shouldBe` []
                length (spendableOuts walletBelow) `shouldBe` 1
                let heldBelow = spendableHeld walletBelow
                heldBelow `shouldBe` hBelow
                heldBelow `shouldSatisfy` (>= reserveInt)
                nLarge <- case large of
                    Right (_, Just prep, _) -> pure (prepFundingCoin prep)
                    _ -> fail "whole-outlay interval: no large preparation"
                case planPreparation pp payer nLarge walletBelow of
                    Left err ->
                        fail
                            ("whole-outlay interval: below still short of N+P+M: " <> show err)
                    Right _ -> pure ()
                chainBefore <- readWallet rig
                stateBeforePreview <- snapshotDir (rigDir rig)
                previewed <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                case previewed of
                    Left (PreparationShortfall text fields) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                        lookup "remainderMin" fields
                            `shouldBe` Just (Aeson.toJSON (0 :: Integer))
                        lookup "held" fields `shouldBe` Just (Aeson.toJSON hBelow)
                        lookup "required" fields
                            `shouldBe` Just (Aeson.toJSON (oLarge + pLarge))
                    other ->
                        expectationFailure
                            ( "whole-outlay interval preview planned unexpectedly: "
                                <> show (voidPrep other)
                            )
                chainAfterPreview <- readWallet rig
                chainAfterPreview `shouldBe` chainBefore
                stateAfterPreview <- snapshotDir (rigDir rig)
                stateAfterPreview `shouldBe` stateBeforePreview
                eventsBefore <- readIORef (rigEvents rig)
                stateBeforeWrite <- snapshotDir (rigDir rig)
                let wc =
                        WriteContext
                            { wcDir = rigDir rig
                            , wcCommand = "whole-outlay-interval"
                            , wcWallet = Just (rigWallet rig)
                            , wcCaller = walletAddr (rigWallet rig)
                            , wcCapabilities = capabilities rig
                            , wcTimeout = Nothing
                            , wcTracer = rigTracer rig
                            , wcSource = "fixture"
                            , wcStaged = Nothing
                            }
                actual <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    prepareFunding wc "book" payer Nothing Nothing measure build v
                case actual of
                    Left (PreparationShortfall text _) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                    other ->
                        expectationFailure
                            ( "whole-outlay interval prepare planned unexpectedly: "
                                <> show (voidPrep other)
                            )
                eventsAfter <- readIORef (rigEvents rig)
                eventsAfter `shouldBe` eventsBefore
                chainAfter <- readWallet rig
                chainAfter `shouldBe` chainBefore
                stateAfterWrite <- snapshotDir (rigDir rig)
                stateAfterWrite `shouldBe` stateBeforeWrite
        it
            "whole-outlay boundary accepts at outlay plus fee and refuses one below"
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
                names <- reshapeRehearsalWallet rig assets
                names `shouldBe` 2
                let payer = walletAddr (rigWallet rig)
                pp <-
                    SessionIO.withLatest
                        (rawChainProvider (rigChain rig))
                        SessionIO.parameters
                let measure = bookingOutlay pp []
                    build = buildBookingLike payer
                    findExact :: Integer -> Int -> IO (Integer, Integer, Integer, Integer)
                    findExact _ 0 = fail "whole-outlay boundary: fee did not stabilise"
                    findExact h n = do
                        shortenWallet rig h
                        wallet <- readWallet rig
                        [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                        previewed <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                            previewFunding "book" payer Nothing Nothing measure build v
                        case previewed of
                            Right (_, Just prep, overTx) -> do
                                let o = outlayTotal (measure overTx)
                                    p = prepFee prep
                                    target = o + p
                                if h == target
                                    then pure (h, o, p, prepFundingCoin prep)
                                    else findExact target (n - 1)
                            other ->
                                fail
                                    ( "whole-outlay boundary: exact candidate refused: "
                                        <> show (voidPrep other)
                                    )
                large <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                (o0, p0) <- case large of
                    Right (_, Just prep, overTx) ->
                        pure (outlayTotal (measure overTx), prepFee prep)
                    other ->
                        fail
                            ( "whole-outlay boundary: large wallet did not prepare: "
                                <> show (voidPrep other)
                            )
                (hExact, oExact, pExact, nExact) <- findExact (o0 + p0) 5
                hExact `shouldBe` (oExact + pExact)
                walletExact <- readWallet rig
                case planPreparation pp payer nExact walletExact of
                    Left err -> fail ("whole-outlay boundary: exact short of N+P+M: " <> show err)
                    Right _ -> pure ()
                chainBeforeExact <- readWallet rig
                previewExact <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                case previewExact of
                    Right (shown, Just prep, _) -> do
                        shown `shouldBe` [prepFunding prep]
                        prepFundingCoin prep `shouldBe` nExact
                        prepFee prep `shouldBe` pExact
                    other ->
                        expectationFailure
                            ( "whole-outlay boundary exact refused unexpectedly: "
                                <> show (voidPrep other)
                            )
                chainAfterExact <- readWallet rig
                chainAfterExact `shouldBe` chainBeforeExact
                let hBelow = hExact - 1
                shortenWallet rig hBelow
                walletBelow <- readWallet rig
                length (spendableOuts walletBelow) `shouldBe` 1
                spendableHeld walletBelow `shouldBe` hBelow
                case planPreparation pp payer nExact walletBelow of
                    Left err -> fail ("whole-outlay boundary: below short of N+P+M: " <> show err)
                    Right _ -> pure ()
                previewBelow <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                case previewBelow of
                    Left (PreparationShortfall text fields) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                        lookup "remainderMin" fields
                            `shouldBe` Just (Aeson.toJSON (0 :: Integer))
                        lookup "held" fields `shouldBe` Just (Aeson.toJSON hBelow)
                    other ->
                        expectationFailure
                            ( "whole-outlay boundary below planned unexpectedly: "
                                <> show (voidPrep other)
                            )
                chainAfterBelow <- readWallet rig
                chainAfterBelow `shouldBe` walletBelow
                -- The write at the same boundary: one lovelace below,
                -- prepareFunding itself refuses with nothing submitted —
                -- journal and state directory byte-identical — and at
                -- exactly outlay plus fee it accepts, submitting one
                -- preparation journalled with the funding expectation.
                eventsBeforeWrite <- readIORef (rigEvents rig)
                stateBeforeWrite <- snapshotDir (rigDir rig)
                let wc =
                        WriteContext
                            { wcDir = rigDir rig
                            , wcCommand = "whole-outlay-boundary"
                            , wcWallet = Just (rigWallet rig)
                            , wcCaller = walletAddr (rigWallet rig)
                            , wcCapabilities = capabilities rig
                            , wcTimeout = Nothing
                            , wcTracer = rigTracer rig
                            , wcSource = "fixture"
                            , wcStaged = Nothing
                            }
                refusedWrite <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                        prepareFunding wc "book" payer Nothing Nothing measure build v
                case refusedWrite of
                    Left (PreparationShortfall text fields) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                        lookup "remainderMin" fields
                            `shouldBe` Just (Aeson.toJSON (0 :: Integer))
                        lookup "held" fields `shouldBe` Just (Aeson.toJSON hBelow)
                    other ->
                        expectationFailure
                            ( "whole-outlay boundary write refused unexpectedly: "
                                <> show (voidPrep other)
                            )
                eventsAfterRefusal <- readIORef (rigEvents rig)
                eventsAfterRefusal `shouldBe` eventsBeforeWrite
                stateAfterRefusal <- snapshotDir (rigDir rig)
                stateAfterRefusal `shouldBe` stateBeforeWrite
                chainAfterRefusal <- readWallet rig
                chainAfterRefusal `shouldBe` walletBelow
                shortenWallet rig hExact
                walletExactAgain <- readWallet rig
                spendableHeld walletExactAgain `shouldBe` hExact
                acceptedWrite <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                        prepareFunding wc "book" payer Nothing Nothing measure build v
                accepted <- case acceptedWrite of
                    Right (shown, Just prep, realTx) -> do
                        shown `shouldBe` [prepFunding prep]
                        prepFundingCoin prep `shouldBe` nExact
                        prepFee prep `shouldBe` pExact
                        pure (prepTx prep, realTx)
                    other -> do
                        expectationFailure
                            ( "whole-outlay boundary write accepted unexpectedly: "
                                <> show (voidPrep other)
                            )
                        fail "unreachable"
                eventsAfterAccepted <- readIORef (rigEvents rig)
                let newEvents = drop (length eventsAfterRefusal) eventsAfterAccepted
                    submittedSteps =
                        [ step
                        | Trace _ (How (Tx TxSubmitted{submitStep = step})) <- newEvents
                        ]
                submittedSteps `shouldBe` ["book"]
                entries <- readJournal (rigDir rig)
                let txid = txIdHex (fst accepted)
                    phases = [journalEvent e | e <- entries, journalTxId e == txid]
                phases `shouldBe` ["prepared", "submitted", "confirmed", "observed"]
                let expects =
                        [ journalExpect e
                        | e <- entries
                        , journalTxId e == txid
                        , journalEvent e == "prepared"
                        ]
                expects
                    `shouldBe` [Just ("funding:" <> T.pack (bech32Address payer))]
                chainAfterAccepted <- readWallet rig
                chainAfterAccepted `shouldNotBe` walletExactAgain
        it
            "a state directory snapshot detects a moved subtree and a renamed file"
            $ withSystemTempDirectory "snapshot-detect"
            $ \dir -> do
                createDirectoryIfMissing True (dir </> "registry" </> "wallets")
                BS.writeFile (dir </> "registry" </> "journal.jsonl") "one line\n"
                BS.writeFile
                    (dir </> "registry" </> "wallets" </> "body.cbor.hex")
                    "bytes"
                snapshotBefore <- snapshotDir dir
                createDirectoryIfMissing True (dir </> "registry-moved")
                renameDirectory (dir </> "registry") (dir </> "registry-moved")
                moved <- snapshotDir dir
                moved `shouldNotBe` snapshotBefore
                renameFile
                    (dir </> "registry-moved" </> "journal.jsonl")
                    (dir </> "registry-moved" </> "journal2.jsonl")
                renamed <- snapshotDir dir
                renamed `shouldNotBe` moved
                BS.appendFile
                    (dir </> "registry-moved" </> "journal2.jsonl")
                    "two lines\n"
                appended <- snapshotDir dir
                appended `shouldNotBe` renamed

dummyTxFromWallet
    :: PParams ConwayEra -> Addr -> [(TxIn, TxOut ConwayEra)] -> IO ConwayTx
dummyTxFromWallet pp payer wallet = case sortOn (Down . coinOf . snd) (spendableOuts wallet) of
    [] -> fail "dummyTxFromWallet: no spendable output to build from"
    (spentIn, spentOut) : _ -> do
        let Coin c = spentOut ^. coinTxOutL
            half = c `div` 2
            unsigned =
                mkBasicTx $
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton spentIn
                        & outputsTxBodyL
                            .~ StrictSeq.singleton
                                (mkBasicTxOut payer (MaryValue (Coin half) mempty))
                        & feeTxBodyL .~ Coin 0
                        & reqSignerHashesTxBodyL
                            .~ Set.singleton (addrWitnessKeyHash (addrKeyHashBytes payer))
        case balanceTx pp [(spentIn, spentOut)] [] payer unsigned of
            Left err -> fail ("dummyTxFromWallet: balancing failed: " <> show err)
            Right (BalanceResult tx _) -> pure tx
  where
    coinOf out = let Coin c = out ^. coinTxOutL in c

buildFromView :: Addr -> Cage.Session NoWitness IO -> IO ConwayTx
buildFromView payer v = do
    pp <- SessionIO.parameters v
    viewWallet <- SessionIO.outputsAt v payer
    dummyTxFromWallet pp payer viewWallet

buildFundingAware
    :: ConwayTx -> Addr -> Cage.Session NoWitness IO -> IO ConwayTx
buildFundingAware dummy payer v = do
    wallet <- SessionIO.outputsAt v payer
    case selectFunding Nothing wallet of
        Left why -> throwIO (ErrorCall why)
        Right _ -> pure dummy

{- | A booking-like build for the whole-outlay interval (#491 PR2b line 1).
Singleton funding input, a bond out to another address plus change back,
balanced by the ledger. Fails when no ada-only output exists (natural),
succeeds from the oversized probe. The bond is a fixture input; every
bound (outlay, requirement, fee, reserve) is read from producers.
-}
bookingBond :: Integer
bookingBond = 2_000_000

otherBookingAddr :: Addr
otherBookingAddr =
    addrFromKeyHashBytes Testnet (BS.replicate 28 0xbb)

buildBookingLike
    :: Addr -> Cage.Session NoWitness IO -> IO ConwayTx
buildBookingLike payer v = do
    wallet <- SessionIO.outputsAt v payer
    case selectFunding Nothing wallet of
        Left why -> throwIO (ErrorCall why)
        Right (fundIn, fundOut) -> do
            pp <- SessionIO.parameters v
            let unsigned =
                    mkBasicTx $
                        mkBasicTxBody
                            & inputsTxBodyL .~ Set.singleton fundIn
                            & outputsTxBodyL
                                .~ StrictSeq.fromList
                                    [ mkBasicTxOut
                                        otherBookingAddr
                                        (MaryValue (Coin bookingBond) mempty)
                                    , mkBasicTxOut
                                        payer
                                        (MaryValue (Coin 1_000_000) mempty)
                                    ]
                            & feeTxBodyL .~ Coin 0
                            & reqSignerHashesTxBodyL
                                .~ Set.singleton
                                    (addrWitnessKeyHash (addrKeyHashBytes payer))
            case balanceTx pp [(fundIn, fundOut)] [] payer unsigned of
                Left err ->
                    throwIO (ErrorCall ("buildBookingLike: " <> show err))
                Right (BalanceResult tx _) -> pure tx

voidPrep
    :: Either PrepareRefusal ([TxIn], Maybe Preparation, ConwayTx) -> String
voidPrep =
    either
        (const "refusal")
        (\(shown, prep, _) -> show (shown, isJust prep))

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
    -- The address of the registry the create made: no node, blueprint or key.
    address <- runAddress rig "address from the state token" t1
    -- A signed bundle of one self-payment from the wallet, sent by submit:
    -- no registry, no key file, the witness written by the signing planner.
    held <- readWallet rig
    (bundle, witness) <- case held of
        output : _ ->
            selfPaymentFiles
                (rigDir rig </> "submit")
                (walletSignKey (rigWallet rig))
                output
        [] -> fail "the lifecycle left the wallet nothing to submit from"
    submitted <-
        run
            rig
            "submit a signed bundle"
            ["submit", "--witnesses", witness, bundle]
    pure
        [ create
        , reclaim
        , create2
        , reject
        , nothingPending
        , emptyDir
        , page
        , address
        , submitted
        ]

{- | @registry address@ over the rig: it reads no chain and takes no node,
blueprint or key, so its line is its own and not the rig's.
-}
runAddress :: Rig -> String -> String -> IO Run
runAddress rig label token = do
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . renderCLIError)
            pure
            ( parseCommand
                [ "registry"
                , "address"
                , "--state-token"
                , token
                , "--network-magic"
                , show magic
                ]
            )
    (code, out, _) <-
        captured (runCommand neutralApplication (envOf rig) command)
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
            , runKey = Nothing
            }

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
plantRequest rig tokenStr seedStr econ key =
    plantRequestDeposit rig tokenStr seedStr econ key 1_000_000

{- | 'plantRequest' with the request's deposit in lovelace named: a deposit
beyond the wallet's largest ada-only output forces a later write to make a
preparation.
-}
plantRequestDeposit
    :: Rig
    -> String
    -> String
    -> RegistryEconomics
    -> BS.ByteString
    -> Integer
    -> IO (TxIn, Integer)
plantRequestDeposit rig tokenStr seedStr econ key deposit = do
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
            requestEdgeImpl cfg v (Coin deposit) tid key edgeInsertActive wallet
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
            , envWrites = \_ k -> k (atTxInCapabilities answer rig)
            }
        )
        "registry"

-- | A command line over the rig, as the packaged command is given it.
commandLine :: Rig -> FilePath -> [String] -> [String]
commandLine rig registry args
    | take 1 args == ["submit"] =
        args
            <> [ "--koios-url"
               , "http://fixture.invalid"
               , "--network-magic"
               , show magic
               ]
    | otherwise =
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
            -- an external signer names its own signer: the key file never joins it
            && not (any (`elem` args) ["--wallet-address", "--bundle", "--vault"])

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

{- | The chain fixture reports a recorded transaction at the chain point
of the block that actually applied it — the slot and header the chain
itself reached when the record was taken — for both the submit path the
rig drives and the planted request the setup records. A receipt built
from this implementer must not name a slot the transaction never
entered.
-}

{- | The rig wallet's own payment back to itself, as the row that reads
an inclusion point submits.
-}
selfPayment :: Wallet -> Cage.Outputs -> SignedTx
selfPayment wallet held = signTx (walletSignKey wallet) (mkBasicTx body)
  where
    fee = Coin 1_000_000
    value = foldMap ((^. valueTxOutL) . snd) held
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList (map fst held)
            & outputsTxBodyL
                .~ StrictSeq.singleton
                    (mkBasicTxOut (walletAddr wallet) (value <-> inject fee))
            & feeTxBodyL .~ fee

inclusionPointRows :: Spec
inclusionPointRows = describe
    "the fixture's inclusion read reports the block that applied the transaction"
    $ do
        it "names the slot and header the submit path advanced the chain to" $
            withRig $ \rig -> do
                held <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                        SessionIO.outputsAt v (walletAddr (rigWallet rig))
                let transaction = selfPayment (rigWallet rig) held
                answer <- capSubmit (capabilities rig) transaction
                _ <- case answer of
                    Cage.SubmitAccepted accepted -> pure accepted
                    other -> fail ("the rig refused the payment: " <> show other)
                (included, tip) <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                        statuses <-
                            either
                                (fail . ("inclusion read failed: " <>) . show)
                                (pure . value)
                                =<< Cage.inclusion v [txIdTx (signedTx transaction)]
                        status <- case statuses of
                            [one] -> pure one
                            _ -> fail "the inclusion read did not answer the payment once"
                        observed <- SessionIO.tip v
                        pure (status, observed)
                case included of
                    Cage.IncludedAt point _ -> do
                        point
                            `shouldBe` Cage.At
                                (Cage.observedSlot tip)
                                (Cage.observedHash tip)
                    other ->
                        expectationFailure
                            ("the chain does not hold the payment: " <> show other)
        it "names the slot and header the planted request entered" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                create <- run rig "create" (["registry", "create"] <> policyArgs)
                runExit create `shouldBe` ExitSuccess
                t1 <- tokenOf create
                (reqIn, _) <-
                    plantRequest rig t1 seed economics (TE.encodeUtf8 "inclusion")
                let planted = case reqIn of TxIn identity _ -> identity
                (included, tip) <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                        statuses <-
                            either
                                (fail . ("inclusion read failed: " <>) . show)
                                (pure . value)
                                =<< Cage.inclusion v [planted]
                        status <- case statuses of
                            [one] -> pure one
                            _ -> fail "the inclusion read did not answer the planted request once"
                        observed <- SessionIO.tip v
                        pure (status, observed)
                case included of
                    Cage.IncludedAt point _ ->
                        point
                            `shouldBe` Cage.At (Cage.observedSlot tip) (Cage.observedHash tip)
                    other ->
                        expectationFailure
                            ("the chain does not hold the planted request: " <> show other)

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

-- ---------------------------------------------------------
-- The external signer (#641 slice 2)
-- ---------------------------------------------------------

{- | A staged write: the caller names their address and a bundle file, the
command builds its whole run as one bundle, sends nothing and exits 19. The
rows cover the three writes, the funding preparation through the chained
view, the bodies' equality with the key-file path's, the waiting lines, the
saved bytes, the refusals and the trace.
-}
externalSignerRows :: Spec
externalSignerRows = describe "the external signer" $ do
    stagedFoldRow
    stagedFoldWithPreparationRow
    stagedRejectRow
    stagedReclaimRow
    noKeyFileRow
    scriptAddressRow
    existingBundleRow
    stagedStopRow
    signerFlagRefusalRows

{- | The external signer's flags for the rig's own wallet: the address as
given (bech32, derived from the rig's key at run time) and the bundle file.
-}
externalArgs :: Rig -> FilePath -> [String]
externalArgs rig bundlePath =
    [ "--wallet-address"
    , bech32Address (walletAddr (rigWallet rig))
    , "--bundle"
    , bundlePath
    ]

-- | The bech32 spelling of an address whose payment part is a script.
aScriptAddress :: String
aScriptAddress =
    bech32Address (Addr Testnet (ScriptHashObj scriptHash) StakeRefNull)
  where
    scriptHash = case hashFromBytes (BS.replicate 28 3) of
        Just h -> ScriptHash h
        Nothing -> error "aScriptAddress: 28 bytes are not a script hash"

{- | The partition directory a run of this registry resolves for a signer
whose payment key hash is the rig wallet's.
-}
stagedPartition :: Rig -> String -> String -> FilePath
stagedPartition rig registry tokenStr =
    managedDir
        (rigDir rig </> registry)
        (fromIntegral magic)
        token
        (addressPartition (walletAddr (rigWallet rig)))
  where
    token = case parseStateToken (T.pack tokenStr) of
        Right t -> t
        Left why -> error ("stagedPartition: " <> T.unpack why)

{- | An environment whose submission capability counts every call: a staged
run must never reach it, and the count proves it.
-}
withCountedSubmissions :: Rig -> (Env -> IO a) -> IO a
withCountedSubmissions rig use = do
    counted <- newIORef (0 :: Int)
    let env =
            (envOf rig)
                { envWrites = \_ k ->
                    k
                        (capabilities rig)
                            { capSubmit = \tx -> do
                                modifyIORef' counted (+ 1)
                                capSubmit (capabilities rig) tx
                            }
                }
    result <- use env
    n <- readIORef counted
    n `shouldBe` 0
    pure result

-- | The bundle at a path, checked, with every body decoded.
checkedBundle :: FilePath -> IO (Bundle, [ConwayTx])
checkedBundle path = do
    bytes <- BS.readFile path
    bundle <-
        either (fail . renderBundleRefusal) pure (decodeBundle bytes)
    either (fail . renderBundleRefusal) pure (checkBundle bundle)
    bodies <-
        forM (toList (bundleTransactions bundle)) $
            either
                (fail . ("a bundle envelope does not decode: " <>))
                pure
                . decodeTransactionEnvelope
                . bundleTxEnvelope
    pure (bundle, bodies)

-- | The BLAKE2b-256 of some bytes, as the receipt names it.
hashOfBytes :: BS.ByteString -> Text
hashOfBytes bytes =
    hexT (hashToBytes (hashWith @Blake2b_256 id bytes))

{- | The unsigned bodies the key-file path built for this registry's command,
read back from its own journal's prepared lines, in build order. The
registry's boot, journalled by @registry create@ into the same partition, is
setup and is left out; a preparation the command made is journalled under
the command and stays in.
-}
keyFilePreparedBodies
    :: Rig -> String -> String -> Text -> IO [ConwayTx]
keyFilePreparedBodies rig registry tokenStr command = do
    entries <- readJournal (stagedPartition rig registry tokenStr)
    forM
        [ e
        | e <- entries
        , journalEvent e == "prepared"
        , journalCommand e == command
        ]
        $ \e -> do
            (_, body) <- boundBody entries (journalTxId e)
            either (fail . T.unpack) pure body

{- | A transaction as the oracle compares its body: the validity interval set aside,
because the staged run and the key-file run build at different moments and
their bounds follow the clock; every other field is compared.
-}
apartFromValidity :: ConwayTx -> ConwayTx
apartFromValidity tx =
    tx & bodyTxL . vldtTxBodyL .~ ValidityInterval SNothing SNothing

{- | The command's own staged transaction, the last of the run, carries an
upper validity bound: the deadline its receipt states.
-}
ownBodyBounded :: [ConwayTx] -> IO ()
ownBodyBounded bodies = case reverse bodies of
    own : _ -> case invalidHereafter (own ^. bodyTxL . vldtTxBodyL) of
        SJust _ -> pure ()
        SNothing -> expectationFailure "the command's staged body has no upper bound"
    [] -> expectationFailure "no staged body"

{- | The transaction a saved body file holds, through the same checks the
prepared-body reader applies: hex text, a decodable Conway transaction
whose own id is the identity the line names, and the line's hash over the
raw bytes. The saved material is bound to what it claims to be, never
taken at its own hash.
-}
savedBodyOf :: JournalEntry -> IO (ConwayTx, BS.ByteString)
savedBodyOf e = do
    path <- case journalBody e of
        Just p -> pure p
        Nothing -> fail "the line names no saved body"
    stored <- BS.readFile path
    raw <-
        either
            (fail . ("the saved body is not hex: " <>))
            pure
            (B16.decode (BC.filter (/= '\n') stored))
    decoded <-
        either
            (fail . ("the saved body does not decode to a transaction: " <>) . show)
            pure
            ( decodeFullAnnotator
                (eraProtVerHigh @ConwayEra)
                "transaction"
                decCBOR
                (BL.fromStrict raw)
            )
    txIdHex decoded `shouldBe` journalTxId e
    journalBodyHash e `shouldBe` Just (hashOfBytes raw)
    pure (decoded, raw)

{- | What a staged run's journal must hold: nothing but one waiting line per
staged transaction, each naming the step, the identity, the bundle's hash in
its detail, the saved body's path and hash, the network and the era; and
each saved body is the bundle's own transaction under that identity — its
raw bytes the envelope's CBOR, its decoded self the bundle's body.
-}
assertWaitingJournal
    :: Rig -> String -> String -> Text -> Bundle -> [ConwayTx] -> IO ()
assertWaitingJournal rig registry tokenStr bundleHash bundle bodies = do
    let dir = stagedPartition rig registry tokenStr
    entries <- readJournal dir
    [e | e <- entries, journalEvent e /= "waiting-for-signatures"]
        `shouldBe` []
    let waiting = [e | e <- entries, journalEvent e == "waiting-for-signatures"]
    length waiting `shouldBe` length bodies
    forM_ (zip3 waiting (toList (bundleTransactions bundle)) bodies) $ \(e, entry, body) -> do
        journalTxId e `shouldBe` txIdHex body
        journalDetail e `shouldBe` Just bundleHash
        journalNetwork e `shouldBe` Just (fromIntegral magic)
        journalEra e `shouldBe` Just "Conway"
        let path = fromMaybe "" (journalBody e)
        path `shouldStartWith` (bodiesDir dir </> "")
        path `shouldEndWith` (T.unpack (txIdHex body) <> ".cbor.hex")
        (decoded, raw) <- savedBodyOf e
        decoded `shouldBe` body
        envelopeBytes <-
            either
                (fail . ("the bundle envelope is not hex: " <>))
                pure
                (B16.decode (TE.encodeUtf8 (envelopeCborHex (bundleTxEnvelope entry))))
        raw `shouldBe` envelopeBytes

{- | A staged run's trace holds one built and one staged event per
transaction, and never a signed, submitted, confirmed or observed one.
-}
assertStagedTrace :: Run -> [ConwayTx] -> IO ()
assertStagedTrace staged bodies = do
    let txEvents = [t | Trace _ (How (Tx t)) <- runEvents staged]
    length [() | TxBuilt{} <- txEvents] `shouldBe` length bodies
    filter otherThanBuilt txEvents `shouldBe` []
    let rendered = mconcat [renderJsonLine e | e <- runEvents staged]
    rendered `shouldSatisfy` BS.isInfixOf "\"tx-staged\""
  where
    otherThanBuilt txEv = case txEv of
        TxBuilt{} -> False
        _ -> True

-- | The receipt's bundle summary, as JSON.
bundleSummaryOf :: Run -> IO Aeson.Value
bundleSummaryOf r = case valueAt "bundle" (runReceipt r) of
    Just v -> pure v
    Nothing -> do
        expectationFailure
            ("no bundle in the receipt: " <> show (runReceipt r))
        pure Aeson.Null

{- | The staged receipt states the command's own fields as expectations only:
every field the key-file receipt of the same command states as an observed
fact appears under expected and never at the top level. The factual set is
read from the key-file run's own receipt, never listed by hand.
-}
assertExpectationOnly :: Run -> Run -> IO ()
assertExpectationOnly staged keyRun = do
    expected <- case valueAt "expected" (runReceipt staged) of
        Just v@(Aeson.Object _) -> pure v
        other -> fail ("no expected fields: " <> show other)
    forM_ (KeyMap.keys (fieldsOf (runReceipt keyRun))) $ \k ->
        unless (k `elem` excluded) $ do
            valueAt k (runReceipt staged) `shouldBe` Nothing
            valueAt k expected `shouldNotBe` Nothing
  where
    excluded = ["command", "outcome", "reconciled", "submissions"]
    fieldsOf = \case
        Aeson.Object o -> o
        _ -> KeyMap.empty

-- | The effect lines of one transaction summary, as text.
effectsOf :: Aeson.Value -> [Text]
effectsOf = \case
    Aeson.Object o -> case KeyMap.lookup "effects" o of
        Just (Aeson.Array ls) -> [t | Aeson.String t <- toList ls]
        _ -> []
    _ -> []

stagedFoldRow :: Spec
stagedFoldRow =
    it "stages a fold as one bundle, waiting for signatures" $
        withRig $ \rig -> withCountedSubmissions rig $ \env -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            t <- tokenOf create
            (req, _) <-
                plantRequest rig t seed economics (TE.encodeUtf8 "bob-fold")
            _ <- certifyPlanted rig t seed economics [req]
            let bundlePath = rigDir rig </> "bob-fold.bundle"
                registry = "bob-external"
            staged <-
                runVia
                    rig
                    env
                    registry
                    "staged fold"
                    ( [ "registry"
                      , "fold"
                      , "--request"
                      , T.unpack (renderOutRef req)
                      ]
                        <> tokenArgs t
                        <> externalArgs rig bundlePath
                    )
            runExit staged `shouldBe` ExitFailure 19
            outcomeOf (runReceipt staged)
                `shouldBe` Just "waiting-for-signatures"
            bytes <- BS.readFile bundlePath
            let bundleHash = hashOfBytes bytes
            (bundle, bodies) <- checkedBundle bundlePath
            bundleCommand bundle `shouldBe` "fold"
            bundleNetworkMagic bundle `shouldBe` fromIntegral magic
            bundleStateToken bundle `shouldBe` Just (T.pack t)
            toList (bundleSigners bundle)
                `shouldBe` [T.pack (bech32Address (walletAddr (rigWallet rig)))]
            length bodies `shouldBe` 1
            [bundleTxIdentity entry | entry <- toList (bundleTransactions bundle)]
                `shouldBe` map bodyIdentity bodies
            case witnessPlan bytes (walletSignKey (rigWallet rig)) of
                Right plan -> length plan `shouldBe` length bodies
                Left refusal ->
                    expectationFailure
                        ("the staged bundle does not sign: " <> renderSignRefusal refusal)
            assertWaitingJournal rig registry t bundleHash bundle bodies
            assertStagedTrace staged bodies
            summary <- bundleSummaryOf staged
            textAt "hash" summary `shouldBe` Just bundleHash
            textAt "written" summary `shouldBe` Just (T.pack bundlePath)
            saved <- case textAt "saved" summary of
                Just p -> pure (T.unpack p)
                Nothing -> fail "no saved path in the bundle summary"
            savedBytes <- BS.readFile saved
            savedBytes `shouldBe` bytes
            saved `shouldSatisfy` isInfixOf (T.unpack bundleHash)
            case valueAt "transactions" summary of
                Just (Aeson.Array txs) -> do
                    length txs `shouldBe` 1
                    forM_ (zip (toList txs) bodies) $ \(txv, _body) ->
                        textAt "step" txv `shouldBe` Just "fold"
                other ->
                    expectationFailure ("no transactions in summary: " <> show other)
            valueAt "submissions" (runReceipt staged) `shouldBe` Nothing
            expected <- case valueAt "expected" (runReceipt staged) of
                Just v@(Aeson.Object _) -> pure v
                other -> fail ("no expected fields: " <> show other)
            case bodies of
                [body] -> do
                    textAt "fold" expected `shouldBe` Just (txIdHex body)
                    textAt "folder" expected
                        `shouldBe` Just
                            (hexT (addrKeyHashBytes (walletAddr (rigWallet rig))))
                _ -> expectationFailure "the bundle holds not exactly one body"
            keyRun <-
                run
                    rig
                    "key-file fold after the staged one"
                    ( [ "registry"
                      , "fold"
                      , "--request"
                      , T.unpack (renderOutRef req)
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt keyRun) `shouldBe` Just "success"
            assertExpectationOnly staged keyRun
            keyBodies <- keyFilePreparedBodies rig "registry" t "fold"
            map ((^. bodyTxL) . apartFromValidity) keyBodies
                `shouldBe` map ((^. bodyTxL) . apartFromValidity) bodies
            ownBodyBounded bodies

stagedFoldWithPreparationRow :: Spec
stagedFoldWithPreparationRow =
    it
        "stages the preparation then the fold, the fold spending the preparation's output"
        $ withRig
        $ \rig -> withCountedSubmissions rig $ \env -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            t <- tokenOf create
            (req, _) <-
                plantRequestDeposit
                    rig
                    t
                    seed
                    economics
                    (TE.encodeUtf8 "bob-fold-prep")
                    3_000_000_000
            approvals <- certifyPlanted rig t seed economics [req]
            _ <- reshapeRehearsalWallet rig approvals
            let bundlePath = rigDir rig </> "bob-fold-prep.bundle"
                registry = "bob-external-prep"
            staged <-
                runVia
                    rig
                    env
                    registry
                    "staged fold with a preparation"
                    ( [ "registry"
                      , "fold"
                      , "--request"
                      , T.unpack (renderOutRef req)
                      ]
                        <> tokenArgs t
                        <> externalArgs rig bundlePath
                    )
            runExit staged `shouldBe` ExitFailure 19
            outcomeOf (runReceipt staged) `shouldBe` Just "waiting-for-signatures"
            bytes <- BS.readFile bundlePath
            (bundle, bodies) <- checkedBundle bundlePath
            case bodies of
                [preparation, foldTx] ->
                    Set.member
                        (txIdTx preparation)
                        ( Set.fromList
                            [i | TxIn i _ <- Set.toList (foldTx ^. bodyTxL . inputsTxBodyL)]
                        )
                        `shouldBe` True
                _ ->
                    expectationFailure
                        "the bundle holds other than two transactions"
            assertWaitingJournal
                rig
                registry
                t
                (hashOfBytes bytes)
                bundle
                bodies
            assertStagedTrace staged bodies
            summary <- bundleSummaryOf staged
            case valueAt "transactions" summary of
                Just (Aeson.Array txs) -> do
                    length txs `shouldBe` 2
                    forM_ (zip (toList txs) bodies) $ \(txv, body) -> do
                        textAt "step" txv `shouldBe` Just "fold"
                        textAt "identity" txv `shouldBe` Just (txIdHex body)
                        case bodyDeadline body of
                            Just slot ->
                                valueAt "deadline" txv `shouldBe` Just (Aeson.toJSON slot)
                            Nothing -> valueAt "deadline" txv `shouldBe` Nothing
                    case toList txs of
                        (prepSummary : _) ->
                            effectsOf prepSummary
                                `shouldSatisfy` any (T.isInfixOf "ada only")
                        _ -> pure ()
                other ->
                    expectationFailure ("no transactions in summary: " <> show other)
            keyRun <-
                run
                    rig
                    "key-file fold after the staged one"
                    ( [ "registry"
                      , "fold"
                      , "--request"
                      , T.unpack (renderOutRef req)
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt keyRun) `shouldBe` Just "success"
            assertExpectationOnly staged keyRun
            keyBodies <- keyFilePreparedBodies rig "registry" t "fold"
            length keyBodies `shouldBe` 2
            map ((^. bodyTxL) . apartFromValidity) keyBodies
                `shouldBe` map ((^. bodyTxL) . apartFromValidity) bodies
            ownBodyBounded bodies

stagedRejectRow :: Spec
stagedRejectRow =
    it "stages a reject as one bundle the key-file path would build too" $
        withRig $ \rig -> withCountedSubmissions rig $ \env -> do
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
            (_, submitted) <-
                plantRequest
                    rig
                    t2
                    seed2
                    shortEcon
                    (TE.encodeUtf8 "bob-reject")
            jumpToAfter
                rig
                (submitted + reProcessTime shortEcon + reRetractTime shortEcon)
                2
            let bundlePath = rigDir rig </> "bob-reject.bundle"
                registry = "bob-external-reject"
            staged <-
                runVia
                    rig
                    env
                    registry
                    "staged reject"
                    (["registry", "reject"] <> tokenArgs t2 <> externalArgs rig bundlePath)
            runExit staged `shouldBe` ExitFailure 19
            outcomeOf (runReceipt staged) `shouldBe` Just "waiting-for-signatures"
            bytes <- BS.readFile bundlePath
            (bundle, bodies) <- checkedBundle bundlePath
            bundleCommand bundle `shouldBe` "reject"
            length bodies `shouldBe` 1
            assertWaitingJournal rig registry t2 (hashOfBytes bytes) bundle bodies
            assertStagedTrace staged bodies
            keyRun <-
                runAt
                    rig
                    "registry-2"
                    "key-file reject after the staged one"
                    (["registry", "reject"] <> tokenArgs t2)
            outcomeOf (runReceipt keyRun) `shouldBe` Just "success"
            assertExpectationOnly staged keyRun
            keyBodies <- keyFilePreparedBodies rig "registry-2" t2 "reject"
            map ((^. bodyTxL) . apartFromValidity) keyBodies
                `shouldBe` map ((^. bodyTxL) . apartFromValidity) bodies
            ownBodyBounded bodies

stagedReclaimRow :: Spec
stagedReclaimRow =
    it "stages a reclaim as one bundle the key-file path would build too" $
        withRig $ \rig -> withCountedSubmissions rig $ \env -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            t <- tokenOf create
            (req, submitted) <-
                plantRequest rig t seed economics (TE.encodeUtf8 "bob-reclaim")
            jumpToAfter rig (submitted + reProcessTime economics) 0
            let bundlePath = rigDir rig </> "bob-reclaim.bundle"
                registry = "bob-external-reclaim"
            staged <-
                runVia
                    rig
                    env
                    registry
                    "staged reclaim"
                    ( [ "registry"
                      , "reclaim"
                      , "--request"
                      , T.unpack (renderOutRef req)
                      ]
                        <> tokenArgs t
                        <> externalArgs rig bundlePath
                    )
            runExit staged `shouldBe` ExitFailure 19
            outcomeOf (runReceipt staged) `shouldBe` Just "waiting-for-signatures"
            bytes <- BS.readFile bundlePath
            (bundle, bodies) <- checkedBundle bundlePath
            bundleCommand bundle `shouldBe` "reclaim"
            length bodies `shouldBe` 1
            assertWaitingJournal rig registry t (hashOfBytes bytes) bundle bodies
            assertStagedTrace staged bodies
            keyRun <-
                run
                    rig
                    "key-file reclaim after the staged one"
                    ( [ "registry"
                      , "reclaim"
                      , "--request"
                      , T.unpack (renderOutRef req)
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt keyRun) `shouldBe` Just "success"
            assertExpectationOnly staged keyRun
            keyBodies <- keyFilePreparedBodies rig "registry" t "reclaim"
            map ((^. bodyTxL) . apartFromValidity) keyBodies
                `shouldBe` map ((^. bodyTxL) . apartFromValidity) bodies
            ownBodyBounded bodies

noKeyFileRow :: Spec
noKeyFileRow =
    it "opens no key file in the external mode" $
        withRig $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            t <- tokenOf create
            (req, _) <-
                plantRequest rig t seed economics (TE.encodeUtf8 "bob-nokey")
            _ <- certifyPlanted rig t seed economics [req]
            let key = rigKey rig
                hidden = key <> ".hidden"
                bundlePath = rigDir rig </> "bob-nokey.bundle"
            renameFile key hidden
            staged <-
                ( do
                    r <-
                        runAt
                            rig
                            "bob-external-nokey"
                            "staged fold with the key file absent"
                            ( [ "registry"
                              , "fold"
                              , "--request"
                              , T.unpack (renderOutRef req)
                              ]
                                <> tokenArgs t
                                <> externalArgs rig bundlePath
                            )
                    pure (Just r)
                )
                    `finally` renameFile hidden key
            case staged of
                Nothing -> expectationFailure "the run did not finish"
                Just r -> do
                    runExit r `shouldBe` ExitFailure 19
                    outcomeOf (runReceipt r)
                        `shouldBe` Just "waiting-for-signatures"

scriptAddressRow :: Spec
scriptAddressRow =
    it
        "refuses a script-payment address before anything is read, naming it"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            t <- tokenOf create
            let bundlePath = rigDir rig </> "script.bundle"
            parseCommand
                ( commandLine
                    rig
                    "bob-external-script"
                    ( [ "registry"
                      , "fold"
                      ]
                        <> tokenArgs t
                        <> ["--wallet-address", aScriptAddress, "--bundle", bundlePath]
                    )
                )
                `shouldBe` Left
                    ( BadValue
                        "--wallet-address"
                        ( aScriptAddress
                            <> " pays a script, not a payment key: the bundle's signer must be a payment key"
                        )
                    )
            doesFileExist bundlePath `shouldReturn` False

existingBundleRow :: Spec
existingBundleRow =
    it
        "refuses an existing bundle file before anything is read, its bytes untouched"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            t <- tokenOf create
            (req, _) <-
                plantRequest rig t seed economics (TE.encodeUtf8 "bob-taken")
            let bundlePath = rigDir rig </> "taken.bundle"
                sentinel = "sentinel bytes"
                registry = "bob-external-taken"
                -- The refusal names the bundle file and leaves its bytes as
                -- they were, whatever else the run would have met.
                refusedOnTheBundle at label = do
                    refused <-
                        runAt
                            rig
                            at
                            label
                            ( [ "registry"
                              , "fold"
                              , "--request"
                              , T.unpack (renderOutRef req)
                              ]
                                <> tokenArgs t
                                <> externalArgs rig bundlePath
                            )
                    runExit refused `shouldBe` ExitFailure 10
                    outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
                    fromMaybe "" (receiptReason refused)
                        `shouldSatisfy` T.isInfixOf (T.pack bundlePath)
                    BS.readFile bundlePath `shouldReturn` sentinel
            BS.writeFile bundlePath sentinel
            -- Nothing of the run is written: no partition, so no lock and
            -- no journal.
            refusedOnTheBundle registry "staged fold onto an existing bundle file"
            doesDirectoryExist (stagedPartition rig registry t)
                `shouldReturn` False
            doesFileExist (journalPath (stagedPartition rig registry t))
                `shouldReturn` False
            -- The blueprint is not read: with it unreadable the refusal is
            -- still the bundle's.
            let blueprint = rigBlueprint rig
                hiddenBlueprint = blueprint <> ".hidden"
            renameFile blueprint hiddenBlueprint
            refusedOnTheBundle
                (registry <> "-blueprint")
                "staged fold onto an existing bundle file, the blueprint unreadable"
                `finally` renameFile hiddenBlueprint blueprint
            -- The partition is not touched: with a file where its directory
            -- and lock would go, the refusal is still the bundle's.
            let occupied = stagedPartition rig (registry <> "-lock") t
            createDirectoryIfMissing True (takeDirectory occupied)
            BS.writeFile occupied "not a partition"
            refusedOnTheBundle
                (registry <> "-lock")
                "staged fold onto an existing bundle file, the partition unusable"
            BS.readFile occupied `shouldReturn` "not a partition"

stagedStopRow :: Spec
stagedStopRow =
    it
        "a staged run stopped after staging names no body as landed and writes no bundle"
        $ withRig
        $ \rig -> do
            let bundlePath = rigDir rig </> "stopped.bundle"
                dir = rigDir rig </> "stopped"
                ws =
                    WriteSettings
                        ( ProviderSettings
                            "http://fixture.invalid"
                            (fromIntegral magic)
                            Nothing
                            Nothing
                        )
                        ( SignerExternal
                            (T.pack (bech32Address (walletAddr (rigWallet rig))))
                            bundlePath
                        )
                        Nothing
            stagedId <- newIORef ""
            stopped <-
                try $
                    withSession (envOf rig) dir "fold" ws $ \wc -> do
                        (confirmed, ()) <-
                            submitBuilt wc "fold" (const (expecting "funding")) $ \v -> do
                                held <- SessionIO.outputsAt v (walletAddr (rigWallet rig))
                                (i, o) <- case held of
                                    first : _ -> pure first
                                    [] -> fail "the rig wallet holds nothing to stage"
                                pure
                                    ( mkBasicTx
                                        ( mkBasicTxBody
                                            & inputsTxBodyL .~ Set.singleton i
                                            & outputsTxBodyL .~ StrictSeq.singleton o
                                        )
                                    , ()
                                    )
                        let identity = txIdHex (confirmedTx confirmed)
                            ref = TxIn (txIdTx (confirmedTx confirmed)) (TxIx 0)
                            (text, fields) =
                                allowanceRefusal
                                    100_000
                                    Outlay{outlayFee = 200_000, outlayBond = 0, outlayFoldBound = 0}
                                    50_000
                                    (Just ref)
                        writeIORef stagedId identity
                        failWithFields ClientRefusal text fields
            identity <- readIORef stagedId
            identity `shouldNotBe` ""
            case stopped of
                Right v -> expectationFailure ("the staged run did not stop: " <> show v)
                Left (CommandFailure c why fields) -> do
                    c `shouldBe` ClientRefusal
                    why `shouldNotSatisfy` isInfixOf (T.unpack identity)
                    why `shouldNotSatisfy` isInfixOf "stands confirmed"
                    lookup "submissions" fields `shouldBe` Nothing
                    [ k
                      | (k, value) <- fields
                      , k /= "staged"
                      , BS.isInfixOf
                            (TE.encodeUtf8 identity)
                            (BL.toStrict (Aeson.encode value))
                      ]
                        `shouldBe` []
                    fmap
                        (BS.isInfixOf (TE.encodeUtf8 identity) . BL.toStrict . Aeson.encode)
                        (lookup "staged" fields)
                        `shouldBe` Just True
            doesPathExist bundlePath `shouldReturn` False

signerFlagRefusalRows :: Spec
signerFlagRefusalRows =
    it "refuses the incomplete and mixed signer lines on the three writes" $ do
        let token = replicate 56 'a' <> "." <> replicate 64 'b'
            base write extra =
                [ "registry"
                , write
                ]
                    <> extra
                    <> [ "--blueprint"
                       , "blueprint.json"
                       , "--state-token"
                       , token
                       , "--koios-url"
                       , "https://koios.example"
                       , "--network-magic"
                       , "1"
                       ]
            address = bech32Address (walletAddr (walletFromSignKey 1 rigKeyOfTest))
            rigKeyOfTest = case parseSignKey (B16.encode (BS.replicate 32 0x77)) of
                Right k -> k
                Left _ -> error "a fixed 32-byte key always parses"
        forM_ ["fold", "reject", "reclaim"] $ \write -> do
            let line flags = parseCommand (base write flags)
            line ["--wallet-address", address]
                `shouldBe` Left
                    ( BadValue
                        "--bundle"
                        ( "is required with --wallet-address: the run's transactions are "
                            <> "written to the bundle for signing elsewhere"
                        )
                    )
            line
                [ "--wallet-skey"
                , "key.skey"
                , "--wallet-address"
                , address
                , "--bundle"
                , "run.bundle"
                ]
                `shouldBe` Left
                    ( BadValue
                        "--wallet-address"
                        "cannot be combined with --wallet-skey: a write takes exactly one signer"
                    )
            line ["--bundle", "run.bundle"]
                `shouldBe` Left
                    ( BadValue
                        "--bundle"
                        "is meaningless without --wallet-address: name the signer too"
                    )

-- ---------------------------------------------------------
-- The external signer's create (#641 slice 3)
-- ---------------------------------------------------------

{- | A staged create: the caller names their address and a bundle file, the
command builds create's whole chain as one bundle, in the order it builds it
(the state publication when no carrier is live, the boot, the request, the
witness publications and, pinned, the application publication), each later
transaction spending an earlier one's output, sends nothing and exits 19.
The bundle names no state token, carries no deadline, the pending identity
stays recorded, and every body equals the key-file create's over the same
chain.
-}
externalCreateRows :: Spec
externalCreateRows = describe "the external signer's create" $ do
    stagedCreatePublishingRow
    stagedCreateLiveCarrierRow
    existingBundleCreateRow
    createSignerLineRows

stagedCreatePublishingRow :: Spec
stagedCreatePublishingRow =
    it "stages a create with the state publication as one bundle" $
        withRig $ \rig -> withCountedSubmissions rig $ \env -> do
            assertStagedCreate rig env Nothing "bob-external-create" "registry"

stagedCreateLiveCarrierRow :: Spec
stagedCreateLiveCarrierRow =
    it "stages a create over a live state carrier as one bundle" $
        withRig $ \rig -> withCountedSubmissions rig $ \env -> do
            seed <- fundSeed rig
            first <-
                run
                    rig
                    "key-file create publishing the carrier"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            outcomeOf (runReceipt first) `shouldBe` Just "success"
            seed2 <- fundSeed2 rig
            assertStagedCreate
                rig
                env
                (Just seed2)
                "bob-external-create-2"
                "registry-2"

{- | Run a staged create of this seed into one registry directory, then the
key-file create of the same seed into another over the same chain, and hold
the staged run to everything the bundle must be.
-}
assertStagedCreate
    :: Rig -> Env -> Maybe String -> String -> String -> IO ()
assertStagedCreate rig env seed registry keyRegistry = do
    let bundlePath = rigDir rig </> (registry <> ".bundle")
        createLine =
            ["registry", "create"]
                <> maybe [] (\s -> ["--seed", s]) seed
                <> policyArgs
    staged <-
        runVia
            rig
            env
            registry
            "staged create"
            (createLine <> externalArgs rig bundlePath)
    runExit staged `shouldBe` ExitFailure 19
    outcomeOf (runReceipt staged) `shouldBe` Just "waiting-for-signatures"
    bytes <- BS.readFile bundlePath
    (bundle, bodies) <- checkedBundle bundlePath
    bundleCommand bundle `shouldBe` "create"
    bundleStateToken bundle `shouldBe` Nothing
    [bundleTxDeadline e | e <- toList (bundleTransactions bundle)]
        `shouldSatisfy` all isNothing
    assertChained bodies
    expected <- case valueAt "expected" (runReceipt staged) of
        Just v@(Aeson.Object _) -> pure v
        other -> fail ("no expected fields: " <> show other)
    t <- case textAt "stateToken" expected of
        Just tok -> pure (T.unpack tok)
        Nothing -> fail ("no expected state token: " <> show expected)
    assertWaitingJournal rig registry t (hashOfBytes bytes) bundle bodies
    assertStagedTrace staged bodies
    doesFileExist (pendingPath (stagedPartition rig registry t))
        `shouldReturn` True
    -- The pending identity, read back by the reader inspect uses for it: it
    -- decodes, records a seed whose state token is the one this bundle will
    -- mint, and names the bundle's network and the seed its boot spends.
    inspected <-
        runAt
            rig
            registry
            "inspect of the pending create"
            ( ["registry", "inspect"]
                <> tokenArgs t
                <> [ "--key"
                   , "any"
                   , "--wallet-address"
                   , bech32Address (walletAddr (rigWallet rig))
                   ]
            )
    outcomeOf (runReceipt inspected) `shouldBe` Just "partial"
    pendingIdentity <- case valueAt "incompleteCreate" (runReceipt inspected) of
        Just v@(Aeson.Object _) -> pure v
        other -> fail ("no pending identity read back: " <> show other)
    valueAt "networkMagic" pendingIdentity
        `shouldBe` Just (Aeson.toJSON (bundleNetworkMagic bundle))
    seedIn <- case textAt "seed" pendingIdentity of
        Just s -> either fail pure (parseOutRef s)
        Nothing ->
            fail ("the pending identity names no seed: " <> show pendingIdentity)
    case [b | b <- bodies, b ^. bodyTxL . mintTxBodyL /= mempty] of
        boot : _ ->
            Set.member seedIn (boot ^. bodyTxL . inputsTxBodyL) `shouldBe` True
        [] -> expectationFailure "no staged body mints the state token"
    keyRun <-
        runAt
            rig
            keyRegistry
            "key-file create after the staged one"
            createLine
    outcomeOf (runReceipt keyRun) `shouldBe` Just "success"
    tokenOf keyRun `shouldReturn` t
    assertExpectationOnly staged keyRun
    keyBodies <- keyFilePreparedBodies rig keyRegistry t "create"
    length keyBodies `shouldBe` length bodies
    map ((^. bodyTxL) . apartFromValidity) keyBodies
        `shouldBe` map ((^. bodyTxL) . apartFromValidity) bodies

-- | Each transaction after the first spends an output of an earlier one.
assertChained :: [ConwayTx] -> IO ()
assertChained bodies =
    forM_ (zip [1 ..] (drop 1 bodies)) $ \(n, body) -> do
        let earlier = Set.fromList (map txIdTx (take n bodies))
            spent =
                Set.map
                    (\(TxIn i _) -> i)
                    (body ^. bodyTxL . inputsTxBodyL)
        Set.null (Set.intersection earlier spent) `shouldBe` False

existingBundleCreateRow :: Spec
existingBundleCreateRow =
    it
        "refuses an existing bundle file on create before anything is read, its bytes untouched"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            let bundlePath = rigDir rig </> "taken-create.bundle"
                sentinel = "sentinel bytes"
                registry = "bob-external-create-taken"
                refusedOnTheBundle at label = do
                    refused <-
                        runAt
                            rig
                            at
                            label
                            ( ["registry", "create", "--seed", seed]
                                <> policyArgs
                                <> externalArgs rig bundlePath
                            )
                    runExit refused `shouldBe` ExitFailure 10
                    outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
                    fromMaybe "" (receiptReason refused)
                        `shouldSatisfy` T.isInfixOf (T.pack bundlePath)
                    BS.readFile bundlePath `shouldReturn` sentinel
            BS.writeFile bundlePath sentinel
            refusedOnTheBundle
                registry
                "staged create onto an existing bundle file"
            doesDirectoryExist (rigDir rig </> registry) `shouldReturn` False
            let blueprint = rigBlueprint rig
                hiddenBlueprint = blueprint <> ".hidden"
            renameFile blueprint hiddenBlueprint
            refusedOnTheBundle
                (registry <> "-blueprint")
                "staged create onto an existing bundle file, the blueprint unreadable"
                `finally` renameFile hiddenBlueprint blueprint

createSignerLineRows :: Spec
createSignerLineRows =
    it
        "reads the external signer on create and refuses an address without a bundle file"
        $ do
            let line extra =
                    parseCommand
                        ( ["registry", "create"]
                            <> extra
                            <> [ "--blueprint"
                               , "blueprint.json"
                               , "--koios-url"
                               , "https://koios.example"
                               , "--network-magic"
                               , "1"
                               ]
                        )
                address = bech32Address (walletAddr (walletFromSignKey 1 key))
                key = case parseSignKey (B16.encode (BS.replicate 32 0x77)) of
                    Right k -> k
                    Left _ -> error "a fixed 32-byte key always parses"
            line ["--wallet-address", address, "--bundle", "run.bundle"]
                `shouldSatisfy` isRight
            line ["--wallet-address", address]
                `shouldBe` Left
                    ( BadValue
                        "--bundle"
                        ( "is required with --wallet-address: the run's transactions are "
                            <> "written to the bundle for signing elsewhere"
                        )
                    )

-- ---------------------------------------------------------
-- The journal phase (#641 slice 4)
-- ---------------------------------------------------------

{- | The real staged run writes the journal, the real reconciliation reads
it and admission decides: a pending bundle stops the next write at 19, a
landed one settles, an expired one dies with every member, and a second
staged create from the same wallet is stopped by the first one's bundle.
Members are judged by their identity and the tip alone: a landed member
whose outputs were spent stays landed, a member whose inputs were consumed
elsewhere stays pending until its deadline and then dies, never rolled back.
-}
journalPhaseRows :: Spec
journalPhaseRows = describe "the journal phase" $ do
    pendingStopsRow
    landedSettlesRow
    landedOutputsSpentRow
    expiredDiesRow
    inputsConsumedElsewhereRow
    preparedBundleDiesWholeRow
    partialLandingRow
    interruptedDeathRow
    secondCreateStoppedRow
    explicitSeedCreateStoppedRow

{- | The windows of the registries these rows create. Both bounds are read
from the wall clock: a fold builds only while the request's processing
deadline is at least thirty seconds ahead of it, and a reject's upper
bound is at most two minutes ahead of it. A processing window of a hundred
seconds and a retract window of one second keep the staged fold buildable
right after the plant, and put the tip one slot past the retract window
still inside the reject's reach.
-}
journalWindows :: RegistryEconomics
journalWindows =
    RegistryEconomics
        { reProcessTime = 100_000
        , reRetractTime = 1_000
        , reTip = Coin 1_000_000
        }

-- | A staged fold over the rig, as 'stageFoldWith' leaves it.
data StagedFold = StagedFold
    { sfToken :: String
    , sfRequest :: TxIn
    , sfSubmitted :: Integer
    -- ^ the request's submission time, in milliseconds, which fixes its windows
    , sfBundlePath :: FilePath
    , sfHash :: Text
    , sfBundle :: Bundle
    , sfBodies :: [ConwayTx]
    }

{- | A registry with one certified planted request of this deposit, the
wallet shaped by the given action over the certified approvals, and a
staged fold of the request in this registry directory.
-}
stageFoldWith
    :: Integer
    -> (Map.Map PolicyID (Map.Map AssetName Integer) -> IO ())
    -> Rig
    -> String
    -> IO StagedFold
stageFoldWith deposit shape rig registry = do
    seed <- fundSeed rig
    create <-
        run
            rig
            "create"
            ( ["registry", "create", "--seed", seed]
                <> [ "--process-time"
                   , show (reProcessTime journalWindows)
                   , "--retract-time"
                   , show (reRetractTime journalWindows)
                   ]
                <> policyArgs
            )
    t <- tokenOf create
    (req, submitted) <-
        plantRequestDeposit
            rig
            t
            seed
            journalWindows
            (TE.encodeUtf8 (T.pack registry))
            deposit
    approvals <- certifyPlanted rig t seed journalWindows [req]
    shape approvals
    let bundlePath = rigDir rig </> (registry <> ".bundle")
    staged <-
        runAt
            rig
            registry
            "staged fold"
            ( ["registry", "fold", "--request", T.unpack (renderOutRef req)]
                <> tokenArgs t
                <> externalArgs rig bundlePath
            )
    runExit staged `shouldBe` ExitFailure 19
    h <- hashOfBytes <$> BS.readFile bundlePath
    (bundle, bodies) <- checkedBundle bundlePath
    pure
        StagedFold
            { sfToken = t
            , sfRequest = req
            , sfSubmitted = submitted
            , sfBundlePath = bundlePath
            , sfHash = h
            , sfBundle = bundle
            , sfBodies = bodies
            }

-- | An ordinary staged fold: a funded wallet, no preparation.
stageAFold :: Rig -> String -> IO StagedFold
stageAFold = stageFoldWith 1_000_000 (const (pure ()))

{- | A staged fold that must prepare its funding, with the setup of the
staged preparation row: a deposit beyond the wallet's largest ada-only
output and the wallet reshaped to hold the approvals beside its ada. The
bundle is two members, the preparation, which has no upper bound, then the
fold, which has one.
-}
stagePreparedFold :: Rig -> String -> IO StagedFold
stagePreparedFold rig registry = do
    sf <-
        stageFoldWith
            3_000_000_000
            (void . reshapeRehearsalWallet rig)
            rig
            registry
    map bodyDeadline (sfBodies sf)
        `shouldSatisfy` \case
            [Nothing, Just _] -> True
            _ -> False
    pure sf

-- | The upper bound of the staged member that has one.
boundedDeadline :: StagedFold -> IO Word64
boundedDeadline sf =
    case mapMaybe bundleTxDeadline (toList (bundleTransactions (sfBundle sf))) of
        d : _ -> pure d
        [] -> fail "the staged bundle carries no deadline"

{- | The next write of these rows, one that builds over the rig: the tip
moved one slot past the retract window the registry fixes for a request
submitted at this time ('journalWindows', which the registry was created
with and the request planted under), then a key-file reject, which takes
that request.
-}
rejectPast :: Rig -> String -> String -> Integer -> String -> IO Run
rejectPast rig registry t submitted label = do
    jumpToAfter
        rig
        ( submitted
            + reProcessTime journalWindows
            + reRetractTime journalWindows
        )
        0
    runAt rig registry label (["registry", "reject"] <> tokenArgs t)

-- | The same reject, at the rig's current tip.
rejectNow :: Rig -> String -> String -> String -> IO Run
rejectNow rig registry t label =
    runAt rig registry label (["registry", "reject"] <> tokenArgs t)

-- | Apply bodies to the rig's chain in order, as a node lands them.
landOnRig :: Rig -> [ConwayTx] -> IO ()
landOnRig rig =
    mapM_ $ \tx -> do
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

-- | Every output of these bodies, by its reference.
outputsOf :: [ConwayTx] -> [(TxIn, TxOut ConwayEra)]
outputsOf bodies =
    [ (TxIn (txIdTx tx) (TxIx ix), out)
    | tx <- bodies
    , (ix, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
    ]

{- | Every output of the landed members is spent by transactions no member
made, through the rig's own chain: a payment takes every output but the
registry's state, and a key-file fold of another certified request, run
from another directory, takes the state output as a later folder would.
-}
spendOutputsElsewhere
    :: Rig -> String -> String -> [ConwayTx] -> IO ()
spendOutputsElsewhere rig t seed bodies = do
    let spentByMembers =
            Set.unions [tx ^. bodyTxL . inputsTxBodyL | tx <- bodies]
        live =
            [ (i, out)
            | (i, out) <- outputsOf bodies
            , not (Set.member i spentByMembers)
            ]
        isState out = case extractCageDatum out of
            Just (StateDatum _) -> True
            _ -> False
    landOnRig
        rig
        [ signedTx
            (selfPayment (rigWallet rig) (filter (not . isState . snd) live))
        ]
    (other, _) <-
        plantRequest rig t seed journalWindows (TE.encodeUtf8 "carol-other")
    _ <- certifyPlanted rig t seed journalWindows [other]
    folded <-
        runAt
            rig
            "carol-elsewhere"
            "key-file fold of another request elsewhere"
            ( ["registry", "fold", "--request", T.unpack (renderOutRef other)]
                <> tokenArgs t
            )
    outcomeOf (runReceipt folded) `shouldBe` Just "success"

-- | Which of these outputs the rig's chain holds live.
liveAmong :: Rig -> [(TxIn, TxOut ConwayEra)] -> IO [TxIn]
liveAmong rig outs =
    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
        held <-
            concat
                <$> mapM
                    (SessionIO.outputsAt v . (^. addrTxOutL))
                    (nub (map snd outs))
        pure [i | (i, _) <- outs, i `elem` map fst held]

-- | The reconciled bundles a receipt reports, by hash.
reportedBundle :: Run -> Text -> Maybe Aeson.Value
reportedBundle r h = case valueAt "reconciled" (runReceipt r) >>= valueAt "bundles" of
    Just (Aeson.Array bs) ->
        listToMaybe [b | b <- toList bs, textAt "hash" b == Just h]
    _ -> Nothing

-- | The reconciled bundle a receipt reports, or the row fails.
requireBundle :: Run -> Text -> IO Aeson.Value
requireBundle r h =
    maybe
        (fail ("no reconciled bundle reported: " <> show (runReceipt r)))
        pure
        (reportedBundle r h)

-- | The identities a receipt's reconciliation rolled back.
rolledBackOf :: Run -> [Text]
rolledBackOf r = case valueAt "reconciled" (runReceipt r) >>= valueAt "rolledBack" of
    Just (Aeson.Array xs) -> [x | Aeson.String x <- toList xs]
    _ -> []

-- | The events the journal holds for one member, in order.
memberEvents :: [JournalEntry] -> ConwayTx -> [Text]
memberEvents entries body =
    [journalEvent e | e <- entries, journalTxId e == txIdHex body]

-- | The identities in a report's list field.
identitiesAt :: Aeson.Key -> Aeson.Value -> Maybe [Text]
identitiesAt k v = case valueAt k v of
    Just (Aeson.Array xs) -> Just [x | Aeson.String x <- toList xs]
    _ -> Nothing

pendingStopsRow :: Spec
pendingStopsRow =
    it
        "a pending bundle stops the next write before it builds anything, naming it"
        $ withRig
        $ \rig -> do
            let registry = "bob-pending"
            sf <- stageAFold rig registry
            let t = sfToken sf
                h = sfHash sf
                bodies = sfBodies sf
                dir = stagedPartition rig registry t
            journalBefore <- readJournal dir
            next <-
                withCountedSubmissions rig $ \env ->
                    runVia
                        rig
                        env
                        registry
                        "key-file fold while the bundle is pending"
                        ( [ "registry"
                          , "fold"
                          , "--request"
                          , T.unpack (renderOutRef (sfRequest sf))
                          ]
                            <> tokenArgs t
                        )
            runExit next `shouldBe` ExitFailure 19
            outcomeOf (runReceipt next) `shouldBe` Just "waiting-for-signatures"
            [() | Trace _ (How (Tx TxBuilt{})) <- runEvents next] `shouldBe` []
            readJournal dir `shouldReturn` journalBefore
            named <- case valueAt "pendingBundle" (runReceipt next) of
                Just v@(Aeson.Object _) -> pure v
                other -> fail ("no pending bundle named: " <> show other)
            textAt "hash" named `shouldBe` Just h
            textAt "saved" named
                `shouldBe` Just
                    (T.pack (bodiesDir dir </> ("bundle-" <> T.unpack h <> ".bundle")))
            awaited <- case valueAt "awaited" named of
                Just (Aeson.Array as) -> pure (toList as)
                other -> fail ("no awaited members: " <> show other)
            map (textAt "identity") awaited `shouldBe` map (Just . txIdHex) bodies
            map (valueAt "deadline") awaited
                `shouldBe` [ Aeson.toJSON <$> bundleTxDeadline e
                           | e <- toList (bundleTransactions (sfBundle sf))
                           ]
            fromMaybe "" (receiptReason next) `shouldSatisfy` T.isInfixOf h

landedSettlesRow :: Spec
landedSettlesRow =
    it
        "a bundle whose members all landed settles, and the next write builds"
        $ withRig
        $ \rig -> do
            let registry = "bob-landed"
            sf <- stageAFold rig registry
            let t = sfToken sf
                bodies = sfBodies sf
            landOnRig rig bodies
            seed <- fundSeed rig
            (second, submitted) <-
                plantRequest
                    rig
                    t
                    seed
                    journalWindows
                    (TE.encodeUtf8 "bob-landed-second")
            _ <- certifyPlanted rig t seed journalWindows [second]
            next <-
                rejectPast
                    rig
                    registry
                    t
                    submitted
                    "key-file reject after the bundle landed"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal (stagedPartition rig registry t)
            let landed = [e | e <- entries, journalEvent e == "landed"]
            map journalTxId landed `shouldBe` map txIdHex bodies
            all (isJust . journalChainPoint) landed `shouldBe` True
            fmap (textAt "state") (reportedBundle next (sfHash sf))
                `shouldBe` Just (Just "landed")

landedOutputsSpentRow :: Spec
landedOutputsSpentRow =
    it
        "a landed member whose outputs were spent before the next run is still judged landed, by its identity"
        $ withRig
        $ \rig -> do
            let registry = "bob-landed-spent"
            sf <- stageAFold rig registry
            let t = sfToken sf
                bodies = sfBodies sf
            landOnRig rig bodies
            seed <- fundSeed rig
            spendOutputsElsewhere rig t seed bodies
            liveAmong rig (outputsOf bodies) `shouldReturn` []
            (second, submitted) <-
                plantRequest
                    rig
                    t
                    seed
                    journalWindows
                    (TE.encodeUtf8 "bob-landed-spent-second")
            _ <- certifyPlanted rig t seed journalWindows [second]
            next <-
                rejectPast
                    rig
                    registry
                    t
                    submitted
                    "key-file reject after the landed outputs were spent"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal (stagedPartition rig registry t)
            map (memberEvents entries) bodies
                `shouldBe` [["waiting-for-signatures", "landed"] | _ <- bodies]
            [ e
              | e <- entries
              , journalEvent e == "landed"
              , isNothing (journalChainPoint e)
              ]
                `shouldBe` []
            bundleReport <- requireBundle next (sfHash sf)
            textAt "state" bundleReport `shouldBe` Just "landed"
            filter (`elem` map txIdHex bodies) (rolledBackOf next) `shouldBe` []

expiredDiesRow :: Spec
expiredDiesRow =
    it
        "a bundle past a member's deadline dies, every member not landed gets a dead line, and the next write builds"
        $ withRig
        $ \rig -> do
            let registry = "bob-expired"
            sf <- stageAFold rig registry
            let t = sfToken sf
                bodies = sfBodies sf
            next <-
                rejectPast
                    rig
                    registry
                    t
                    (sfSubmitted sf)
                    "key-file reject after the bundle expired"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal (stagedPartition rig registry t)
            let dead = [e | e <- entries, journalEvent e == "dead"]
            map journalTxId dead `shouldBe` map txIdHex bodies
            map journalDetail dead
                `shouldBe` [Just "expired, rebuild" | _ <- bodies]
            bundleReport <- requireBundle next (sfHash sf)
            textAt "state" bundleReport `shouldBe` Just "dead"
            valueAt "wentThrough" bundleReport
                `shouldBe` Just (Aeson.toJSON ([] :: [Text]))

inputsConsumedElsewhereRow :: Spec
inputsConsumedElsewhereRow =
    it
        "a member whose inputs were consumed elsewhere stays pending until its deadline, then dies, never landed and never rolled back"
        $ withRig
        $ \rig -> do
            let registry = "bob-raced"
                elsewhere = "carol-elsewhere"
            sf <- stageAFold rig registry
            let t = sfToken sf
                bodies = sfBodies sf
                dir = stagedPartition rig registry t
            -- The wallet spends the funding Bob's fold takes, and Carol folds
            -- the same request from another directory: every input of Bob's
            -- member is consumed elsewhere, by transactions that are not it.
            held <-
                SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    SessionIO.outputsAt v (walletAddr (rigWallet rig))
            let memberInputs =
                    Set.unions [tx ^. bodyTxL . inputsTxBodyL | tx <- bodies]
                funding = [u | u@(i, _) <- held, Set.member i memberInputs]
            funding `shouldSatisfy` (not . null)
            landOnRig rig [signedTx (selfPayment (rigWallet rig) funding)]
            raced <-
                runAt
                    rig
                    elsewhere
                    "key-file fold of the same request elsewhere"
                    ( [ "registry"
                      , "fold"
                      , "--request"
                      , T.unpack (renderOutRef (sfRequest sf))
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt raced) `shouldBe` Just "success"
            racedBodies <- keyFilePreparedBodies rig elsewhere t "fold"
            filter (`elem` map txIdTx bodies) (map txIdTx racedBodies)
                `shouldBe` []
            let consumed =
                    Set.unions [tx ^. bodyTxL . inputsTxBodyL | tx <- racedBodies]
            [ i
              | tx <- bodies
              , i <- Set.toList (tx ^. bodyTxL . inputsTxBodyL)
              , Set.member i consumed
              ]
                `shouldSatisfy` elem (sfRequest sf)
            seed <- fundSeed rig
            (second, submitted) <-
                plantRequest
                    rig
                    t
                    seed
                    journalWindows
                    (TE.encodeUtf8 "bob-raced-second")
            _ <- certifyPlanted rig t seed journalWindows [second]
            stopped <-
                rejectNow rig registry t "key-file reject before the deadline"
            runExit stopped `shouldBe` ExitFailure 19
            fmap (textAt "hash") (valueAt "pendingBundle" (runReceipt stopped))
                `shouldBe` Just (Just (sfHash sf))
            journalAtStop <- readJournal dir
            map (memberEvents journalAtStop) bodies
                `shouldBe` [["waiting-for-signatures"] | _ <- bodies]
            next <-
                rejectPast
                    rig
                    registry
                    t
                    submitted
                    "key-file reject past the deadline"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal dir
            map (memberEvents entries) bodies
                `shouldBe` [["waiting-for-signatures", "dead"] | _ <- bodies]
            [journalDetail e | e <- entries, journalEvent e == "dead"]
                `shouldBe` [Just "expired, rebuild" | _ <- bodies]
            bundleReport <- requireBundle next (sfHash sf)
            textAt "state" bundleReport `shouldBe` Just "dead"
            identitiesAt "wentThrough" bundleReport `shouldBe` Just []
            filter (`elem` map txIdHex bodies) (rolledBackOf next) `shouldBe` []

preparedBundleDiesWholeRow :: Spec
preparedBundleDiesWholeRow =
    it
        "a preparation and fold bundle is pending until the fold's bound, then dies whole: the unbounded preparation gets its dead line too"
        $ withRig
        $ \rig -> do
            let registry = "bob-prepared-expired"
            sf <- stagePreparedFold rig registry
            let t = sfToken sf
                bodies = sfBodies sf
                dir = stagedPartition rig registry t
            deadline <- boundedDeadline sf
            jumpChainTo (rigChain rig) (SlotNo (deadline - 1))
            stopped <-
                rejectNow rig registry t "key-file reject one slot before the bound"
            runExit stopped `shouldBe` ExitFailure 19
            awaitedIds <- case valueAt "pendingBundle" (runReceipt stopped) >>= valueAt "awaited" of
                Just (Aeson.Array as) -> pure (map (textAt "identity") (toList as))
                other -> fail ("no awaited members: " <> show other)
            awaitedIds `shouldBe` map (Just . txIdHex) bodies
            jumpChainTo (rigChain rig) (SlotNo deadline)
            atBound <-
                rejectNow rig registry t "key-file reject at the bound"
            runExit atBound `shouldNotBe` ExitFailure 19
            next <-
                rejectPast
                    rig
                    registry
                    t
                    (sfSubmitted sf)
                    "key-file reject past the request's windows"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal dir
            map (memberEvents entries) bodies
                `shouldBe` [["waiting-for-signatures", "dead"] | _ <- bodies]
            sort
                [ (journalTxId e, journalDetail e)
                | e <- entries
                , journalEvent e == "dead"
                ]
                `shouldBe` sort
                    ( zip
                        (map txIdHex bodies)
                        [Just "its bundle died", Just "expired, rebuild"]
                    )
            bundleReport <- requireBundle next (sfHash sf)
            textAt "state" bundleReport `shouldBe` Just "dead"
            textAt "reason" bundleReport `shouldBe` Just "expired, rebuild"
            identitiesAt "died" bundleReport `shouldBe` Just (map txIdHex bodies)
            identitiesAt "wentThrough" bundleReport `shouldBe` Just []

partialLandingRow :: Spec
partialLandingRow =
    it
        "a bundle whose preparation landed and whose fold expired is dead, naming the preparation as gone through"
        $ withRig
        $ \rig -> do
            let registry = "bob-partial"
            sf <- stagePreparedFold rig registry
            let t = sfToken sf
            (preparation, foldTx) <- case sfBodies sf of
                [p, f] -> pure (p, f)
                _ -> fail "the prepared bundle is not two members"
            landOnRig rig [preparation]
            next <-
                rejectPast
                    rig
                    registry
                    t
                    (sfSubmitted sf)
                    "key-file reject after the fold expired"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal (stagedPartition rig registry t)
            memberEvents entries preparation
                `shouldBe` ["waiting-for-signatures", "landed"]
            memberEvents entries foldTx
                `shouldBe` ["waiting-for-signatures", "dead"]
            [journalDetail e | e <- entries, journalEvent e == "dead"]
                `shouldBe` [Just "expired, rebuild"]
            bundleReport <- requireBundle next (sfHash sf)
            textAt "state" bundleReport `shouldBe` Just "dead"
            textAt "reason" bundleReport `shouldBe` Just "expired, rebuild"
            identitiesAt "wentThrough" bundleReport
                `shouldBe` Just [txIdHex preparation]
            identitiesAt "died" bundleReport `shouldBe` Just [txIdHex foldTx]

secondCreateStoppedRow :: Spec
secondCreateStoppedRow =
    it
        "a second staged create from the same wallet is stopped by the first one's pending bundle"
        $ withRig
        $ \rig -> withCountedSubmissions rig $ \env -> do
            let registry = "bob-create-twice"
                firstBundle = rigDir rig </> "first-create.bundle"
                secondBundle = rigDir rig </> "second-create.bundle"
                createLine = ["registry", "create"] <> policyArgs
            first <-
                runVia
                    rig
                    env
                    registry
                    "first staged create"
                    (createLine <> externalArgs rig firstBundle)
            runExit first `shouldBe` ExitFailure 19
            h <- hashOfBytes <$> BS.readFile firstBundle
            second <-
                runVia
                    rig
                    env
                    registry
                    "second staged create"
                    (createLine <> externalArgs rig secondBundle)
            runExit second `shouldBe` ExitFailure 19
            outcomeOf (runReceipt second) `shouldBe` Just "waiting-for-signatures"
            fmap (textAt "hash") (valueAt "pendingBundle" (runReceipt second))
                `shouldBe` Just (Just h)
            doesPathExist secondBundle `shouldReturn` False

{- | Cut the real journal right after its first dead line, as a run stopped
between two appends leaves it: a prefix of what the producer wrote, one
entry per line.
-}
cutAfterFirstDead :: FilePath -> IO ()
cutAfterFirstDead dir = do
    entries <- readJournal dir
    rows <- BC.lines <$> BS.readFile (journalPath dir)
    length rows `shouldBe` length entries
    case [i | (i, e) <- zip [1 ..] entries, journalEvent e == "dead"] of
        i : _ -> BS.writeFile (journalPath dir) (BC.unlines (take i rows))
        [] -> fail "the journal holds no dead line to cut after"

interruptedDeathRow :: Spec
interruptedDeathRow =
    it
        "a dead bundle whose run stopped after its first dead line is completed by the next run, every member not landed getting its dead line"
        $ withRig
        $ \rig -> do
            let registry = "bob-interrupted"
            sf <- stagePreparedFold rig registry
            let t = sfToken sf
                bodies = sfBodies sf
                dir = stagedPartition rig registry t
            deadline <- boundedDeadline sf
            jumpChainTo (rigChain rig) (SlotNo deadline)
            atBound <-
                rejectNow rig registry t "key-file reject at the bound"
            runExit atBound `shouldNotBe` ExitFailure 19
            cutAfterFirstDead dir
            cut <- readJournal dir
            [journalDetail e | e <- cut, journalEvent e == "dead"]
                `shouldBe` [Just "expired, rebuild"]
            next <-
                rejectPast
                    rig
                    registry
                    t
                    (sfSubmitted sf)
                    "key-file reject after the interrupted run"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal dir
            map (memberEvents entries) bodies
                `shouldBe` [["waiting-for-signatures", "dead"] | _ <- bodies]
            sort
                [ (journalTxId e, journalDetail e)
                | e <- entries
                , journalEvent e == "dead"
                ]
                `shouldBe` sort
                    ( zip
                        (map txIdHex bodies)
                        [Just "its bundle died", Just "expired, rebuild"]
                    )
            bundleReport <- requireBundle next (sfHash sf)
            textAt "state" bundleReport `shouldBe` Just "dead"
            identitiesAt "died" bundleReport `shouldBe` Just (map txIdHex bodies)

explicitSeedCreateStoppedRow :: Spec
explicitSeedCreateStoppedRow =
    it
        "a second create naming the same seed is stopped by the first one's pending bundle before the existing-state check, for either signer"
        $ withRig
        $ \rig -> withCountedSubmissions rig $ \env -> do
            seed <- fundSeed rig
            let registry = "bob-create-seed-twice"
                firstBundle = rigDir rig </> "first-seeded.bundle"
                secondBundle = rigDir rig </> "second-seeded.bundle"
                createLine =
                    ["registry", "create", "--seed", seed] <> policyArgs
            first <-
                runVia
                    rig
                    env
                    registry
                    "first staged create naming its seed"
                    (createLine <> externalArgs rig firstBundle)
            runExit first `shouldBe` ExitFailure 19
            firstBytes <- BS.readFile firstBundle
            (bundle, bodies) <- checkedBundle firstBundle
            let h = hashOfBytes firstBytes
            staged <-
                runVia
                    rig
                    env
                    registry
                    "second staged create naming the same seed"
                    (createLine <> externalArgs rig secondBundle)
            keyFile <-
                runVia
                    rig
                    env
                    registry
                    "key-file create naming the same seed"
                    createLine
            forM_ [staged, keyFile] $ \second -> do
                runExit second `shouldBe` ExitFailure 19
                outcomeOf (runReceipt second) `shouldBe` Just "waiting-for-signatures"
                named <- case valueAt "pendingBundle" (runReceipt second) of
                    Just v@(Aeson.Object _) -> pure v
                    other -> fail ("no pending bundle named: " <> show other)
                textAt "hash" named `shouldBe` Just h
                case textAt "saved" named of
                    Just saved -> do
                        T.unpack saved `shouldSatisfy` isInfixOf (T.unpack h)
                        BS.readFile (T.unpack saved) `shouldReturn` firstBytes
                    Nothing -> expectationFailure "no saved path named"
                awaited <- case valueAt "awaited" named of
                    Just (Aeson.Array as) -> pure (toList as)
                    other -> fail ("no awaited members: " <> show other)
                map (textAt "identity") awaited `shouldBe` map (Just . txIdHex) bodies
                map (valueAt "deadline") awaited
                    `shouldBe` [ Aeson.toJSON <$> bundleTxDeadline e
                               | e <- toList (bundleTransactions bundle)
                               ]
            doesPathExist secondBundle `shouldReturn` False

-- ---------------------------------------------------------
-- The vault signer (#641 slice 5)
-- ---------------------------------------------------------

{- | The vault mode over the rig: the command builds the bundle the
external mode writes for the vault's address, signs every member from
the vault, sends them in order through the submit core and journals the
outcome by the journal phase's rules. The vault is the rig wallet's own
key, sealed under a passphrase the run reads from a descriptor.
-}
vaultSignerRows :: Spec
vaultSignerRows = describe "the vault signer" $ do
    vaultSameBundleRow
    vaultAllLandedRow
    vaultRefusedRow
    vaultUncertainRow
    vaultRefusalsRow
    vaultVariableRow
    vaultVariableDescriptorRow
    vaultVariableRefusedRow
    walletVariableRow

{- | The vault fold on the development network with the passphrase in
@SINGULAR_PASSPHRASE@ and no descriptor: the bundle is the one the
external mode writes for the vault's address, as with a descriptor.
-}
vaultVariableRow :: Spec
vaultVariableRow =
    it
        "a vault fold on the development network signs from SINGULAR_PASSPHRASE, builds the bundle the external mode writes and names no secret"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-variable" 1_000_000 False
            let bundlePath = rigDir rig </> "alice-external.bundle"
                registry = "alice-variable-vault"
            external <-
                runAt
                    rig
                    "alice-external"
                    "external fold"
                    (foldLineOf t req <> externalArgs rig bundlePath)
            runExit external `shouldBe` ExitFailure 19
            externalBytes <- BS.readFile bundlePath
            vault <- rigVault rig "alice"
            signed <-
                withVariable (Just (BC.pack vaultPassphrase)) $
                    runAt
                        rig
                        registry
                        "vault fold, passphrase from the variable"
                        (foldLineOf t req <> ["--vault", vault])
            outcomeOf (runReceipt signed) `shouldBe` Just "success"
            (h, _, _) <- vaultBundleOf signed (stagedPartition rig registry t)
            h `shouldBe` hashOfBytes externalBytes
            assertNoVaultSecret rig (stagedPartition rig registry t) signed

-- | The descriptor wins over the variable: a wrong variable beside the right descriptor signs.
vaultVariableDescriptorRow :: Spec
vaultVariableDescriptorRow =
    it
        "--passphrase-fd wins over SINGULAR_PASSPHRASE: a wrong variable beside the right descriptor still signs"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-wins" 1_000_000 False
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            signed <-
                withVariable (Just "not the passphrase") $
                    runAt
                        rig
                        "alice-wins-vault"
                        "vault fold, the descriptor and a wrong variable"
                        (foldLineOf t req <> vaultArgs vault fd)
            outcomeOf (runReceipt signed) `shouldBe` Just "success"

{- | The same command with the variable set and a public network's magic:
refused naming the variable and the network, before the vault, the
blueprint or the chain is read. Mainnet is refused by the write parser
itself, before any passphrase is considered, so a write has two public
networks to try; the wallet commands try all three.
-}
vaultVariableRefusedRow :: Spec
vaultVariableRefusedRow =
    it
        "SINGULAR_PASSPHRASE is refused on a public network, naming it and the network, before the vault, the blueprint or the chain is read, and an empty one is refused on the development network"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-public" 1_000_000 False
            let registry = "alice-vault-public"
                dir = stagedPartition rig registry t
                absent = rigDir rig </> "absent.vault"
                blind =
                    (envOf rig)
                        { envReads = \_ _ -> fail "read"
                        , envWrites = \_ _ -> fail "read"
                        , envLoadRelease = \_ _ -> pure (Left "the blueprint cannot be loaded")
                        }
                refusedOn network variable = do
                    command <-
                        either (fail . show) pure $
                            parseCommand
                                ( onNetwork
                                    network
                                    ( commandLine
                                        rig
                                        registry
                                        (foldLineOf t req <> ["--vault", absent])
                                    )
                                )
                    (code, out, _) <-
                        withVariable (Just variable) $
                            captured (runCommand neutralApplication blind command)
                    receipt <-
                        maybe
                            (fail ("no receipt: " <> show out))
                            pure
                            (Aeson.decodeStrict out)
                    pure (code, receipt :: Aeson.Value, out)
            forM_ [("preprod", "1"), ("preview", "2")] $ \(name, public) -> do
                (code, receipt, out) <- refusedOn public (BC.pack vaultPassphrase)
                code `shouldBe` ExitFailure 10
                outcomeOf receipt `shouldBe` Just "client-refusal"
                let reason = fromMaybe "" (textAt "reason" receipt)
                forM_ ["SINGULAR_PASSPHRASE", name, "network magic " <> public] $
                    \word -> reason `shouldSatisfy` T.isInfixOf (T.pack word)
                forM_ ["absent.vault", "blueprint"] $ \word ->
                    reason `shouldNotSatisfy` T.isInfixOf word
                out `shouldNotSatisfy` BS.isInfixOf (BC.pack vaultPassphrase)
            (emptyCode, emptyReceipt, _) <- refusedOn "42" ""
            emptyCode `shouldBe` ExitFailure 10
            fromMaybe "" (textAt "reason" emptyReceipt)
                `shouldSatisfy` T.isInfixOf "SINGULAR_PASSPHRASE is set but empty"
            doesPathExist dir `shouldReturn` False

{- | The wallet commands with the variable: refused on every public network
before the vault is read or made, taken on the development one.
-}
walletVariableRow :: Spec
walletVariableRow =
    it
        "wallet create and wallet address take SINGULAR_PASSPHRASE on the development network and refuse it on mainnet, preprod and preview before they read or make a vault"
        $ withRig
        $ \rig -> do
            vault <- rigVault rig "alice"
            let absent = rigDir rig </> "absent.vault"
                fresh = rigDir rig </> "fresh.vault"
                arguments path network =
                    WalletArgs
                        { walletVaultPath = path
                        , walletNetworkMagic = network
                        , walletPassphraseFd = Nothing
                        }
                running command =
                    withVariable (Just (BC.pack vaultPassphrase)) $
                        captured (runCommand neutralApplication (envOf rig) command)
            forM_ publicNetworks $ \(name, public) -> do
                (code, out, err) <- running (WalletAddress (arguments absent public))
                code `shouldBe` ExitFailure 1
                out `shouldBe` ""
                forM_ [passphraseVariable, name, show public] $ \word ->
                    BC.unpack err `shouldSatisfy` isInfixOf word
                BC.unpack err `shouldNotSatisfy` isInfixOf "absent.vault"
                (createCode, createOut, _) <-
                    running (WalletCreate (arguments fresh public))
                createCode `shouldBe` ExitFailure 1
                createOut `shouldBe` ""
                doesPathExist fresh `shouldReturn` False
            (code, out, _) <-
                running (WalletAddress (arguments vault (fromIntegral magic)))
            code `shouldBe` ExitSuccess
            BC.unpack out `shouldSatisfy` isPrefixOf "addr_test1"
            (createCode, createOut, _) <-
                running (WalletCreate (arguments fresh (fromIntegral magic)))
            createCode `shouldBe` ExitSuccess
            BC.unpack createOut `shouldSatisfy` isPrefixOf "addr_test1"
            doesPathExist fresh `shouldReturn` True

-- | A command line with the network magic its value names.
onNetwork :: String -> [String] -> [String]
onNetwork network = \case
    "--network-magic" : _ : rest -> "--network-magic" : network : onNetwork network rest
    word : rest -> word : onNetwork network rest
    [] -> []

{- | Run an action with @SINGULAR_PASSPHRASE@ set to these bytes, or unset,
and the process's own value put back after.
-}
withVariable :: Maybe BS.ByteString -> IO a -> IO a
withVariable wanted act = do
    saved <- PosixEnv.getEnv name
    set wanted
    act `finally` set saved
  where
    name = BC.pack passphraseVariable
    set =
        maybe
            (PosixEnv.unsetEnv name)
            (\value -> PosixEnv.setEnv name value True)

-- | The passphrase the rows' vaults are sealed with.
vaultPassphrase :: String
vaultPassphrase = "a passphrase only the rig's vault knows"

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

{- | The rig's environment with the submission of this ordinal answered by
the given function of the rig's own submission: the node refusing it, or
the node applying it and its answer lost.
-}
answeringAt
    :: Rig
    -> Int
    -> (IO Cage.SubmitResult -> IO Cage.SubmitResult)
    -> IO Env
answeringAt rig ordinal answer = do
    counted <- newIORef (0 :: Int)
    let caps = capabilities rig
        caps' =
            caps
                { capSubmit = \tx -> do
                    modifyIORef' counted (+ 1)
                    n <- readIORef counted
                    if n == ordinal
                        then answer (capSubmit caps tx)
                        else capSubmit caps tx
                }
    pure
        (envOf rig){envReads = \_ k -> k caps', envWrites = \_ k -> k caps'}

-- | The bundle a vault run names in its receipt, read from beside the journal.
vaultBundleOf :: Run -> FilePath -> IO (Text, Bundle, [ConwayTx])
vaultBundleOf r dir = do
    h <-
        maybe
            (fail ("no bundle hash in the receipt: " <> show (runReceipt r)))
            pure
            (valueAt "bundle" (runReceipt r) >>= textAt "hash")
    (bundle, bodies) <-
        checkedBundle
            (bodiesDir dir </> ("bundle-" <> T.unpack h <> ".bundle"))
    pure (h, bundle, bodies)

-- | A registry with one certified request, to fold from the vault.
vaultRegistry
    :: Rig -> String -> Integer -> Bool -> IO (String, TxIn, Integer)
vaultRegistry rig key deposit reshape = do
    seed <- fundSeed rig
    create <-
        run
            rig
            "create"
            (["registry", "create", "--seed", seed] <> policyArgs)
    t <- tokenOf create
    (req, submitted) <-
        plantRequestDeposit
            rig
            t
            seed
            economics
            (TE.encodeUtf8 (T.pack key))
            deposit
    approvals <- certifyPlanted rig t seed economics [req]
    when reshape (void (reshapeRehearsalWallet rig approvals))
    pure (t, req, submitted)

-- | The fold line of a request.
foldLineOf :: String -> TxIn -> [String]
foldLineOf t req =
    ["registry", "fold", "--request", T.unpack (renderOutRef req)]
        <> tokenArgs t

vaultSameBundleRow :: Spec
vaultSameBundleRow =
    it
        "a vault fold builds the bundle bytes the external mode writes for the vault's address"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-same" 1_000_000 False
            let bundlePath = rigDir rig </> "alice-external.bundle"
            external <-
                runAt
                    rig
                    "alice-external"
                    "external fold"
                    (foldLineOf t req <> externalArgs rig bundlePath)
            runExit external `shouldBe` ExitFailure 19
            externalBytes <- BS.readFile bundlePath
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            let registry = "alice-vault"
            signed <-
                runAt
                    rig
                    registry
                    "vault fold"
                    (foldLineOf t req <> vaultArgs vault fd)
            outcomeOf (runReceipt signed) `shouldBe` Just "success"
            (h, _, _) <- vaultBundleOf signed (stagedPartition rig registry t)
            h `shouldBe` hashOfBytes externalBytes
            BS.readFile
                ( bodiesDir (stagedPartition rig registry t)
                    </> ("bundle-" <> T.unpack h <> ".bundle")
                )
                `shouldReturn` externalBytes

vaultAllLandedRow :: Spec
vaultAllLandedRow =
    it
        "a vault fold signs every member, sends them in order through the submit core and, all landed, journals each landed and states the command's fields as fact, with no secret anywhere"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-prep" 3_000_000_000 True
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            let registry = "alice-vault-prep"
                dir = stagedPartition rig registry t
            signed <-
                runAt
                    rig
                    registry
                    "vault fold with a preparation"
                    (foldLineOf t req <> vaultArgs vault fd)
            runExit signed `shouldBe` ExitSuccess
            outcomeOf (runReceipt signed) `shouldBe` Just "success"
            (_, _, bodies) <- vaultBundleOf signed dir
            length bodies `shouldBe` 2
            sent <- case valueAt "submissions" (runReceipt signed) of
                Just (Aeson.Array xs) -> pure (toList xs)
                other -> fail ("no submissions: " <> show other)
            map (textAt "identity") sent `shouldBe` map (Just . txIdHex) bodies
            map (textAt "how") sent `shouldBe` [Just "sent" | _ <- bodies]
            entries <- readJournal dir
            map (memberEvents entries) bodies
                `shouldBe` [["waiting-for-signatures", "landed"] | _ <- bodies]
            [ e
              | e <- entries
              , journalEvent e == "landed"
              , isNothing (journalChainPoint e)
              ]
                `shouldBe` []
            valueAt "expected" (runReceipt signed) `shouldBe` Nothing
            textAt "fold" (runReceipt signed)
                `shouldBe` fmap txIdHex (listToMaybe (reverse bodies))
            assertNoVaultSecret rig dir signed

vaultRefusedRow :: Spec
vaultRefusedRow =
    it
        "a node refusal of a member journals the bundle dead and ends as a ledger refusal naming the members that went through"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-refused" 3_000_000_000 True
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            env <-
                answeringAt
                    rig
                    2
                    (const (pure (Cage.SubmitRefused "the fold's inputs are gone")))
            let registry = "alice-vault-refused"
                dir = stagedPartition rig registry t
            signed <-
                runVia
                    rig
                    env
                    registry
                    "vault fold refused by the node"
                    (foldLineOf t req <> vaultArgs vault fd)
            runExit signed `shouldBe` ExitFailure 11
            outcomeOf (runReceipt signed) `shouldBe` Just "ledger-refusal"
            (_, _, bodies) <- vaultBundleOf signed dir
            (preparation, foldTx) <- case bodies of
                [p, f'] -> pure (p, f')
                _ -> fail "the refused bundle is not two members"
            entries <- readJournal dir
            memberEvents entries preparation
                `shouldBe` ["waiting-for-signatures", "landed"]
            memberEvents entries foldTx
                `shouldBe` ["waiting-for-signatures", "dead"]
            [journalDetail e | e <- entries, journalEvent e == "dead"]
                `shouldSatisfy` all (maybe False (T.isPrefixOf "refused by the node"))
            identitiesAt "wentThrough" (runReceipt signed)
                `shouldBe` Just [txIdHex preparation]
            fromMaybe "" (receiptReason signed)
                `shouldSatisfy` T.isInfixOf "the fold's inputs are gone"
            assertNoVaultSecret rig dir signed
            reference <- keyFileFoldOf 3_000_000_000 True
            assertExpectationOnly signed reference

vaultUncertainRow :: Spec
vaultUncertainRow =
    it
        "an uncertain answer ends the vault run partial, and the next run settles the bundle by identity"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    ( ["registry", "create", "--seed", seed]
                        <> [ "--process-time"
                           , show (reProcessTime journalWindows)
                           , "--retract-time"
                           , show (reRetractTime journalWindows)
                           ]
                        <> policyArgs
                    )
            t <- tokenOf create
            (req, _) <-
                plantRequest
                    rig
                    t
                    seed
                    journalWindows
                    (TE.encodeUtf8 "alice-uncertain")
            _ <- certifyPlanted rig t seed journalWindows [req]
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            env <-
                answeringAt
                    rig
                    1
                    ( \applied -> applied >> pure (Cage.SubmitFailed "the node did not answer")
                    )
            let registry = "alice-vault-uncertain"
                dir = stagedPartition rig registry t
            signed <-
                runVia
                    rig
                    env
                    registry
                    "vault fold whose answer was lost"
                    (foldLineOf t req <> vaultArgs vault fd)
            runExit signed `shouldBe` ExitFailure 15
            outcomeOf (runReceipt signed) `shouldBe` Just "partial"
            reference <- keyFileFoldOf 1_000_000 False
            assertExpectationOnly signed reference
            (h, _, bodies) <- vaultBundleOf signed dir
            (second, submitted) <-
                plantRequest
                    rig
                    t
                    seed
                    journalWindows
                    (TE.encodeUtf8 "alice-uncertain-second")
            _ <- certifyPlanted rig t seed journalWindows [second]
            next <-
                rejectPast
                    rig
                    registry
                    t
                    submitted
                    "key-file reject after the lost answer"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal dir
            map (memberEvents entries) bodies
                `shouldBe` [["waiting-for-signatures", "landed"] | _ <- bodies]
            fmap (textAt "state") (reportedBundle next h)
                `shouldBe` Just (Just "landed")

vaultRefusalsRow :: Spec
vaultRefusalsRow =
    it
        "a wrong passphrase, an unreadable vault or a descriptor without a vault is refused naming it, before the blueprint or anything else is read or written"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-wrong" 1_000_000 False
            vault <- rigVault rig "alice"
            let registry = "alice-vault-wrong"
                dir = stagedPartition rig registry t
                -- nothing can be read: no chain, and no blueprint either, so
                -- a refusal that came after either would name that instead
                blind =
                    (envOf rig)
                        { envReads = \_ _ -> fail "read"
                        , envWrites = \_ _ -> fail "read"
                        , envLoadRelease = \_ _ -> pure (Left "the blueprint cannot be loaded")
                        }
            wrong <- passphraseDescriptor rig "wrong" "not the passphrase"
            refused <-
                runVia
                    rig
                    blind
                    registry
                    "vault fold, wrong passphrase"
                    (foldLineOf t req <> vaultArgs vault wrong)
            fd <- passphraseDescriptor rig "missing" vaultPassphrase
            missing <-
                runVia
                    rig
                    blind
                    registry
                    "vault fold, no vault"
                    (foldLineOf t req <> vaultArgs (rigDir rig </> "absent.vault") fd)
            forM_ [(refused, vault), (missing, rigDir rig </> "absent.vault")] $ \(r, named) -> do
                runExit r `shouldBe` ExitFailure 10
                outcomeOf (runReceipt r) `shouldBe` Just "client-refusal"
                fromMaybe "" (receiptReason r)
                    `shouldSatisfy` T.isInfixOf (T.pack named)
                fromMaybe "" (receiptReason r)
                    `shouldNotSatisfy` T.isInfixOf "blueprint"
            parseCommand
                ( commandLine
                    rig
                    registry
                    (foldLineOf t req <> ["--passphrase-fd", "3"])
                )
                `shouldSatisfy` \case
                    Left (BadValue "--passphrase-fd" _) -> True
                    _ -> False
            doesPathExist dir `shouldReturn` False

{- | The receipt of a key-file fold over the same setup, on a rig of its own:
the command's own fields, which a vault run that did not land states only
under expected.
-}
keyFileFoldOf :: Integer -> Bool -> IO Run
keyFileFoldOf deposit reshape = withRig $ \rig -> do
    (t, req, _) <- vaultRegistry rig "alice-reference" deposit reshape
    r <- run rig "key-file fold for reference" (foldLineOf t req)
    outcomeOf (runReceipt r) `shouldBe` Just "success"
    pure r

-- | The roots a run narrates as seen on chain.
rootsSeen :: Run -> [(Text, Text)]
rootsSeen r = [(b, a) | Trace _ (What (RootSeen b a)) <- runEvents r]

{- | A staged body was never on chain, so its readback names no root as
seen: an external fold, reject and reclaim narrate none, and a vault fold
narrates the root once its bundle has landed, as a key-file fold does.
-}
stagedNarrationRows :: Spec
stagedNarrationRows = describe "staged narration" $ do
    it
        "an external fold narrates no root as seen; a landed vault fold narrates it"
        $ withRig
        $ \rig -> do
            (t, req, _) <- vaultRegistry rig "alice-narration" 1_000_000 False
            let bundlePath = rigDir rig </> "alice-narration.bundle"
            staged <-
                runAt
                    rig
                    "alice-narration-external"
                    "external fold"
                    (foldLineOf t req <> externalArgs rig bundlePath)
            runExit staged `shouldBe` ExitFailure 19
            rootsSeen staged `shouldBe` []
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            signed <-
                runAt
                    rig
                    "alice-narration-vault"
                    "vault fold"
                    (foldLineOf t req <> vaultArgs vault fd)
            outcomeOf (runReceipt signed) `shouldBe` Just "success"
            length (rootsSeen signed) `shouldBe` 1
    it "an external reject narrates no root as seen" $
        withRig $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    ( [ "registry"
                      , "create"
                      , "--seed"
                      , seed
                      , "--process-time"
                      , "1"
                      , "--retract-time"
                      , "1"
                      ]
                        <> policyArgs
                    )
            t <- tokenOf create
            let windows =
                    RegistryEconomics
                        { reProcessTime = 1
                        , reRetractTime = 1
                        , reTip = Coin 1_000_000
                        }
            (_, submitted) <-
                plantRequest
                    rig
                    t
                    seed
                    windows
                    (TE.encodeUtf8 "alice-narration-reject")
            jumpToAfter
                rig
                (submitted + reProcessTime windows + reRetractTime windows)
                2
            staged <-
                runAt
                    rig
                    "alice-narration-reject"
                    "external reject"
                    ( ["registry", "reject"]
                        <> tokenArgs t
                        <> externalArgs rig (rigDir rig </> "alice-reject.bundle")
                    )
            runExit staged `shouldBe` ExitFailure 19
            rootsSeen staged `shouldBe` []
    it "an external reclaim narrates no root as seen" $
        withRig $ \rig -> do
            seed <- fundSeed rig
            create <-
                run
                    rig
                    "create"
                    (["registry", "create", "--seed", seed] <> policyArgs)
            t <- tokenOf create
            (req, submitted) <-
                plantRequest
                    rig
                    t
                    seed
                    economics
                    (TE.encodeUtf8 "alice-narration-reclaim")
            jumpToAfter rig (submitted + reProcessTime economics) 0
            staged <-
                runAt
                    rig
                    "alice-narration-reclaim"
                    "external reclaim"
                    ( ["registry", "reclaim", "--request", T.unpack (renderOutRef req)]
                        <> tokenArgs t
                        <> externalArgs rig (rigDir rig </> "alice-reclaim.bundle")
                    )
            runExit staged `shouldBe` ExitFailure 19
            rootsSeen staged `shouldBe` []

-- | A registry with one certified request under these windows, to fold from the vault.
vaultRegistryWith
    :: Rig
    -> RegistryEconomics
    -> String
    -> Integer
    -> Bool
    -> IO (String, TxIn, Integer)
vaultRegistryWith rig windows key deposit reshape = do
    seed <- fundSeed rig
    create <-
        run
            rig
            "create"
            ( ["registry", "create", "--seed", seed]
                <> [ "--process-time"
                   , show (reProcessTime windows)
                   , "--retract-time"
                   , show (reRetractTime windows)
                   ]
                <> policyArgs
            )
    t <- tokenOf create
    (req, submitted) <-
        plantRequestDeposit
            rig
            t
            seed
            windows
            (TE.encodeUtf8 (T.pack key))
            deposit
    approvals <- certifyPlanted rig t seed windows [req]
    when reshape (void (reshapeRehearsalWallet rig approvals))
    pure (t, req, submitted)

-- | The submissions a receipt names.
submissionsIn :: Run -> IO [Aeson.Value]
submissionsIn r = case valueAt "submissions" (runReceipt r) of
    Just (Aeson.Array xs) -> pure (toList xs)
    other -> fail ("no submissions: " <> show other)

{- | Once the submit core has answered, the transactions it sent are paid
for: a journal that cannot be appended afterwards keeps the core's outcome
and sends in the receipt, names the failure apart, and the next run
settles the bundle by identity. The journal is made read-only by the rig's
own submission of the last member, after the node has applied it or
refused it.
-}
vaultBookkeepingRows :: Spec
vaultBookkeepingRows = describe "the vault signer's bookkeeping" $ do
    it
        "a journal that cannot be appended after every member landed keeps the core's sends and a partial outcome, and the next run settles the bundle"
        $ withRig
        $ \rig -> do
            (t, req, _) <-
                vaultRegistryWith
                    rig
                    journalWindows
                    "alice-unjournalled"
                    3_000_000_000
                    True
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            let registry = "alice-vault-unjournalled"
                dir = stagedPartition rig registry t
            env <-
                answeringAt rig 2 $ \applied ->
                    applied <* setFileMode (journalPath dir) ownerReadMode
            signed <-
                runVia
                    rig
                    env
                    registry
                    "vault fold whose journal cannot be appended"
                    (foldLineOf t req <> vaultArgs vault fd)
            setFileMode
                (journalPath dir)
                (ownerReadMode `unionFileModes` ownerWriteMode)
            runExit signed `shouldBe` ExitFailure 15
            outcomeOf (runReceipt signed) `shouldBe` Just "partial"
            (h, _, bodies) <- vaultBundleOf signed dir
            sent <- submissionsIn signed
            map (textAt "identity") sent `shouldBe` map (Just . txIdHex) bodies
            map (textAt "how") sent `shouldBe` [Just "sent" | _ <- bodies]
            valueAt "bookkeeping" (runReceipt signed) `shouldSatisfy` isJust
            reference <- keyFileFoldOf 3_000_000_000 True
            assertExpectationOnly signed reference
            seed <- fundSeed rig
            (second, submitted) <-
                plantRequest
                    rig
                    t
                    seed
                    journalWindows
                    (TE.encodeUtf8 "alice-unjournalled-second")
            _ <- certifyPlanted rig t seed journalWindows [second]
            next <-
                rejectPast
                    rig
                    registry
                    t
                    submitted
                    "key-file reject after the unjournalled landing"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal dir
            map (memberEvents entries) bodies
                `shouldBe` [["waiting-for-signatures", "landed"] | _ <- bodies]
            fmap (textAt "state") (reportedBundle next h)
                `shouldBe` Just (Just "landed")
    it
        "a journal that cannot be appended after the node refused a member keeps the ledger refusal, its answer and what went through, and the next run settles the bundle"
        $ withRig
        $ \rig -> do
            (t, req, submitted) <-
                vaultRegistryWith
                    rig
                    journalWindows
                    "alice-refused-unjournalled"
                    3_000_000_000
                    True
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            let registry = "alice-vault-refused-unjournalled"
                dir = stagedPartition rig registry t
            env <-
                answeringAt rig 2 $ \_ -> do
                    setFileMode (journalPath dir) ownerReadMode
                    pure (Cage.SubmitRefused "the fold's inputs are gone")
            signed <-
                runVia
                    rig
                    env
                    registry
                    "vault fold refused, its journal not appendable"
                    (foldLineOf t req <> vaultArgs vault fd)
            setFileMode
                (journalPath dir)
                (ownerReadMode `unionFileModes` ownerWriteMode)
            runExit signed `shouldBe` ExitFailure 11
            outcomeOf (runReceipt signed) `shouldBe` Just "ledger-refusal"
            fromMaybe "" (receiptReason signed)
                `shouldSatisfy` T.isInfixOf "the fold's inputs are gone"
            (h, _, bodies) <- vaultBundleOf signed dir
            (preparation, foldTx) <- case bodies of
                [p, f'] -> pure (p, f')
                _ -> fail "the refused bundle is not two members"
            sent <- submissionsIn signed
            map (textAt "how") sent
                `shouldBe` [Just "sent", Just "submission-refused"]
            identitiesAt "wentThrough" (runReceipt signed)
                `shouldBe` Just [txIdHex preparation]
            valueAt "bookkeeping" (runReceipt signed) `shouldSatisfy` isJust
            reference <- keyFileFoldOf 3_000_000_000 True
            assertExpectationOnly signed reference
            next <-
                rejectPast
                    rig
                    registry
                    t
                    submitted
                    "key-file reject after the unjournalled refusal"
            outcomeOf (runReceipt next) `shouldBe` Just "success"
            entries <- readJournal dir
            memberEvents entries preparation
                `shouldBe` ["waiting-for-signatures", "landed"]
            memberEvents entries foldTx
                `shouldBe` ["waiting-for-signatures", "dead"]
            bundleReport <- requireBundle next h
            textAt "state" bundleReport `shouldBe` Just "dead"
            identitiesAt "wentThrough" bundleReport
                `shouldBe` Just [txIdHex preparation]

{- | After the sends, the journal itself cannot be read back: neither the
bookkeeping nor the session's own closing read may replace the outcome the
submit core gave; each failure is named beside it.
-}
vaultUnreadJournalRows :: Spec
vaultUnreadJournalRows = describe "the vault signer's journal unread" $ do
    it
        "a journal that cannot be read after every member landed keeps the core's sends and a partial outcome, naming both failures"
        $ withRig
        $ \rig -> do
            (t, req, _) <-
                vaultRegistryWith rig journalWindows "alice-unread" 3_000_000_000 True
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            let registry = "alice-vault-unread"
                dir = stagedPartition rig registry t
            env <-
                answeringAt rig 2 $ \applied ->
                    applied <* setFileMode (journalPath dir) nullFileMode
            signed <-
                runVia
                    rig
                    env
                    registry
                    "vault fold whose journal cannot be read"
                    (foldLineOf t req <> vaultArgs vault fd)
            setFileMode
                (journalPath dir)
                (ownerReadMode `unionFileModes` ownerWriteMode)
            runExit signed `shouldBe` ExitFailure 15
            outcomeOf (runReceipt signed) `shouldBe` Just "partial"
            (_, _, bodies) <- vaultBundleOf signed dir
            sent <- submissionsIn signed
            map (textAt "identity") sent `shouldBe` map (Just . txIdHex) bodies
            map (textAt "how") sent `shouldBe` [Just "sent" | _ <- bodies]
            valueAt "bookkeeping" (runReceipt signed) `shouldSatisfy` isJust
            valueAt "journalUnread" (runReceipt signed) `shouldSatisfy` isJust
            reference <- keyFileFoldOf 3_000_000_000 True
            assertExpectationOnly signed reference
    it
        "a half-written last journal line after the node refused a member keeps the ledger refusal, its answer and what went through, naming both failures"
        $ withRig
        $ \rig -> do
            (t, req, _) <-
                vaultRegistryWith rig journalWindows "alice-half" 3_000_000_000 True
            vault <- rigVault rig "alice"
            fd <- passphraseDescriptor rig "alice" vaultPassphrase
            let registry = "alice-vault-half"
                dir = stagedPartition rig registry t
            env <-
                answeringAt rig 2 $ \_ -> do
                    BS.appendFile (journalPath dir) "{\"journalCommand\":\"fold\""
                    pure (Cage.SubmitRefused "the fold's inputs are gone")
            signed <-
                runVia
                    rig
                    env
                    registry
                    "vault fold refused over a half-written journal"
                    (foldLineOf t req <> vaultArgs vault fd)
            runExit signed `shouldBe` ExitFailure 11
            outcomeOf (runReceipt signed) `shouldBe` Just "ledger-refusal"
            fromMaybe "" (receiptReason signed)
                `shouldSatisfy` T.isInfixOf "the fold's inputs are gone"
            (_, _, bodies) <- vaultBundleOf signed dir
            preparation <- case bodies of
                [p, _] -> pure p
                _ -> fail "the refused bundle is not two members"
            sent <- submissionsIn signed
            map (textAt "how") sent
                `shouldBe` [Just "sent", Just "submission-refused"]
            identitiesAt "wentThrough" (runReceipt signed)
                `shouldBe` Just [txIdHex preparation]
            valueAt "bookkeeping" (runReceipt signed) `shouldSatisfy` isJust
            valueAt "journalUnread" (runReceipt signed) `shouldSatisfy` isJust
            reference <- keyFileFoldOf 3_000_000_000 True
            assertExpectationOnly signed reference

-- ---------------------------------------------------------
-- --save-state-token: the registry's name kept by create
-- ---------------------------------------------------------

{- | A create can keep the new registry's name in the settings file, so the
commands after it name no registry on their line. The name is whatever the
create's own receipt prints, read from the run and never typed; a create that
does not succeed leaves the file as it was; the receipt is the one the same
create prints without the switch.
-}
saveStateTokenRows :: Spec
saveStateTokenRows = describe "Create keeps the registry's name in the settings file" $ do
    savedAfterSuccessRows
    savedFileRows
    notSavedRows
    failedWriteRows
    sameReceiptRows
    receiptDecidesRows
    laterCommandRows
    chosenFileRows
    rootRefusalRows

saveSwitch :: String
saveSwitch = "--save-state-token"

-- | A create of the first seed, with the switch and this settings file.
saveLine :: String -> FilePath -> [String]
saveLine seed file =
    ["registry", "create", "--seed", seed]
        <> policyArgs
        <> [saveSwitch, "--config", file]

{- | One command line as the packaged command parses it and the dispatch runs
it, with the standard error it wrote.
-}
runSaving
    :: Rig -> [String] -> IO (ExitCode, Aeson.Value, BS.ByteString)
runSaving rig args = do
    command <-
        either
            (fail . renderCLIError)
            pure
            (parseCommand (commandLine rig "registry" args))
    saving rig command

saving :: Rig -> Command -> IO (ExitCode, Aeson.Value, BS.ByteString)
saving rig command = do
    (code, out, err) <-
        captured (runCommand neutralApplication (envOf rig) command)
    receipt <-
        maybe
            (fail ("no receipt: " <> show out))
            pure
            (Aeson.decodeStrict out)
    pure (code, receipt, err)

-- | The state token a receipt prints.
receiptToken :: Aeson.Value -> IO Text
receiptToken receipt =
    maybe
        (fail ("no state token in " <> show receipt))
        pure
        (textAt "stateToken" receipt)

-- | The keys of a settings file, which must be one JSON object.
settingsKeys :: FilePath -> IO Aeson.Object
settingsKeys file =
    BS.readFile file >>= \bytes -> case Aeson.eitherDecodeStrict bytes of
        Right (Aeson.Object o) -> pure o
        Right other -> fail (file <> " is not one object: " <> show other)
        Left why -> fail (file <> " is not JSON: " <> why)

-- | The permission bits of a file.
permissionsOf :: FilePath -> IO Word
permissionsOf file =
    (\status -> fromIntegral (fileMode status .&. 0o777))
        <$> getFileStatus file

-- | A directory the test may lock, and unlock again whatever happens.
lockedDirectory :: FilePath -> IO a -> IO a
lockedDirectory dir =
    (setFileMode dir 0o555 >>) . (`finally` setFileMode dir 0o755)

savedAfterSuccessRows :: Spec
savedAfterSuccessRows =
    describe "after a create that succeeds" $ do
        it "makes the settings file holding the receipt's state token alone" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                (code, receipt, err) <- runSaving rig (saveLine seed file)
                code `shouldBe` ExitSuccess
                outcomeOf receipt `shouldBe` Just "success"
                token <- receiptToken receipt
                keys <- settingsKeys file
                KeyMap.toList keys `shouldBe` [("state-token", Aeson.String token)]
                -- one line says which file now holds the name
                BC.unpack err `shouldSatisfy` isInfixOf file
        it
            "writes the token the same create printed, not a typed one, for two registries"
            $ withRig
            $ \rig -> do
                first <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                (_, firstReceipt, _) <- runSaving rig (saveLine first file)
                firstToken <- receiptToken firstReceipt
                keys <- settingsKeys file
                KeyMap.lookup "state-token" keys
                    `shouldBe` Just (Aeson.String firstToken)
                second <- fundSeed2 rig
                (secondCode, secondReceipt, _) <-
                    runSaving rig (saveLine second file)
                secondCode `shouldBe` ExitSuccess
                secondToken <- receiptToken secondReceipt
                secondToken `shouldSatisfy` (/= firstToken)
                keysAfter <- settingsKeys file
                KeyMap.lookup "state-token" keysAfter
                    `shouldBe` Just (Aeson.String secondToken)

savedFileRows :: Spec
savedFileRows =
    describe "the file it rewrites" $ do
        it
            "keeps every other key with its value and its kind, and replaces a name"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                BC.writeFile file . BC.pack $
                    "{\"koios-url\": \"http://koios.example\","
                        <> " \"network-magic\": 42,"
                        <> " \"state-token\": \"stale.token\","
                        <> " \"trace\": \"what\"}"
                (_, receipt, _) <- runSaving rig (saveLine seed file)
                token <- receiptToken receipt
                keys <- settingsKeys file
                KeyMap.toList keys
                    `shouldMatchList` [ ("koios-url", Aeson.String "http://koios.example")
                                      , ("network-magic", Aeson.Number 42)
                                      , ("state-token", Aeson.String token)
                                      , ("trace", Aeson.String "what")
                                      ]
        it "is one indented JSON object, ended by a line" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                BC.writeFile file "{\"trace\":\"what\",\"vault\":\"alice.vault\"}"
                _ <- runSaving rig (saveLine seed file)
                bytes <- BS.readFile file
                length (BC.lines bytes) `shouldSatisfy` (> 2)
                BC.last bytes `shouldBe` '\n'
                bytes `shouldSatisfy` BS.isPrefixOf "{"
        it "keeps the permissions of the file it replaces" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                BC.writeFile file "{\"trace\":\"what\"}"
                setFileMode file 0o640
                _ <- runSaving rig (saveLine seed file)
                permissionsOf file `shouldReturn` 0o640
        it "leaves nothing but the settings file in its folder" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let dir = rigDir rig </> "settings-home"
                    file = dir </> "settings.json"
                createDirectory dir
                BC.writeFile file "{\"trace\":\"what\"}"
                _ <- runSaving rig (saveLine seed file)
                listDirectory dir `shouldReturn` ["settings.json"]

notSavedRows :: Spec
notSavedRows =
    describe "a create that does not succeed" $ do
        it "leaves the file byte for byte as it was, whatever the outcome" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                    untouched = "{\"state-token\": \"stale.token\", \"trace\": \"what\"}"
                BC.writeFile file untouched
                refused <-
                    runAtTxIn
                        (Left (Cage.BackendReadFailure "the exchange died"))
                        rig
                        "create-read-failed"
                        ( ["registry", "create", "--seed", seed]
                            <> policyArgs
                            <> [saveSwitch, "--config", file]
                        )
                outcomeOf (runReceipt refused) `shouldBe` Just "partial"
                runExit refused `shouldSatisfy` (/= ExitSuccess)
                BS.readFile file `shouldReturn` untouched
        it "makes no file where there was none" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                refused <-
                    runAtTxIn
                        (Left (Cage.BackendReadFailure "the exchange died"))
                        rig
                        "create-read-failed"
                        ( ["registry", "create", "--seed", seed]
                            <> policyArgs
                            <> [saveSwitch, "--config", file]
                        )
                runExit refused `shouldSatisfy` (/= ExitSuccess)
                doesPathExist file `shouldReturn` False
        it "leaves the file alone when the seed is not the wallet's" $
            withRig $ \rig -> do
                let file = rigDir rig </> "settings.json"
                    untouched = "{\"trace\": \"what\"}"
                BC.writeFile file untouched
                (code, receipt, _) <-
                    runSaving
                        rig
                        ( [ "registry"
                          , "create"
                          , "--seed"
                          , T.unpack (renderOutRef (fundOutput 9))
                          ]
                            <> policyArgs
                            <> [saveSwitch, "--config", file]
                        )
                code `shouldSatisfy` (/= ExitSuccess)
                outcomeOf receipt `shouldNotBe` Just "success"
                BS.readFile file `shouldReturn` untouched
        it "never touches the file when the switch is not given" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                    untouched = "{\"state-token\": \"stale.token\"}"
                BC.writeFile file untouched
                (code, receipt, _) <-
                    runSaving
                        rig
                        ( ["registry", "create", "--seed", seed]
                            <> policyArgs
                            <> ["--config", file]
                        )
                code `shouldBe` ExitSuccess
                outcomeOf receipt `shouldBe` Just "success"
                BS.readFile file `shouldReturn` untouched

failedWriteRows :: Spec
failedWriteRows =
    describe "a write that fails after the registry exists" $ do
        it
            "says so on standard error, keeps the receipt and the exit status, and keeps the old file"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                let dir = rigDir rig </> "settings-home"
                    file = dir </> "settings.json"
                    untouched = "{\"trace\": \"what\"}"
                createDirectory dir
                BC.writeFile file untouched
                (code, receipt, err) <-
                    lockedDirectory dir (runSaving rig (saveLine seed file))
                -- the registry exists: the status and the receipt are the create's
                code `shouldBe` ExitSuccess
                outcomeOf receipt `shouldBe` Just "success"
                -- one sentence names the file, the cause, and where the name is
                let said = T.toLower (TE.decodeUtf8 err)
                said `shouldSatisfy` T.isInfixOf (T.pack file)
                said `shouldSatisfy` T.isInfixOf "permission denied"
                said `shouldSatisfy` T.isInfixOf "receipt"
                -- the old file stays whole and nothing else is left behind
                BS.readFile file `shouldReturn` untouched
                listDirectory dir `shouldReturn` ["settings.json"]
        it "does not replace a read-only file, and says why" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                    untouched = "{\"trace\": \"what\"}"
                BC.writeFile file untouched
                setFileMode file 0o444
                (code, receipt, err) <- runSaving rig (saveLine seed file)
                code `shouldBe` ExitSuccess
                outcomeOf receipt `shouldBe` Just "success"
                let said = T.toLower (TE.decodeUtf8 err)
                said `shouldSatisfy` T.isInfixOf (T.pack file)
                said `shouldSatisfy` T.isInfixOf "read-only"
                BS.readFile file `shouldReturn` untouched
        it "does not rewrite a file that is not one JSON object" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                    untouched = "[1, 2, 3]"
                BC.writeFile file untouched
                (code, _, err) <- runSaving rig (saveLine seed file)
                code `shouldBe` ExitSuccess
                TE.decodeUtf8 err `shouldSatisfy` T.isInfixOf (T.pack file)
                BS.readFile file `shouldReturn` untouched

sameReceiptRows :: Spec
sameReceiptRows =
    describe "the receipt" $
        it "is the one the same create prints without the switch" $ do
            plain <- creating []
            again <- creating []
            -- the control: two creates without the switch agree, so a
            -- difference below is the switch's
            again `shouldBe` plain
            saved <- creating [saveSwitch]
            saved `shouldBe` plain
  where
    creating extra = withRig $ \rig -> do
        seed <- fundSeed rig
        (code, receipt, _) <-
            runSaving
                rig
                ( ["registry", "create", "--seed", seed]
                    <> policyArgs
                    <> extra
                    <> ["--config" | not (null extra)]
                    <> [rigDir rig </> "settings.json" | not (null extra)]
                )
        pure (code, normalised rig receipt)
    normalised rig =
        T.replace (T.pack (rigDir rig)) "RIG"
            . TE.decodeUtf8
            . BL.toStrict
            . Aeson.encode

laterCommandRows :: Spec
laterCommandRows =
    describe "the commands after it" $
        it "name the registry from the file alone" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "settings.json"
                (_, receipt, _) <- runSaving rig (saveLine seed file)
                token <- receiptToken receipt
                named <- case parseStateToken token of
                    Right asset -> pure asset
                    Left why -> fail (T.unpack why)
                sources <-
                    loadSources
                        (singularProgram singularVersion)
                        [("SINGULAR_CONFIG", file)]
                        (Raw [] [])
                case parseInvocationFrom
                    sources
                    [ "registry"
                    , "inspect"
                    , "--key"
                    , "alice"
                    , "--blueprint"
                    , rigBlueprint rig
                    , "--koios-url"
                    , "http://fixture.invalid"
                    , "--network-magic"
                    , show magic
                    ] of
                    Right (Inspect inspecting, _) ->
                        inspectAccess inspecting
                            `shouldBe` RegistryAccess{accessToken = named}
                    other -> expectationFailure ("not an inspect: " <> show other)

chosenFileRows :: Spec
chosenFileRows =
    describe "the settings file in use" $ do
        it "is the one SINGULAR_CONFIG names" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                let file = rigDir rig </> "from-variable.json"
                command <-
                    either
                        (fail . renderCLIError)
                        pure
                        ( parseCommandWithEnvironment
                            [("SINGULAR_CONFIG", file)]
                            ( commandLine
                                rig
                                "registry"
                                (["registry", "create", "--seed", seed] <> policyArgs <> [saveSwitch])
                            )
                        )
                (code, receipt, _) <- saving rig command
                code `shouldBe` ExitSuccess
                token <- receiptToken receipt
                keys <- settingsKeys file
                KeyMap.lookup "state-token" keys `shouldBe` Just (Aeson.String token)
        it
            "is singular.json in the working directory when none is named, made holding the one key"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                let dir = rigDir rig </> "working"
                createDirectory dir
                original <- getCurrentDirectory
                (_, receipt, _) <-
                    ( setCurrentDirectory dir
                        >> runSaving
                            rig
                            (["registry", "create", "--seed", seed] <> policyArgs <> [saveSwitch])
                    )
                        `finally` setCurrentDirectory original
                token <- receiptToken receipt
                keys <- settingsKeys (dir </> "singular.json")
                KeyMap.toList keys `shouldBe` [("state-token", Aeson.String token)]

{- | The root refuses a switch whose file cannot be written before it opens a
vault or asks a provider: the vault is absent and the provider unreachable, so
reaching either would be a different failure than the one-line refusal.
-}
rootRefusalRows :: Spec
rootRefusalRows =
    describe "the packaged command" $ do
        it
            "refuses a read-only settings file with status 2, before opening anything"
            $ withSystemTempDirectory "save-root"
            $ \dir -> do
                let file = dir </> "settings.json"
                BC.writeFile file "{\"trace\": \"what\"}"
                setFileMode file 0o444
                (code, out, err) <-
                    captured
                        ( runSingular
                            neutralApplication
                            (Just stderr)
                            []
                            (rootLine dir ["--config", file, saveSwitch])
                        )
                code `shouldBe` ExitFailure 2
                out `shouldBe` ""
                let said = TE.decodeUtf8 err
                said `shouldSatisfy` T.isInfixOf (T.pack saveSwitch)
                said `shouldSatisfy` T.isInfixOf (T.pack file)
                said `shouldSatisfy` T.isInfixOf "read-only"
                said `shouldSatisfy` (not . T.isInfixOf "absent.vault")
                doesPathExist (dir </> "state") `shouldReturn` False
        it "refuses a missing settings file in a folder it cannot write" $
            withSystemTempDirectory "save-root" $ \dir -> do
                original <- getCurrentDirectory
                (code, out, err) <-
                    lockedDirectory dir $
                        ( setCurrentDirectory dir
                            >> captured
                                ( runSingular
                                    neutralApplication
                                    (Just stderr)
                                    []
                                    (rootLine dir [saveSwitch])
                                )
                        )
                            `finally` setCurrentDirectory original
                code `shouldBe` ExitFailure 2
                out `shouldBe` ""
                let said = TE.decodeUtf8 err
                said `shouldSatisfy` T.isInfixOf (T.pack saveSwitch)
                said `shouldSatisfy` T.isInfixOf "singular.json"
                said `shouldSatisfy` T.isInfixOf "folder"
        it "runs the same create to its own failure without the switch" $
            withSystemTempDirectory "save-root" $ \dir -> do
                let file = dir </> "settings.json"
                BC.writeFile file "{\"trace\": \"what\"}"
                setFileMode file 0o444
                -- the control: nothing refuses it at the root, so the create
                -- goes on and stops on the vault that is not there
                (code, _, _) <-
                    captured
                        ( runSingular
                            neutralApplication
                            (Just stderr)
                            []
                            (rootLine dir ["--config", file])
                        )
                code `shouldNotBe` ExitFailure 2
  where
    rootLine dir extra =
        [ "registry"
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
        ]
            <> extra

{- | What is written is decided by the receipt the create returned, not by the
route to it: only a success that names a registry writes, and the receipt
comes back as it went in. The receipts here are made up for the purpose, since
no real create returns a failure that carries a token; the real ones are held
by the rows above.
-}
receiptDecidesRows :: Spec
receiptDecidesRows =
    describe "the receipt decides what is written" $ do
        it "writes the token of a success and returns the receipt as it was" $
            withSystemTempDirectory "keep" $ \dir -> do
                let file = dir </> "settings.json"
                    made =
                        Aeson.object
                            [ "outcome" .= outcomeName Success
                            , "stateToken" .= ("p.n" :: Text)
                            , "root" .= ("00" :: Text)
                            ]
                (returned, _, err) <-
                    captured (keepStateToken "singular" (Just file) (pure made))
                returned `shouldBe` made
                keys <- settingsKeys file
                KeyMap.toList keys `shouldBe` [("state-token", Aeson.String "p.n")]
                BC.unpack err `shouldSatisfy` isInfixOf file
        it
            "writes nothing for any other outcome, whatever the receipt carries"
            $ withSystemTempDirectory "keep"
            $ \dir ->
                forM_ [c | c <- [minBound .. maxBound], c /= Success] $ \other -> do
                    let file = dir </> (T.unpack (outcomeName other) <> ".json")
                        made =
                            Aeson.object
                                ["outcome" .= outcomeName other, "stateToken" .= ("p.n" :: Text)]
                    (returned, _, err) <-
                        captured (keepStateToken "singular" (Just file) (pure made))
                    returned `shouldBe` made
                    doesPathExist file `shouldReturn` False
                    err `shouldBe` ""
        it
            "writes nothing for a preview, whose success names a registry that does not exist"
            $ withSystemTempDirectory "keep"
            $ \dir -> do
                let file = dir </> "settings.json"
                    made =
                        Aeson.object
                            [ "outcome" .= outcomeName Success
                            , "preview" .= True
                            , "stateToken" .= ("p.n" :: Text)
                            ]
                (returned, _, _) <-
                    captured (keepStateToken "singular" (Just file) (pure made))
                returned `shouldBe` made
                doesPathExist file `shouldReturn` False
        it
            "says so, and writes nothing, for a success that names no state token"
            $ withSystemTempDirectory "keep"
            $ \dir -> do
                let file = dir </> "settings.json"
                    made =
                        Aeson.object
                            ["outcome" .= outcomeName Success, "stateToken" .= Aeson.Null]
                (returned, _, err) <-
                    captured (keepStateToken "singular" (Just file) (pure made))
                returned `shouldBe` made
                doesPathExist file `shouldReturn` False
                TE.decodeUtf8 err `shouldSatisfy` T.isInfixOf "no state token"
        it "writes nothing when no file was asked for" $
            withSystemTempDirectory "keep" $ \dir -> do
                let made =
                        Aeson.object
                            ["outcome" .= outcomeName Success, "stateToken" .= ("p.n" :: Text)]
                (returned, _, err) <-
                    captured (keepStateToken "singular" Nothing (pure made))
                returned `shouldBe` made
                err `shouldBe` ""
                listDirectory dir `shouldReturn` []
        it "leaves a thrown failure to the caller and writes nothing" $
            withSystemTempDirectory "keep" $ \dir -> do
                let file = dir </> "settings.json"
                result <-
                    try
                        ( captured
                            ( keepStateToken
                                "singular"
                                (Just file)
                                (throwIO (ErrorCall "the create failed"))
                            )
                        )
                case result of
                    Left (ErrorCall why) -> why `shouldBe` "the create failed"
                    Right _ -> expectationFailure "the failure was swallowed"
                doesPathExist file `shouldReturn` False

-- ---------------------------------------------------------
-- A registry has an address (#728)
-- ---------------------------------------------------------

{- | The receipts and the refusals of a registry that has an address, run
through the same dispatch as every command above. The address and the
fingerprint a receipt gives are judged by 'Singular.Registry.AddressOracle', which
reads the word with the @bech32@ package and hashes with @crypton@ directly,
never by the code that wrote them.
-}
registryAddressRows :: Spec
registryAddressRows =
    describe "a registry has an address" $ do
        createReceiptAddressRows
        pageAndInspectAddressRows
        addressGivenRows
        foreignContractsRows

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

createReceiptAddressRows :: Spec
createReceiptAddressRows = describe "the create receipt" $ do
    it
        "carries the address and the fingerprint beside the state token, and says them once on standard error"
        $ withRig
        $ \rig -> do
            seed <- fundSeed rig
            (code, receipt, err) <-
                runSaving rig (["registry", "create", "--seed", seed] <> policyArgs)
            code `shouldBe` ExitSuccess
            token <- receiptToken receipt
            shouldNameRegistry
                (T.unpack token)
                (textAt "registry" receipt)
                (textAt "fingerprint" receipt)
            address <- field "registry" receipt
            fingerprint <- field "fingerprint" receipt
            let told = filter (isInfixOf address) (lines (BC.unpack err))
            length told `shouldBe` 1
            forM_ [T.unpack token, fingerprint] $ \word ->
                told `shouldSatisfy` all (isInfixOf word)
            -- the describe line is the one it always was, on the state token
            fromMaybe "" (textAt "describeCommand" receipt)
                `shouldSatisfy` T.isInfixOf ("--state-token " <> token)
    it "carries them in the preview" $ withRig $ \rig -> do
        seed <- fundSeed rig
        previewed <-
            run
                rig
                "preview"
                ( [ "registry"
                  , "create"
                  , "--preview"
                  , "--seed"
                  , seed
                  , "--network-time"
                  , rigDir rig
                  ]
                    <> policyArgs
                )
        outcomeOf (runReceipt previewed) `shouldBe` Just "success"
        token <- tokenOf previewed
        shouldNameRegistry
            token
            (textAt "registry" (runReceipt previewed))
            (textAt "fingerprint" (runReceipt previewed))
    it "has a fingerprint and no address on a network without a prefix" $
        withRig $ \rig -> do
            seed <- fundSeed rig
            command <-
                either
                    (fail . renderCLIError)
                    pure
                    ( parseCommand
                        ( onNetwork
                            "3"
                            ( commandLine
                                rig
                                "registry"
                                (["registry", "create", "--seed", seed] <> policyArgs)
                            )
                        )
                    )
            (code, receipt, err) <- saving rig command
            code `shouldBe` ExitSuccess
            token <- receiptToken receipt
            valueAt "registry" receipt `shouldBe` Just Aeson.Null
            body <-
                maybe
                    (fail "the state token is not hex")
                    pure
                    (bodyOfToken (T.unpack token))
            fmap T.unpack (textAt "fingerprint" receipt)
                `shouldBe` fingerprintOf body
            BC.unpack err `shouldSatisfy` isInfixOf (T.unpack token)
            -- and the line says why there is no address
            BC.unpack err `shouldSatisfy` isInfixOf "prefix"
  where
    field key receipt =
        maybe
            (fail ("no " <> show key <> " in " <> show receipt))
            (pure . T.unpack)
            (textAt key receipt)

pageAndInspectAddressRows :: Spec
pageAndInspectAddressRows =
    describe "the describe and the inspect receipts"
        $ it
            "name the address, the state token and the fingerprint of the registry, and keep what they carried"
        $ withRig
        $ \rig -> do
            runs <- lifecycle rig
            let named label = case [r | r <- runs, runLabel r == label] of
                    r : _ -> pure r
                    [] -> fail ("no run labelled " <> label)
            create <- named "create"
            inspected <-
                named "inspect from an empty directory with the state token"
            page <- named "describe by state token"
            token <- tokenOf create
            -- describe: the registry object keeps its keys, and holds the two new ones
            let registryObject = valueAt "registry" (runReceipt page)
            shouldNameRegistry
                token
                (registryObject >>= textAt "address")
                (registryObject >>= textAt "fingerprint")
            (registryObject >>= textAt "stateToken")
                `shouldBe` Just (T.pack token)
            forM_ ["stateOutput", "stateScript", "applicationScript"] $ \key ->
                (registryObject >>= valueAt key) `shouldSatisfy` isJust
            forM_ ["release", "rules", "state", "provenance"] $ \key ->
                valueAt key (runReceipt page) `shouldSatisfy` isJust
            -- inspect: the registry it read, by address, state token and fingerprint
            outcomeOf (runReceipt inspected) `shouldBe` Just "success"
            shouldNameRegistry
                token
                (textAt "registry" (runReceipt inspected))
                (textAt "fingerprint" (runReceipt inspected))
            textAt "stateToken" (runReceipt inspected)
                `shouldBe` Just (T.pack token)

-- | The state token a registry the rig made has, and its address on the rig's network.
madeRegistry :: Rig -> IO (String, String)
madeRegistry rig = do
    seed <- fundSeed rig
    made <-
        run
            rig
            "create"
            (["registry", "create", "--seed", seed] <> policyArgs)
    token <- tokenOf made
    address <-
        maybe
            (fail ("no address for " <> token))
            pure
            (addressOf (fromIntegral magic) token)
    pure (token, address)

-- | A registry's flag: the address, in place of the state token.
registryArgs :: String -> [String]
registryArgs address = ["--registry", address]

-- | A command line without its network magic.
withoutMagic :: [String] -> [String]
withoutMagic = \case
    "--network-magic" : _ : rest -> withoutMagic rest
    word : rest -> word : withoutMagic rest
    [] -> []

addressGivenRows :: Spec
addressGivenRows = describe "a registry given by its address" $ do
    it
        "is read as the registry of its state token, with no state token and no network magic on the line"
        $ withRig
        $ \rig -> do
            (token, address) <- madeRegistry rig
            byToken <-
                runAt
                    rig
                    "empty-actor"
                    "inspect by the state token"
                    (["registry", "inspect", "--key", "alice-1"] <> tokenArgs token)
            command <-
                either
                    (fail . renderCLIError)
                    pure
                    ( parseCommand
                        ( withoutMagic
                            ( commandLine
                                rig
                                "empty-actor"
                                (["registry", "inspect", "--key", "alice-1"] <> registryArgs address)
                            )
                        )
                    )
            (code, byAddress, _) <- saving rig command
            outcomeOf (runReceipt byToken) `shouldBe` Just "success"
            code `shouldBe` runExit byToken
            outcomeOf byAddress `shouldBe` outcomeOf (runReceipt byToken)
            forM_ ["root", "leaf", "stateToken"] $ \key ->
                valueAt key byAddress `shouldBe` valueAt key (runReceipt byToken)
    it
        "is refused, naming both, beside a network magic of another network"
        $ withRig
        $ \rig -> do
            (token, address) <- madeRegistry rig
            let line =
                    commandLine
                        rig
                        "empty-actor"
                        (["registry", "inspect", "--key", "alice-1"] <> registryArgs address)
            -- the control: the line as it stands, whose magic is the address's, is read
            either (const False) (const True) (parseCommand line) `shouldBe` True
            case parseCommand (onNetwork "1" line) of
                Left err -> do
                    renderCLIError err `shouldSatisfy` isInfixOf "singular_devnet"
                    renderCLIError err `shouldSatisfy` isInfixOf "--network-magic"
                Right _ ->
                    expectationFailure
                        "a network magic that names another network was accepted"
            -- and beside a state token of another registry
            other <- maybe (fail "no other token") pure (otherToken token)
            case parseCommand (line <> tokenArgs other) of
                Left err -> do
                    renderCLIError err `shouldSatisfy` isInfixOf token
                    renderCLIError err `shouldSatisfy` isInfixOf other
                Right _ ->
                    expectationFailure
                        "a state token that names another token was accepted"
  where
    -- the same policy, another name
    otherToken token = case break (== '.') token of
        (policy, '.' : name) -> Just (policy <> "." <> map flipped name)
        _ -> Nothing
    flipped c = if c == '0' then '1' else '0'

{- | The state-contract hash of each published release's blueprint, read from
the blueprint's own @state.state@ validator with @jq@, with the releases that
carry it, oldest first. The archives are the ones the releases published; the
hashes were not computed by the program.
-}
releasedContracts :: [(String, [String])]
releasedContracts =
    [
        ( "64d1afbfe585b496a325ecacf2600210ff773368010bbab96e5cf1ce"
        , ["v0.3.0"]
        )
    ,
        ( "3f62792585903776fc69059588783c7ca67ee9d24886c8722ebf8b2a"
        , ["v0.4.0"]
        )
    ,
        ( "8ac9562f5fb6be9b9b913ae2ad2cc1d9e038f7f7039256f1ac9f7a62"
        , ["v0.4.1", "v0.5.0", "v0.6.0", "v0.6.1"]
        )
    ,
        ( "492c5595b83b5deba587db17ea819cf769a930f379cd3ecbde56d2a5"
        , ["v0.7.0"]
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

-- | A state token of this policy: the name does not matter, only the policy is judged.
tokenOfPolicy :: String -> String
tokenOfPolicy policy = policy <> "." <> replicate 64 '1'

{- | A registry made by other contracts than the blueprint the command was
given is refused by name, before any chain read: the provider here fails every
read, so a refusal that came after one would be that failure.
-}
foreignContractsRows :: Spec
foreignContractsRows = describe "a registry made by other contracts" $ do
    let commands =
            [ ("inspect", ["registry", "inspect", "--key", "alice-1"])
            , ("describe", ["registry", "describe"])
            , ("fold", ["registry", "fold"])
            , ("reject", ["registry", "reject"])
            ,
                ( "reclaim"
                , ["registry", "reclaim", "--request", replicate 64 'a' <> "#0"]
                )
            ]
        -- a provider that is read at all fails, and counts the reads: a refusal
        -- that came after one would leave the count above zero
        blind rig = do
            readsMade <- newIORef (0 :: Int)
            pure
                ( (envOf rig)
                    { envReads = \_ _ -> modifyIORef' readsMade (+ 1) >> fail "read"
                    , envWrites = \_ _ -> modifyIORef' readsMade (+ 1) >> fail "read"
                    }
                , readsMade
                )
        refusedBy rig name line policy = do
            (env, readsMade) <- blind rig
            refused <-
                runVia
                    rig
                    env
                    "registry"
                    ("foreign " <> name)
                    (line <> tokenArgs (tokenOfPolicy policy))
            readIORef readsMade `shouldReturn` 0
            pure refused
        -- the page names the release it was run from, beside the blueprint
        versioned rig =
            writeFile
                (takeDirectory (rigBlueprint rig) </> "version.txt")
                "0.10.1\n"
    forM_ commands $ \(name, line) -> do
        it
            ( "refuses "
                <> name
                <> " naming the releases of the contracts and where to get the newest"
            )
            $ withRig
            $ \rig -> do
                versioned rig
                forM_ releasedContracts $ \(policy, tags) -> do
                    refused <- refusedBy rig name line policy
                    let reason = T.unpack (fromMaybe "" (receiptReason refused))
                        newest = last tags
                        url tag = "https://github.com/lambdasistemi/singular/releases/tag/" <> tag
                    reason `shouldSatisfy` isInfixOf "state-token-foreign-release"
                    outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
                    runExit refused `shouldBe` ExitFailure 10
                    forM_ tags $ \tag -> reason `shouldSatisfy` isInfixOf tag
                    reason `shouldSatisfy` isInfixOf (url newest)
                    forM_ (init tags) $ \tag ->
                        reason `shouldNotSatisfy` isInfixOf (url tag)
        it ("refuses " <> name <> " as made by contracts of no known release") $
            withRig $ \rig -> do
                versioned rig
                refused <- refusedBy rig name line (replicate 56 '1')
                let reason = T.unpack (fromMaybe "" (receiptReason refused))
                reason `shouldSatisfy` isInfixOf "state-token-foreign-release"
                reason `shouldSatisfy` isInfixOf "no known release"
                runExit refused `shouldBe` ExitFailure 10
    it
        "reads a registry of the contracts it was given as before, over the same fixture"
        $ withRig
        $ \rig -> do
            (token, _) <- madeRegistry rig
            read' <-
                runAt
                    rig
                    "empty-actor"
                    "inspect of its own registry"
                    (["registry", "inspect", "--key", "alice-1"] <> tokenArgs token)
            outcomeOf (runReceipt read') `shouldBe` Just "success"
            fromMaybe "" (receiptReason read')
                `shouldNotSatisfy` T.isInfixOf "state-token-foreign-release"

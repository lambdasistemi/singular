{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.WalletShortfallSpec
Description : #526 — a write asks the wallet for what it costs
License     : Apache-2.0

As Alice with 20 ada in two outputs, preview and write go
through when the wallet covers what the operation costs;
when it does not, both refuse before signing with outcome
@client-refusal@, naming the wallet, what it holds, what is
required and the shortfall, never @node-unavailable@, with
equal figures in preview and write.

Every compared figure is read at run time from a receipt,
never typed: the wallet total from its outputs, the required
from the fold bound or the measured outlay, the shortfall
as their difference. Wallets hold more than one output;
the boundary is exactly the amount and one lovelace under
in the pure rows of @OutlaySpec@.
-}
module Singular.Application.OpenDatum.WalletShortfallSpec (spec) where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM_, when)
import Control.Tracer (Tracer (..), nullTracer)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, nub, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, (</>))
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

import Cardano.Ledger.Address (Addr)
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
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.TxIn (TxIn (..))

import Data.Aeson ((.=))
import Singular.Application.OpenDatum.Command (parseOpenDatumCommand)
import Singular.Application.OpenDatum.Run (runOpenDatum)
import Singular.CLI.Live (txInText)
import Singular.CLI.Outlay (walletShortfall)
import Singular.CLI.Plan
    ( refuseUnderfunded
    , retainedFaucetStep
    )
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , readJournal
    )
import Singular.CLI.ReceiptBody (boundBody)
import Singular.CLI.Registry (loadReleaseCodes)
import Singular.CLI.Session (CommandFailure (..), Env (..))
import Singular.CLI.Trace
    ( Event (..)
    , How (..)
    , Trace (..)
    , TxEvent (..)
    , What (EdgeStarted)
    )
import Singular.Provider.Koios.FakeServer qualified as Fake
import Singular.Provider.Koios.Recorded (loadFixtureSet)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.Lifecycle (protocolFeeReserve)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (signedTx)
import Singular.Registry.StateToken (parseStateToken)
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Terminal (withWritesObserved)
import Singular.Registry.TxBuilder.BookingFixture
    ( payer
    , preprodParams
    )
import Singular.Registry.TxBuilder.Edges (adaOnlyOut, selectFunding)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.TxBuilder.Prepare
    ( planPreparation
    , spendableHeld
    , spendableOuts
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )

spec :: Spec
spec = describe "a write asks the wallet for what it costs (#526)" $ do
    it "lets 20 ada in two outputs preview and write" $ with20AdaRig $ \rig -> do
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        outcomeOf (runReceipt create) `shouldBe` Just "success"
        t <- tokenOf create
        previewed <-
            run
                rig
                "insert preview"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-1"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  , "--preview"
                  , "--wallet-address"
                  , previewAddr rig
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt previewed) `shouldBe` Just "success"
        inserted <-
            runWithKey
                (rigTestKey rig)
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
        outcomeOf (runReceipt inserted) `shouldBe` Just "success"
    it "refuses a wallet under the fold reserve before building" $ do
        let outs =
                [ (fundOutput 11, mkBasicTxOut payer (MaryValue (Coin 500_000) mempty))
                , (fundOutput 12, mkBasicTxOut payer (MaryValue (Coin 500_000) mempty))
                ]
            Coin reserve = protocolFeeReserve preprodParams []
            held = 500_000 + 500_000
        held `shouldSatisfy` (< reserve)
        walletShortfall outs reserve `shouldBe` Just (held, reserve - held)
        reached <- newIORef False
        result <-
            try $ do
                refuseUnderfunded
                    payer
                    outs
                    reserve
                    "fold reserve"
                writeIORef reached True
        case result of
            Left (CommandFailure ClientRefusal why _) ->
                why `shouldSatisfy` ("(client policy)" `isSuffixOf`)
            Left other ->
                expectationFailure ("wrong refusal: " <> show other)
            Right _ ->
                expectationFailure "a wallet under the reserve reached the builder"
        readIORef reached `shouldReturn` False
    it "refuses a wallet between the reserve and the measured total" $ withBetweenRig $ \rig -> do
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        outcomeOf (runReceipt create) `shouldBe` Just "success"
        t <- tokenOf create
        previewed <-
            run
                rig
                "insert preview underfunded"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-9"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  , "--preview"
                  , "--wallet-address"
                  , previewAddr rig
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
        reasonOf previewed `shouldSatisfy` ("(client policy)" `isSuffixOf`)
        written <-
            runWithKey
                (rigTestKey rig)
                rig
                "insert underfunded"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-9"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt written) `shouldBe` Just "client-refusal"
        reasonOf written `shouldSatisfy` ("(client policy)" `isSuffixOf`)
        figuresOf previewed `shouldBe` figuresOf written
        figuresOf previewed `shouldSatisfy` allPresent
        walletOfRun previewed `shouldBe` Just (T.pack (previewAddr rig))
        walletOfRun previewed `shouldBe` walletOfRun written
        countOfRun previewed `shouldBe` countOfRun written
        policyOfRun previewed `shouldBe` Just "client"
        policyOfRun written `shouldBe` Just "client"
        walletOfRun previewed `shouldBe` Just (T.pack (previewAddr rig))
        walletOfRun previewed `shouldBe` walletOfRun written
        countOfRun previewed `shouldBe` countOfRun written
        countOfRun previewed `shouldSatisfy` isJust
        policyOfRun previewed `shouldBe` Just "client"
        policyOfRun written `shouldBe` Just "client"
        submittedOf written `shouldBe` False
    it "refuses an empty wallet before building, on insert and update" $ with20AdaRig $ \rig -> do
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        t <- tokenOf create
        inserted <-
            runWithKey
                (rigTestKey rig)
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
        outcomeOf (runReceipt inserted) `shouldBe` Just "success"
        folded <-
            run
                rig
                "fold alice-1"
                (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
        outcomeOf (runReceipt folded) `shouldBe` Just "success"
        emptyKey <- emptyWalletKey rig
        emptyWallet <- loadWallet (fromIntegral magic) emptyKey
        let emptyAddr = bech32Address (walletAddr emptyWallet)
        emptyPreview <-
            run
                rig
                "insert preview with an empty wallet"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-2"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  , "--preview"
                  , "--wallet-address"
                  , emptyAddr
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt emptyPreview)
            `shouldBe` Just "client-refusal"
        reasonOf emptyPreview
            `shouldSatisfy` isInfixOf "(client policy)"
        reasonOf emptyPreview
            `shouldSatisfy` isInfixOf retainedFaucetStep
        emptyInsert <-
            runWithKey
                emptyKey
                rig
                "insert with an empty wallet"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-2"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt emptyInsert)
            `shouldBe` Just "client-refusal"
        reasonOf emptyInsert
            `shouldSatisfy` isInfixOf "(client policy)"
        reasonOf emptyInsert
            `shouldSatisfy` isInfixOf retainedFaucetStep
        policyOfRun emptyInsert `shouldBe` Just "client"
        walletOfRun emptyInsert `shouldSatisfy` isJust
        countOfRun emptyInsert `shouldSatisfy` isJust
        emptyTestWalletOutputs rig
        emptyUpdate <-
            runWithKey
                (rigTestKey rig)
                rig
                "update with an empty wallet"
                ( [ "open-datum"
                  , "update"
                  , "--key"
                  , "alice-1"
                  , "--payload"
                  , rigDir rig </> "payload-2.json"
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt emptyUpdate)
            `shouldBe` Just "client-refusal"
        reasonOf emptyUpdate
            `shouldSatisfy` isInfixOf "(client policy)"
        reasonOf emptyUpdate
            `shouldSatisfy` isInfixOf retainedFaucetStep
        reasonOf emptyUpdate
            `shouldSatisfy` (not . isInfixOf "send one self-payment")
        policyOfRun emptyUpdate `shouldBe` Just "client"
        walletOfRun emptyUpdate `shouldBe` Just (T.pack (previewAddr rig))
        countOfRun emptyUpdate `shouldSatisfy` isJust
        selectFunding Nothing [] `shouldSatisfy` isLeftWithEmpty
        selectFunding (Just (fundOutput 99)) []
            `shouldSatisfy` isLeftWithEmpty
    it "refuses a foreign funding output before building" $ with20AdaRig $ \rig -> do
        -- Pinned exact old wording (the base's foreign-choice branch of the funding resolution, no prefix,
        -- no faucet): msg frozen literal + wallet address (producer) + policy suffix.
        let foreignMsg = "the chosen funding output is not an ada-only output of the payer"
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        t <- tokenOf create
        foreignInsert <-
            runWithKey
                (rigTestKey rig)
                rig
                "insert with a foreign fund input"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-2"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  , "--fund-input"
                  , T.unpack (renderOutRef (fundOutput 99))
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt foreignInsert)
            `shouldBe` Just "client-refusal"
        runCode foreignInsert `shouldBe` ExitFailure 10
        reasonOf foreignInsert
            `shouldBe` (foreignMsg <> " for wallet " <> previewAddr rig <> " (client policy)")
        reasonOf foreignInsert
            `shouldSatisfy` (not . isInfixOf retainedFaucetStep)
        policyOfRun foreignInsert `shouldBe` Just "client"
        walletOfRun foreignInsert `shouldBe` Just (T.pack (previewAddr rig))
        countOfRun foreignInsert `shouldSatisfy` isJust
        submittedOf foreignInsert `shouldBe` False
    it "refuses a foreign funding output for terminate with today's text" $ with20AdaRig $ \rig -> do
        let foreignMsg = "the chosen funding output is not an ada-only output of the payer"
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        t <- tokenOf create
        inserted <-
            runWithKey
                (rigTestKey rig)
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
        outcomeOf (runReceipt inserted) `shouldBe` Just "success"
        folded <-
            run
                rig
                "fold alice-1"
                (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
        outcomeOf (runReceipt folded) `shouldBe` Just "success"
        foreignTerminate <-
            runWithKey
                (rigTestKey rig)
                rig
                "terminate with a foreign fund input"
                ( [ "open-datum"
                  , "terminate"
                  , "--key"
                  , "alice-1"
                  , "--fund-input"
                  , T.unpack (renderOutRef (fundOutput 99))
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt foreignTerminate)
            `shouldBe` Just "client-refusal"
        runCode foreignTerminate `shouldBe` ExitFailure 10
        reasonOf foreignTerminate
            `shouldBe` (foreignMsg <> " for wallet " <> previewAddr rig <> " (client policy)")
        submittedOf foreignTerminate `shouldBe` False
    it "refuses a funded insert past a tiny allowance before signing" $ with20AdaRig $ \rig -> do
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        t <- tokenOf create
        refused <-
            runWithKey
                (rigTestKey rig)
                rig
                "insert past max-outlay 1"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-2"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  , "--max-outlay"
                  , "1"
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
        runCode refused `shouldBe` ExitFailure 10
        reasonOf refused
            `shouldSatisfy` isInfixOf "passes the approved allowance"
        submittedOf refused `shouldBe` False
    it "refuses a funded terminate past a tiny allowance before signing" $ with20AdaRig $ \rig -> do
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        t <- tokenOf create
        inserted <-
            runWithKey
                (rigTestKey rig)
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
        outcomeOf (runReceipt inserted) `shouldBe` Just "success"
        folded <-
            run
                rig
                "fold alice-1"
                (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
        outcomeOf (runReceipt folded) `shouldBe` Just "success"
        refused <-
            runWithKey
                (rigTestKey rig)
                rig
                "terminate past max-outlay 1"
                ( [ "open-datum"
                  , "terminate"
                  , "--key"
                  , "alice-1"
                  , "--max-outlay"
                  , "1"
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
        runCode refused `shouldBe` ExitFailure 10
        reasonOf refused
            `shouldSatisfy` isInfixOf "passes the approved allowance"
        submittedOf refused `shouldBe` False
    it
        "judges preview and write on the same wallet, with the same figures"
        $ withBetweenRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            previewed <-
                run
                    rig
                    "insert preview"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            written <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "insert"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
            outcomeOf (runReceipt written) `shouldBe` Just "client-refusal"
            outcomeOf (runReceipt previewed) `shouldNotBe` Just "node-unavailable"
            outcomeOf (runReceipt written) `shouldNotBe` Just "node-unavailable"
            figuresOf previewed `shouldBe` figuresOf written
            figuresOf previewed `shouldSatisfy` allPresent
    it
        "drops only the self-payment sentence from the faucet step (#491 PR2 RED)"
        $ do
            retainedFaucetStep `shouldBe` retainedFaucet
            retainedFaucetStep
                `shouldSatisfy` (not . isInfixOf "send one self-payment")
    it
        "insert preview from an empty wallet names the faucet without the hand step (#491 PR2 RED)"
        $ with20AdaRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            emptyKey <- emptyWalletKey rig
            emptyWallet <- loadWallet (fromIntegral magic) emptyKey
            let emptyAddr = bech32Address (walletAddr emptyWallet)
            previewed <-
                run
                    rig
                    "insert preview empty without hand step"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-2"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--preview"
                      , "--wallet-address"
                      , emptyAddr
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
            runCode previewed `shouldBe` ExitFailure 10
            reasonOf previewed `shouldSatisfy` isInfixOf retainedFaucet
            reasonOf previewed
                `shouldSatisfy` (not . isInfixOf "send one self-payment")
            walletOfRun previewed `shouldBe` Just (T.pack emptyAddr)
            heldOfRun previewed `shouldBe` Just 0
            countOfRun previewed `shouldBe` Just 0
    it
        "insert write from an empty wallet names the faucet without the hand step (#491 PR2 RED)"
        $ with20AdaRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            emptyKey <- emptyWalletKey rig
            emptyWallet <- loadWallet (fromIntegral magic) emptyKey
            let emptyAddr = bech32Address (walletAddr emptyWallet)
            written <-
                runWithKey
                    emptyKey
                    rig
                    "insert empty without hand step"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-2"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt written) `shouldBe` Just "client-refusal"
            runCode written `shouldBe` ExitFailure 10
            reasonOf written `shouldSatisfy` isInfixOf retainedFaucet
            reasonOf written
                `shouldSatisfy` (not . isInfixOf "send one self-payment")
            walletOfRun written `shouldBe` Just (T.pack emptyAddr)
            heldOfRun written `shouldBe` Just 0
            countOfRun written `shouldBe` Just 0
    it
        "terminate preview from an empty wallet names the faucet without the hand step (#491 PR2 RED)"
        $ with20AdaRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            inserted <-
                runWithKey
                    (rigTestKey rig)
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
            outcomeOf (runReceipt inserted) `shouldBe` Just "success"
            folded <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            emptyTestWalletOutputs rig
            previewed <-
                run
                    rig
                    "terminate preview empty without hand step"
                    ( [ "open-datum"
                      , "terminate"
                      , "--key"
                      , "alice-1"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
            runCode previewed `shouldBe` ExitFailure 10
            reasonOf previewed `shouldSatisfy` isInfixOf retainedFaucet
            reasonOf previewed
                `shouldSatisfy` (not . isInfixOf "send one self-payment")
            walletOfRun previewed `shouldBe` Just (T.pack (previewAddr rig))
            heldOfRun previewed `shouldBe` Just 0
            countOfRun previewed `shouldBe` Just 0
    it
        "terminate write from an empty wallet names the faucet without the hand step (#491 PR2 RED)"
        $ with20AdaRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            inserted <-
                runWithKey
                    (rigTestKey rig)
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
            outcomeOf (runReceipt inserted) `shouldBe` Just "success"
            folded <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            emptyTestWalletOutputs rig
            written <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "terminate empty without hand step"
                    ( [ "open-datum"
                      , "terminate"
                      , "--key"
                      , "alice-1"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt written) `shouldBe` Just "client-refusal"
            runCode written `shouldBe` ExitFailure 10
            reasonOf written `shouldSatisfy` isInfixOf retainedFaucet
            reasonOf written
                `shouldSatisfy` (not . isInfixOf "send one self-payment")
            walletOfRun written `shouldBe` Just (T.pack (previewAddr rig))
            heldOfRun written `shouldBe` Just 0
            countOfRun written `shouldBe` Just 0
    it
        "refuses a token-only insert below the whole outlay plus preparation fee before signing (#491 PR2b)"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            (policy, kinds) <- rehearsalKindsOf create
            let testPayer = walletAddr (rigTestWallet rig)
                deposit = 15_000_000
                bundle = singleKindBundle policy kinds
                insertAt k =
                    runWithKey
                        (rigTestKey rig)
                        rig
                        ("insert probe " <> show (k :: Int))
                        ( [ "open-datum"
                          , "insert"
                          , "--key"
                          , "probe-" <> show k
                          , "--payload"
                          , rigDir rig </> "payload.json"
                          , "--deposit"
                          , show deposit
                          ]
                            <> tokenArgs t
                        )
            -- A rich token-only wallet completes through one preparation:
            -- the receipt's preparation members measure this rig's
            -- requirement and preparation fee, never typed here.
            plantTokenOutputs rig bundle 100_000_000 0
            richWallet <- readTestWallet rig
            [() | (_, o) <- richWallet, adaOnlyOut o] `shouldBe` []
            completed <- insertAt 1
            outcomeOf (runReceipt completed) `shouldBe` Just "success"
            (nRich, pRich) <- preparationFiguresOf completed
            nRich `shouldSatisfy` (> deposit)
            pRich `shouldSatisfy` (> 0)
            pp <-
                SessionIO.withLatest
                    (rawChainProvider (rigChain rig))
                    SessionIO.parameters
            -- A wallet between the preparation plan (its requirement, fee
            -- and remainder floor) and the whole outlay plus the preparation
            -- fee. The interval is found by bisecting run results, every
            -- bound read from the producers: each probe replants the
            -- token-only wallet at a total lovelace of h on a fresh output
            -- and books a fresh key; a wallet whose run completes was too
            -- rich, one whose run refuses at the preparation plan was too
            -- poor, and a run that refuses on the whole outlay with a zero
            -- remainder floor is the row's subject. The plan gate uses the
            -- most recent completing run's measured requirement, so the
            -- requirement's small drift as the registry grows never misses
            -- the interval.
            let wholeOutlayRefusal r =
                    outcomeOf (runReceipt r) == Just "client-refusal"
                        && numberOfRun "remainderMin" r == Just 0
                        && isInfixOf "preparation-unfunded:" (reasonOf r)
                planRefusal r =
                    outcomeOf (runReceipt r) == Just "client-refusal"
                        && maybe False (> 0) (numberOfRun "remainderMin" r)
                search
                    :: (Integer, Integer) -> Integer -> Integer -> Int -> IO Run
                search _ _ _ 0 =
                    fail
                        "no token-only wallet between the preparation plan and the whole outlay refused"
                search measured lower upper attempts = do
                    let k = 2 + (14 - attempts)
                        h =
                            if attempts == 14
                                then 20_000_000
                                else (lower + upper) `div` 2
                    plantTokenOutputs rig bundle h k
                    wallet <- readTestWallet rig
                    [() | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                    length (spendableOuts wallet) `shouldBe` 1
                    spendableHeld wallet `shouldBe` h
                    case planPreparation pp testPayer (fst measured) wallet of
                        Left _ -> search measured h upper (attempts - 1)
                        Right _ -> do
                            beforeState <- snapshotStateDir rig
                            r <- insertAt k
                            if wholeOutlayRefusal r
                                then do
                                    outcomeOf (runReceipt r) `shouldBe` Just "client-refusal"
                                    runCode r `shouldBe` ExitFailure 10
                                    reasonOf r
                                        `shouldSatisfy` isInfixOf "preparation-unfunded:"
                                    reasonOf r
                                        `shouldSatisfy` isSuffixOf "(client policy); nothing was submitted"
                                    heldOfRun r `shouldBe` Just h
                                    numberOfRun "fee" r `shouldSatisfy` (> Just 0)
                                    numberOfRun "remainderMin" r `shouldBe` Just 0
                                    numberOfRun "required" r `shouldSatisfy` (> Just h)
                                    numberOfRun "shortfall" r
                                        `shouldBe` ((-) <$> numberOfRun "required" r <*> Just h)
                                    submittedOf r `shouldBe` False
                                    submissionsOfRun r `shouldBe` Just []
                                    afterWallet <- readTestWallet rig
                                    afterWallet `shouldBe` wallet
                                    afterState <- snapshotStateDir rig
                                    afterState `shouldBe` beforeState
                                    pure r
                                else
                                    if outcomeOf (runReceipt r) == Just "success"
                                        then do
                                            fresh <- preparationFiguresOf r
                                            search fresh lower h (attempts - 1)
                                        else
                                            if planRefusal r
                                                then search measured h upper (attempts - 1)
                                                else
                                                    fail
                                                        ( "probe wallet refused for another reason: "
                                                            <> reasonOf r
                                                        )
            _ <-
                search
                    (nRich, pRich)
                    (nRich + pRich)
                    100_000_000
                    14
            pure ()
    it
        "a token-only insert completes through one preparation (#491 PR2b)"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            (policy, kinds) <- rehearsalKindsOf create
            let testPayer = walletAddr (rigTestWallet rig)
                bundle = singleKindBundle policy kinds
            plantTokenOutputs rig bundle 100_000_000 0
            walletBefore <- readTestWallet rig
            [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
            length (spendableOuts walletBefore) `shouldBe` 1
            assetsOf walletBefore `shouldBe` bundle
            refsBefore <- referenceOutputs rig
            inserted <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "insert from the token-only wallet"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--deposit"
                      , "15000000"
                      ]
                        <> tokenArgs t
                    )
            _ <- expectBookedThroughPreparation rig testPayer inserted
            walletAfter <- readTestWallet rig
            assetsOf walletAfter `shouldBe` bundle
            refsAfter <- referenceOutputs rig
            refsAfter `shouldBe` refsBefore
    it
        "a token-only terminate completes through one preparation (#491 PR2b)"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            (policy, kinds) <- rehearsalKindsOf create
            let testPayer = walletAddr (rigTestWallet rig)
                bundle = singleKindBundle policy kinds
            -- a live key first: an insert from the wallet as the rig
            -- funds it (ada only, no preparation), then the fold that
            -- delivers it
            inserted <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "insert alice-1 for the terminate"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--deposit"
                      , "15000000"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt inserted) `shouldBe` Just "success"
            folded <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            -- token-only: the whole wallet replanted around the bundle
            plantTokenOutputs rig bundle 100_000_000 0
            walletBefore <- readTestWallet rig
            [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
            assetsOf walletBefore `shouldBe` bundle
            refsBefore <- referenceOutputs rig
            terminated <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "terminate from the token-only wallet"
                    (["open-datum", "terminate", "--key", "alice-1"] <> tokenArgs t)
            _ <- expectBookedThroughPreparation rig testPayer terminated
            walletAfter <- readTestWallet rig
            assetsOf walletAfter `shouldBe` bundle
            refsAfter <- referenceOutputs rig
            refsAfter `shouldBe` refsBefore
    it "a funded wallet books with no preparation member (#491 PR2b)" $ with20AdaRig $ \rig -> do
        seed <- fundSeed rig
        create <- run rig "create" ["open-datum", "create", "--seed", seed]
        outcomeOf (runReceipt create) `shouldBe` Just "success"
        t <- tokenOf create
        inserted <-
            runWithKey
                (rigTestKey rig)
                rig
                "insert from a funded wallet"
                ( [ "open-datum"
                  , "insert"
                  , "--key"
                  , "alice-1"
                  , "--payload"
                  , rigDir rig </> "payload.json"
                  ]
                    <> tokenArgs t
                )
        outcomeOf (runReceipt inserted) `shouldBe` Just "success"
        runCode inserted `shouldBe` ExitSuccess
        case runReceipt inserted of
            Aeson.Object o -> KeyMap.member "preparation" o `shouldBe` False
            _ -> fail "the funded insert printed no receipt object"
    it
        "the booking preview plans the preparation the insert then makes equal (#491 PR2b)"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            (policy, kinds) <- rehearsalKindsOf create
            let bundle = singleKindBundle policy kinds
            plantTokenOutputs rig bundle 100_000_000 0
            walletBefore <- readTestWallet rig
            [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
            assetsOf walletBefore `shouldBe` bundle
            stateBefore <- snapshotStateDir rig
            previewed <-
                run
                    rig
                    "insert preview from the token-only wallet"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--deposit"
                      , "15000000"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "success"
            runCode previewed `shouldBe` ExitSuccess
            BL.toStrict (Aeson.encode (runReceipt previewed))
                `shouldSatisfy` (not . BS.isInfixOf "send one self-payment")
            (prepTxP, prepOutP, coinP, feeP) <- preparationMembersOf previewed
            submittedOf previewed `shouldBe` False
            walletAfterPreview <- readTestWallet rig
            walletAfterPreview `shouldBe` walletBefore
            stateAfterPreview <- snapshotStateDir rig
            stateAfterPreview `shouldBe` stateBefore
            inserted <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "insert after the preview"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--deposit"
                      , "15000000"
                      ]
                        <> tokenArgs t
                    )
            _ <-
                expectBookedThroughPreparation
                    rig
                    (walletAddr (rigTestWallet rig))
                    inserted
            (prepTxW, prepOutW, coinW, feeW) <- preparationMembersOf inserted
            (prepTxW, coinW, feeW) `shouldBe` (prepTxP, coinP, feeP)
            prepOutW `shouldBe` prepOutP
    it
        "the booking preview refuses a short token-only wallet with the write's figures (#491 PR2b)"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            (policy, kinds) <- rehearsalKindsOf create
            let bundle = singleKindBundle policy kinds
            plantTokenOutputs rig bundle 10_000_000 0
            walletBefore <- readTestWallet rig
            [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
            stateBefore <- snapshotStateDir rig
            previewed <-
                run
                    rig
                    "insert preview short token-only"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--deposit"
                      , "15000000"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
            runCode previewed `shouldBe` ExitFailure 10
            reasonOf previewed `shouldSatisfy` isInfixOf "preparation-unfunded:"
            reasonOf previewed
                `shouldSatisfy` isSuffixOf "(client policy); nothing was submitted"
            reasonOf previewed
                `shouldSatisfy` (not . isInfixOf "send one self-payment")
            reasonOf previewed
                `shouldSatisfy` (not . isInfixOf retainedFaucetStep)
            submittedOf previewed `shouldBe` False
            walletAfterPreview <- readTestWallet rig
            walletAfterPreview `shouldBe` walletBefore
            stateAfterPreview <- snapshotStateDir rig
            stateAfterPreview `shouldBe` stateBefore
            written <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "insert short token-only"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "bob-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--deposit"
                      , "15000000"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt written) `shouldBe` Just "client-refusal"
            runCode written `shouldBe` ExitFailure 10
            reasonOf written `shouldSatisfy` isInfixOf "preparation-unfunded:"
            submissionsOfRun written `shouldBe` Just []
            figuresPreview <- figuresPresentOf previewed
            figuresWritten <- figuresPresentOf written
            figuresPreview `shouldBe` figuresWritten
            feePreview <- requireNumberOf "fee" previewed
            feeWritten <- requireNumberOf "fee" written
            feePreview `shouldBe` feeWritten
            floorPreview <- requireNumberOf "remainderMin" previewed
            floorWritten <- requireNumberOf "remainderMin" written
            floorPreview `shouldBe` floorWritten
    it "a funded wallet previews with no preparation member (#491 PR2b)" $
        with20AdaRig $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            stateBefore <- snapshotStateDir rig
            previewed <-
                run
                    rig
                    "insert preview funded"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "success"
            runCode previewed `shouldBe` ExitSuccess
            case runReceipt previewed of
                Aeson.Object o -> KeyMap.member "preparation" o `shouldBe` False
                _ -> fail "the funded preview printed no receipt object"
            submittedOf previewed `shouldBe` False
            stateAfterPreview <- snapshotStateDir rig
            stateAfterPreview `shouldBe` stateBefore
            inserted <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "insert alice-1 for the terminate preview"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt inserted) `shouldBe` Just "success"
            folded <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            stateBeforeTerminate <- snapshotStateDir rig
            terminatedPreview <-
                run
                    rig
                    "terminate preview funded"
                    ( [ "open-datum"
                      , "terminate"
                      , "--key"
                      , "alice-1"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt terminatedPreview) `shouldBe` Just "success"
            runCode terminatedPreview `shouldBe` ExitSuccess
            case runReceipt terminatedPreview of
                Aeson.Object o -> KeyMap.member "preparation" o `shouldBe` False
                _ -> fail "the funded terminate preview printed no receipt object"
            submittedOf terminatedPreview `shouldBe` False
            stateAfterTerminate <- snapshotStateDir rig
            stateAfterTerminate `shouldBe` stateBeforeTerminate
    it
        "the booking preview refuses a foreign choice below the reserve with today's text (#491 PR2b)"
        $ withFundedRig [(11, 500_000), (12, 500_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            let foreignMsg =
                    "the chosen funding output is not an ada-only output of the payer"
            walletBefore <- readTestWallet rig
            pp <-
                SessionIO.withLatest
                    (rawChainProvider (rigChain rig))
                    SessionIO.parameters
            let Coin reserveBelow = protocolFeeReserve pp []
            spendableHeld walletBefore `shouldSatisfy` (< reserveBelow)
            stateBefore <- snapshotStateDir rig
            previewed <-
                run
                    rig
                    "insert preview foreign below the reserve"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--fund-input"
                      , T.unpack (renderOutRef (fundOutput 99))
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
            runCode previewed `shouldBe` ExitFailure 10
            reasonOf previewed
                `shouldBe` (foreignMsg <> " for wallet " <> previewAddr rig <> " (client policy)")
            walletOfRun previewed `shouldBe` Just (T.pack (previewAddr rig))
            countOfRun previewed `shouldSatisfy` isJust
            submittedOf previewed `shouldBe` False
            walletAfter <- readTestWallet rig
            walletAfter `shouldBe` walletBefore
            stateAfter <- snapshotStateDir rig
            stateAfter `shouldBe` stateBefore
    it
        "the booking preview refuses a foreign choice from a funded wallet with today's text (#491 PR2b)"
        $ with20AdaRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            let foreignMsg =
                    "the chosen funding output is not an ada-only output of the payer"
            previewed <-
                run
                    rig
                    "insert preview foreign funded"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      , "--fund-input"
                      , T.unpack (renderOutRef (fundOutput 99))
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
            runCode previewed `shouldBe` ExitFailure 10
            reasonOf previewed
                `shouldBe` (foreignMsg <> " for wallet " <> previewAddr rig <> " (client policy)")
            submittedOf previewed `shouldBe` False
    it
        "the terminate preview plans the preparation the command then makes equal (#491 PR2b)"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            (policy, kinds) <- rehearsalKindsOf create
            let bundle = singleKindBundle policy kinds
                insertFor k label =
                    runWithKey
                        (rigTestKey rig)
                        rig
                        label
                        ( [ "open-datum"
                          , "insert"
                          , "--key"
                          , k
                          , "--payload"
                          , rigDir rig </> "payload.json"
                          ]
                            <> tokenArgs t
                        )
            -- a live key from the funded wallet, then the fold that delivers it
            inserted <-
                insertFor "alice-1" "insert alice-1 for the terminate preview"
            outcomeOf (runReceipt inserted) `shouldBe` Just "success"
            folded <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            plantTokenOutputs rig bundle 100_000_000 0
            walletBefore <- readTestWallet rig
            [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
            stateBefore <- snapshotStateDir rig
            previewed <-
                run
                    rig
                    "terminate preview from the token-only wallet"
                    ( [ "open-datum"
                      , "terminate"
                      , "--key"
                      , "alice-1"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "success"
            runCode previewed `shouldBe` ExitSuccess
            BL.toStrict (Aeson.encode (runReceipt previewed))
                `shouldSatisfy` (not . BS.isInfixOf "send one self-payment")
            (prepTxP, prepOutP, coinP, feeP) <- preparationMembersOf previewed
            submittedOf previewed `shouldBe` False
            walletAfterPreview <- readTestWallet rig
            walletAfterPreview `shouldBe` walletBefore
            stateAfterPreview <- snapshotStateDir rig
            stateAfterPreview `shouldBe` stateBefore
            terminated <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "terminate after the preview"
                    (["open-datum", "terminate", "--key", "alice-1"] <> tokenArgs t)
            _ <-
                expectBookedThroughPreparation
                    rig
                    (walletAddr (rigTestWallet rig))
                    terminated
            (prepTxW, prepOutW, coinW, feeW) <- preparationMembersOf terminated
            (prepTxW, coinW, feeW) `shouldBe` (prepTxP, coinP, feeP)
            prepOutW `shouldBe` prepOutP
    it
        "the terminate preview refuses a short token-only wallet with the write's figures (#491 PR2b)"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            outcomeOf (runReceipt create) `shouldBe` Just "success"
            t <- tokenOf create
            (policy, kinds) <- rehearsalKindsOf create
            let bundle = singleKindBundle policy kinds
            inserted <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "insert alice-1 for the short terminate preview"
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "alice-1"
                      , "--payload"
                      , rigDir rig </> "payload.json"
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt inserted) `shouldBe` Just "success"
            folded <-
                run
                    rig
                    "fold alice-1"
                    (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
            outcomeOf (runReceipt folded) `shouldBe` Just "success"
            -- a wallet the terminate booking itself refuses: found by
            -- bisecting PREVIEW results (too rich completes; below the
            -- fold reserve refuses with another text), every bound a run
            let findShort h attempts
                    | attempts <= 0 =
                        fail "no token-only wallet refused the terminate preview"
                    | otherwise = do
                        plantTokenOutputs rig bundle h attempts
                        probed <-
                            run
                                rig
                                ("terminate preview probe " <> show (attempts :: Int))
                                ( [ "open-datum"
                                  , "terminate"
                                  , "--key"
                                  , "alice-1"
                                  , "--preview"
                                  , "--wallet-address"
                                  , previewAddr rig
                                  ]
                                    <> tokenArgs t
                                )
                        if outcomeOf (runReceipt probed) == Just "success"
                            then findShort (h `div` 2) (attempts - 1)
                            else
                                if "preparation-unfunded:" `isInfixOf` reasonOf probed
                                    then pure (probed, h)
                                    else findShort (h + h `div` 2) (attempts - 1)
            (_, hShort) <- findShort 6_000_000 8
            plantTokenOutputs rig bundle hShort 0
            walletBefore <- readTestWallet rig
            [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
            stateBefore <- snapshotStateDir rig
            previewed <-
                run
                    rig
                    "terminate preview short token-only"
                    ( [ "open-datum"
                      , "terminate"
                      , "--key"
                      , "alice-1"
                      , "--preview"
                      , "--wallet-address"
                      , previewAddr rig
                      ]
                        <> tokenArgs t
                    )
            outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
            runCode previewed `shouldBe` ExitFailure 10
            reasonOf previewed `shouldSatisfy` isInfixOf "preparation-unfunded:"
            reasonOf previewed
                `shouldSatisfy` isSuffixOf "(client policy); nothing was submitted"
            reasonOf previewed
                `shouldSatisfy` (not . isInfixOf "send one self-payment")
            submittedOf previewed `shouldBe` False
            walletAfterPreview <- readTestWallet rig
            walletAfterPreview `shouldBe` walletBefore
            stateAfterPreview <- snapshotStateDir rig
            stateAfterPreview `shouldBe` stateBefore
            written <-
                runWithKey
                    (rigTestKey rig)
                    rig
                    "terminate short token-only"
                    (["open-datum", "terminate", "--key", "alice-1"] <> tokenArgs t)
            outcomeOf (runReceipt written) `shouldBe` Just "client-refusal"
            runCode written `shouldBe` ExitFailure 10
            reasonOf written `shouldSatisfy` isInfixOf "preparation-unfunded:"
            submissionsOfRun written `shouldBe` Just []
            figuresPreview <- figuresPresentOf previewed
            figuresWritten <- figuresPresentOf written
            figuresPreview `shouldBe` figuresWritten
            feePreview <- requireNumberOf "fee" previewed
            feeWritten <- requireNumberOf "fee" written
            feePreview `shouldBe` feeWritten
            floorPreview <- requireNumberOf "remainderMin" previewed
            floorWritten <- requireNumberOf "remainderMin" written
            floorPreview `shouldBe` floorWritten
    it "opens a write session for 20 ada in two outputs with no threshold" $ do
        withSystemTempDirectory "wallet-floor-open" $ \dir -> do
            let keyPath = dir </> "payment.skey"
            BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
            _ <- loadWallet 1 keyPath
            set <- loadFixtureSet "test/fixtures/koios/preprod" >>= requireRight
            Fake.withFakeKoios (Fake.replayFixtures set) $ \url _ -> do
                let settings = ProviderSettings (T.unpack url) 1 Nothing Nothing
                ran <- newIORef False
                _ <-
                    try @SomeException
                        $ withWritesObserved
                            nullTracer
                            nullTracer
                            (const (pure ()))
                            settings
                        $ \_ ->
                            writeIORef ran True
                readIORef ran `shouldReturn` True
    updatePreparationRows
    splitApprovalsRows
    approvalsAboveOneRows

-- ---------------------------------------------------------
-- update prepares the funding output it needs (#491 part 3)
-- ---------------------------------------------------------

{- | As Alice, my wallet holds one output that carries my approval tokens
beside the ada. I run @open-datum update@: the preview shows the one
preparation transaction the command will make, and the command makes it as
an ordinary journalled transaction, then updates against the output it made
and leaves my tokens and the published scripts alone. A wallet that suffices
gets no preparation, a named output stays final, a wallet that cannot pay for
both is refused with the figures before anything is signed.
-}
updatePreparationRows :: Spec
updatePreparationRows =
    describe "update prepares the funding output it needs (#491 part 3)" $ do
        it
            "an update preview from an empty wallet names the faucet and no hand step"
            $ with20AdaRig
            $ \rig -> do
                (t, _) <- liveKeyRig rig
                emptyTestWalletOutputs rig
                previewed <- previewUpdateAs rig t "update preview, empty wallet" []
                outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
                runCode previewed `shouldBe` ExitFailure 10
                reasonOf previewed
                    `shouldBe` ( "the payer wallet has no ada-only output for wallet "
                                    <> previewAddr rig
                                    <> " (client policy). "
                                    <> retainedFaucet
                               )
                walletOfRun previewed `shouldBe` Just (T.pack (previewAddr rig))
                heldOfRun previewed `shouldBe` Just 0
                countOfRun previewed `shouldBe` Just 0
                submittedOf previewed `shouldBe` False
        it "a token-only update completes through one preparation" $
            withFundedRig [(11, 100_000_000), (12, 100_000_000)] $ \rig -> do
                (t, bundle) <- liveKeyRig rig
                let testPayer = walletAddr (rigTestWallet rig)
                plantTokenOutputs rig bundle 100_000_000 0
                walletBefore <- readTestWallet rig
                [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
                length (spendableOuts walletBefore) `shouldBe` 1
                assetsOf walletBefore `shouldBe` bundle
                refsBefore <- referenceOutputs rig
                updated <- updateAs rig t "update from the token-only wallet" []
                (outcomeOf (runReceipt updated), reasonOf updated)
                    `shouldBe` (Just "success", "")
                (_, prepOut) <-
                    expectCompletedThroughPreparation
                        "update"
                        "update"
                        rig
                        testPayer
                        updated
                updateTx <- requireMember "update" updated
                entries <- concat <$> (mapM readJournal =<< journalDirs rig)
                [journalEvent e | e <- entries, journalTxId e == updateTx]
                    `shouldBe` ["prepared", "submitted", "confirmed", "observed"]
                sent <- decodeJsonFile (rigDir rig </> "payload-2.json")
                valueOfRun "payload" updated `shouldBe` Just sent
                BL.toStrict (Aeson.encode (runReceipt updated))
                    `shouldSatisfy` (not . BS.isInfixOf "send one self-payment")
                walletAfter <- readTestWallet rig
                assetsOf walletAfter `shouldBe` bundle
                map (renderOutRef . fst) walletAfter `shouldNotContain` [prepOut]
                refsAfter <- referenceOutputs rig
                refsAfter `shouldBe` refsBefore
        it
            "the update preview plans the preparation the update then makes, and submits nothing"
            $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
            $ \rig -> do
                (t, bundle) <- liveKeyRig rig
                plantTokenOutputs rig bundle 100_000_000 0
                walletBefore <- readTestWallet rig
                [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
                stateBefore <- snapshotStateDir rig
                previewed <-
                    previewUpdateAs rig t "update preview, token-only wallet" []
                (outcomeOf (runReceipt previewed), reasonOf previewed)
                    `shouldBe` (Just "success", "")
                runCode previewed `shouldBe` ExitSuccess
                BL.toStrict (Aeson.encode (runReceipt previewed))
                    `shouldSatisfy` (not . BS.isInfixOf "send one self-payment")
                (txP, outP, coinP, feeP) <- preparationMembersOf previewed
                submittedOf previewed `shouldBe` False
                readTestWallet rig `shouldReturn` walletBefore
                snapshotStateDir rig `shouldReturn` stateBefore
                updated <- updateAs rig t "update after the preview" []
                _ <-
                    expectCompletedThroughPreparation
                        "update"
                        "update"
                        rig
                        (walletAddr (rigTestWallet rig))
                        updated
                (txW, outW, coinW, feeW) <- preparationMembersOf updated
                (txW, coinW, feeW) `shouldBe` (txP, coinP, feeP)
                outW `shouldBe` outP
        it
            "a token-only wallet too short for the update is refused before signing, in the preview and in the update, with the same figures"
            $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
            $ \rig -> do
                (t, bundle) <- liveKeyRig rig
                pp <-
                    SessionIO.withLatest
                        (rawChainProvider (rigChain rig))
                        SessionIO.parameters
                -- what the approval tokens alone need to sit in an output
                let Coin held =
                        getMinCoinTxOut
                            pp
                            ( mkBasicTxOut
                                (walletAddr (rigTestWallet rig))
                                (MaryValue (Coin 0) (MultiAsset bundle))
                            )
                plantTokenOutputs rig bundle held 0
                walletBefore <- readTestWallet rig
                [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
                spendableHeld walletBefore `shouldBe` held
                stateBefore <- snapshotStateDir rig
                previewed <-
                    previewUpdateAs rig t "update preview, short token-only wallet" []
                previewFigures <- expectPreparationUnfunded held previewed
                submittedOf previewed `shouldBe` False
                readTestWallet rig `shouldReturn` walletBefore
                snapshotStateDir rig `shouldReturn` stateBefore
                written <- updateAs rig t "update, short token-only wallet" []
                writeFigures <- expectPreparationUnfunded held written
                submissionsOfRun written `shouldBe` Just []
                submittedOf written `shouldBe` False
                writeFigures `shouldBe` previewFigures
                readTestWallet rig `shouldReturn` walletBefore
                snapshotStateDir rig `shouldReturn` stateBefore
        it
            "the allowance judges the update with its preparation fee, before anything is signed"
            $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
            $ \rig -> do
                (t, bundle) <- liveKeyRig rig
                plantTokenOutputs rig bundle 100_000_000 0
                walletBefore <- readTestWallet rig
                previewed <-
                    previewUpdateAs rig t "update preview for the allowance" []
                outcomeOf (runReceipt previewed) `shouldBe` Just "success"
                outlayCommand <- outlayTotalOf previewed
                (_, _, _, feePrep) <- preparationMembersOf previewed
                outlayCommand `shouldSatisfy` (> 0)
                feePrep `shouldSatisfy` (> 1)
                let whole = outlayCommand + feePrep
                    refusalAt allowance =
                        "the measured outlay of "
                            <> show outlayCommand
                            <> " lovelace with the preparation fee of "
                            <> show feePrep
                            <> " lovelace passes the approved allowance of "
                            <> show allowance
                            <> " (client policy); nothing was submitted"
                stateBefore <- snapshotStateDir rig
                forM_
                    [ ("one lovelace below the whole", whole - 1)
                    , ("the command's outlay alone", outlayCommand)
                    ]
                    $ \(label, allowance) -> do
                        previewRefused <-
                            previewUpdateAs
                                rig
                                t
                                ("update preview, allowance " <> label)
                                ["--max-outlay", show allowance]
                        outcomeOf (runReceipt previewRefused) `shouldBe` Just "client-refusal"
                        runCode previewRefused `shouldBe` ExitFailure 10
                        reasonOf previewRefused `shouldBe` refusalAt allowance
                        submittedOf previewRefused `shouldBe` False
                        refused <-
                            updateAs
                                rig
                                t
                                ("update, allowance " <> label)
                                ["--max-outlay", show allowance]
                        outcomeOf (runReceipt refused) `shouldBe` Just "client-refusal"
                        runCode refused `shouldBe` ExitFailure 10
                        reasonOf refused `shouldBe` refusalAt allowance
                        submissionsOfRun refused `shouldBe` Just []
                        submittedOf refused `shouldBe` False
                        readTestWallet rig `shouldReturn` walletBefore
                        snapshotStateDir rig `shouldReturn` stateBefore
                accepted <-
                    updateAs
                        rig
                        t
                        "update, allowance equal to the whole"
                        ["--max-outlay", show whole]
                _ <-
                    expectCompletedThroughPreparation
                        "update"
                        "update"
                        rig
                        (walletAddr (rigTestWallet rig))
                        accepted
                (_, _, _, feeMade) <- preparationMembersOf accepted
                feeMade `shouldBe` feePrep
        it
            "an explicit funding choice is final: the smaller named output funds the update, not the natural one"
            $ withFundedRig [(11, 300_000_000), (12, 100_000_000)]
            $ \rig -> do
                (t, _) <- liveKeyRig rig
                wallet <- readTestWallet rig
                let adaOnly =
                        sortOn
                            (Down . coinOf . snd)
                            [u | u@(_, o) <- wallet, adaOnlyOut o]
                (natural, named) <- case adaOnly of
                    n : m : _ -> do
                        coinOf (snd n) `shouldSatisfy` (> coinOf (snd m))
                        pure (fst n, fst m)
                    _ -> fail "the wallet does not hold two ada-only outputs"
                let choice = ["--fund-input", T.unpack (renderOutRef named)]
                previewed <-
                    previewUpdateAs rig t "update preview, named output" choice
                outcomeOf (runReceipt previewed) `shouldBe` Just "success"
                previewInputs <- updateInputsOf previewed
                previewInputs `shouldContain` [renderOutRef named]
                previewInputs `shouldNotContain` [renderOutRef natural]
                hasMember "preparation" previewed `shouldBe` False
                updated <- updateAs rig t "update, named output" choice
                (outcomeOf (runReceipt updated), reasonOf updated)
                    `shouldBe` (Just "success", "")
                hasMember "preparation" updated `shouldBe` False
                updateTx <- requireMember "update" updated
                entries <- concat <$> (mapM readJournal =<< journalDirs rig)
                (_, bodyOrWhy) <- boundBody entries updateTx
                tx <- either (fail . T.unpack) pure bodyOrWhy
                let inputs = toList (tx ^. bodyTxL . inputsTxBodyL)
                    collateral = toList (tx ^. bodyTxL . collateralInputsTxBodyL)
                inputs `shouldContain` [named]
                inputs `shouldNotContain` [natural]
                collateral `shouldBe` [named]
        it
            "an explicit choice naming an output that carries tokens is refused with today's text, not prepared around"
            $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
            $ \rig -> do
                (t, bundle) <- liveKeyRig rig
                plantTokenOutputs rig bundle 100_000_000 0
                walletBefore <- readTestWallet rig
                carrying <- case walletBefore of
                    [(i, _)] -> pure i
                    _ -> fail "the planted wallet is not exactly one output"
                stateBefore <- snapshotStateDir rig
                let choice = ["--fund-input", T.unpack (renderOutRef carrying)]
                    expected =
                        "the chosen funding output is not an ada-only output of the payer"
                            <> " for wallet "
                            <> previewAddr rig
                            <> " (client policy)"
                previewed <-
                    previewUpdateAs rig t "update preview, token-carrying choice" choice
                outcomeOf (runReceipt previewed) `shouldBe` Just "client-refusal"
                runCode previewed `shouldBe` ExitFailure 10
                reasonOf previewed `shouldBe` expected
                submittedOf previewed `shouldBe` False
                written <- updateAs rig t "update, token-carrying choice" choice
                outcomeOf (runReceipt written) `shouldBe` Just "client-refusal"
                runCode written `shouldBe` ExitFailure 10
                reasonOf written `shouldBe` expected
                submissionsOfRun written `shouldBe` Just []
                submittedOf written `shouldBe` False
                -- refused before the edge starts, as the old resolution did
                edgesStartedOf written `shouldBe` 0
                readTestWallet rig `shouldReturn` walletBefore
                snapshotStateDir rig `shouldReturn` stateBefore
        it
            "a funded wallet updates with no preparation, from the same output as before"
            $ with20AdaRig
            $ \rig -> do
                (t, _) <- liveKeyRig rig
                wallet <- readTestWallet rig
                natural <- case sortOn (Down . coinOf . snd) [u | u@(_, o) <- wallet, adaOnlyOut o] of
                    n : _ -> pure (fst n)
                    [] -> fail "the funded wallet holds no ada-only output"
                stateBefore <- snapshotStateDir rig
                previewed <- previewUpdateAs rig t "update preview, funded wallet" []
                outcomeOf (runReceipt previewed) `shouldBe` Just "success"
                hasMember "preparation" previewed `shouldBe` False
                submittedOf previewed `shouldBe` False
                snapshotStateDir rig `shouldReturn` stateBefore
                updated <- updateAs rig t "update, funded wallet" []
                (outcomeOf (runReceipt updated), reasonOf updated)
                    `shouldBe` (Just "success", "")
                runCode updated `shouldBe` ExitSuccess
                -- the instrument that counts started edges can see one
                edgesStartedOf updated `shouldBe` 1
                hasMember "preparation" updated `shouldBe` False
                updateTx <- requireMember "update" updated
                [ (s, txid)
                  | Trace _ (How (Tx TxSubmitted{submitStep = s, submitTxId = txid})) <-
                        runEvents updated
                  ]
                    `shouldBe` [("update", updateTx)]
                entries <- concat <$> (mapM readJournal =<< journalDirs rig)
                (_, bodyOrWhy) <- boundBody entries updateTx
                tx <- either (fail . T.unpack) pure bodyOrWhy
                toList (tx ^. bodyTxL . inputsTxBodyL) `shouldContain` [natural]
                toList (tx ^. bodyTxL . collateralInputsTxBodyL) `shouldBe` [natural]

{- | As Carol, my approvals of one registry sit in two outputs under the same
policy, each with little ada, and I hold no ada-only output. The update tells
me nothing is short and completes through ONE preparation that spends both
outputs: no single output can pay for it, and every approval is back in the
wallet afterwards, each name at the quantity it had.
-}
splitApprovalsRows :: Spec
splitApprovalsRows =
    describe "approvals in several outputs of one policy (#710)"
        $ it
            "an update from a wallet whose approvals sit in two outputs of one policy, with little ada, completes through one preparation that spends both"
        $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
        $ \rig -> do
            (t, policy, kinds) <- liveKeyRigKinds rig
            (a, b) <- case kinds of
                [x, y] -> pure (x, y)
                _ -> fail "the rehearsal names are not two"
            plantSplitTokenOutputs rig policy [(a, 3), (b, 5)] littleAda
            walletBefore <- readTestWallet rig
            length walletBefore `shouldBe` 2
            [() | (_, o) <- walletBefore, adaOnlyOut o] `shouldBe` []
            spendableHeld walletBefore `shouldBe` 2 * littleAda
            assetsOf walletBefore
                `shouldBe` Map.singleton policy (Map.fromList [(a, 3), (b, 5)])
            refsBefore <- referenceOutputs rig
            updated <-
                updateAs rig t "update, approvals in two outputs of one policy" []
            (outcomeOf (runReceipt updated), reasonOf updated)
                `shouldBe` (Just "success", "")
            (prepTx, _) <-
                expectCompletedThroughPreparation
                    "update"
                    "update"
                    rig
                    (walletAddr (rigTestWallet rig))
                    updated
            entries <- concat <$> (mapM readJournal =<< journalDirs rig)
            (_, prepBody) <- boundBody entries prepTx
            prep <- either (fail . T.unpack) pure prepBody
            map fst walletBefore
                `shouldSatisfy` all (`elem` toList (prep ^. bodyTxL . inputsTxBodyL))
            walletAfter <- readTestWallet rig
            assetsOf walletAfter `shouldBe` assetsOf walletBefore
            refsAfter <- referenceOutputs rig
            refsAfter `shouldBe` refsBefore

-- | Each output of a split wallet holds this much ada: little, and no single output covers an update's preparation.
littleAda :: Integer
littleAda = 2_300_000

{- | Replant the test wallet as one token-carrying output per given asset name
under one policy, each with the given quantity and this much ada; every
other output at the test wallet's address is deleted.
-}
plantSplitTokenOutputs
    :: Rig -> PolicyID -> [(AssetName, Integer)] -> Integer -> IO ()
plantSplitTokenOutputs rig policy named lovelace = do
    let addr = walletAddr (rigTestWallet rig)
        made =
            [ ( fundOutput (31 + i)
              , mkBasicTxOut
                    addr
                    ( MaryValue
                        (Coin lovelace)
                        (MultiAsset (Map.singleton policy (Map.singleton name quantity)))
                    )
              )
            | (i, (name, quantity)) <- zip [0 ..] named
            ]
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.union
                    (Map.fromList made)
                    (Map.filter ((/= addr) . (^. addrTxOutL)) (csUTxO facts))
            }

{- | As Alice, my wallet holds two approval kinds at quantities above one,
spread over three outputs under one policy (the first kind in two of them),
beside my ada, and no ada-only output. A command that prepares its own
funding output spends what it must of them and leaves every approval in the
wallet at the quantity it had: each kind's total is the same before and after,
and the kinds' quantities differ, so a swap, a sum of the two kinds or a
reset to one shows.
-}
approvalsAboveOneRows :: Spec
approvalsAboveOneRows =
    describe
        "approval tokens above quantity one, over several outputs, stay exact across a preparation (#491 part 3)"
        $ do
            it
                "an insert from a wallet holding two kinds above quantity one over three outputs"
                $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
                $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    outcomeOf (runReceipt create) `shouldBe` Just "success"
                    t <- tokenOf create
                    (policy, kinds) <- rehearsalKindsOf create
                    plantSplitTokenOutputs rig policy (spreadOver kinds) bookingOutputAda
                    walletBefore <- readTestWallet rig
                    expectKindsAboveOne walletBefore
                    inserted <-
                        runWithKey
                            (rigTestKey rig)
                            rig
                            "insert, quantities above one"
                            ( [ "open-datum"
                              , "insert"
                              , "--key"
                              , "bob-1"
                              , "--payload"
                              , rigDir rig </> "payload.json"
                              ]
                                <> tokenArgs t
                            )
                    (outcomeOf (runReceipt inserted), reasonOf inserted)
                        `shouldBe` (Just "success", "")
                    (prepTx, _) <-
                        expectBookedThroughPreparation
                            rig
                            (walletAddr (rigTestWallet rig))
                            inserted
                    expectSeveralSpent rig prepTx
                    walletAfter <- readTestWallet rig
                    assetsOf walletAfter `shouldBe` assetsOf walletBefore
            it
                "a terminate from a wallet holding two kinds above quantity one over three outputs"
                $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
                $ \rig -> do
                    (t, policy, kinds) <- liveKeyRigKinds rig
                    plantSplitTokenOutputs rig policy (spreadOver kinds) bookingOutputAda
                    walletBefore <- readTestWallet rig
                    expectKindsAboveOne walletBefore
                    terminated <-
                        runWithKey
                            (rigTestKey rig)
                            rig
                            "terminate, quantities above one"
                            (["open-datum", "terminate", "--key", "alice-1"] <> tokenArgs t)
                    (outcomeOf (runReceipt terminated), reasonOf terminated)
                        `shouldBe` (Just "success", "")
                    (prepTx, _) <-
                        expectBookedThroughPreparation
                            rig
                            (walletAddr (rigTestWallet rig))
                            terminated
                    expectSeveralSpent rig prepTx
                    walletAfter <- readTestWallet rig
                    assetsOf walletAfter `shouldBe` assetsOf walletBefore
            it
                "an update from a wallet holding two kinds above quantity one over three outputs"
                $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
                $ \rig -> do
                    (t, policy, kinds) <- liveKeyRigKinds rig
                    plantSplitTokenOutputs rig policy (spreadOver kinds) littleAda
                    walletBefore <- readTestWallet rig
                    expectKindsAboveOne walletBefore
                    updated <- updateAs rig t "update, quantities above one" []
                    (prepTx, _) <-
                        expectCompletedThroughPreparation
                            "update"
                            "update"
                            rig
                            (walletAddr (rigTestWallet rig))
                            updated
                    expectSeveralSpent rig prepTx
                    walletAfter <- readTestWallet rig
                    assetsOf walletAfter `shouldBe` assetsOf walletBefore
            it
                "the quantity check refuses a wallet holding one of each kind, the same quantity of both, or everything in one output"
                $ withFundedRig [(11, 100_000_000), (12, 100_000_000)]
                $ \rig -> do
                    seed <- fundSeed rig
                    create <- run rig "create" ["open-datum", "create", "--seed", seed]
                    outcomeOf (runReceipt create) `shouldBe` Just "success"
                    (policy, kinds) <- rehearsalKindsOf create
                    (a, b) <- case kinds of
                        [x, y] -> pure (x, y)
                        _ -> fail "the rehearsal names are not two"
                    forM_
                        [ [(a, 1), (b, 1), (a, 1)]
                        , [(a, 4), (b, 4)]
                        ]
                        $ \named -> do
                            plantSplitTokenOutputs rig policy named littleAda
                            held <- readTestWallet rig
                            expectKindsAboveOne held `shouldThrow` anyException
                    plantTokenOutputs
                        rig
                        (Map.singleton policy (Map.fromList [(a, 3), (b, 5)]))
                        littleAda
                        0
                    alone <- readTestWallet rig
                    expectKindsAboveOne alone `shouldThrow` anyException

-- | Three of the first kind in one output and one in another, five of the second: totals four and five.
spreadOver :: [AssetName] -> [(AssetName, Integer)]
spreadOver kinds = case kinds of
    [a, b] -> [(a, 3), (b, 5), (a, 1)]
    _ -> error "spreadOver: the rehearsal names are not two"

{- | What each of three outputs holds for a booking: together they cover the
fold reserve and the outlay the booking is judged on, and apart none covers
the preparation of an insert or a terminate (each needs more than this alone),
so the preparation must spend several of them.
-}
bookingOutputAda :: Integer
bookingOutputAda = 5_000_000

{- | What the wallet read through the provider holds: more than one kind,
each kind's total above one and no two alike, over more than one output. The
fixture sets them; the row reads them back, so an unplanted or collapsed
wallet fails here.
-}
expectKindsAboveOne :: [(TxIn, TxOut ConwayEra)] -> Expectation
expectKindsAboveOne wallet = do
    let totals = concatMap Map.elems (Map.elems (assetsOf wallet))
    length totals `shouldSatisfy` (> 1)
    all (> 1) totals `shouldBe` True
    length (nub totals) `shouldBe` length totals
    length
        [ () | (i, o) <- wallet, not (Map.null (assetsOf [(i, o)]))
        ]
        `shouldSatisfy` (> 1)

{- | The preparation spent more than one output: no single output of the
wallet could pay for it, which is what makes the tokens' spread over outputs
matter.
-}
expectSeveralSpent :: Rig -> Text -> Expectation
expectSeveralSpent rig prepTx = do
    entries <- concat <$> (mapM readJournal =<< journalDirs rig)
    (_, bodyOrWhy) <- boundBody entries prepTx
    prep <- either (fail . T.unpack) pure bodyOrWhy
    length (prep ^. bodyTxL . inputsTxBodyL)
        `shouldSatisfy` (> 1)

-- | How many edges a run's trace reports started.
edgesStartedOf :: Run -> Int
edgesStartedOf r = length [() | Trace _ (What (EdgeStarted _)) <- runEvents r]

-- | The lovelace an output holds.
coinOf :: TxOut ConwayEra -> Integer
coinOf o = let Coin c = o ^. coinTxOutL in c

{- | A registry holding one live key, @alice-1@: inserted from the test
wallet as the rig funds it and folded, so the test wallet may update it.
Returns the state token and the approval bundle the test wallet is later
made to hold.
-}
liveKeyRig
    :: Rig -> IO (String, Map.Map PolicyID (Map.Map AssetName Integer))
liveKeyRig rig = do
    (t, policy, kinds) <- liveKeyRigKinds rig
    pure (t, singleKindBundle policy kinds)

-- | The same registry, with the policy and the names of its approval kinds.
liveKeyRigKinds :: Rig -> IO (String, PolicyID, [AssetName])
liveKeyRigKinds rig = do
    seed <- fundSeed rig
    create <- run rig "create" ["open-datum", "create", "--seed", seed]
    outcomeOf (runReceipt create) `shouldBe` Just "success"
    t <- tokenOf create
    (policy, kinds) <- rehearsalKindsOf create
    inserted <-
        runWithKey
            (rigTestKey rig)
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
    outcomeOf (runReceipt inserted) `shouldBe` Just "success"
    folded <-
        run
            rig
            "fold alice-1"
            (["open-datum", "fold"] <> requestOf inserted <> tokenArgs t)
    outcomeOf (runReceipt folded) `shouldBe` Just "success"
    pure (t, policy, kinds)

-- | The update of @alice-1@ to the second payload, with these further flags.
updateWords :: Rig -> String -> [String] -> [String]
updateWords rig t extra =
    [ "open-datum"
    , "update"
    , "--key"
    , "alice-1"
    , "--payload"
    , rigDir rig </> "payload-2.json"
    ]
        <> extra
        <> tokenArgs t

-- | The update signed by the test wallet's key file.
updateAs :: Rig -> String -> String -> [String] -> IO Run
updateAs rig t label extra =
    runWithKey (rigTestKey rig) rig label (updateWords rig t extra)

-- | The preview of the update for the test wallet's address.
previewUpdateAs :: Rig -> String -> String -> [String] -> IO Run
previewUpdateAs rig t label extra =
    run
        rig
        label
        ( updateWords rig t extra
            <> ["--preview", "--wallet-address", previewAddr rig]
        )

-- | A top-level receipt member, if present and whatever it holds.
valueOfRun :: Aeson.Key -> Run -> Maybe Aeson.Value
valueOfRun k r = case runReceipt r of
    Aeson.Object o -> KeyMap.lookup k o
    _ -> Nothing

-- | Whether the receipt has this top-level member at all (null counts).
hasMember :: Aeson.Key -> Run -> Bool
hasMember k r = isJust (valueOfRun k r)

-- | A top-level text member the row requires.
requireMember :: Aeson.Key -> Run -> IO Text
requireMember k r = case textAt k (runReceipt r) of
    Just v -> pure v
    Nothing -> fail ("no " <> show k <> " member in " <> runLabel r)

decodeJsonFile :: FilePath -> IO Aeson.Value
decodeJsonFile path =
    Aeson.eitherDecodeFileStrict' path >>= either fail pure

-- | The total of the outlay a receipt reports, required present.
outlayTotalOf :: Run -> IO Integer
outlayTotalOf r = case valueOfRun "outlay" r of
    Just (Aeson.Object o) | Just n <- numberAt "total" o -> pure n
    _ -> fail ("no outlay total in " <> runLabel r)

-- | The inputs a preview's update body lists, as output references.
updateInputsOf :: Run -> IO [Text]
updateInputsOf r = case valueOfRun "update" r of
    Just (Aeson.Object o)
        | Just (Aeson.Array xs) <- KeyMap.lookup "inputs" o ->
            pure [x | Aeson.String x <- toList xs]
    _ -> fail ("no update inputs in " <> runLabel r)

{- | A refusal for a wallet that cannot pay for the command and its
preparation: client policy, exit 10, the seam's text built from the figures
the receipt carries, ending that nothing was submitted, and neither the
faucet sentence (the wallet is not empty) nor a hand step. Returns the
held, required, shortfall, fee and remainder floor, all required present.
-}
expectPreparationUnfunded
    :: Integer -> Run -> IO (Integer, Integer, Integer, Integer, Integer)
expectPreparationUnfunded planted r = do
    outcomeOf (runReceipt r) `shouldBe` Just "client-refusal"
    runCode r `shouldBe` ExitFailure 10
    held <- requireNumberOf "held" r
    needed <- requireNumberOf "required" r
    shortfall <- requireNumberOf "shortfall" r
    fee <- requireNumberOf "fee" r
    remainder <- requireNumberOf "remainderMin" r
    held `shouldBe` planted
    needed `shouldSatisfy` (> held)
    shortfall `shouldBe` needed - held
    reasonOf r
        `shouldBe` ( "preparation-unfunded: the wallet holds "
                        <> show held
                        <> " lovelace but "
                        <> show needed
                        <> " is required for the preparation ("
                        <> show (needed - fee - remainder)
                        <> " for the command, "
                        <> show fee
                        <> " fee and "
                        <> show remainder
                        <> " remainder floor) (client policy); nothing was submitted"
                   )
    walletOfRun r `shouldSatisfy` isJust
    pure (held, needed, shortfall, fee, remainder)

-- ---------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------

-- The retained faucet sentence, pinned exactly as the base's `Plan.hs` text
-- (A-007: keep the faucet sentence, drop only the self-payment sentence).
-- Frozen literal of `"Fund this address, then rerun. On preprod the faucet
-- is https://docs.cardano.org/cardano-testnets/tools/faucet."`.
retainedFaucet :: String
retainedFaucet =
    "Fund this address, then rerun. On preprod the faucet is "
        <> "https://docs.cardano.org/cardano-testnets/tools/faucet."

isSuffixOf :: String -> String -> Bool
isSuffixOf suffix whole = reverse suffix `isPrefixOf` reverse whole
  where
    isPrefixOf [] _ = True
    isPrefixOf _ [] = False
    isPrefixOf (x : xs) (y : ys) = x == y && isPrefixOf xs ys

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (fail . show) pure

isLeftWithEmpty :: Either String a -> Bool
isLeftWithEmpty = \case
    Left _ -> True
    Right _ -> False

-- ---------------------------------------------------------
-- The rig
-- ---------------------------------------------------------

data Rig = Rig
    { rigDir :: FilePath
    , rigChain :: RawChain
    , rigKey :: FilePath
    , rigTestWallet :: Wallet
    , rigTestKey :: FilePath
    , rigBlueprint :: FilePath
    , rigEvents :: IORef [Trace]
    , rigAnswer :: IORef (Maybe Cage.SubmitResult)
    , rigTracer :: Tracer IO Trace
    }

data Run = Run
    { runLabel :: String
    , runReceipt :: Aeson.Value
    , runEvents :: [Trace]
    , runCode :: ExitCode
    , runRefsBefore :: Map.Map TxIn (TxOut ConwayEra)
    -- ^ The published reference outputs of the creator, read before the command ran
    , runRefsAfter :: Map.Map TxIn (TxOut ConwayEra)
    -- ^ The same, read once it had finished
    }

magic :: Integer
magic = 42

fundOutput :: Int -> TxIn
fundOutput n =
    either
        (error . ("fundOutput: " <>))
        id
        (parseOutRef (T.pack (replicate 64 'f' <> "#" <> show n)))

with20AdaRig :: (Rig -> IO a) -> IO a
with20AdaRig = withFundedRig [(11, 10_000_000), (12, 10_000_000)]

withBetweenRig :: (Rig -> IO a) -> IO a
withBetweenRig = withFundedRig [(11, 5_000_000), (12, 500_000)]

withFundedRig :: [(Int, Integer)] -> (Rig -> IO a) -> IO a
withFundedRig funds use =
    withSystemTempDirectory "wallet-shortfall" $ \dir ->
        withRigIn dir funds syntheticBlueprint pure use

withRigIn
    :: FilePath
    -> [(Int, Integer)]
    -> Aeson.Value
    -> (Tracer IO Trace -> IO (Tracer IO Trace))
    -> (Rig -> IO a)
    -> IO a
withRigIn dir funds blueprintJson compose use = do
    let keyPath = dir </> "payment.skey"
        testKeyPath = dir </> "test.skey"
        blueprint = dir </> "plutus.json"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    BS.writeFile testKeyPath (B16.encode (BC.replicate 32 'a'))
    BL.writeFile blueprint (Aeson.encode blueprintJson)
    BL.writeFile
        (dir </> "payload.json")
        (Aeson.encode (Aeson.object ["int" .= (7 :: Int)]))
    BL.writeFile
        (dir </> "payload-2.json")
        (Aeson.encode (Aeson.object ["int" .= (8 :: Int)]))
    wallet <- loadWallet (fromIntegral magic) keyPath
    testWallet <- loadWallet (fromIntegral magic) testKeyPath
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = fromIntegral magic
                , csTip = Nothing
                , csPParams = withSyntheticCosts preprodParams
                , csUTxO =
                    Map.fromList $
                        [ ( fundOutput n
                          , mkBasicTxOut
                                (walletAddr wallet)
                                (MaryValue (Coin 2_000_000_000) mempty)
                          )
                        | n <- [1 .. 6]
                        ]
                            <> [ ( fundOutput n
                                 , mkBasicTxOut
                                    (walletAddr testWallet)
                                    (MaryValue (Coin c) mempty)
                                 )
                               | (n, c) <- funds
                               ]
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    advanceChain chain id
    events <- newIORef []
    answer <- newIORef Nothing
    tracer <- compose (Tracer (\t -> modifyIORef' events (<> [t])))
    use
        ( Rig
            dir
            chain
            keyPath
            testWallet
            testKeyPath
            blueprint
            events
            answer
            tracer
        )

syntheticBlueprint :: Aeson.Value
syntheticBlueprint = blueprintOf (const unitProgram)

blueprintOf :: (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintOf program =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= [ validator "state.state" 1
               , validator "request.request" 3
               , validator "open_datum.open_datum" 2
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

envOf :: Rig -> Env
envOf rig =
    Env
        { envTracer = rigTracer rig
        , envSource = "fixture"
        , envLoadRelease = loadReleaseCodes
        , envReads = \_ k -> k (capabilities rig)
        , envWrites = \_ k -> k (capabilities rig)
        }

capabilities :: Rig -> Capabilities NoWitness IO
capabilities rig =
    Capabilities
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
            in  (network, observeProvider unverifiedVerifier (\_ -> pure ()) provider)
        , capSubmit = \signed -> do
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

fundSeed :: Rig -> IO String
fundSeed _ = pure (T.unpack (renderOutRef (fundOutput 1)))

previewAddr :: Rig -> String
previewAddr rig = bech32Address (walletAddr (rigTestWallet rig))

tokenOf :: Run -> IO String
tokenOf r = case textAt "stateToken" (runReceipt r) of
    Just t -> pure (T.unpack t)
    Nothing -> fail ("no state token in " <> runLabel r)

tokenArgs :: String -> [String]
tokenArgs t = ["--state-token", t]

requestOf :: Run -> [String]
requestOf r =
    maybe
        []
        (\q -> ["--request", T.unpack q])
        (textAt "request" (runReceipt r))

run :: Rig -> String -> [String] -> IO Run
run rig = runAt rig "registry"

runAt :: Rig -> FilePath -> String -> [String] -> IO Run
runAt rig = runVia rig (envOf rig)

runVia :: Rig -> Env -> FilePath -> String -> [String] -> IO Run
runVia rig env registry label args = do
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . show)
            pure
            (parseOpenDatumCommand (commandLine rig registry args))
    refsBefore <- referenceOutputs rig
    (code, out, _) <- captured (runOpenDatum env command)
    refsAfter <- referenceOutputs rig
    receipt <-
        maybe
            (fail ("no receipt for " <> label <> ": " <> show out))
            pure
            (Aeson.decodeStrict out)
    events <- readIORef (rigEvents rig)
    pure
        Run
            { runLabel = label
            , runReceipt = receipt
            , runEvents = events
            , runCode = code
            , runRefsBefore = refsBefore
            , runRefsAfter = refsAfter
            }

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
    wantsKey =
        take 2 args /= ["open-datum", "inspect"]
            && "--preview" `notElem` args
            && "--wallet-skey" `notElem` args

runWithKey :: FilePath -> Rig -> String -> [String] -> IO Run
runWithKey keyPath rig label args =
    runAt rig "registry" label (args <> ["--wallet-skey", keyPath])

emptyWalletKey :: Rig -> IO FilePath
emptyWalletKey rig = do
    let path = rigDir rig </> "empty.skey"
    BS.writeFile path (B16.encode (BC.replicate 32 'e'))
    pure path

emptyTestWalletOutputs :: Rig -> IO ()
emptyTestWalletOutputs rig =
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.filter
                    (\out -> out ^. addrTxOutL /= walletAddr (rigTestWallet rig))
                    (csUTxO facts)
            }

captured :: IO a -> IO (a, BS.ByteString, BS.ByteString)
captured act = withSystemTempDirectory "wallet-shortfall-captured" $ \dir -> do
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

outcomeOf :: Aeson.Value -> Maybe Text
outcomeOf = textAt "outcome"

reasonOf :: Run -> String
reasonOf r = maybe "" T.unpack (textAt "reason" (runReceipt r))

textAt :: Aeson.Key -> Aeson.Value -> Maybe Text
textAt k = \case
    Aeson.Object o | Just (Aeson.String t) <- KeyMap.lookup k o -> Just t
    _ -> Nothing

figuresOf :: Run -> Maybe (Integer, Integer, Integer)
figuresOf r = do
    o <- findObjectWith (runReceipt r)
    held <- numberAt "held" o
    required <- numberAt "required" o
    shortfall <- numberAt "shortfall" o
    pure (held, required, shortfall)

walletOfRun :: Run -> Maybe Text
walletOfRun r = do
    o <- findObjectWith (runReceipt r)
    textIn "wallet" o

countOfRun :: Run -> Maybe Integer
countOfRun r = do
    o <- findObjectWith (runReceipt r)
    numberAt "utxoCount" o

heldOfRun :: Run -> Maybe Integer
heldOfRun r = do
    o <- findObjectWith (runReceipt r)
    numberAt "held" o

numberOfRun :: Aeson.Key -> Run -> Maybe Integer
numberOfRun k r = numberAt k =<< findObjectWith (runReceipt r)

{- | A refusal's numeric figure, required present: a missing or null
member fails the row rather than comparing two nothings.
-}
requireNumberOf :: Aeson.Key -> Run -> IO Integer
requireNumberOf k r = case numberOfRun k r of
    Just n -> pure n
    Nothing -> fail ("no " <> show k <> " figure in " <> runLabel r)

-- | The refusal's held, required and shortfall, all required present.
figuresPresentOf :: Run -> IO (Integer, Integer, Integer)
figuresPresentOf r = do
    held <- requireNumberOf "held" r
    required <- requireNumberOf "required" r
    shortfall <- requireNumberOf "shortfall" r
    pure (held, required, shortfall)

{- | The @submissions@ member of a receipt, present and typed: a refusal
that submits nothing carries an empty list, never an absent member.
-}
submissionsOfRun :: Run -> Maybe [Aeson.Value]
submissionsOfRun r = case runReceipt r of
    Aeson.Object o -> case KeyMap.lookup "submissions" o of
        Just (Aeson.Array a) -> Just (toList a)
        _ -> Nothing
    _ -> Nothing

{- | The preparation a completing command made: its funding lovelace and
fee, typed from the receipt, with the shape members present. The funding
output holds exactly the requirement, so its lovelace is the measured
requirement of this rig.
-}
preparationFiguresOf :: Run -> IO (Integer, Integer)
preparationFiguresOf r = case runReceipt r of
    Aeson.Object o -> case KeyMap.lookup "preparation" o of
        Just (Aeson.Object p)
            | KeyMap.member "transaction" p
            , KeyMap.member "output" p ->
                case (KeyMap.lookup "lovelace" p, KeyMap.lookup "fee" p) of
                    (Just (Aeson.Number l), Just (Aeson.Number f)) ->
                        pure (round l, round f)
                    _ ->
                        fail
                            ( "preparation figures are not numbers in "
                                <> runLabel r
                            )
        _ -> fail ("no preparation object in " <> runLabel r)
    _ -> fail ("no preparation member in " <> runLabel r)

{- | The registry's policy (parsed from the create receipt's state token)
and two approval names under it, neither the state token's own name: a
wallet must not hold the state token itself — a preparation that returned
it would touch the registry's token outside its lineage and stale every
later replay. The wallet holds both names on one output, each at
quantity 1 (the rehearsal shape of pull request 1).
-}
rehearsalKindsOf :: Run -> IO (PolicyID, [AssetName])
rehearsalKindsOf r = case textAt "stateToken" (runReceipt r) of
    Just t ->
        either
            (fail . T.unpack)
            ( \(policy, AssetName stateName) -> do
                let names =
                        [ AssetName (SBS.toShort (BC.pack "approval-one"))
                        , AssetName (SBS.toShort (BC.pack "beside-ada"))
                        ]
                when (any (\(AssetName n) -> n == stateName) names) $
                    fail "rehearsal names collide with the state token name"
                pure (policy, names)
            )
            (parseStateToken t)
    Nothing -> fail ("no state token in " <> runLabel r)

{- | One output's bundle: the given names under the policy, each at
quantity 1.
-}
singleKindBundle
    :: PolicyID
    -> [AssetName]
    -> Map.Map PolicyID (Map.Map AssetName Integer)
singleKindBundle policy names =
    Map.singleton policy (Map.fromList [(name, 1) | name <- names])

-- | Every output at the test wallet's address, read at run time.
readTestWallet :: Rig -> IO [(TxIn, TxOut ConwayEra)]
readTestWallet rig =
    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
        SessionIO.outputsAt v (walletAddr (rigTestWallet rig))

{- | Replant the test wallet as exactly one token-carrying output holding
the bundle beside the given lovelace, on a fresh output reference for
this planting round; every other output at the test wallet's address is
deleted, so the wallet is token-only whose spendable lovelace is the
total.
-}
plantTokenOutputs
    :: Rig
    -> Map.Map PolicyID (Map.Map AssetName Integer)
    -> Integer
    -> Int
    -> IO ()
plantTokenOutputs rig bundle lovelace round_ = do
    let addr = walletAddr (rigTestWallet rig)
        made = mkBasicTxOut addr (MaryValue (Coin lovelace) (MultiAsset bundle))
        ref = fundOutput (21 + round_)
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.insert
                    ref
                    made
                    (Map.filter ((/= addr) . (^. addrTxOutL)) (csUTxO facts))
            }

{- | Every file under the state directory with its bytes: a refusal that
submits nothing must leave it byte-identical, journal and all.
-}
snapshotStateDir :: Rig -> IO [(FilePath, BS.ByteString)]
snapshotStateDir rig = walk (rigDir rig </> "registry")
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
                    pure [(makeRelative (rigDir rig) p, bytes)]

{- | The directories holding a journal under the state directory: one
managed partition per wallet that wrote here.
-}
journalDirs :: Rig -> IO [FilePath]
journalDirs rig = walk (rigDir rig </> "registry")
  where
    walk dir = do
        names <- sort <$> listDirectory dir
        fmap concat (mapM one names)
      where
        one n = do
            let p = dir </> n
            isDir <- doesDirectoryExist p
            if isDir then walk p else pure [dir | n == "journal.jsonl"]

{- | Every published reference output at the creator's address, by its
input: the references a booking must never spend. Read through the
provider at run time.
-}
referenceOutputs :: Rig -> IO (Map.Map TxIn (TxOut ConwayEra))
referenceOutputs rig = do
    creator <- loadWallet (fromIntegral magic) (rigKey rig)
    outs <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v (walletAddr creator)
    pure
        ( Map.fromList
            [u | u@(_, o) <- outs, o ^. referenceScriptTxOutL /= SNothing]
        )

-- | The non-ada assets a wallet holds, summed over its outputs.
assetsOf
    :: [(TxIn, TxOut ConwayEra)]
    -> Map.Map PolicyID (Map.Map AssetName Integer)
assetsOf = foldr step mempty
  where
    step (_, o) acc = case o ^. valueTxOutL of
        MaryValue _ (MultiAsset m) -> Map.unionWith (Map.unionWith (+)) m acc

{- | The preparation a completing command made, typed from its receipt:
the transaction identifier, the made output reference, the lovelace of
the funding output and the fee.
-}
preparationMembersOf :: Run -> IO (Text, Text, Integer, Integer)
preparationMembersOf r = case runReceipt r of
    Aeson.Object o -> case KeyMap.lookup "preparation" o of
        Just (Aeson.Object p) ->
            case (KeyMap.lookup "transaction" p, KeyMap.lookup "output" p) of
                (Just (Aeson.String tx), Just (Aeson.String out)) ->
                    case (KeyMap.lookup "lovelace" p, KeyMap.lookup "fee" p) of
                        (Just (Aeson.Number l), Just (Aeson.Number f)) ->
                            pure (tx, out, round l, round f)
                        _ -> fail ("preparation figures are not numbers in " <> runLabel r)
                _ -> fail ("preparation members are not strings in " <> runLabel r)
        _ -> fail ("no preparation object in " <> runLabel r)
    _ -> fail ("no preparation member in " <> runLabel r)

-- | The saved body path a transaction's prepared journal line names.
preparedBodyOf :: [JournalEntry] -> Text -> Maybe FilePath
preparedBodyOf entries txid =
    listToMaybe
        [ p
        | e <- entries
        , journalTxId e == txid
        , journalEvent e == "prepared"
        , Just p <- [journalBody e]
        ]

{- | What every command that completed through one preparation must show:
the receipt's typed preparation member; exactly two submitted transactions
for the command, both under the command's step — the preparation then the
command's own transaction, named by the receipt member given; the
preparation's journal phases in order with the @funding@ expectation
naming the payer; and the command's own prepared journal line listing the
made output among its inputs, read from the journal the submission wrote,
not the receipt; that body's collateral is exactly the made output, which
the preparation's own body shows ada only at the lovelace the receipt
reports; and the creator's published reference outputs are, by input and
value, what they were before the command ran. Returns the preparation's
transaction and made output.
-}
expectCompletedThroughPreparation
    :: Text -> Text -> Rig -> Addr -> Run -> IO (Text, Text)
expectCompletedThroughPreparation commandStep member rig payerOfRun r = do
    outcomeOf (runReceipt r) `shouldBe` Just "success"
    runCode r `shouldBe` ExitSuccess
    -- the creator's published reference outputs, by input and whole value,
    -- are what they were before the command ran and are not an empty census
    Map.null (runRefsBefore r) `shouldBe` False
    runRefsAfter r `shouldBe` runRefsBefore r
    (prepTx, prepOut, prepLovelace, prepFeeFig) <- preparationMembersOf r
    prepLovelace `shouldSatisfy` (> 0)
    prepFeeFig `shouldSatisfy` (> 0)
    T.length prepTx `shouldBe` 64
    prepTx `T.isPrefixOf` prepOut `shouldBe` True
    commandTx <- case textAt (Key.fromText member) (runReceipt r) of
        Just b -> pure b
        Nothing -> fail ("no " <> T.unpack member <> " member in " <> runLabel r)
    let submitted =
            [ (s, txid)
            | Trace _ (How (Tx TxSubmitted{submitStep = s, submitTxId = txid})) <-
                runEvents r
            ]
    submitted `shouldBe` [(commandStep, prepTx), (commandStep, commandTx)]
    entries <- concat <$> (mapM readJournal =<< journalDirs rig)
    let phases = [journalEvent e | e <- entries, journalTxId e == prepTx]
    phases `shouldBe` ["prepared", "submitted", "confirmed", "observed"]
    let expects =
            [ journalExpect e
            | e <- entries
            , journalTxId e == prepTx
            , journalEvent e == "prepared"
            ]
    expects
        `shouldBe` [Just ("funding:" <> T.pack (bech32Address payerOfRun))]
    let commandInputs =
            [ journalInputs e
            | e <- entries
            , journalTxId e == commandTx
            , journalEvent e == "prepared"
            ]
    -- the SUBMITTED command body, bound to its prepared line by byte hash
    -- and derived id: the made output is among the inputs it decodes with
    (mPreparedLine, bodyOrWhy) <- boundBody entries commandTx
    case bodyOrWhy of
        Left why -> fail ("the command's saved body does not bind: " <> T.unpack why)
        Right tx -> do
            map txInText (toList (tx ^. bodyTxL . inputsTxBodyL))
                `shouldContain` [prepOut]
            -- the collateral is the made output and nothing else: a ledger
            -- refuses collateral that carries tokens, and the fixture's
            -- submission accepts any body
            map txInText (toList (tx ^. bodyTxL . collateralInputsTxBodyL))
                `shouldBe` [prepOut]
    -- the made output itself, read from the preparation's own saved body:
    -- ada only, holding the lovelace the receipt reports
    (_, prepBodyOrWhy) <- boundBody entries prepTx
    prepBody <-
        either
            (fail . ("the preparation's saved body does not bind: " <>) . T.unpack)
            pure
            prepBodyOrWhy
    madeIndex <- case parseOutRef prepOut of
        Right (TxIn _ (TxIx ix)) -> pure (fromIntegral ix :: Int)
        Left why -> fail ("the made output does not parse: " <> why)
    case drop madeIndex (toList (prepBody ^. bodyTxL . outputsTxBodyL)) of
        made : _ -> do
            adaOnlyOut made `shouldBe` True
            coinOf made `shouldBe` prepLovelace
        [] -> fail ("the preparation made no output " <> T.unpack prepOut)
    -- the journal's own list of the command's inputs agrees (second observation)
    case commandInputs of
        [Just ins] -> ins `shouldContain` [prepOut]
        _ ->
            fail
                ("the command's prepared journal line is missing in " <> runLabel r)
    -- negative control: a SUBSTITUTED saved body — another transaction's
    -- bytes over the command's file — is rejected, and the restored body
    -- binds again
    case (journalBody =<< mPreparedLine, preparedBodyOf entries prepTx) of
        (Just commandPath, Just preparationPath) -> do
            original <- BS.readFile commandPath
            substitutedBytes <- BS.readFile preparationPath
            BS.writeFile commandPath substitutedBytes
            (_, substituted) <- boundBody entries commandTx
            case substituted of
                Left _ -> pure ()
                Right _ ->
                    fail
                        ( "a substituted saved command body was accepted in "
                            <> runLabel r
                        )
            BS.writeFile commandPath original
            (_, restored) <- boundBody entries commandTx
            case restored of
                Right _ -> pure ()
                Left why ->
                    fail ("the restored body no longer binds: " <> T.unpack why)
        _ -> fail ("the bodies are not recorded in " <> runLabel r)
    pure (prepTx, prepOut)

-- | A booking that completed through one preparation, under the step @book@.
expectBookedThroughPreparation
    :: Rig -> Addr -> Run -> IO (Text, Text)
expectBookedThroughPreparation =
    expectCompletedThroughPreparation "book" "booking"

policyOfRun :: Run -> Maybe Text
policyOfRun r = do
    o <- findObjectWith (runReceipt r)
    textIn "policy" o

textIn :: Aeson.Key -> Aeson.Object -> Maybe Text
textIn k o = case KeyMap.lookup k o of
    Just (Aeson.String s) -> Just s
    _ -> Nothing

findObjectWith :: Aeson.Value -> Maybe Aeson.Object
findObjectWith = \case
    Aeson.Object o | KeyMap.member "held" o -> Just o
    Aeson.Object o ->
        foldr ((<|>) . findObjectWith) Nothing (KeyMap.elems o)
    Aeson.Array xs -> foldr ((<|>) . findObjectWith) Nothing xs
    _ -> Nothing

numberAt :: Aeson.Key -> Aeson.Object -> Maybe Integer
numberAt k o = case KeyMap.lookup k o of
    Just (Aeson.Number n) -> Just (round n)
    _ -> Nothing

allPresent :: Maybe (Integer, Integer, Integer) -> Bool
allPresent = isJust

submittedOf :: Run -> Bool
submittedOf r = any isSubmitted (runEvents r)
  where
    isSubmitted = \case
        Trace _ (How (Tx TxSubmitted{})) -> True
        Trace _ (How (Tx (TxSigned{}))) -> True
        _ -> False

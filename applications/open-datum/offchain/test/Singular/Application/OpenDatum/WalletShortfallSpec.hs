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
import Control.Tracer (Tracer (..), nullTracer)
import Data.Aeson qualified as Aeson
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
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
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

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Data.Aeson ((.=))
import Singular.Application.OpenDatum.Command (parseOpenDatumCommand)
import Singular.Application.OpenDatum.Run (runOpenDatum)
import Singular.CLI.Outlay (walletShortfall)
import Singular.CLI.Plan
    ( faucetStep
    , refuseUnderfunded
    , retainedFaucetStep
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (loadReleaseCodes)
import Singular.CLI.Session (CommandFailure (..), Env (..))
import Singular.CLI.Trace
    ( Event (..)
    , How (..)
    , Trace (..)
    , TxEvent (..)
    )
import Singular.Provider.Koios.FakeServer qualified as Fake
import Singular.Provider.Koios.Recorded (loadFixtureSet)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger (Coin (..))
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
import Singular.Registry.Signing (signedTx)
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
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
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
            `shouldSatisfy` isInfixOf faucetStep
        policyOfRun emptyUpdate `shouldBe` Just "client"
        walletOfRun emptyUpdate `shouldBe` Just (T.pack (previewAddr rig))
        countOfRun emptyUpdate `shouldSatisfy` isJust
        selectFunding Nothing [] `shouldSatisfy` isLeftWithEmpty
        selectFunding (Just (fundOutput 99)) []
            `shouldSatisfy` isLeftWithEmpty
    it "refuses a foreign funding output before building" $ with20AdaRig $ \rig -> do
        -- Pinned exact old wording (base `Plan.hs` resolveFunding foreign branch, no prefix,
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
            `shouldSatisfy` (not . isInfixOf faucetStep)
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
    it
        "insert write from an empty wallet names the faucet without the hand step (#491 PR2 RED)"
        $ with20AdaRig
        $ \rig -> do
            seed <- fundSeed rig
            create <- run rig "create" ["open-datum", "create", "--seed", seed]
            t <- tokenOf create
            emptyKey <- emptyWalletKey rig
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
    it "opens a write session for 20 ada in two outputs with no threshold" $ do
        withSystemTempDirectory "wallet-floor-open" $ \dir -> do
            let keyPath = dir </> "payment.skey"
            BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
            wallet <- loadWallet 1 keyPath
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
                            wallet
                        $ \_ ->
                            writeIORef ran True
                readIORef ran `shouldReturn` True

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
        , envWrites = \_ _ k -> k (capabilities rig)
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
    (code, out, _) <- captured (runOpenDatum env command)
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

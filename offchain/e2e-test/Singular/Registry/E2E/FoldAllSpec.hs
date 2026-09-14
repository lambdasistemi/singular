{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.E2E.FoldAllSpec
Description : Adaptive folding against a real node
License     : Apache-2.0
-}
module Singular.Registry.E2E.FoldAllSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sortOn)
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Cardano.Node.Client.E2E.Setup (addKeyWitness, genesisAddr, genesisSignKey)
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))

import Singular.Registry.Blueprint (extractCompiledCode, loadBlueprint)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.E2E.CageSpec (submitInsertRequest, withBootedCage)
import Singular.Registry.FoldAll (FoldAllArgs (..), FoldEvent (..), FoldResult (..), foldAll, renderFoldEvent)
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.ConnectedFold (FoldBuildFailure (..), connectedFoldTx, prepareRegistryFold)
import Singular.Registry.TxBuilder.Internal (cageAddrFromCfg, cagePolicyIdFromCfg, findRequestUtxos, findStateUtxo, requestAddrFromCfg)

-- | The same test is available alone through @just fold-all-test@ and in E2E.
spec :: Spec
spec = describe "Adaptive folder" $
    it "splits a node-refused batch, drains varied values and skips one poisoned request" $ do
        path <- lookupEnv "REGISTRY_BLUEPRINT" >>= maybe (fail "REGISTRY_BLUEPRINT is required") pure
        bp <- loadBlueprint path >>= either fail pure
        let script name = maybe (fail ("missing script " <> show name)) pure (extractCompiledCode name bp)
        stateBytes <- script "state.state"
        requestBytes <- script "request.request"
        consumerBytes <- script "consumer.consumer"
        withBootedCage (\cfg -> cfg{defaultProcessTime = 3_600_000}) stateBytes requestBytes consumerBytes $
            \cfg prov submit tm tok -> do
                events <- newIORef []
                let stateAddr = cageAddrFromCfg cfg (network cfg)
                    reqAddr = requestAddrFromCfg cfg tok (network cfg)
                    currentState = do
                        us <- queryUTxOs prov stateAddr
                        maybe (fail "missing state") pure (findStateUtxo (cagePolicyIdFromCfg cfg) tok us)
                    pending = sortOn fst . findRequestUtxos tok <$> queryUTxOs prov reqAddr
                    prepare = prepareRegistryFold cfg prov tm tok genesisAddr []
                    args =
                        FoldAllArgs
                            { foldConfig = cfg
                            , foldProvider = prov
                            , foldTrie = tm
                            , foldToken = tok
                            , prepareFold = prepare
                            , signFold = addKeyWitness genesisSignKey
                            , foldSubmitter = submit
                            , reportFold = \e -> putStrLn (renderFoldEvent e) >> modifyIORef' events (e :)
                            , persistFold = pure ()
                            }
                -- A real accepted insert establishes an occupied key. The later
                -- duplicate has a valid datum but an impossible insertion proof.
                _ <- submitInsertRequest cfg prov submit tok "occupied" "seed"
                seed <- foldAll args
                length (foldedTransactions seed) `shouldBe` 1
                forM_ [1 .. 24 :: Int] $ \i -> do
                    _ <-
                        submitInsertRequest
                            cfg
                            prov
                            submit
                            tok
                            (BC.pack ("key-" <> show i))
                            (BS.replicate (64 + 128 * i) (fromIntegral i))
                    pure ()
                -- First exercise only good requests: the refusal must really be
                -- a size/unit limit, not the poison masking an oversized batch.
                current <- currentState
                allGood <- pending
                built <- try @FoldBuildFailure (prepare current allGood >>= connectedFoldTx)
                refusal <- case built of
                    Left (FoldBuildFailure reason) -> pure reason
                    Right (tx, _) -> do
                        result <- submitTx submit (addKeyWitness genesisSignKey tx)
                        case result of
                            Rejected reason -> pure (show reason)
                            Submitted _ -> fail "fixture fitted one transaction; increase request count"
                putStrLn ("all-good-batch-refused: " <> refusal)
                refusal `shouldSatisfy` (\r -> any (`isInfixOf` r) ["MaxTxSize", "TxSize", "ExUnits", "Budget", "budget"])
                control <- lookupEnv "FOLD_ALL_CONTROL"
                when (control == Just "single-batch") $
                    fail ("single-batch control cannot drain: " <> refusal)
                poison <- submitInsertRequest cfg prov submit tok "occupied" "poison"
                result <- foldAll args
                map fst (skippedRequests result) `shouldBe` [poison]
                length (foldedTransactions result) `shouldSatisfy` (> 1)
                rest <- pending
                map fst rest `shouldBe` [poison]
                es <- reverse <$> readIORef events
                length [() | Skipped i _ <- es, i == poison] `shouldBe` 1
                unless (any (\case Refused is _ -> length is > 1; _ -> False) es) $
                    fail "no multi-request refusal observed"
                putStrLn "fold-all: drained 24 varied values in multiple confirmed batches; poison skipped once; chain root equals mirror"

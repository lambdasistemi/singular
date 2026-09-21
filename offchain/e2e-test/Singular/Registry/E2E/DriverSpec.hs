{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.E2E.DriverSpec
Description : The boot-and-fold driver discharges the mirror obligation
License     : Apache-2.0

#190. A fold's speculative session starts from the COMMITTED trie and is
discarded, so a caller that lands a fold without mirroring the edge builds
its next proof against a root the chain no longer has. Before this driver
the obligation lived in a comment: `Fork81Spec` honoured it, the #173 edge
harness did not, and every second fold failed against a stale root — three
devnet runs and an escalation to find, with the library correct throughout.

Two scenarios, on one real devnet:

1. the control — two edges folded THROUGH the driver, which is the correct
   use, and both land;
2. the seeded caller — one edge landed BEHIND the driver's back, through
   the library calls a caller would otherwise write by hand, skipping the
   mirror. The very next `foldEdge` must reject it, naming both roots,
   rather than letting it build a proof that fails later somewhere else.

Scenario 2 is the one that must be able to fail: with the driver's
in-step precondition removed it does not reject, and the run only breaks
later, at a fold that has nothing to do with the omission.
-}
module Singular.Registry.E2E.DriverSpec (spec) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.List (isInfixOf)
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, expectationFailure, it, runIO, shouldBe)

import Singular.Registry.Blueprint (
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Driver (
    FoldOutcome (..),
    bootRegistry,
    chainRoot,
    foldEdge,
    mirrorRoot,
    registryRefs,
    registryTokenId,
 )
import Singular.Registry.Ledger (Root (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types (OnChainRoot (..), edgeInsertAbsent)

import Singular.Registry.E2E.CageSpec (submitWithGenesis, withE2E)

driverKeyA, driverKeyB, seededKey, afterSeededKey :: ByteString
driverKeyA = "t190-driver-a"
driverKeyB = "t190-driver-b"
seededKey = "t190-seeded"
afterSeededKey = "t190-after-seeded"

spec :: Spec
spec = describe "#190 the boot-and-fold driver" $ do
    mPath <- runIO $ lookupEnv "REGISTRY_BLUEPRINT"
    case mPath of
        Nothing -> it "skipped (REGISTRY_BLUEPRINT not set)" (pure () :: IO ())
        Just path -> do
            ebp <- runIO $ loadBlueprint path
            case ebp of
                Left err -> it ("blueprint error: " <> err) (expectationFailure err)
                Right bp ->
                    case ( extractCompiledCode "state.state" bp
                         , extractCompiledCode "request.request" bp
                         ) of
                        (Just stateBytes, Just requestBytes) ->
                            driverSpec stateBytes requestBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure "state or request script not found"

driverSpec :: SBS.ShortByteString -> SBS.ShortByteString -> Spec
driverSpec stateBytes requestBytes = do
    it "folds a named sequence of edges, each committed before the next proof" $
        withE2E stateBytes requestBytes $ \cfg prov submit tm -> do
            codes <- loadRegistryCodesFromEnv
            reg <-
                bootRegistry cfg codes prov (submitWithGenesis submit) genesisAddr tm

            -- Two edges through the driver. The second is the load-bearing
            -- one: its proof is built after the first has landed, so it can
            -- only succeed if the first was committed into the manager.
            outA <- foldEdge reg driverKeyA edgeInsertAbsent
            outB <- foldEdge reg driverKeyB edgeInsertAbsent

            -- The receipt carries both roots, and they move.
            unRoot (foRootBefore outA) /= unRoot (foRootAfter outA)
                `shouldBe` True
            unRoot (foRootAfter outA) `shouldBe` unRoot (foRootBefore outB)

            -- And the manager ends in step with the chain, which is the
            -- whole obligation, observed rather than asserted by comment.
            mirror <- mirrorRoot reg
            onChain <- chainRoot reg
            unRoot mirror `shouldBe` unOnChainRoot onChain

    it "rejects a caller that landed a fold without committing it, at the next fold" $
        withE2E stateBytes requestBytes $ \cfg prov submit tm -> do
            codes <- loadRegistryCodesFromEnv
            let submit' = submitWithGenesis submit
            reg <- bootRegistry cfg codes prov submit' genesisAddr tm

            -- The seeded caller: exactly the calls a harness writes by
            -- hand today — book the edge, build the fold with duties,
            -- submit it — and then NOT the mirror. The edge is on chain;
            -- the manager does not know.
            _ <-
                Edges.bookEdge
                    cfg
                    codes
                    prov
                    submit'
                    genesisAddr
                    (registryTokenId reg)
                    seededKey
                    edgeInsertAbsent
            ctx <- Edges.registryContextFor cfg codes prov (registryRefs reg)
            unsigned <-
                updateTokenWithDuties
                    cfg
                    prov
                    tm
                    (registryTokenId reg)
                    genesisAddr
                    ctx
            _ <- submit' unsigned

            -- The manager is now behind the chain, and the driver must say
            -- so at the NEXT fold rather than letting it build a doomed
            -- proof. The control for this assertion is the first example
            -- above, where the identical call succeeds.
            result <- try @SomeException (foldEdge reg afterSeededKey edgeInsertAbsent)
            case result of
                Right _ ->
                    expectationFailure
                        "the driver accepted a fold although the manager was \
                        \behind the chain: the skipped commit was not rejected \
                        \here, so it will surface at a later unrelated fold"
                Left err -> do
                    let msg = show err
                    if "out of step" `isInfixOf` msg
                        then pure ()
                        else
                            expectationFailure
                                ( "the driver failed, but not for the skipped \
                                  \commit — the rejection must name the \
                                  \out-of-step manager and both roots. Got: "
                                    <> msg
                                )

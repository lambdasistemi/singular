{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.Fork81Spec
Description : Ticket #81 acceptance — lone-Fork absence insertion on a devnet
License     : Apache-2.0

Desk ruling A-001 acceptance for the vendored lone-fork-exclusion patch:
on the real packaged patched validator, a fresh devnet must

1. accept the valid absence insertion of key "cs07-fork-C11" (the CS07
   witness shape whose sole proof step is a root-level Fork with skip > 0),
   with the key readable back from chain;
2. refuse a second insert of the now-present key (occupied-key);
3. (run separately) reproduce the original refusal on the unpatched staging.
-}
module Singular.Registry.E2E.Fork81Spec (spec) where

import Control.Exception (ErrorCall, fromException, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef)
import Test.Hspec

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
 )
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Singular.Registry.Blueprint (
    Blueprint,
    extractCompiledCode,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    Root (..),
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    evalScriptHash,
    extractCageDatum,
    findStateUtxo,
    leafAbsent,
    scriptHashBytes,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    edgeInsertAbsent,
 )

import Singular.Registry.Driver (
    bootRegistry,
    foldEdge,
    registryTokenId,
 )
import Singular.Registry.E2E.CageSpec (
    submitWithGenesis,
    withE2E,
 )

-- mts pieces for the independent read-back recompute
import Data.ByteString.Short qualified as SBS

import MPF.Backend.Pure (
    emptyMPFInMemoryDB,
    runMPFPure,
    runMPFPureTransaction,
 )
import MPF.Backend.Standalone (
    MPFStandalone (..),
    MPFStandaloneCodecs (..),
 )
import MPF.Hashes (
    MPFHash,
    isoMPFHash,
    mkMPFHash,
    mpfHashing,
    renderMPFHash,
 )
import MPF.Interface (
    FromHexKV (..),
    HexKey,
    byteStringToHexKey,
    hexKeyPrism,
 )
import MPF.Proof.Insertion (
    foldMPFProof,
    mkMPFInclusionProof,
 )

import Singular.Registry.Trie (
    Trie (..),
 )
import Singular.Registry.Trie.Pure (mkPureTrieFromRef)

spec :: Blueprint -> Spec
spec bp = describe "Inserting an absent key through a single trie fork" $ do
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         ) of
        (Just stateBytes, Just requestBytes) ->
            fork81Spec stateBytes requestBytes
        _ ->
            it "no compiled code" $
                expectationFailure
                    "state or request script not found in blueprint"

fork81Spec ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Spec
fork81Spec stateBytes requestBytes = do
    it "when a key is absent, inserts it through the fork and reads it back" $
        withE2E stateBytes requestBytes $
            \cfg prov submit tm -> do
                codes <- loadRegistryCodesFromEnv
                reg <-
                    bootRegistry cfg codes prov (submitWithGenesis submit) genesisAddr tm
                let tokenId = registryTokenId reg
                    foldInsert k = void (foldEdge reg k edgeInsertAbsent)
                foldInsert "cs07-fork-A"
                foldInsert "cs07-fork-B1294"
                -- The previously-refused fold (CS07): its proof's sole step
                -- is a root-level Fork with skip > 0.
                foldInsert "cs07-fork-C11"
                -- Read back from chain: the state datum root must equal an
                -- independent {A,B,C} recompute, and an inclusion proof for
                -- C built from the independent trie must fold to the chain
                -- root (C provably present with value vc).
                -- The cage address also holds the custody each absence
                -- insertion created (#157 C6), so the state UTxO is the
                -- one carrying the registry policy token, not the only one.
                let stateAddr = cageAddrFromCfg cfg Testnet
                stateUtxos <- Cage.queryUTxOs prov stateAddr
                chainRoot <-
                    case findStateUtxo (cagePolicyIdFromCfg cfg) tokenId stateUtxos of
                        Just (_, out) -> case extractCageDatum out of
                            Just (StateDatum st) ->
                                pure (unOnChainRoot (stateRoot st))
                            _ -> error "fork81: state UTxO datum missing"
                        Nothing ->
                            error "fork81: no state UTxO carrying the policy token"
                ref <- newIORef emptyMPFInMemoryDB
                let trie = mkPureTrieFromRef ref
                _ <- insert trie "cs07-fork-A" leafAbsent
                _ <- insert trie "cs07-fork-B1294" leafAbsent
                _ <- insert trie "cs07-fork-C11" leafAbsent
                recomputed <- getRoot trie
                unRoot recomputed `shouldBe` chainRoot
                db <- readIORef ref
                let (mProof, _) =
                        runMPFPure db $
                            runMPFPureTransaction
                                codecs
                                ( mkMPFInclusionProof
                                    []
                                    identityKV
                                    mpfHashing
                                    MPFStandaloneMPFCol
                                    (hashPath "cs07-fork-C11")
                                )
                case mProof of
                    Nothing -> error "fork81: no inclusion proof for C"
                    Just p ->
                        renderMPFHash (foldMPFProof mpfHashing p) `shouldBe` chainRoot

    it "when the key is already present, refuses a second insertion" $
        withE2E stateBytes requestBytes $
            \cfg prov submit tm -> do
                codes <- loadRegistryCodesFromEnv
                reg <-
                    bootRegistry cfg codes prov (submitWithGenesis submit) genesisAddr tm
                let foldInsert k = void (foldEdge reg k edgeInsertAbsent)
                foldInsert "cs07-fork-A"
                foldInsert "cs07-fork-B1294"
                foldInsert "cs07-fork-C11"
                -- The edge table cannot see the trie: an insert is edge 0
                -- whether or not the key is present, so this books and the
                -- CAGE refuses it, which is the refusal under test.
                -- Through the driver, so the refusal observed is the one a
                -- production caller meets: the driver books, finds the
                -- manager in step, builds, and the cage refuses the build.
                res <- try (foldEdge reg "cs07-fork-C11" edgeInsertAbsent)
                case res of
                    Right _ ->
                        expectationFailure "occupied-key insert was accepted"
                    Left e -> do
                        -- NOTE-018 bind 1: the expected applied identity
                        -- derives from THIS run's actual production-applied
                        -- cfg bytes (no hardcoded hash, no copied hash).
                        let expectedStateHex =
                                hex (scriptHashBytes (cfgScriptHash cfg))
                        -- Retain the full refusal text (NOTE-005): the
                        -- occupied-key negative is a builder-evaluation
                        -- refusal, and this is its actual error body.
                        putStrLn
                            ( "occupied EvalFailure (retained evidence): "
                                <> show e
                            )
                        case (fromException e :: Maybe ErrorCall) of
                            Just ec -> do
                                let msg = show ec
                                -- NOTE-018 binds: stable constructor
                                -- markers (EvalFailure, ConwaySpending
                                -- purpose of the state spend, CekError
                                -- body) plus the failed witness's NAMED
                                -- script field matched against the DERIVED
                                -- applied identity from this run's actual
                                -- cfg bytes — never a hardcoded hash,
                                -- never a hex substring of the full show
                                -- (transaction data and parameterized
                                -- script bytes can contain the policy).
                                msg `shouldContain` "EvalFailure"
                                msg `shouldContain` "ConwaySpending"
                                msg `shouldContain` "CekError"
                                evalScriptHash msg `shouldBe` Just expectedStateHex
                            Nothing ->
                                expectationFailure
                                    ("unexpected exception: " <> show e)

codecs :: MPFStandaloneCodecs HexKey MPFHash MPFHash
codecs =
    MPFStandaloneCodecs
        { mpfKeyCodec = hexKeyPrism
        , mpfValueCodec = isoMPFHash
        , mpfNodeCodec = isoMPFHash
        }

identityKV :: FromHexKV HexKey MPFHash MPFHash
identityKV =
    FromHexKV
        { fromHexK = id
        , fromHexV = id
        , hexTreePrefix = const []
        }

hashPath :: ByteString -> HexKey
hashPath = byteStringToHexKey . renderMPFHash . mkMPFHash

-- | Hex rendering for derived-identity comparison (NOTE-018 bind 1).
hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

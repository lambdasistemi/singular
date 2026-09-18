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
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef)
import System.Environment (lookupEnv)
import Test.Hspec

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
 )
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Singular.Registry.Blueprint (
    extractCompiledCode,
    loadBlueprint,
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
import Singular.Registry.TxBuilder.Update (
    updateTokenWithDuties,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRoot (..),
    OnChainTokenState (..),
 )

import Singular.Registry.E2E.CageSpec (
    bookEdge,
    publishCageRefs,
    registryContextFor,
    submitWithGenesis,
    withBootedCage,
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
    TrieManager (..),
 )
import Singular.Registry.Trie.Pure (mkPureTrieFromRef)

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

spec :: Spec
spec = describe "Fork #81 acceptance (lone-Fork absence insertion)" $ do
    mPath <- runIO $ lookupEnv "REGISTRY_BLUEPRINT"
    case mPath of
        Nothing ->
            it
                "skipped (REGISTRY_BLUEPRINT not set)"
                (pure () :: IO ())
        Just path -> do
            ebp <- runIO $ loadBlueprint path
            case ebp of
                Left err ->
                    it ("blueprint error: " <> err) (expectationFailure err)
                Right bp ->
                    case ( extractCompiledCode "state.state" bp
                         , extractCompiledCode "request.request" bp
                         ) of
                        (Just stateBytes, Just requestBytes) ->
                            fork81Spec stateBytes requestBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure
                                    "state or request script not found in blueprint"

-- | Hex rendering for derived-identity comparison (NOTE-018 bind 1).
hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

fork81Spec ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Spec
fork81Spec stateBytes requestBytes = do
    it "accepts the real absence insertion of C and reads it back" $
        withBootedCage id stateBytes requestBytes $
            \cfg prov submit tm tokenId -> do
                refs <- publishCageRefs cfg prov submit tokenId
                foldInsert cfg prov submit tm tokenId refs "cs07-fork-A"
                foldInsert cfg prov submit tm tokenId refs "cs07-fork-B1294"
                -- The previously-refused fold (CS07): its proof's sole step
                -- is a root-level Fork with skip > 0.
                foldInsert cfg prov submit tm tokenId refs "cs07-fork-C11"
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

    it "refuses a second insert of the now-present key (occupied-key)" $
        withBootedCage id stateBytes requestBytes $
            \cfg prov submit tm tokenId -> do
                refs <- publishCageRefs cfg prov submit tokenId
                foldInsert cfg prov submit tm tokenId refs "cs07-fork-A"
                foldInsert cfg prov submit tm tokenId refs "cs07-fork-B1294"
                foldInsert cfg prov submit tm tokenId refs "cs07-fork-C11"
                -- The edge table cannot see the trie: an insert is edge 0
                -- whether or not the key is present, so this books and the
                -- CAGE refuses it, which is the refusal under test.
                _ <-
                    bookEdge
                        cfg
                        prov
                        submit
                        tokenId
                        "cs07-fork-C11"
                        (OpInsert leafAbsent)
                ctx <- registryContextFor cfg prov tokenId refs
                res <- try (updateTokenWithDuties cfg prov tm tokenId genesisAddr ctx)
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
  where
    -- The speculative session inside updateTokenImpl starts from the
    -- manager's committed trie and is discarded; the production caller
    -- mirrors each landed fold into the committed trie. Without this,
    -- every fold would re-prove against the boot state (fold 2 would
    -- submit an empty proof and fail).
    foldInsert cfg prov submit tm tokenId refs k = do
        _ <- bookEdge cfg prov submit tokenId k (OpInsert leafAbsent)
        ctx <- registryContextFor cfg prov tokenId refs
        unsigned <- updateTokenWithDuties cfg prov tm tokenId genesisAddr ctx
        _ <- submitWithGenesis submit unsigned
        withTrie tm tokenId $ \t -> do
            _ <- insert t k leafAbsent
            pure ()

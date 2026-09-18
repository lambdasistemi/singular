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
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Singular.Registry.Blueprint (
    extractCompiledCode,
    loadBlueprint,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.E2E.CageSpec (
    CageEnv (..),
    bookAbsence,
    foldCage,
    submitWithGenesis,
    withBootedCage,
 )
import Singular.Registry.Ledger (
    Root (..),
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (cageAddrFromCfg, cagePolicyIdFromCfg, evalScriptHash, extractCageDatum, findStateUtxo, leafAbsent, scriptHashBytes)
import Singular.Registry.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
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
    -- #157 D-BOOT: a cage boots with four pins derived from the naming
    -- partition, and the edges folded here are certified by the
    -- application policy and witnessed by a token policy. The naming
    -- blueprint is an input for those identities alone.
    mNaming <- runIO $ lookupEnv "NAMING_BLUEPRINT"
    case (mPath, mNaming) of
        (Nothing, _) ->
            it
                "skipped (REGISTRY_BLUEPRINT not set)"
                (pure () :: IO ())
        (_, Nothing) ->
            it
                "skipped (NAMING_BLUEPRINT not set)"
                (pure () :: IO ())
        (Just path, Just namingPath) -> do
            ebp <- runIO $ loadBlueprint path
            enbp <- runIO $ loadBlueprint namingPath
            case (ebp, enbp) of
                (Left err, _) ->
                    it ("blueprint error: " <> err) (expectationFailure err)
                (_, Left err) ->
                    it ("naming blueprint error: " <> err) (expectationFailure err)
                (Right bp, Right nbp) ->
                    case ( extractCompiledCode "state.state" bp
                         , extractCompiledCode "request.request" bp
                         , extractCompiledCode "application.application" nbp
                         , extractCompiledCode "witness.witness.mint" nbp
                         ) of
                        (Just stateBytes, Just requestBytes, Just appBytes, Just witnessBytes) ->
                            fork81Spec stateBytes requestBytes appBytes witnessBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure
                                    "state, request, application or witness \
                                    \script not found in the blueprints"

-- | Hex rendering for derived-identity comparison (NOTE-018 bind 1).
hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

fork81Spec ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Spec
fork81Spec stateBytes requestBytes appBytes witnessBytes = do
    it "accepts the real absence insertion of C and reads it back" $
        withBootedCage id stateBytes requestBytes appBytes witnessBytes $
            \env -> do
                let cfg = ceCfg env
                    prov = ceProv env
                foldInsert env "cs07-fork-A"
                foldInsert env "cs07-fork-B1294"
                -- The previously-refused fold (CS07): its proof's sole step
                -- is a root-level Fork with skip > 0.
                foldInsert env "cs07-fork-C11"
                -- Read back from chain: the state datum root must equal an
                -- independent {A,B,C} recompute, and an inclusion proof for
                -- C built from the independent trie must fold to the chain
                -- root (C provably present with value vc).
                -- The cage address holds the custody each absence
                -- insertion created beside the state itself, so the
                -- state UTxO is the one carrying the cage's own token,
                -- not the only one there.
                let stateAddr = cageAddrFromCfg cfg Testnet
                stateUtxos <- Cage.queryUTxOs prov stateAddr
                chainRoot <-
                    case findStateUtxo
                        (cagePolicyIdFromCfg cfg)
                        (ceToken env)
                        stateUtxos of
                        Just (_, out) -> case extractCageDatum out of
                            Just (StateDatum st) ->
                                pure (unOnChainRoot (stateRoot st))
                            _ -> error "fork81: state UTxO datum missing"
                        Nothing -> error "fork81: no state UTxO carrying the cage token"
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
        withBootedCage id stateBytes requestBytes appBytes witnessBytes $
            \env -> do
                let cfg = ceCfg env
                foldInsert env "cs07-fork-A"
                foldInsert env "cs07-fork-B1294"
                foldInsert env "cs07-fork-C11"
                -- The approval certifies an absence for a key it cannot
                -- know is already taken; the occupied key is the fold's
                -- to refuse, and it does.
                _ <- bookAbsence env "cs07-fork-C11"
                res <- try (foldCage env)
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
    foldInsert env k = do
        _ <- bookAbsence env k
        unsigned <- foldCage env
        _ <- submitWithGenesis (ceSubmit env) unsigned
        withTrie (ceTrie env) (ceToken env) $ \t -> do
            _ <- insert t k leafAbsent
            pure ()

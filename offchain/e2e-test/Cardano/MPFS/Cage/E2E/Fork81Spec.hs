{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.MPFS.Cage.E2E.Fork81Spec
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
module Cardano.MPFS.Cage.E2E.Fork81Spec (spec) where

import Control.Exception (ErrorCall, fromException, try)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef)
import System.Environment (lookupEnv)
import Test.Hspec

import Cardano.MPFS.Cage.Blueprint (
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.TxBuilder.Internal (
    cageAddrFromCfg,
    evalScriptHash,
    extractCageDatum,
    scriptHashBytes,
 )
import Cardano.MPFS.Cage.Ledger (
    Root (..),
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.TxBuilder.Update (
    updateTokenImpl,
 )
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
 )
import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
 )

import Cardano.MPFS.Cage.E2E.CageSpec (
    submitInsertRequest,
    submitWithGenesis,
    withBootedCage,
 )
-- mts pieces for the independent read-back recompute
import Data.ByteString.Short qualified as SBS

import MPF.Backend.Pure
    ( emptyMPFInMemoryDB
    , runMPFPure
    , runMPFPureTransaction
    )
import MPF.Backend.Standalone
    ( MPFStandalone (..)
    , MPFStandaloneCodecs (..)
    )
import MPF.Hashes
    ( MPFHash
    , isoMPFHash
    , mkMPFHash
    , mpfHashing
    , renderMPFHash
    )
import MPF.Interface
    ( FromHexKV (..)
    , HexKey
    , byteStringToHexKey
    , hexKeyPrism
    )
import MPF.Proof.Insertion
    ( foldMPFProof
    , mkMPFInclusionProof
    )

import Cardano.MPFS.Cage.Trie (
    Trie (..)
    , TrieManager (..)
    )
import Cardano.MPFS.Cage.Trie.Pure (mkPureTrieFromRef)

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
    mPath <- runIO $ lookupEnv "MPFS_BLUEPRINT"
    case mPath of
        Nothing ->
            it
                "skipped (MPFS_BLUEPRINT not set)"
                (pure () :: IO ())
        Just path -> do
            ebp <- runIO $ loadBlueprint path
            case ebp of
                Left err ->
                    it ("blueprint error: " <> err) (expectationFailure err)
                Right bp ->
                    case ( extractCompiledCode "state.state" bp
                         , extractCompiledCode "request.request" bp
                         , extractCompiledCode "consumer.consumer" bp
                         ) of
                        (Just stateBytes, Just requestBytes, Just consumerBytes) ->
                            fork81Spec stateBytes requestBytes consumerBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure
                                    "state, request or consumer script not found in blueprint"

-- | Hex rendering for derived-identity comparison (NOTE-018 bind 1).
hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

fork81Spec ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Spec
fork81Spec stateBytes requestBytes consumerBytes = do
    it "accepts the real absence insertion of C and reads it back" $
        withBootedCage id stateBytes requestBytes consumerBytes $
            \cfg prov submit tm tokenId -> do
                foldInsert cfg prov submit tm tokenId "cs07-fork-A" "va"
                foldInsert cfg prov submit tm tokenId "cs07-fork-B1294" "vb"
                -- The previously-refused fold (CS07): its proof's sole step
                -- is a root-level Fork with skip > 0.
                foldInsert cfg prov submit tm tokenId "cs07-fork-C11" "vc"
                -- Read back from chain: the state datum root must equal an
                -- independent {A,B,C} recompute, and an inclusion proof for
                -- C built from the independent trie must fold to the chain
                -- root (C provably present with value vc).
                let stateAddr = cageAddrFromCfg cfg Testnet
                stateUtxos <- Cage.queryUTxOs prov stateAddr
                chainRoot <- case stateUtxos of
                    [(_, out)] -> case extractCageDatum out of
                        Just (StateDatum st) ->
                            pure (unOnChainRoot (stateRoot st))
                        _ -> error "fork81: state UTxO datum missing"
                    _ -> error "fork81: expected exactly one state UTxO"
                ref <- newIORef emptyMPFInMemoryDB
                let trie = mkPureTrieFromRef ref
                _ <- insert trie "cs07-fork-A" "va"
                _ <- insert trie "cs07-fork-B1294" "vb"
                _ <- insert trie "cs07-fork-C11" "vc"
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
        withBootedCage id stateBytes requestBytes consumerBytes $
            \cfg prov submit tm tokenId -> do
                foldInsert cfg prov submit tm tokenId "cs07-fork-A" "va"
                foldInsert cfg prov submit tm tokenId "cs07-fork-B1294" "vb"
                foldInsert cfg prov submit tm tokenId "cs07-fork-C11" "vc"
                _ <-
                    submitInsertRequest
                        cfg
                        prov
                        submit
                        tokenId
                        "cs07-fork-C11"
                        "vc2"
                res <- try (updateTokenImpl cfg prov tm tokenId genesisAddr)
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
                                    ( "unexpected exception: " <> show e
                                    )
  where
    -- The speculative session inside updateTokenImpl starts from the
    -- manager's committed trie and is discarded; the production caller
    -- mirrors each landed fold into the committed trie. Without this,
    -- every fold would re-prove against the boot state (fold 2 would
    -- submit an empty proof and fail).
    foldInsert cfg prov submit tm tokenId k v = do
        _ <- submitInsertRequest cfg prov submit tokenId k v
        unsigned <- updateTokenImpl cfg prov tm tokenId genesisAddr
        _ <- submitWithGenesis submit unsigned
        withTrie tm tokenId $ \t -> do
            _ <- insert t k v
            pure ()

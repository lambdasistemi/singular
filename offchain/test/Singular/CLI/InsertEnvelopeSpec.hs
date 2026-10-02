{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.InsertEnvelopeSpec
Description : The insert command feeds the envelope builder from the right sources
License     : Apache-2.0

Every expected envelope is assembled here from the sources by hand, as the
datum a user wrote before the command built it: the registry's state asset
from the saved script hash and token, the active policy from the saved
config, the key, the signing wallet's key hash, the deposit and the
payload. The command's function is never the producer of an expected value.
Each source is exercised at two registries, two keys, two controllers, two
deposits and two payloads, so a field read from the wrong place cannot
coincide with the right one.
-}
module Singular.CLI.InsertEnvelopeSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Test.Hspec

import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeToData
    , envelopeVersion
    , saName
    , saPolicy
    )
import Singular.CLI.InsertEnvelope (insertEnvelope)
import Singular.Registry.Blueprint (applyBytesParam)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), TokenId (..))
import Singular.Registry.TxBuilder.BookingFixture
    ( cfg
    , program
    , tokenId
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )

-- | A second registry: another state script and another active policy.
otherCfg :: CageConfig
otherCfg =
    cfg
        { cfgScriptHash = computeScriptHash (applyBytesParam "other" program)
        , cfgActivePolicy = SBS.pack (replicate 28 0x44)
        }

otherToken :: TokenId
otherToken = TokenId (AssetName "another-registry")

registries :: [(CageConfig, TokenId)]
registries = [(cfg, tokenId), (otherCfg, otherToken)]

payloads :: [PLC.Data]
payloads =
    [ PLC.Map [(PLC.B "control", PLC.B "alice-1")]
    , PLC.List [PLC.I (-7), PLC.Constr 2 []]
    ]

-- | The datum the sources make, assembled by hand.
expected
    :: CageConfig
    -> TokenId
    -> ByteString
    -> ByteString
    -> Integer
    -> PLC.Data
    -> PLC.Data
expected c (TokenId (AssetName name)) key controller deposit payload =
    PLC.Constr
        0
        [ PLC.Constr
            0
            [ PLC.I 1
            , PLC.Constr
                0
                [ PLC.B (scriptHashBytes (cfgScriptHash c))
                , PLC.B (SBS.fromShort name)
                ]
            , PLC.B (SBS.fromShort (cfgActivePolicy c))
            , PLC.B key
            , PLC.B controller
            , PLC.I deposit
            ]
        , payload
        ]

spec :: Spec
spec = describe "the insert envelope, from the registry and the caller" $ do
    it "equals the hand-assembled datum for every combination of sources" $
        forM_ registries $ \(c, t) ->
            forM_ ["alice-1", "bob-2"] $ \key ->
                forM_ [BS.replicate 28 0x33, BS.replicate 28 0x55] $ \who ->
                    forM_ [2_000_000, 3_500_000] $ \deposit ->
                        forM_ payloads $ \payload ->
                            envelopeToData (insertEnvelope c t key who deposit payload)
                                `shouldBe` expected c t key who deposit payload
    it
        "names the registry's state asset: saved script hash and saved token"
        $ forM_ registries
        $ \(c, t@(TokenId (AssetName name))) -> do
            let asset =
                    ctlRegistry
                        (envControl (insertEnvelope c t "k" "w" 2_000_000 (PLC.I 0)))
            saPolicy asset `shouldBe` scriptHashBytes (cfgScriptHash c)
            saName asset `shouldBe` SBS.fromShort name
    it "names the registry's active policy" $
        forM_ registries $ \(c, t) ->
            ctlActivePolicy
                (envControl (insertEnvelope c t "k" "w" 2_000_000 (PLC.I 0)))
                `shouldBe` SBS.fromShort (cfgActivePolicy c)
    it "builds under the envelope version, with the caller as controller" $ do
        let control =
                envControl
                    (insertEnvelope cfg tokenId "k" "caller-hash" 2_000_000 (PLC.I 0))
        ctlVersion control `shouldBe` envelopeVersion
        ctlController control `shouldBe` "caller-hash"
    it "tells two registries apart" $
        envelopeToData
            (insertEnvelope cfg tokenId "k" "w" 2_000_000 (PLC.I 0))
            `shouldNotBe` envelopeToData
                (insertEnvelope otherCfg otherToken "k" "w" 2_000_000 (PLC.I 0))

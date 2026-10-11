{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.RulesSpec
Description : The stub holding rules find, refuse and release
License     : Apache-2.0

Rows over the value's own holding rules: finding one holding, refusing
a foreign datum and a duplicate, the live output, the release shape
and the carried-datum check. The config and token are unused by
design: the datum carries the key and no policy field, so every
expected value here is derived from the inputs, never typed.
-}
module Singular.Application.KeriStub.RulesSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~))
import Test.Hspec

import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Application.KeriStub.Datum
    ( Holding (..)
    , holdingToData
    )
import Singular.Application.KeriStub.Value
    ( decodeHolding
    , keriStubApplication
    )
import Singular.Registry.Application
    ( Application (..)
    , DecodedHolding (..)
    , HoldingRules (..)
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra, TxIn)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , mkInlineDatum
    )
import Singular.Registry.TxBuilder.Update
    ( HolderRelease (..)
    , RegistryContext (..)
    , emptyRegistryContext
    )
import Singular.Registry.Types
    ( OnChainRequest (..)
    , OnChainTokenId (..)
    , edgeInsertActive
    )

spec :: Spec
spec = describe "the stub holding rules" $ do
    finding
    refusals
    live
    release
    carried

rules :: HoldingRules
rules = case appHolding keriStubApplication of
    Just r -> r
    Nothing -> error "RulesSpec: the stub value carries no holding rules"

keyA :: BS.ByteString
keyA = "key-a"

controllerA :: BS.ByteString
controllerA = BS.replicate 28 7

holdingA :: Holding
holdingA =
    Holding
        { hdKey = keyA
        , hdController = controllerA
        , hdDeposit = 2_000_000
        , hdPayload = PLC.B "prefix-a"
        }

outputFor :: Holding -> TxOut ConwayEra
outputFor h =
    mkBasicTxOut
        (addrFromKeyHashBytes Testnet (BS.replicate 28 9))
        (MaryValue (Coin 3_000_000) mempty)
        & datumTxOutL .~ mkInlineDatum (holdingToData h)

txIn :: String -> TxIn
txIn s = case parseOutRef (T.pack s) of
    Right i -> i
    Left why -> error ("RulesSpec: bad outref: " <> why)

finding :: Spec
finding = describe "finding" $ do
    it "finds the one output whose datum names the key" $
        let outs = [(txIn (replicate 64 'a' <> "#0"), outputFor holdingA)]
        in  hrFindHoldings rules undefined undefined keyA outs
                `shouldSatisfy` ((== 1) . length)
    it "decodes the found holding" $
        let outs = [(txIn (replicate 64 'a' <> "#0"), outputFor holdingA)]
        in  case hrFindHoldings rules undefined undefined keyA outs of
                [(_, decoded)] -> do
                    dhKey decoded `shouldBe` keyA
                    dhController decoded `shouldBe` controllerA
                    dhDeposit decoded `shouldBe` 2_000_000
                other ->
                    expectationFailure ("find decoded: " <> show (length other))

refusals :: Spec
refusals = describe "foreign and duplicate refusals" $ do
    it
        "refuses a foreign datum: an output naming another key is no holding"
        $ let other =
                holdingA
                    { hdKey = "other-key"
                    }
              outs = [(txIn (replicate 64 'a' <> "#0"), outputFor other)]
          in  hrFindHoldings rules undefined undefined keyA outs
                `shouldBe` []
    it "refuses an unreadable datum: no inline datum is no holding" $
        let bare =
                mkBasicTxOut
                    (addrFromKeyHashBytes Testnet (BS.replicate 28 9))
                    (MaryValue (Coin 3_000_000) mempty)
            outs = [(txIn (replicate 64 'a' <> "#0"), bare)]
        in  hrFindHoldings rules undefined undefined keyA outs
                `shouldBe` []
    it "refuses a duplicate: two holdings for one key name it" $
        let outs =
                [ (txIn (replicate 64 'a' <> "#0"), outputFor holdingA)
                , (txIn (replicate 64 'b' <> "#1"), outputFor holdingA)
                ]
        in  hrLiveOutputFor rules undefined undefined keyA outs
                `shouldSatisfy` isLeft
    it "decoding names why a bare output carries nothing" $
        let bare =
                mkBasicTxOut
                    (addrFromKeyHashBytes Testnet (BS.replicate 28 9))
                    (MaryValue (Coin 3_000_000) mempty)
        in  decodeHolding bare `shouldSatisfy` isLeft

live :: Spec
live = describe "the live output" $ do
    it "is the one holding of the key" $
        let outs = [(txIn (replicate 64 'a' <> "#0"), outputFor holdingA)]
        in  hrLiveOutputFor rules undefined undefined keyA outs
                `shouldSatisfy` isRight
    it "names the hex when no live output holds the key" $
        let hex = TE.decodeUtf8 (B16.encode keyA)
        in  hrLiveOutputFor rules undefined undefined keyA []
                `shouldBe` Left ("no live output holds key 0x" <> hex)
    it "names the hex when two outputs claim the key" $
        let hex = TE.decodeUtf8 (B16.encode keyA)
            outs =
                [ (txIn (replicate 64 'a' <> "#0"), outputFor holdingA)
                , (txIn (replicate 64 'b' <> "#1"), outputFor holdingA)
                ]
        in  hrLiveOutputFor rules undefined undefined keyA outs
                `shouldBe` Left ("more than one live output claims key 0x" <> hex)

release :: Spec
release = describe "the release" $ do
    it "spends with a unit redeemer, the controller and the deposit" $
        let pair = (txIn (replicate 64 'a' <> "#0"), outputFor holdingA)
        in  case hrReleaseOf rules undefined pair of
                Right (found, rel) -> do
                    found `shouldBe` fst pair
                    hrRedeemer rel `shouldBe` PLC.Constr 0 []
                    hrRecipient rel `shouldBe` controllerA
                    hrReleased rel `shouldBe` 2_000_000
                Left why ->
                    expectationFailure ("release refused: " <> T.unpack why)
    it
        "adds the live outputs and one release per output to the fold context"
        $ let outs = [(txIn (replicate 64 'a' <> "#0"), outputFor holdingA)]
          in  case hrWithApplication rules undefined Nothing outs emptyRegistryContext of
                Right ctx -> do
                    length (rcHolderUtxos ctx) `shouldBe` 1
                    Map.size (rcHolderReleases ctx) `shouldBe` 1
                Left why ->
                    expectationFailure ("context refused: " <> T.unpack why)

carried :: Spec
carried = describe "the carried datum" $ do
    it "is the holding the booking wrote into the request" $
        let datum = holdingToData holdingA
        in  hrCheckCarried rules (requestCarrying (Just datum))
                `shouldBe` Right datum
    it "is refused, by name, when the request carries no holding" $
        case hrCheckCarried rules (requestCarrying Nothing) of
            Left why ->
                T.isInfixOf "carries no holding" why `shouldBe` True
            Right _ ->
                expectationFailure "a dataless request was carried"
    it
        "is refused, by name, when what the request carries is not a holding"
        $ case hrCheckCarried rules (requestCarrying (Just (PLC.B "not a holding"))) of
            Left why ->
                T.isInfixOf "cannot be read" why `shouldBe` True
            Right _ ->
                expectationFailure "a foreign datum was carried"
  where
    requestCarrying datum =
        OnChainRequest
            { requestToken = OnChainTokenId (BuiltinByteString "registry")
            , requestOwner = BuiltinByteString (BS.replicate 28 0x33)
            , requestKey = keyA
            , requestEdge = edgeInsertActive
            , requestDeposit = 2_000_000
            , requestSubmittedAt = 0
            , requestDestination = ("address", datum)
            }

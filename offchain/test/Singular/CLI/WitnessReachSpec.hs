{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.WitnessReachSpec
Description : The witness token of a key, and the outputs the provider says hold it
License     : Apache-2.0

@inspect --key@ finds a key's output by the key's witness token: the registry's
active witness policy, or the terminal one, with the key's bytes as the asset
name. These cases hold the one function that turns a registry's configuration,
a witness kind and a key into that asset, and the reader that asks a provider
who holds it. The packaged command's rows, over a chain fixture where keys are
booked, folded and terminated, are in the application suite.

The policies a case expects are made here from the pins of the fixture
registry, never read from the function under test.
-}
module Singular.CLI.WitnessReachSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.StubSession (stubSession)
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.Witness
    ( WitnessFound (..)
    , WitnessKind (..)
    , findWitness
    , holdsAsset
    , witnessAsset
    )

spec :: Spec
spec = describe "the key reached by its witness token" $ do
    assetRows
    readerRows

-- | The policy a pin names, made from its 28 bytes.
policyOf :: SBS.ShortByteString -> PolicyID
policyOf pin = case hashFromBytes (SBS.fromShort pin) of
    Just hash -> PolicyID (ScriptHash hash)
    Nothing -> error "WitnessReachSpec: a pin of the fixture is not 28 bytes"

-- | A key, one to 32 bytes: what the command line takes.
genKey :: Gen ByteString
genKey = do
    size <- choose (1, 32)
    BS.pack <$> vectorOf size arbitrary

assetRows :: Spec
assetRows = describe "the asset a key's witness is" $ do
    it "is the active pin with the key's bytes as the name, for any key" $
        forAll genKey $ \key ->
            witnessAsset Fixture.cfg ActiveWitness key
                === (policyOf (cfgActivePolicy Fixture.cfg), AssetName (SBS.toShort key))
    it
        "follows each registry: two registries with different pins look up different policies, the same name"
        $ forAll genKey
        $ \key ->
            let registries = [Fixture.cfg, otherRegistry]
                lookups kind = [witnessAsset cfg kind key | cfg <- registries]
                name = AssetName (SBS.toShort key)
            in  conjoin
                    [ map fst (lookups ActiveWitness)
                        === map (policyOf . cfgActivePolicy) registries
                    , map snd (lookups ActiveWitness)
                        === replicate 2 name
                    , counterexample
                        "the two registries must differ in the active pin"
                        (cfgActivePolicy Fixture.cfg /= cfgActivePolicy otherRegistry)
                    ]
    it
        "follows the registry: another active pin is another policy, the name the same"
        $ forAll genKey
        $ \key ->
            let other = Fixture.cfg{cfgActivePolicy = SBS.pack (replicate 28 0x07)}
                (policy, name) = witnessAsset other ActiveWitness key
            in  (policy, name)
                    === (policyOf (SBS.pack (replicate 28 0x07)), AssetName (SBS.toShort key))

-- | A second registry whose two pins both differ from the fixture's.
otherRegistry :: CageConfig
otherRegistry =
    Fixture.cfg
        { cfgApplicationPolicy = SBS.pack (replicate 28 0x11)
        , cfgActivePolicy = SBS.pack (replicate 28 0x13)
        }

-- | An output holding these assets, at the fixture's payer.
holding :: [(PolicyID, AssetName)] -> TxOut ConwayEra
holding assets =
    mkBasicTxOut
        Fixture.payer
        ( MaryValue
            (Coin 2_000_000)
            ( MultiAsset
                ( Map.fromListWith
                    Map.union
                    [(policy, Map.singleton name 1) | (policy, name) <- assets]
                )
            )
        )

-- | The output reference of a transaction made of one repeated digit.
outRef :: Char -> Int -> TxIn
outRef digit index =
    either
        (error . ("WitnessReachSpec: " <>))
        id
        (parseOutRef (T.pack (replicate 64 digit <> "#" <> show index)))

readerRows :: Spec
readerRows = describe "the reader that asks who holds a key's witness" $ do
    let key = "witness-key" :: ByteString
        name = AssetName (SBS.toShort key)
        active = policyOf (cfgActivePolicy Fixture.cfg)
        elsewhere = policyOf (SBS.pack (replicate 28 0x09))
        -- a provider that answers the one query for this asset and refuses
        -- every other, so a second or a different question fails the row
        servingAs asset answer =
            stubSession
                { outputs = \query ->
                    pure $
                        if query == HoldingAsset asset
                            then Right (Evidenced answer Nothing)
                            else Left (BackendReadFailure "a query nobody expected")
                }
    it "asks the provider once, for the asset, and for nothing else" $ do
        let held = (outRef 'f' 0, holding [(active, name)])
            session = servingAs (active, name) [held]
        found <- findWitness session Fixture.cfg ActiveWitness key
        found `shouldBe` Right (WitnessFound (active, name) [held])
    it
        "keeps an output only when its own value holds the asset, in the order of the references"
        $ do
            let one = (outRef 'b' 0, holding [(active, name)])
                two = (outRef 'a' 1, holding [(active, name)])
                otherPolicy = (outRef 'c' 0, holding [(elsewhere, name)])
                otherName = (outRef 'd' 0, holding [(active, AssetName "another-key")])
                nothing = (outRef 'e' 0, holding [])
                session =
                    servingAs
                        (active, name)
                        [one, otherPolicy, nothing, two, otherName]
            found <- findWitness session Fixture.cfg ActiveWitness key
            fmap (map fst . foundHolders) found
                `shouldBe` Right [outRef 'a' 1, outRef 'b' 0]
    it "finds no holder when the provider names none" $ do
        found <-
            findWitness
                (servingAs (active, name) [])
                Fixture.cfg
                ActiveWitness
                key
        found `shouldBe` Right (WitnessFound (active, name) [])
    it "reports a provider that cannot answer, and nothing else" $ do
        let session =
                stubSession
                    { outputs = const (pure (Left (BackendReadFailure "refused")))
                    }
        found <- findWitness session Fixture.cfg ActiveWitness key
        found `shouldBe` Left (BackendReadFailure "refused")
    it "holds an asset only in an output whose own value has it" $ do
        holdsAsset (active, name) (holding [(active, name)]) `shouldBe` True
        holdsAsset (active, name) (holding [(elsewhere, name)])
            `shouldBe` False
        holdsAsset
            (active, name)
            (holding [(active, AssetName "another-key")])
            `shouldBe` False
        holdsAsset (active, name) (holding []) `shouldBe` False

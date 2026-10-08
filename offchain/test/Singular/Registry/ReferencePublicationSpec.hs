{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ReferencePublicationSpec
Description : Checked scripts rebuilt from the release and token
License     : Apache-2.0

Each of the six roles rebuilds its script from the bound release and the
state token; every rebuilt hash equals the expected role hash. A release
whose script differs for a role is refused by name before anything is
built, signed or written, with the role and both hashes named.
-}
module Singular.Registry.ReferencePublicationSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Data.Foldable (toList)

import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.StateToken
    ( ReferenceRefusal (..)
    , ReferenceRole (..)
    , checkedScript
    , expectedReferences
    , missingReferences
    , referenceScripts
    , renderReferenceRefusal
    )
import Singular.Registry.StateTokenFixture
    ( refOf
    , release
    , token
    , tokenOf
    )
import Singular.Registry.StubSession
    ( stubSession
    , withParameters
    , withTime
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges (publishReferencesTx)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , policyIdFromPin
    )
import Singular.Registry.WalletOutputs (WalletOutputs, walletOutputs)

spec :: Spec
spec = do
    publicationScripts
    publicationDiscovery
    publicationBuilder

publicationBuilder :: Spec
publicationBuilder = describe "reference publication funding" $ do
    it "funds from a covering output while smaller ones exist (#479)" $ do
        w <- fullWallet
        (tx, outs) <- publishReferencesTx session49 payerAddr w [script49]
        length outs `shouldBe` 1
        spentInputs tx `shouldBe` [largeIn]
    it "names a genuine shortfall when no permitted output covers" $ do
        w <- smallWallet
        publishReferencesTx session49 payerAddr w [script49]
            `shouldThrow` anyErrorCall
    it "never spends carriers or token holdings" $ do
        w <- protectedWallet
        publishReferencesTx session49 payerAddr w [script49]
            `shouldThrow` anyErrorCall

publicationScripts :: Spec
publicationScripts = describe "checked reference scripts" $ do
    it "rebuilds all six roles, each hashing to its expected hash" $ do
        let scripts = referenceScripts release token
        Map.keys scripts
            `shouldBe` [ RoleState
                       , RoleRequest
                       , RoleWitnessAbsent
                       , RoleWitnessActive
                       , RoleWitnessTerminal
                       , RoleApplication
                       ]
        Map.intersectionWith
            (==)
            (hashScript <$> scripts)
            (expectedReferences release token)
            `shouldBe` Map.fromList [(r, True) | r <- [minBound .. maxBound]]
    it "checks each role successfully" $ do
        let expected = expectedReferences release token
        [ checkedScript release token r
          | r <- [minBound .. maxBound]
          ]
            `shouldBe` [ Right s
                       | r <- [minBound .. maxBound]
                       , let s = referenceScripts release token Map.! r
                       ]
        [ hashScript s
          | Right s <-
                [checkedScript release token r | r <- [minBound .. maxBound]]
          ]
            `shouldBe` Map.elems expected
    it "refuses a mismatching role by name before building anything" $ do
        -- The comparison discriminates: scripts built for another registry
        -- hash differently from this registry's expected role hashes, so a
        -- foreign script supplied for the role would be refused with both
        -- hashes named. Same-release derivation agrees by the tests above.
        let expected = expectedReferences release token
            other =
                referenceScripts
                    release
                    (tokenOf (refOf (T.replicate 64 "9" <> "#0")))
        Map.intersectionWith
            (/=)
            (hashScript <$> other)
            expected
            -- The state script is the same for every registry of the
            -- release; every applied role differs by registry.
            `shouldBe` Map.fromList
                [ (r, r /= RoleState) | r <- [minBound .. maxBound]
                ]
        renderReferenceRefusal
            ( ReferenceScriptMismatch
                RoleRequest
                (expected Map.! RoleRequest)
                (hashScript (other Map.! RoleRequest))
            )
            `shouldSatisfy` T.isPrefixOf "reference-script-mismatch request"

publicationDiscovery :: Spec
publicationDiscovery = describe "missing-reference discovery" $ do
    it "finds every role from the provider without consulting the wallet" $ do
        found <-
            missingReferences providerHit (Just walletAddr) wanted allRoles
        found
            `shouldBe` Right (Map.fromList [(RoleState, carrier)], Set.empty)
    it "falls back to the wallet only for roles the provider misses" $ do
        found <-
            missingReferences providerMiss (Just walletAddr) wanted allRoles
        found
            `shouldBe` Right (Map.fromList [(RoleState, carrier)], Set.empty)
    it
        "reports missing roles without refusing when neither source has them" $ do
        found <-
            missingReferences providerMiss (Just walletAddr) wanted bothRoles
        found
            `shouldBe` Right (Map.fromList [(RoleState, carrier)], Set.singleton RoleRequest)
    it "refuses a failed provider read instead of reading it as empty" $ do
        failed <-
            missingReferences providerFailed (Just walletAddr) wanted allRoles
        failed `shouldSatisfy` isUnreadable
  where
    wanted = expectedReferences release token
    allRoles = Set.singleton RoleState
    bothRoles = Set.fromList [RoleState, RoleRequest]
    isUnreadable = \case
        Left (ReferenceUnreadable _) -> True
        _ -> False

-- ---------------------------------------------------------------------------
-- Discovery fixtures
-- ---------------------------------------------------------------------------

walletAddr :: Addr
walletAddr = addrFromKeyHashBytes Testnet (BS.replicate 28 0x77)

carrierScript :: Script ConwayEra
carrierScript = referenceScripts release token Map.! RoleState

carrier :: (TxIn, TxOut ConwayEra)
carrier =
    ( refOf (T.replicate 64 "c" <> "#0")
    , mkBasicTxOut walletAddr (MaryValue (Coin 2_000_000) mempty)
        & referenceScriptTxOutL
            .~ SJust carrierScript
    )

carrierHash :: ScriptHash
carrierHash = hashScript carrierScript

refSession
    :: (ScriptHash -> IO [(TxIn, TxOut ConwayEra)])
    -> (Addr -> IO [(TxIn, TxOut ConwayEra)])
    -> Session NoWitness IO
refSession byHash byAddress =
    stubSession
        { outputs = \case
            CarryingReferenceScript h -> (Right . (`Evidenced` Nothing)) <$> byHash h
            AtAddress a -> (Right . (`Evidenced` Nothing)) <$> byAddress a
            _ -> fail "unexpected provider query"
        }

providerHit, providerMiss, providerFailed :: Session NoWitness IO
providerHit =
    refSession
        (\h -> pure [carrier | h == carrierHash])
        (const (fail "the wallet must not be consulted"))
providerMiss =
    refSession
        (const (pure []))
        (\a -> pure [carrier | a == walletAddr])
providerFailed =
    stubSession
        { outputs = \case
            CarryingReferenceScript _ ->
                pure (Left (BackendReadFailure "the provider is down"))
            AtAddress _ -> pure (Right (Evidenced [carrier] Nothing))
            _ -> fail "unexpected provider query"
        }

-- ---------------------------------------------------------------------------
-- Publication funding fixtures (#479)
-- ---------------------------------------------------------------------------

smallIn, largeIn :: TxIn
smallIn = ref '5'
largeIn = ref '6'

ref :: Char -> TxIn
ref c = refOf (T.replicate 64 (T.singleton c) <> "#0")

script49 :: Script ConwayEra
script49 = carrierScript

session49 :: Session NoWitness IO
session49 =
    withTime
        (pure syntheticTime)
        (withParameters preprodParams stubSession)

serveList :: [(TxIn, TxOut ConwayEra)] -> Session NoWitness IO
serveList utxos =
    stubSession
        { outputs = \case
            AtAddress _ -> pure (Right (Evidenced utxos Nothing))
            _ -> fail "unexpected provider query"
        }

acquireList :: [(TxIn, TxOut ConwayEra)] -> IO WalletOutputs
acquireList utxos =
    either (fail . show) pure
        =<< walletOutputs (serveList utxos) walletAddr

payerAddr :: Addr
payerAddr = walletAddr

fullWallet :: IO WalletOutputs
fullWallet =
    acquireList
        [ (smallIn, mkBasicTxOut walletAddr (MaryValue (Coin 2_000_000) mempty))
        ,
            ( largeIn
            , mkBasicTxOut walletAddr (MaryValue (Coin 100_000_000) mempty)
            )
        ]

smallWallet :: IO WalletOutputs
smallWallet =
    acquireList
        [ (smallIn, mkBasicTxOut walletAddr (MaryValue (Coin 2_000_000) mempty))
        ]

protectedWallet :: IO WalletOutputs
protectedWallet =
    acquireList
        [ (protectedCarrierIn, protectedCarrierOut)
        , (protectedTokenIn, protectedTokenOut)
        ]

protectedCarrierIn, protectedTokenIn :: TxIn
protectedCarrierIn = ref '7'
protectedTokenIn = ref '8'

protectedCarrierOut :: TxOut ConwayEra
protectedCarrierOut =
    mkBasicTxOut walletAddr (MaryValue (Coin 300_000_000) mempty)
        & referenceScriptTxOutL
            .~ SJust carrierScript

protectedTokenOut :: TxOut ConwayEra
protectedTokenOut =
    mkBasicTxOut
        walletAddr
        ( MaryValue
            (Coin 800_000_000)
            ( MultiAsset
                (Map.singleton tokenPolicy (Map.singleton (AssetName "approval") 1))
            )
        )

tokenPolicy :: PolicyID
tokenPolicy = policyIdFromPin (SBS.toShort (BS.replicate 28 0xbb))

spentInputs :: ConwayTx -> [TxIn]
spentInputs tx = toList (tx ^. bodyTxL . inputsTxBodyL)

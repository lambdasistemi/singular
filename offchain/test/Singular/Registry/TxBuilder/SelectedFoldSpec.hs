{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.SelectedFoldSpec
Description : The fold builder spends exactly a chosen pending request
License     : Apache-2.0

Pull request 1 of #518 gives the fold builder an entry point over a
chosen set of pending request outputs. Today the builder spends every
pending request, so settling one among several cannot be built. The new
entry point takes the same arguments as the all-pending entry point
plus a non-empty list of request output references. It builds the fold
that spends the state output and exactly those request outputs among
those pending, with the redeemer action list for exactly those
requests. It fails, naming the reference, when a selected reference is
not among the pending outputs. The validity upper bound follows the
earliest deadline among the selected requests.

These rows execute the real builder against a stubbed chain view and a
fixture capability snapshot. Three pending requests on three distinct
keys with three distinct deadlines keep the choice and the all-pending
set apart. Every expected set is read from the pending outputs the
builder was given and the chosen reference, never typed.
-}
module Singular.Registry.TxBuilder.SelectedFoldSpec (spec) where

import Control.Exception (SomeException, displayException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, vldtTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (FromData (..))

import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId (..))
import Singular.Registry.LedgerProvider (Session, TipObservation (..))
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TrieState
    ( CreateRecord (..)
    , RegistryIdentity (..)
    , SessionBinding (..)
    , SessionId (..)
    , StatePoint (..)
    , StatePolicyId (..)
    , TrieSelection (..)
    , TrieSnapshot
    )
import Singular.Registry.TrieState.Fixture
    ( fixtureSnapshot
    , fixtureStore
    )
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.Internal.Identity
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , emptyRoot
    , mkInlineDatum
    , mkRequestDatumWith
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , emptyRegistryContext
    , updateTokenSelected
    , updateTokenWithTrieState
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    )

-- ---------------------------------------------------------
-- Fixtures: one registry, three pending requests
-- ---------------------------------------------------------

cfg :: CageConfig
cfg =
    Fixture.cfg
        { cageScriptBytes = unitProgram 1
        , cfgScriptHash = computeScriptHash (unitProgram 1)
        , requestScriptBytes = unitProgram 3
        }

tokenId :: TokenId
tokenId = Fixture.tokenId

payer :: Addr
payer = Fixture.payer

txIn :: Char -> Int -> TxIn
txIn c i =
    either
        (error . ("SelectedFoldSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

stateIn :: TxIn
stateIn = txIn 'b' 0

reqIn1, reqIn2, reqIn3 :: TxIn
reqIn1 = txIn 'a' 0
reqIn2 = txIn 'a' 1
reqIn3 = txIn 'a' 2

feeIn :: TxIn
feeIn = txIn 'e' 0

missingIn :: TxIn
missingIn = txIn 'f' 9

key1, key2, key3 :: ByteString
key1 = "test-key-1"
key2 = "test-key-2"
key3 = "test-key-3"

submitted1, submitted2, submitted3 :: Integer
submitted1 = 1_000
submitted2 = 2_000
submitted3 = 3_000

requestOut :: ByteString -> Integer -> TxOut ConwayEra
requestOut key submittedAt =
    mkBasicTxOut
        (requestAddrFromCfg cfg tokenId Testnet)
        (MaryValue (Coin 10_000_000) mempty)
        & datumTxOutL
            .~ mkInlineDatum
                ( mkRequestDatumWith
                    tokenId
                    payer
                    key
                    1
                    2_000_000
                    submittedAt
                    (serialiseAddr payer, Nothing)
                )

pendingReqs :: [(TxIn, TxOut ConwayEra)]
pendingReqs =
    [ (reqIn1, requestOut key1 submitted1)
    , (reqIn2, requestOut key2 submitted2)
    , (reqIn3, requestOut key3 submitted3)
    ]

deadlineOf :: Integer -> Integer
deadlineOf submittedAt = submittedAt + defaultProcessTime cfg

stateOut :: TxOut ConwayEra
stateOut =
    let TokenId name = tokenId
    in  mkBasicTxOut
            (cageAddrFromCfg cfg Testnet)
            ( MaryValue
                (Coin 2_000_000)
                ( MultiAsset
                    (Map.singleton (cagePolicyIdFromCfg cfg) (Map.singleton name 1))
                )
            )
            & datumTxOutL
                .~ mkInlineDatum
                    (toPlcData (StateDatum (bootStateFromCfg cfg (OnChainRoot emptyRoot))))

feeOut :: TxOut ConwayEra
feeOut = mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty)

-- ---------------------------------------------------------
-- Stubbed chain view and fixture capability snapshot
-- ---------------------------------------------------------

chainViewWith :: [(TxIn, TxOut ConwayEra)] -> Session NoWitness IO
chainViewWith reqs =
    withTip (TipObservation (SlotNo 1) (BS.replicate 32 0) 1 0) $
        withAddressOutputs
            ( \addr ->
                pure $
                    if addr == requestAddrFromCfg cfg tokenId Testnet
                        then reqs
                        else
                            if addr == cageAddrFromCfg cfg Testnet
                                then [(stateIn, stateOut)]
                                else [(feeIn, feeOut)]
            )
            ( withParameters (withSyntheticCosts Fixture.preprodParams) $
                withTime (pure syntheticTime) $
                    withResolvedOutputs
                        ( \wanted ->
                            pure
                                [ (reference, output)
                                | (reference, output) <-
                                    (stateIn, stateOut) : (feeIn, feeOut) : reqs
                                , reference `Set.member` wanted
                                ]
                        )
                        stubSession
            )

chainView :: Session NoWitness IO
chainView = chainViewWith pendingReqs

emptyView :: Session NoWitness IO
emptyView = chainViewWith []

snapshot :: TrieSnapshot IO
snapshot =
    let TokenId name = tokenId
        who =
            RegistryIdentity
                (StatePolicyId (scriptHashBytes (cfgScriptHash cfg)))
                name
        point = StatePoint (SessionId "selected-fold-fixture") Unbound stateIn
        chosen = TrieSelection who point (Root emptyRoot)
        store =
            fixtureStore
                [(chosen, Just (CreateRecord who stateIn), [], emptyMPFInMemoryDB)]
    in  either (error . show) id (fixtureSnapshot store chosen)

-- ---------------------------------------------------------
-- What the built fold carries
-- ---------------------------------------------------------

inputsOf :: ConwayTx -> Set.Set TxIn
inputsOf tx = tx ^. bodyTxL . inputsTxBodyL

upperOf :: ConwayTx -> SlotNo
upperOf tx = case tx ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust u) -> u
    _ -> error "SelectedFoldSpec: the built fold carries no upper bound"

actionsOf :: ConwayTx -> IO [RequestAction]
actionsOf tx =
    case [ actions
         | (_, (d, _)) <- Map.toList rdmrs
         , Just (Modify actions) <-
            [fromBuiltinData (BuiltinData (getPlutusData d))]
         ] of
        [actions] -> pure actions
        _ -> fail "the built fold carries other than one Modify action list"
  where
    Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL

ctx0 :: RegistryContext
ctx0 =
    emptyRegistryContext
        { rcWitnessScripts = Map.singleton 1 Fixture.applicationScript
        }

buildSelected :: TxIn -> IO ConwayTx
buildSelected = buildSelectedOn chainView

buildSelectedOn :: Session NoWitness IO -> TxIn -> IO ConwayTx
buildSelectedOn view ref = do
    let ctx = ctx0
    updateTokenSelected
        cfg
        view
        snapshot
        tokenId
        payer
        ctx
        (ref :| [])

buildAll :: IO ConwayTx
buildAll = do
    let ctx = ctx0
    updateTokenWithTrieState cfg chainView snapshot tokenId payer ctx

spec :: Spec
spec = describe "The fold builder over a chosen pending request" $ do
    it "spends the state output and exactly the chosen request output" $ do
        let chosen = reqIn2
            pendingRefs = map fst pendingReqs
            others = [r | r <- pendingRefs, r /= chosen]
        tx <- buildSelected chosen
        let spent = inputsOf tx
        (chosen `Set.member` spent) `shouldBe` True
        (stateIn `Set.member` spent) `shouldBe` True
        map (`Set.member` spent) others `shouldBe` [False, False]
        actions <- actionsOf tx
        length actions `shouldBe` 1
        case actions of
            [Update _] -> pure ()
            _ ->
                expectationFailure
                    "the redeemer carries other than the one chosen action"
    it "refuses a chosen reference that is not pending, naming it" $ do
        result <-
            try (buildSelected missingIn) :: IO (Either SomeException ConwayTx)
        case result of
            Left err ->
                displayException err `shouldSatisfy` isInfixOf (show missingIn)
            Right _ ->
                expectationFailure
                    "a chosen reference that is not pending built a fold"
        _ <- buildSelected reqIn1
        pure ()
    it "names the chosen reference when nothing is pending" $ do
        result <-
            try (buildSelectedOn emptyView reqIn1)
                :: IO (Either SomeException ConwayTx)
        case result of
            Left err ->
                displayException err `shouldSatisfy` isInfixOf (show reqIn1)
            Right _ ->
                expectationFailure
                    "an empty pending set built a fold"
    it "bounds the fold by the chosen request deadline" $ do
        txMid <- buildSelected reqIn2
        txAll <- buildAll
        txEarly <- buildSelected reqIn1
        let upperMid = upperOf txMid
            upperAll = upperOf txAll
            upperEarly = upperOf txEarly
            expectedMid = SlotNo (fromInteger (deadlineOf submitted2 `div` 1000))
            expectedAll = SlotNo (fromInteger (deadlineOf submitted1 `div` 1000))
        upperMid `shouldBe` expectedMid
        upperAll `shouldBe` expectedAll
        (upperMid == upperAll) `shouldBe` False
        upperEarly `shouldBe` upperAll

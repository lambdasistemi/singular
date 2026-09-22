{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.BurnSourceSpec
Description : #177 I177-BUILDER — the retirement burns a token it holds
License     : Apache-2.0

`updateTerminal` (edge ordinal 3) is the only registry edge whose token
column is a burn with no carrier output: @deltaOf 3 = [(active, -1)]@,
and the Lean transaction row
`Singular.Statements.update_terminal_transaction_row` puts the asset it
destroys on a WITNESS INPUT —
@{ role := .witness, assets := [((.active, r.key), 1)] }@ — and on no
output at all.

A mint of @-1@ with no such input is not a retirement. It is a claim the
ledger cannot settle and the cage refuses (`token-missing`), so a builder
that emits it has produced a transaction whose only possible outcome is a
refusal. The failure belongs HERE, in the builder, where it is cheap and
named — the same rule `registryDuties` already applies to the custody an
`updateActive` spends.

These rows are pure. `registryDuties` is the ONE place the off-chain side
decides what an edge owes; it is the decision site this ticket changes,
and these rows assert what it decides, not what a node later does with it.
-}
module Singular.Registry.TxBuilder.BurnSourceSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Either (isLeft, isRight)
import Data.Word (Word8)
import Test.Hspec

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn)
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins (toBuiltin)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.TxBuilder.ConnectedFold (ConnectedSpend (..))
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    computeScriptHash,
    extractCageDatum,
    mkInlineDatum,
    policyIdFromPin,
    scriptFromBytes,
    toPlcData,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext (..),
    RegistryDuties (..),
    emptyRegistryContext,
    registryDuties,
 )
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenId (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
    edgeDeleteAbsent,
    edgeInsertAbsent,
    edgeUpdateActive,
    edgeUpdateTerminal,
 )

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text qualified as T

-- ---------------------------------------------------------
-- Fixtures: one registry, two keys
-- ---------------------------------------------------------

keyA, keyB :: ByteString
keyA = "t177-key-a"
keyB = "t177-key-b"

-- | The edge under test, spelled once.
retirement :: Edge
retirement = edgeUpdateTerminal

{- | A 28-byte policy pin, one distinct byte per kind, so a row that
swept the wrong policy could not accidentally agree with the right one.
-}
pin :: Word8 -> SBS.ShortByteString
pin b = SBS.toShort (BS.replicate 28 b)

cfg :: CageConfig
cfg =
    CageConfig
        { cageScriptBytes = SBS.toShort (BS.pack [0x01])
        , requestScriptBytes = SBS.toShort (BS.pack [0x02])
        , cfgScriptHash = computeScriptHash (SBS.toShort (BS.pack [0x01]))
        , cageSeed = seedRef
        , defaultProcessTime = 30000
        , defaultRetractTime = 30000
        , defaultTip = Coin 1000000
        , cfgApplicationPolicy = pin 0xa1
        , cfgActivePolicy = pin 0xa2
        , cfgAbsentPolicy = pin 0xa3
        , cfgTerminalPolicy = pin 0xa4
        , cfgConsumerScript = SBS.empty
        , network = Testnet
        }

seedRef :: OnChainTxOutRef
seedRef = case parseOutRef (T.pack (replicate 64 '1' <> "#0")) of
    Right r -> txInToRef r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

tokenState :: OnChainTokenState
tokenState =
    OnChainTokenState
        { stateRoot = OnChainRoot BS.empty
        , stateMaxFee = 1000000
        , stateProcessTime = 30000
        , stateRetractTime = 30000
        , stateAppPolicy = toBuiltin (SBS.fromShort (cfgApplicationPolicy cfg))
        , stateActivePolicy = toBuiltin (SBS.fromShort (cfgActivePolicy cfg))
        , stateAbsentPolicy = toBuiltin (SBS.fromShort (cfgAbsentPolicy cfg))
        , stateTerminalPolicy = toBuiltin (SBS.fromShort (cfgTerminalPolicy cfg))
        }

requestIn :: TxIn
requestIn = case parseOutRef (T.pack (replicate 64 '2' <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

{- | A request UTxO carrying `op` at `keyA`, and NO approval asset: the
approval-return leg is not what these rows are about, and a request
carrying none leaves it untouched.
-}
requestFor :: Edge -> (TxIn, TxOut ConwayEra)
requestFor edge =
    ( requestIn
    , mkBasicTxOut (cageAddrFromCfg cfg Testnet) (MaryValue (Coin 3000000) mempty)
        & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req))
    )
  where
    req =
        OnChainRequest
            { requestToken = OnChainTokenId (toBuiltin ("t177-registry" :: ByteString))
            , requestOwner = toBuiltin (BS.replicate 28 0x5a)
            , requestKey = keyA
            , requestEdge = edge
            , requestDeposit = 2000000
            , requestSubmittedAt = 0
            , requestDestination = ("", "")
            }

{- | The three witness policies the fold mints under. Their BYTES do
not matter to these rows — only that the builder has one per kind, so a
`Left` below is about the burn source and never about a missing script.
-}
witnessScripts :: RegistryContext
witnessScripts =
    emptyRegistryContext
        { rcWitnessScripts =
            Map.fromList
                [ (k, scriptFromBytes "t177 witness" (SBS.toShort (BS.pack [0x59, fromIntegral k])))
                | k <- [0, 1, 2]
                ]
        }

-- | What the builder decides this single request owes.
decide :: Edge -> Either String ()
decide edge =
    ()
        <$ registryDuties
            cfg
            emptyPParams
            tokenState
            witnessScripts
            [requestFor edge]
            [True]

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec = do
    custodyIdentity
    holderSelection
    burnSourceRequired

-- ---------------------------------------------------------
-- #178: absent custody identity comes from its sole asset
-- ---------------------------------------------------------

custodyRef :: TxIn
custodyRef = holderIn 8

refund :: ByteString
refund = serialiseAddr (cageAddrFromCfg cfg Testnet)

refundOnly, retiredTwoField :: PLC.Data
refundOnly = PLC.Constr 2 [PLC.B refund]
retiredTwoField = PLC.Constr 2 [PLC.B keyA, PLC.B refund]

custodyValue :: SBS.ShortByteString -> ByteString -> Integer -> MaryValue
custodyValue policy key quantity =
    MaryValue
        (Coin 10000000)
        ( MultiAsset
            ( Map.singleton
                (policyIdFromPin policy)
                (Map.singleton (AssetName (SBS.toShort key)) quantity)
            )
        )

twoAssetCustodyValue :: MaryValue
twoAssetCustodyValue =
    MaryValue
        (Coin 10000000)
        ( MultiAsset
            ( Map.fromList
                [
                    ( policyIdFromPin (cfgAbsentPolicy cfg)
                    , Map.singleton (AssetName (SBS.toShort keyA)) 1
                    )
                ,
                    ( policyIdFromPin (cfgActivePolicy cfg)
                    , Map.singleton (AssetName (SBS.toShort keyB)) 1
                    )
                ]
            )
        )

custodyWith :: PLC.Data -> MaryValue -> (TxIn, TxOut ConwayEra)
custodyWith datum value =
    ( custodyRef
    , mkBasicTxOut (cageAddrFromCfg cfg Testnet) value
        & datumTxOutL .~ mkInlineDatum datum
    )

decideCustody :: (TxIn, TxOut ConwayEra) -> Either String RegistryDuties
decideCustody held =
    registryDuties
        cfg
        emptyPParams
        tokenState
        custodyContext
        [requestFor edgeDeleteAbsent]
        [True]
  where
    cageScript = scriptFromBytes "t178 cage" (SBS.toShort (BS.pack [0x58]))
    custodyContext =
        witnessScripts
            { rcCageScript = Just cageScript
            , rcCageUtxos = [held]
            }

expectAssetRefusal :: (TxIn, TxOut ConwayEra) -> Expectation
expectAssetRefusal held@(_, out) = do
    extractCageDatum out `shouldSatisfy` isJust
    (() <$ decideCustody held) `shouldSatisfy` isLeft

custodyIdentity :: Spec
custodyIdentity = describe "#178: absent custody derives identity from its sole asset" $ do
    it "selects a refund-only custody carrying one absent asset" $ do
        let held = custodyWith refundOnly (custodyValue (cfgAbsentPolicy cfg) keyA 1)
        extractCageDatum (snd held) `shouldSatisfy` isJust
        case decideCustody held of
            Left err -> expectationFailure err
            Right duties -> map (fst . csUtxo) (rdSpends duties) `shouldBe` [custodyRef]

    it "does not use the retired datum key as an identity fallback" $
        ( ()
            <$ decideCustody
                (custodyWith retiredTwoField (custodyValue (cfgAbsentPolicy cfg) keyA 1))
        )
            `shouldSatisfy` isLeft

    it "refuses refund-only custody with no non-ADA asset" $
        expectAssetRefusal (custodyWith refundOnly (MaryValue (Coin 10000000) mempty))

    it "refuses refund-only custody with two non-ADA assets" $
        expectAssetRefusal (custodyWith refundOnly twoAssetCustodyValue)

    it "refuses refund-only custody under the wrong policy" $
        expectAssetRefusal
            (custodyWith refundOnly (custodyValue (cfgActivePolicy cfg) keyA 1))

    it "refuses refund-only custody with a quantity other than one" $
        expectAssetRefusal
            (custodyWith refundOnly (custodyValue (cfgAbsentPolicy cfg) keyA 2))

burnSourceRequired :: Spec
burnSourceRequired = describe "#177 I177-BUILDER: updateTerminal sources its burn from a holder" $ do
    -- The row under test. With nothing in hand that carries the key's
    -- active witness, the only transaction this edge could produce mints
    -- `-1` against no input — the shape the cage refuses `token-missing`.
    -- The builder must say so instead of handing back a fold.
    it "refuses to build the retirement when nothing holds the key's active witness" $
        decide retirement `shouldSatisfy` isLeft

    -- The control for the row above, and the reason it is not vacuous:
    -- `updateActive` at the same key, through the same call, with the
    -- same empty context, ALREADY fails — for its own missing custody.
    -- So `registryDuties` is demonstrably able to return `Left` here,
    -- and a green row above is about the retirement, not about the
    -- harness.
    it "already refuses updateActive with no custody in hand (the harness can fail)" $
        decide edgeUpdateActive `shouldSatisfy` isLeft

    -- The other direction: an edge that owes nothing beyond its mint
    -- must still build from the same empty context, so `Left` above is
    -- attributable to the missing witness rather than to the fixture.
    it "still builds an edge that owes no external input (insertAbsent)" $
        decide edgeInsertAbsent `shouldSatisfy` isRight

{- | The candidate burn-source inventory the builder selects from: wallet
outputs that actually hold registry witnesses.
-}
holding :: [(TxIn, TxOut ConwayEra)] -> RegistryContext
holding utxos = witnessScripts{rcHolderUtxos = utxos}

-- | One wallet UTxO holding `quantity` of the active witness for `key`.
holderOf :: Int -> ByteString -> Integer -> (TxIn, TxOut ConwayEra)
holderOf i key quantity =
    ( holderIn i
    , mkBasicTxOut
        (cageAddrFromCfg cfg Testnet)
        ( MaryValue
            (Coin 2000000)
            ( MultiAsset
                ( Map.singleton
                    (policyIdFromPin (cfgActivePolicy cfg))
                    (Map.singleton (AssetName (SBS.toShort key)) quantity)
                )
            )
        )
    )

holderIn :: Int -> TxIn
holderIn i = case parseOutRef (T.pack (replicate 63 '3' <> show i <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

-- | What the builder decides, with a candidate inventory in hand.
decideWith :: RegistryContext -> Edge -> Either String RegistryDuties
decideWith ctx edge =
    registryDuties cfg emptyPParams tokenState ctx [requestFor edge] [True]

{- | The same decision with the duties discarded. `RegistryDuties` holds
ledger values that have no `Show`, and a row that only asks WHETHER the
builder refused does not need them.
-}
refusedWith :: RegistryContext -> Edge -> Either String ()
refusedWith ctx edge = () <$ decideWith ctx edge

{- | The rows that need the candidate inventory: selection is exact in
both directions, and the selected UTxO is the one the fold consumes.
-}
holderSelection :: Spec
holderSelection = describe "#177 I177-BUILDER: the burn source is selected exactly" $ do
    it "takes the key's own holder as an input of the fold" $
        case decideWith (holding [holderOf 1 keyA 1]) retirement of
            Left err -> expectationFailure err
            Right d -> map fst (rdInputs d) `shouldBe` [holderIn 1]

    -- Non-vacuity, the direction that matters most here: a builder that
    -- swept whatever it found would pass the row above and this one
    -- too, so the wrong key is offered ALONE. Nothing else in the
    -- inventory can rescue it.
    it "does not sweep another key's holder" $
        refusedWith (holding [holderOf 1 keyB 1]) retirement `shouldSatisfy` isLeft

    -- And with both in hand it must still take exactly the right one,
    -- which an inventory-order accident would not survive.
    it "picks this key's holder out of an inventory that holds both" $
        case decideWith (holding [holderOf 1 keyB 1, holderOf 2 keyA 1]) retirement of
            Left err -> expectationFailure err
            Right d -> map fst (rdInputs d) `shouldBe` [holderIn 2]

    it "refuses an inventory carrying the witness twice over" $
        refusedWith (holding [holderOf 1 keyA 1, holderOf 2 keyA 1]) retirement
            `shouldSatisfy` isLeft

    it "refuses a holder carrying more than one of the witness" $
        refusedWith (holding [holderOf 1 keyA 2]) retirement `shouldSatisfy` isLeft

    -- The retirement creates no carrier: the Lean row has the active
    -- asset on an input and on no output at all.
    it "creates no output carrying the asset it burns" $
        case decideWith (holding [holderOf 1 keyA 1]) retirement of
            Left err -> expectationFailure err
            Right d -> rdOutputs d `shouldBe` []

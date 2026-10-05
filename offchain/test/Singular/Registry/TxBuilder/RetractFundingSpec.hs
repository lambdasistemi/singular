{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.RetractFundingSpec
Description : #300 — a retraction is funded and collateralised by an output that can carry it
License     : Apache-2.0

The retraction reclaims a refused request's bond, so on a permanent registry
it runs every time a refusal leaves one behind. It is funded and
collateralised by one wallet output, and a wallet that also holds a larger
output carrying a token or a published script must not lose or fail on it:
the funding output holds ada and nothing else and is not a reference
publication. Whatever it funds, the retraction states its total collateral
and returns the rest, pays the ledger's fee and leaves every output its
minimum. Expected values come from the wallet the generator drew and the
ledger's own functions under the public preprod parameters.
-}
module Singular.Registry.TxBuilder.RetractFundingSpec (spec) where

import Control.Exception (SomeException, displayException, try)
import Data.List (isInfixOf, maximumBy)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , chooseInteger
    , conjoin
    , forAll
    , ioProperty
    , listOf1
    , property
    , (===)
    )

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body (vldtTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.Provider (ChainPoint (..), View (..))
import Singular.Registry.StubView (stubView)
import Singular.Registry.TxBuilder.BookingFixture
    ( applicationScript
    , cfg
    , payer
    , preprodParams
    , tokenId
    )
import Singular.Registry.TxBuilder.CollateralJudgement
    ( Spend (..)
    , judgeCollateral
    )
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , currentPosixMs
    , emptyRoot
    , mkInlineDatum
    , mkRequestDatumWith
    , requestAddrFromCfg
    , toPlcData
    )
import Singular.Registry.TxBuilder.Reject (rejectRequestsImpl)
import Singular.Registry.TxBuilder.Retract
    ( retractRequestAtTipImpl
    , retractRequestImpl
    )
import Singular.Registry.Types (CageDatum (..), OnChainRoot (..))

txIn :: Char -> Int -> TxIn
txIn c i =
    either
        (error . ("RetractFundingSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

requestIn, stateIn, tokenHeldIn, publicationIn :: TxIn
requestIn = txIn 'a' 0
stateIn = txIn 'b' 0
tokenHeldIn = txIn 'c' 0
publicationIn = txIn 'd' 0

-- | The bond the request locks: its tip and deposit.
bond :: Integer
bond = 3_000_000

-- | The request script's address and the pending request, submitted at a time.
requestOut :: Integer -> TxOut ConwayEra
requestOut submittedAt =
    mkBasicTxOut
        (requestAddrFromCfg cfg tokenId Testnet)
        (MaryValue (Coin bond) mempty)
        & datumTxOutL
            .~ mkInlineDatum
                ( mkRequestDatumWith
                    tokenId
                    payer
                    "a-key"
                    1
                    2_000_000
                    submittedAt
                    ("", "")
                )

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

-- | A larger output holding a token, and a larger one publishing a script.
tokenHeldOut, publicationOut :: Integer -> TxOut ConwayEra
tokenHeldOut lovelace =
    mkBasicTxOut
        payer
        ( MaryValue
            (Coin lovelace)
            ( MultiAsset
                ( Map.singleton
                    (PolicyID (cfgScriptHash cfg))
                    (Map.singleton (AssetName "approval") 1)
                )
            )
        )
publicationOut lovelace =
    mkBasicTxOut payer (MaryValue (Coin lovelace) mempty)
        & referenceScriptTxOutL .~ SJust applicationScript

data Scenario = Scenario
    { scAda :: [Integer]
    -- ^ the ada-only outputs
    , scTrap :: Integer
    -- ^ how much more than the largest ada-only output the traps hold
    }
    deriving stock (Show)

genScenario :: Gen Scenario
genScenario =
    Scenario
        <$> listOf1 (chooseInteger (9_000_000, 12_000_000_000))
        <*> chooseInteger (1_000_000, 5_000_000_000)

wallet :: Scenario -> [(TxIn, TxOut ConwayEra)]
wallet sc =
    [ (txIn 'e' i, mkBasicTxOut payer (MaryValue (Coin l) mempty))
    | (i, l) <- zip [0 ..] (scAda sc)
    ]
        <> [ (tokenHeldIn, tokenHeldOut (largest sc + scTrap sc))
           , (publicationIn, publicationOut (largest sc + scTrap sc + 1))
           ]

largest :: Scenario -> Integer
largest = maximum . scAda

-- | The output the design funds from: the largest that is ada-only and no publication.
fundingOf :: Scenario -> (TxIn, Integer)
fundingOf sc =
    maximumBy
        (comparing snd)
        [(txIn 'e' i, l) | (i, l) <- zip [0 ..] (scAda sc)]

chainView :: Scenario -> Integer -> Maybe Integer -> View IO
chainView sc submittedAt horizon =
    stubView
        { viewPoint =
            (viewPoint stubView)
                { cpSlot =
                    SlotNo
                        (fromInteger ((submittedAt + defaultProcessTime cfg + 999) `div` 1000))
                }
        , viewUTxOsAt = \addr ->
            pure $
                if addr == requestAddrFromCfg cfg tokenId Testnet
                    then [(requestIn, requestOut submittedAt)]
                    else
                        if addr == cageAddrFromCfg cfg Testnet
                            then [(stateIn, stateOut)]
                            else wallet sc
        , viewProtocolParams = preprodParams
        , viewEvaluateTx = \tx ->
            let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
            in  pure (Map.map (const (Right (ExUnits 400_000 150_000_000))) m)
        , viewPosixMsToSlot = \ms -> case horizon of
            Just limit | ms > limit -> fail "PastHorizon"
            _ -> pure (SlotNo (fromIntegral (ms `div` 1000)))
        , viewPosixMsCeilSlot = \ms -> pure (SlotNo (fromIntegral ((ms + 999) `div` 1000)))
        }

spec :: Spec
spec = do
    rejectValidity
    retractValidity
    retractFunding

{- | These rows inspect the actual reject body. Scripts and evaluation are
fixtures, so this establishes builder bounds rather than node acceptance.
-}
rejectValidity :: Spec
rejectValidity = describe "a reject's validity starts at the acquired view's tip" $ do
    it "never starts ahead of a tip lagging the host clock" $
        property $
            forAll (chooseInteger (1, 600)) $ \lag -> ioProperty $ do
                now <- currentPosixMs
                let view = rejectView (slotOf (now - lag * 1000)) Nothing
                    tip = cpSlot (viewPoint view)
                tx <- rejectRequestsImpl cfg view tokenId payer
                let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                pure $
                    conjoin
                        [ property (lower <= SJust tip)
                        , lower === SJust tip
                        , property (upper > lower)
                        ]
    it "keeps a nonempty interval when the host clock is behind the tip" $ do
        now <- currentPosixMs
        let view = rejectView (slotOf (now + 300_000)) Nothing
        tx <- rejectRequestsImpl cfg view tokenId payer
        let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
        lower `shouldBe` SJust (cpSlot (viewPoint view))
        upper `shouldSatisfy` (> lower)
    it "keeps the upper-bound fallback inside the conversion horizon" $ do
        now <- currentPosixMs
        let view = rejectView (slotOf (now - 36_000)) (Just (now + 10_000))
        tx <- rejectRequestsImpl cfg view tokenId payer
        let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
        lower `shouldBe` SJust (cpSlot (viewPoint view))
        upper `shouldSatisfy` (> lower)
        upper `shouldSatisfy` (<= SJust (slotOf (now + 10_000)))
  where
    slotOf ms = SlotNo (fromInteger (ms `div` 1000))
    rejectView tip horizon =
        let view = chainView (Scenario [100_000_000] 1_000_000) 1_000 horizon
        in  view{viewPoint = (viewPoint view){cpSlot = tip}}

{- | Both public entry points must refuse a future lower bound rather
than return a transaction the acquired ledger cannot accept yet.
-}
retractValidity :: Spec
retractValidity = describe "a retraction never starts ahead of its acquired view" $ do
    it
        "refuses when phase two opens after the view tip, through either entry point"
        $ property
        $ forAll (chooseInteger (0, 30))
        $ \tip -> ioProperty $ do
            let view = atTip (SlotNo (fromInteger tip))
            mapM_
                refuses
                [ retractRequestImpl cfg view tokenId requestIn payer
                , retractRequestAtTipImpl
                    (cpSlot (viewPoint view))
                    cfg
                    view
                    tokenId
                    requestIn
                    payer
                ]
            pure True
    it "refuses a caller-supplied lower bound ahead of the acquired tip" $ do
        let view = atTip (SlotNo 40)
        refuses
            (retractRequestAtTipImpl (SlotNo 41) cfg view tokenId requestIn payer)
    it "admits phase two's opening slot through either entry point" $ do
        let view = atTip (SlotNo 31)
        mapM_
            ( \build -> do
                tx <- build
                let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                lower `shouldBe` SJust (cpSlot (viewPoint view))
                upper `shouldSatisfy` (> lower)
            )
            [ retractRequestImpl cfg view tokenId requestIn payer
            , retractRequestAtTipImpl
                (cpSlot (viewPoint view))
                cfg
                view
                tokenId
                requestIn
                payer
            ]
  where
    atTip tip =
        let view = chainView (Scenario [100_000_000] 1_000_000) 1_000 Nothing
        in  view{viewPoint = (viewPoint view){cpSlot = tip}}
    refuses build = do
        result <- try @SomeException build
        case result of
            Left err ->
                displayException err
                    `shouldSatisfy` isInfixOf "lower-bound-ahead-of-view"
            Right tx -> do
                let interval = tx ^. bodyTxL . vldtTxBodyL
                expectationFailure ("built a future retraction: " <> show interval)

retractFunding :: Spec
retractFunding =
    describe
        "a retraction is funded and collateralised by an output that can carry it (#300)"
        $ do
            it
                "funds from the largest ada-only output, never a larger token or publication, and states its collateral"
                $ property
                $ forAll genScenario
                $ \sc -> ioProperty $ do
                    tx <-
                        retractRequestAtTipImpl
                            (SlotNo 0)
                            cfg
                            (chainView sc 1_000 Nothing)
                            tokenId
                            requestIn
                            payer
                    let (funding, fundingValue) = fundingOf sc
                        spend =
                            Spend
                                { spInputs = [(requestIn, bond), (funding, fundingValue)]
                                , spFunding = funding
                                , spRefBytes = 0
                                }
                    pure (judgeCollateral spend tx === [])
            it
                "is built with a validity bound inside its window when the window's end is past the node's horizon"
                $ property
                $ forAll genScenario
                $ \sc -> ioProperty $ do
                    now <- currentPosixMs
                    let processTime = defaultProcessTime cfg
                        retractTime = defaultRetractTime cfg
                        -- phase 2 opened a second ago; the node translates nothing
                        -- more than ten seconds ahead
                        submittedAt = now - processTime - 1_000
                        windowEnd = submittedAt + processTime + retractTime
                        windowStart = submittedAt + processTime
                    tx <-
                        retractRequestAtTipImpl
                            (SlotNo 0)
                            cfg
                            (chainView sc submittedAt (Just (now + 10_000)))
                            tokenId
                            requestIn
                            payer
                    let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                        secondsOf ms = fromIntegral (ms `div` 1000) :: Integer
                    pure
                        ( conjoin
                            [ property
                                (lower >= SJust (SlotNo (fromIntegral (secondsOf windowStart))))
                            , property (upper > lower)
                            , property
                                ( case upper of
                                    SJust (SlotNo u) -> toInteger u < secondsOf windowEnd
                                    SNothing -> False
                                )
                            ]
                        )

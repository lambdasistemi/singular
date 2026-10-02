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

import Data.List (maximumBy)
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
import Singular.Registry.Provider (View (..))
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
import Singular.Registry.TxBuilder.Retract (retractRequestAtTipImpl)
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
        { viewUTxOsAt = \addr ->
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
spec =
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

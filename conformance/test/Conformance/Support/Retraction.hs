{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

{- | A live retraction's collateral, as the ledger checks it.

Appendix material: the runner takes the offchain builder's balanced
retraction, collateralises it by a dedicated pot and declares its units and
fee. The ledger's own collateral rule judges the declared transaction against
the pot it names, before any script runs.
-}
module Conformance.Support.Retraction (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec (Spec, describe, expectationFailure, it)
import Validation (validationToEither)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..), Prices (..))
import Cardano.Ledger.Api.PParams (
    CoinPerByte (..),
    PParams,
    emptyPParams,
    ppCoinsPerUTxOByteL,
    ppCollateralPercentageL,
    ppTxFeeFixedL,
    ppTxFeePerByteL,
    ppPricesL,
 )
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Babbage.Rules (validateTotalCollateral)
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..), boundRational)
import Cardano.Ledger.Coin (Coin (..), CompactForm (CompactCoin))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Balance (BalanceResult (..), balanceTx)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.TxBuilder.Internal (
    addrFromKeyHashBytes,
    mkInlineDatum,
    placeholderExUnits,
    spendingIndex,
    toLedgerData,
    toPlcData,
    txInToRef,
 )
import Singular.Registry.Types (UpdateRedeemer (Retract))

import Conformance.Run.Retraction (declareRetraction)

{- | The devnet genesis's fee and collateral parameters
(@genesis/shelley-genesis.json@, @genesis/alonzo-genesis.json@).
-}
devnetParams :: PParams ConwayEra
devnetParams =
    emptyPParams
        & ppTxFeePerByteL .~ CoinPerByte (CompactCoin 44)
        & ppTxFeeFixedL .~ Coin 155_381
        & ppCoinsPerUTxOByteL .~ CoinPerByte (CompactCoin 4_310)
        & ppCollateralPercentageL .~ 150
        & ppPricesL .~ Prices
            (fromJust (boundRational (577 / 10_000)))
            (fromJust (boundRational (721 / 10_000_000)))

-- | The wallet the runner signs with: owner, fee payer and change.
wallet :: Addr
wallet = addrFromKeyHashBytes Testnet (BS.replicate 28 7)

-- | A distinct output reference, named by the ledger's own transaction id.
reference :: Integer -> TxIn
reference n = TxIn (txIdTx (mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin n) :: ConwayTx)) (TxIx 0)

ada :: Integer -> TxOut ConwayEra
ada lovelace = mkBasicTxOut wallet (MaryValue (Coin lovelace) mempty)

{- | The retraction as the offchain builder hands it over: the request spent
alone under a @Retract@ redeemer, its lovelace returned to the owner bound to
the request's reference, the wallet's largest output as fee input and
collateral, balanced by the builder's own balancer.
-}
builderRetraction :: Integer -> (TxIn, TxOut ConwayEra) -> Either String ConwayTx
builderRetraction bond funder = do
    let requestIn = reference 1
        request = (requestIn, ada bond)
        inputs = Set.fromList [requestIn, fst funder]
        refund = ada bond & datumTxOutL .~ mkInlineDatum (toPlcData (txInToRef requestIn))
        redeemers = Redeemers (Map.singleton
            (ConwaySpending (AsIx (spendingIndex requestIn inputs)))
            (toLedgerData (Retract (txInToRef (reference 2))), placeholderExUnits))
        unbalanced = mkBasicTx (mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton requestIn
                & outputsTxBodyL .~ StrictSeq.singleton refund
                & collateralInputsTxBodyL .~ Set.singleton (fst funder))
            & witsTxL . rdmrsTxWitsL .~ redeemers
    either (Left . show) (Right . balancedTx)
        (balanceTx devnetParams [funder, request] [] wallet unbalanced)

-- | What the ledger's collateral rule says of a transaction whose collateral is this pot.
collateralVerdict :: (TxIn, TxOut ConwayEra) -> ConwayTx -> Either String ()
collateralVerdict pot transaction =
    either (Left . show) Right $ validationToEither $
        validateTotalCollateral @ConwayEra @"UTXO" devnetParams (transaction ^. bodyTxL)
            (Map.fromList [pot])

spec :: Spec
spec = describe "A live retraction's collateral" $ do
    -- The runner's pot: a 5 ADA ada-only output of its own wallet.
    let pot = (reference 3, ada 5_000_000)
        -- Funders on either side of the pot: the devnet's genesis scale and a
        -- wallet barely larger than the pot.
        funders = [("the devnet's genesis funder", 30_000_000_000_000_000), ("a small funder", 20_000_000)]
        -- Per-purpose units as the runner declares them: the builder's own,
        -- the probe allowance and the twice-measured untampered retraction.
        allowances =
            [ ("the builder's own units", const Nothing)
            , ("the probe allowance", const (Just (ExUnits 1_400_000 500_000_000)))
            , ("twice the measured units", const (Just (ExUnits 582_686 201_987_952)))
            ]
    mapM_ (\(funderName, funderLovelace) -> mapM_ (\(unitsName, unitsOf) ->
        it ("balances against the pot the ledger is shown, from " <> funderName <> " with " <> unitsName) $ do
            let outcome = do
                    honest <- builderRetraction 3_000_000 (reference 4, ada funderLovelace)
                    let Redeemers purposes = honest ^. witsTxL . rdmrsTxWitsL
                        units = Map.fromList
                            [ (T.pack (show purpose), declared)
                            | purpose <- Map.keys purposes, Just declared <- [unitsOf purpose] ]
                    declared <- declareRetraction devnetParams units (fst pot) 0 wallet honest
                    collateralVerdict pot declared
            either expectationFailure pure outcome) allowances) funders

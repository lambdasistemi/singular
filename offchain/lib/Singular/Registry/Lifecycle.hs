{-# LANGUAGE OverloadedStrings #-}

{- | Funding and evaluation for the public-node lifecycle. The devnet row
suites keep their own fixtures; these helpers never submit a refusal probe.
-}
module Singular.Registry.Lifecycle (
    lifecycleRequested,
    protocolFeeReserve,
    minimumCoin,
    fundedOutput,
    collateralOutput,
    requestDeposit,
    sizedOutput,
    verifyLifecycleBudget,
    fundingRequirement,
    fundLifecycle,
    fundingProvider,
    checkExecutionLimit,
    prepareLifecycleTx,
) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams (ppCollateralPercentageL, ppMaxTxExUnitsL, ppMaxTxSizeL, ppTxFeePerByteL)
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, estimateMinFeeTx, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, mkBasicTxBody, outputsTxBodyL, scriptIntegrityHashTxBodyL)
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, datumTxOutL, getMinCoinTxOut, mkBasicTxOut, referenceScriptTxOutL, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Coin (CoinPerByte (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Balance (BalanceResult (..), balanceFeeLoop, balanceTx, refScriptsSize)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusLedgerApi.V3 qualified as PLC

import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams, TokenId)
import Singular.Registry.Node (ExternalNode (..), NodeMode (..), NodeSession (..), awaitTx, funderAddr, funderSignKey)
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.Internal (computeScriptIntegrity, mkInlineDatum, mkRequestDatum, requestAddrFromCfg)
import Singular.Registry.TxBuilder.Request (requestLockedAda)
import Singular.Registry.Types (OnChainOperation)

{- | Public external nodes use the lifecycle automatically. The explicit flag
also exercises that path on the factory devnet (network magic 42).
-}
lifecycleRequested :: NodeSession -> [String] -> Bool
lifecycleRequested sess args =
    "--lifecycle" `elem` args || case nsMode sess of
        External e -> extMagic e /= 42
        Devnet -> False

{- | A funding allowance, not the fee charged: one maximum-size transaction,
the live aggregate execution limit, and the actual reference scripts.
Each submitted transaction is subsequently evaluated and balanced exactly.
-}
protocolFeeReserve :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> Coin
protocolFeeReserve pp refs =
    let dummy =
            mkBasicTx mkBasicTxBody
                & witsTxL . rdmrsTxWitsL
                    .~ Redeemers
                        ( Map.singleton
                            (ConwayMinting (AsIx 0))
                            (Data (PLC.Constr 0 []), pp ^. ppMaxTxExUnitsL)
                        )
        Coin measured = estimateMinFeeTx pp dummy 2 0 (refScriptsSize (Set.fromList (map fst refs)) refs)
        CoinPerByte compactPerByte = pp ^. ppTxFeePerByteL
        Coin perByte = fromCompact compactPerByte
     in Coin (measured + perByte * fromIntegral (pp ^. ppMaxTxSizeL))

-- | Ten percent above the live minimum, recomputed with the final coin width.
minimumCoin :: PParams ConwayEra -> TxOut ConwayEra -> Coin
minimumCoin pp out =
    let Coin first = getMinCoinTxOut pp out
        Coin final = getMinCoinTxOut pp (out & coinTxOutL .~ Coin ((first * 110 + 99) `div` 100))
     in Coin ((final * 110 + 99) `div` 100)

-- | Only the change and live fee allowance are added to actual deposits.
fundedOutput :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> Addr -> Coin -> TxOut ConwayEra
fundedOutput pp refs addr deposit =
    let probe = mkBasicTxOut addr (MaryValue (Coin 0) mempty)
     in probe & coinTxOutL .~ (deposit <> protocolFeeReserve pp refs <> minimumCoin pp probe <> minimumCoin pp probe)

collateralOutput :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> Addr -> TxOut ConwayEra
collateralOutput pp refs addr =
    let Coin fee = protocolFeeReserve pp refs
        probe = mkBasicTxOut addr (MaryValue (Coin 0) mempty)
        collateral = Coin ((fee * fromIntegral (pp ^. ppCollateralPercentageL) + 99) `div` 100)
     in probe & coinTxOutL .~ max (minimumCoin pp probe) collateral

sizedOutput :: Bool -> PParams ConwayEra -> TxOut ConwayEra -> TxOut ConwayEra
sizedOutput False _ out = out
sizedOutput True pp out = out & coinTxOutL .~ minimumCoin pp out

requestDeposit :: PParams ConwayEra -> CageConfig -> TokenId -> Addr -> ByteString -> OnChainOperation -> Integer -> Coin
requestDeposit pp cfg tok addr spelling operation now =
    let draft =
            mkBasicTxOut (requestAddrFromCfg cfg tok (network cfg)) (MaryValue (Coin 0) mempty)
                & datumTxOutL .~ mkInlineDatum (mkRequestDatum tok addr spelling operation 1000000 now)
     in requestLockedAda pp draft (mkBasicTxOut addr (MaryValue (Coin 0) mempty)) 1000000

{- | Connected-fold builders already balance node-evaluated budgets. Check
their aggregate before signing without changing semantic refund outputs.
-}
verifyLifecycleBudget :: Bool -> PParams ConwayEra -> ConwayTx -> IO ()
verifyLifecycleBudget False _ _ = pure ()
verifyLifecycleBudget True pp tx = do
    let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    total <- either fail pure (checkExecutionLimit (pp ^. ppMaxTxExUnitsL) (map snd (Map.elems redeemers)))
    putStrLn ("lifecycle connected budget: " <> show total <> "; fee=" <> show (tx ^. bodyTxL . feeTxBodyL))

fundingRequirement :: PParams ConwayEra -> [TxOut ConwayEra] -> Coin
fundingRequirement pp outs =
    let Coin fees = protocolFeeReserve pp []
        Coin change = minimumCoin pp (mkBasicTxOut funderAddr (MaryValue (Coin 0) mempty))
     in Coin (sum [c | o <- outs, let { Coin c = o ^. coinTxOutL }] + fees + change)

-- | Keep request funding away from references and inputs reserved for later steps.
fundingProvider :: [TxIn] -> Provider IO -> Provider IO
fundingProvider reserved prov = prov
    { queryUTxOs = \addr -> filter available <$> queryUTxOs prov addr
    }
  where
    available (i, out) = i `notElem` reserved
        && out ^. referenceScriptTxOutL == SNothing
        && (let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL in Map.null assets)

-- | Fund exactly the requested actors, then return the confirmed output references.
fundLifecycle :: Provider IO -> Submitter IO -> PParams ConwayEra -> [TxOut ConwayEra] -> IO [(TxIn, TxOut ConwayEra)]
fundLifecycle prov submit pp outs = do
    wallet <- queryUTxOs (fundingProvider [] prov) funderAddr
    let ordinary = sortOn (Down . (^. coinTxOutL) . snd) wallet
        Coin available = foldMap ((^. coinTxOutL) . snd) ordinary
        Coin need = fundingRequirement pp outs
        pick :: Integer -> [(TxIn, TxOut ConwayEra)] -> [(TxIn, TxOut ConwayEra)]
        pick _ [] = []
        pick remaining (u@(_, o) : rest)
            | remaining <= 0 = []
            | otherwise = u : pick (remaining - (let Coin c = o ^. coinTxOutL in c)) rest
    putStrLn ("lifecycle funding: requirement " <> show need <> " lovelace; spendable " <> show available <> " lovelace (reference publications excluded)")
    unless (available >= need) $ fail ("lifecycle funding: requires " <> show need <> " lovelace, available " <> show available)
    let inputs = pick need ordinary
        draft = mkBasicTx (mkBasicTxBody & outputsTxBodyL .~ StrictSeq.fromList outs)
    unsigned <- either (fail . show) (pure . balancedTx) (balanceTx pp inputs [] funderAddr draft)
    let signed = addKeyWitness funderSignKey unsigned
    submitTx submit signed >>= \result -> case result of
        Submitted _ -> pure ()
        Rejected reason -> fail ("lifecycle funding rejected: " <> show reason)
    awaitTx signed
    putStrLn ("lifecycle funding confirmed: " <> show (txIdTx signed))
    pure [(TxIn (txIdTx signed) (TxIx (fromIntegral i)), o) | (i, o) <- zip [(0 :: Int) ..] outs]

checkExecutionLimit :: ExUnits -> [ExUnits] -> Either String ExUnits
checkExecutionLimit (ExUnits maxMem maxSteps) costs =
    let total@(ExUnits mem steps) = foldl add (ExUnits 0 0) costs
        add (ExUnits a b) (ExUnits c d) = ExUnits (a + c) (b + d)
     in if mem <= maxMem && steps <= maxSteps
            then Right total
            else
                Left
                    ( "lifecycle execution limit: requires memory="
                        <> show mem
                        <> ", steps="
                        <> show steps
                        <> "; live transaction limit memory="
                        <> show maxMem
                        <> ", steps="
                        <> show maxSteps
                    )

{- | Evaluate before signing, replace every declared budget with the node's
measured cost, and charge the actual fee from the final change output only.
Re-evaluate the final fee/body until both budgets and fee are stable.
-}
prepareLifecycleTx :: Bool -> Provider IO -> PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> Int -> ConwayTx -> IO ConwayTx
prepareLifecycleTx False _ _ _ _ tx = pure tx
prepareLifecycleTx True prov pp refs witnesses initial = go (4 :: Int) initial
  where
    go 0 _ = fail "lifecycle evaluation and fee did not converge"
    go rounds tx = do
        measured <- evaluateTx prov tx
        let Redeemers original = tx ^. witsTxL . rdmrsTxWitsL
        unless (Map.keysSet measured == Map.keysSet original) $ fail "lifecycle evaluation did not cover every redeemer"
        costs <- traverse (either (fail . ("lifecycle evaluation refused: " <>) . show) pure) measured
        total <- either fail pure (checkExecutionLimit (pp ^. ppMaxTxExUnitsL) (Map.elems costs))
        let patched = Redeemers (Map.mapWithKey (\purpose (dat, _) -> (dat, costs Map.! purpose)) original)
            evaluated =
                tx
                    & witsTxL . rdmrsTxWitsL .~ patched
                    & bodyTxL . scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp patched
            Coin oldFee = tx ^. bodyTxL . feeTxBodyL
            outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
        (fixed, change) <- case reverse outputs of
            lastOut : rest -> pure (reverse rest, lastOut)
            [] -> fail "lifecycle balancing needs a final change output"
        let Coin oldChange = change ^. coinTxOutL
            mkOutputs (Coin fee) =
                let adjusted = change & coinTxOutL .~ Coin (oldChange + oldFee - fee)
                 in if adjusted ^. coinTxOutL < getMinCoinTxOut pp adjusted
                        then Left "lifecycle change cannot cover the evaluated fee and minimum UTxO"
                        else Right (StrictSeq.fromList (fixed ++ [adjusted]))
        balanced <- either (fail . show) pure (balanceFeeLoop pp mkOutputs witnesses refs evaluated)
        if patched == (tx ^. witsTxL . rdmrsTxWitsL)
            && balanced ^. bodyTxL . feeTxBodyL == tx ^. bodyTxL . feeTxBodyL
            then do
                putStrLn ("lifecycle evaluated: " <> show total <> "; fee=" <> show (balanced ^. bodyTxL . feeTxBodyL))
                pure balanced
            else go (rounds - 1) balanced

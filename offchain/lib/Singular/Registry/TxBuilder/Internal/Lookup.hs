{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.TxBuilder.Internal.Lookup
Description : UTxO lookup, balancing, script integrity and time helpers
License     : Apache-2.0

One owner for where a builder finds its inputs and closes its
transaction: UTxO lookup by input, state and request
('findUtxoByTxIn', 'findStateUtxo', 'findRequestUtxos'), spending-index
computation, script evaluation and balancing ('evaluateAndBalance'),
script-integrity hashing, rejected-row refund outputs
('computeRefund'), and POSIX-time to slot conversion
('currentPosixMs', 'trySlots').

This is the lookup-and-balance owner extracted from
@Singular.Registry.TxBuilder.Internal@; the public module re-exports
it and is its only intended consumer surface.
-}
module Singular.Registry.TxBuilder.Internal.Lookup (
    -- * UTxO lookup
    findUtxoByTxIn,
    findStateUtxo,
    findRequestUtxos,

    -- * Indexing
    spendingIndex,

    -- * Script integrity
    computeScriptIntegrity,

    -- * Evaluate and balance
    evaluateAndBalance,
    placeholderExUnits,

    -- * Time and slot helpers
    currentPosixMs,
    trySlots,

    -- * Refund computation
    computeRefund,
) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.PParams (
    LangDepView,
    getLanguageView,
 )
import Cardano.Ledger.Alonzo.Tx (
    ScriptIntegrity (..),
    ScriptIntegrityHash,
    hashScriptIntegrity,
 )
import Cardano.Ledger.Alonzo.TxBody (
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Alonzo.TxWits (
    Redeemers (..),
    TxDats (..),
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    rdmrsTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network,
    StrictMaybe (..),
 )
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (Language (PlutusV3))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Balance (
    BalanceResult (..),
    balanceTx,
 )
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (SomeException, try)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PParams,
    TokenId (..),
 )
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.Internal.Identity (
    addrFromKeyHashBytes,
    extractCageDatum,
    extractOwnerBytes,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainRequest (..),
    OnChainTokenId (..),
 )

{- | Placeholder execution units used in the initial
unbalanced transaction.
-}
placeholderExUnits :: ExUnits
placeholderExUnits = ExUnits 0 0

{- | Evaluate script execution units and balance
a transaction.
-}
evaluateAndBalance ::
    Provider IO ->
    PParams ConwayEra ->
    -- | All input UTxOs (fee + script)
    [(TxIn, TxOut ConwayEra)] ->
    -- | Change address
    Addr ->
    -- | Unbalanced tx with placeholder ExUnits
    ConwayTx ->
    IO ConwayTx
evaluateAndBalance prov pp inputUtxos changeAddr tx =
    do
        let existingIns =
                tx ^. bodyTxL . inputsTxBodyL
            allIns =
                foldl
                    ( \s (tin, _) ->
                        Set.insert tin s
                    )
                    existingIns
                    inputUtxos
            txForEval =
                tx
                    & bodyTxL . inputsTxBodyL
                        .~ allIns
        evalResult <- evaluateTx prov txForEval
        let failures =
                [ (p, e)
                | (p, Left e) <-
                    Map.toList evalResult
                ]
        if null failures
            then pure ()
            else
                error $
                    "evaluateAndBalance: \
                    \script eval failed: "
                        <> show failures
        let
            Redeemers rdmrMap =
                tx ^. witsTxL . rdmrsTxWitsL
            patched =
                Map.mapWithKey
                    ( \purpose (dat, eu) ->
                        case Map.lookup
                            purpose
                            evalResult of
                            Just (Right eu') ->
                                (dat, eu')
                            _ -> (dat, eu)
                    )
                    rdmrMap
            newRedeemers = Redeemers patched
            integrity =
                computeScriptIntegrity
                    pp
                    newRedeemers
            patched' =
                tx
                    & witsTxL . rdmrsTxWitsL
                        .~ newRedeemers
                    & bodyTxL
                        . scriptIntegrityHashTxBodyL
                        .~ integrity
        case balanceTx
            pp
            inputUtxos
            []
            changeAddr
            patched' of
            Left err ->
                error $
                    "evaluateAndBalance: "
                        <> show err
            Right br -> pure (balancedTx br)

-- | Find a UTxO by its 'TxIn'.
findUtxoByTxIn ::
    TxIn ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, TxOut ConwayEra)
findUtxoByTxIn needle =
    find' (\(tin, _) -> tin == needle)
  where
    find' _ [] = Nothing
    find' p (x : xs)
        | p x = Just x
        | otherwise = find' p xs

-- | Find the state UTxO for a token.
findStateUtxo ::
    PolicyID ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, TxOut ConwayEra)
findStateUtxo policyId tid = find' isState
  where
    assetName = unTokenId tid
    isState (_, txOut) =
        case txOut ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                case Map.lookup policyId ma of
                    Just assets ->
                        Map.member assetName assets
                    Nothing -> False
    find' _ [] = Nothing
    find' p (x : xs)
        | p x = Just x
        | otherwise = find' p xs

-- | Find all request UTxOs for a token.
findRequestUtxos ::
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    [(TxIn, TxOut ConwayEra)]
findRequestUtxos tid = filter isRequest
  where
    targetName = unTokenId tid
    isRequest (_, txOut) =
        case extractCageDatum txOut of
            Just (RequestDatum req) ->
                let OnChainRequest
                        { requestToken =
                            OnChainTokenId
                                (BuiltinByteString bs)
                        } = req
                 in AssetName (SBS.toShort bs)
                        == targetName
            _ -> False

-- | Compute the spending index of a 'TxIn'.
spendingIndex :: TxIn -> Set.Set TxIn -> Word32
spendingIndex needle inputs =
    let sorted = Set.toAscList inputs
     in go 0 sorted
  where
    go _ [] =
        error "spendingIndex: TxIn not in set"
    go n (x : xs)
        | x == needle = n
        | otherwise = go (n + 1) xs

-- | Compute the 'ScriptIntegrityHash'.
computeScriptIntegrity ::
    PParams ConwayEra ->
    Redeemers ConwayEra ->
    StrictMaybe ScriptIntegrityHash
computeScriptIntegrity pp rdmrs =
    let langViews :: Set.Set LangDepView
        langViews =
            Set.singleton
                (getLanguageView pp PlutusV3)
        emptyDats :: TxDats ConwayEra
        emptyDats = TxDats mempty
     in SJust
            ( hashScriptIntegrity
                (ScriptIntegrity rdmrs emptyDats langViews)
            )

-- | Get current POSIX time in milliseconds.
currentPosixMs :: IO Integer
currentPosixMs = do
    t <- getPOSIXTime
    pure $ floor (t * 1000)

{- | Try converting successive POSIX ms values to
slots, returning the first that succeeds.
-}
trySlots ::
    Provider IO -> [Integer] -> IO SlotNo
trySlots _ [] =
    error
        "posixMsToSlot: all fallbacks \
        \past horizon"
trySlots p (ms : rest) = do
    r <-
        try @SomeException
            (posixMsCeilSlot p ms)
    case r of
        Right s -> pure s
        Left _ -> trySlots p rest

{- | Compute a rejected row's refund output (NOTE-014 item A2, delegated
routing): exactly `input lovelace − tip`, floored at min-UTxO with the
top-up funded visibly. No fee share is deducted here and none is
invented (fees ride funding inputs; the validator pins per-owner floors
and exact lock accumulation instead of an aggregate envelope). THE shared
helper for every rejected-refund emission — `Reject` and manual paths
call it; processed rows emit no refunds at all (their bond locks).
-}
computeRefund ::
    PParams ConwayEra ->
    Network ->
    Integer ->
    TxOut ConwayEra ->
    TxOut ConwayEra
computeRefund pp net tipAmount reqOut =
    let Coin reqVal = reqOut ^. coinTxOutL
        rawRefund =
            Coin (reqVal - tipAmount)
        refundAddr =
            addrFromKeyHashBytes
                net
                (extractOwnerBytes reqOut)
        draft =
            mkBasicTxOut
                refundAddr
                (inject rawRefund)
        minCoin = getMinCoinTxOut pp draft
     in mkBasicTxOut
            refundAddr
            (inject (max rawRefund minCoin))
